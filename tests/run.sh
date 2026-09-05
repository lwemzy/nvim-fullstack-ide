#!/usr/bin/env bash
# Test runner for this Neovim config.
#
#   tests/run.sh                 # unit + integration
#   tests/run.sh unit            # fast, no plugins, no language servers
#   tests/run.sh integration     # boots the real config
#   tests/run.sh unit jdk        # only specs whose path matches "jdk"
#   NVIM_IDE_TEST_SLOW=1 tests/run.sh integration   # include jdtls specs
#
# One nvim process per spec file. Isolation is the reason: these specs install
# autocmds, replace vim.lsp handlers and start LSP clients, and a spec that
# leaked any of that into the next file would make failures depend on file
# order. Per-file processes also mean one hung server cannot take the suite
# down with it.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

SUITE="${1:-all}"
PATTERN="${2:-}"

NVIM="${NVIM_TEST_BIN:-nvim}"
: "${NVIM_IDE_TEST_TIMEOUT:=180}"

# 0.12's LSP APIs (vim.lsp.config, in-process cmd functions, inlay-hint
# capability framework) are load-bearing for these specs.
if ! "$NVIM" --version | head -1 | grep -qE 'NVIM v0\.(1[2-9]|[2-9][0-9])'; then
  echo "warning: these specs target Neovim 0.12+, found: $("$NVIM" --version | head -1)" >&2
fi

if [ ! -d "$(nvim --headless -c 'lua io.write(vim.fn.stdpath("data"))' -c 'qa!' 2>/dev/null)/lazy/plenary.nvim" ]; then
  echo "error: plenary.nvim not installed (it is a telescope dependency)." >&2
  echo "       run :Lazy sync once, then re-run the tests." >&2
  exit 2
fi

# Run "$@" and SIGTERM it after $1 seconds, leaving $TIMEOUT_MARKER behind if it
# had to.
#
# Not a nicety: headless nvim still stops on interactive prompts (`:w` on a file
# that changed on disk asks W12/"write anyway?"), and because output is captured
# per file, a spec that trips one produces no output at all and hangs the whole
# run until someone notices. macOS ships no timeout(1), hence the watchdog.
#
# The marker rather than the exit status: nvim catches SIGTERM and exits 1, which
# is indistinguishable from an ordinary failing assertion. The watchdog's stdout
# goes to /dev/null so it cannot hold the command-substitution pipe open after
# the real process is done.
TIMEOUT_MARKER="$(mktemp -u "${TMPDIR:-/tmp}/nvim-ide-test-timeout.XXXXXX")"

run_limited() {
  local secs="$1"; shift
  rm -f "$TIMEOUT_MARKER"
  "$@" &
  local pid=$!
  ( sleep "$secs"; touch "$TIMEOUT_MARKER"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid"; local rc=$?
  kill -TERM "$watchdog" >/dev/null 2>&1
  return "$rc"
}

trap 'rm -f "$TIMEOUT_MARKER"' EXIT

collect() {
  local dir="$1"
  [ -d "$ROOT/tests/$dir" ] || return 0
  find "$ROOT/tests/$dir" -name '*_spec.lua' | sort
}

FILES=""
case "$SUITE" in
  unit)        FILES="$(collect unit)" ;;
  integration) FILES="$(collect integration)" ;;
  all)         FILES="$(collect unit)
$(collect integration)" ;;
  *)
    echo "usage: tests/run.sh [unit|integration|all] [pattern]" >&2
    exit 2
    ;;
esac

if [ -n "$PATTERN" ]; then
  FILES="$(printf '%s\n' "$FILES" | grep -- "$PATTERN")"
fi
FILES="$(printf '%s\n' "$FILES" | sed '/^$/d')"

if [ -z "$FILES" ]; then
  echo "no spec files matched" >&2
  exit 2
fi

passed=0
failed=0
skipped=0
failed_files=()

while IFS= read -r file; do
  rel="${file#"$ROOT"/}"
  case "$rel" in
    # No --noplugin for integration: it clears 'loadplugins', and lazy.setup()
    # returns immediately when that is off (lazy/init.lua:50), so the whole
    # plugin spec would silently never be parsed.
    tests/integration/*) init="tests/full_init.lua"; flags="" ;;
    # Unit specs never touch lazy, so skipping runtime plugin scripts is free
    # isolation: a passing unit spec cannot be relying on one.
    *)                   init="tests/minimal_init.lua"; flags="--noplugin" ;;
  esac

  printf '\n\033[1m── %s\033[0m (%s)\n' "$rel" "${init#tests/}"

  # `Ncq` from plenary.busted is how a headless run reports its result, so the
  # exit status is the source of truth here, not the printed output.
  out=$(cd "$ROOT" && run_limited "$NVIM_IDE_TEST_TIMEOUT" \
        "$NVIM" --headless $flags -u "$init" \
        -c "lua require('plenary.busted').run('$file')" 2>&1)
  status=$?
  if [ -e "$TIMEOUT_MARKER" ]; then
    status=1
    out="$out
TIMEOUT: killed after ${NVIM_IDE_TEST_TIMEOUT}s (raise with NVIM_IDE_TEST_TIMEOUT).
Usually an interactive prompt — headless nvim still waits on one, and prints
nothing while it does. \`:w\` on a file changed on disk (W12) is the common cause;
use \`:w!\` or assert on the ex-command with H.capture_ex instead."
  fi

  # nvim writes progress messages without trailing newlines, which run into the
  # spec output; \r -> \n keeps the report readable.
  clean=$(printf '%s\n' "$out" | tr '\r' '\n')
  printf '%s\n' "$clean" | sed '/^$/d;s/^/  /'

  # H.skip() returns early from a spec that plenary then still prints as
  # Success, so the pass count alone cannot distinguish "asserted" from "not
  # run because the tool is missing". Surfacing the total keeps that honest.
  n_skipped=$(printf '%s\n' "$clean" | grep -c '^SKIP: ' || true)
  skipped=$((skipped + n_skipped))

  if [ "$status" -eq 0 ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failed_files+=("$rel (exit $status)")
  fi
done <<< "$FILES"

echo
echo "════════════════════════════════════════════════════════"
printf 'spec files: %d passed, %d failed\n' "$passed" "$failed"
if [ "$skipped" -gt 0 ]; then
  printf 'skipped assertions: %d (missing tool/parser/JDK — see SKIP: lines)\n' "$skipped"
fi
if [ "$failed" -gt 0 ]; then
  printf '\nfailed:\n'
  for f in "${failed_files[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
