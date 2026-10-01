# Suggestions

Candidates found by scanning the current Neovim/r-neovim ecosystem (2026) and
cross-checking against what this config already runs — not a generic
"trending plugins" list, only things that address a real, identifiable gap or
pain point already present here. None of these are implemented; this is a
shortlist to decide against, in priority order.

## 1. `saghen/blink.cmp` — replace `nvim-cmp`

**Gap it closes:** `lua/plugins/lsp.lua`'s `nvim-cmp` setup already has a
comment documenting the problem this would fix — ts_ls returns ~1000
completion items for a bare cursor and cssls ~890 (measured), and cmp sorts
and renders the whole set through 10 comparators on every keystroke. The
current `performance` block (`debounce = 20, throttle = 10, max_view_entries
= 25`) is a workaround that caps the *view* — it doesn't touch the per-
keystroke sort/match cost itself, which stays in Lua.

blink.cmp does fuzzy matching and sorting in a native (Rust) matcher instead
of Lua, so the cost this config is working around goes away rather than
being capped. It's the completion engine most of the ecosystem has moved
toward as of 2026, with built-in LSP/cmdline/signature-help/snippet sources
comparable to nvim-cmp's.

**Trade-off:** different config surface entirely (`opts.sources`,
`opts.keymap`, its own fuzzy-matching options) — not a drop-in, a real
migration. The custom `<CR>`/`<Tab>`/`<S-Tab>` mapping logic in
`lua/plugins/lsp.lua` (confirm-only-on-explicit-select, luasnip
jump-vs-indent disambiguation) would need to be re-derived for blink's
mapping API, not copy-pasted.

**Worth doing if:** completion still feels laggy in Java/TS files day to day
despite the current tuning.

## 2. `coder/claudecode.nvim` — replace the custom Claude bridge

**Gap it closes:** this config's AI integration (`lua/claude_cli.lua` +
`mcp/nvim_context_server.py`) bridges to the `claude` CLI by writing files to
disk and polling for changes (`:checktime` on `FocusGained`/`BufEnter`/
`CursorHold`/`TermLeave`). That disk-write-plus-poll architecture is the
root cause of more than one bug chased in this repo's history:
`didClose`/`didOpen` reload cycles from external edits forcing jdtls to fully
discard and rebuild a file's compilation unit, and — more concretely — the
jdtls folding-range crash fixed in commit `fc6fe4c`, which was reachable
precisely because a reload could race an in-flight LSP request.

`claudecode.nvim` implements the actual WebSocket-based MCP "IDE companion"
protocol that ships with Claude Code and that the official VS Code/JetBrains
extensions use: Claude reads the live buffer/selection/diagnostics directly
over the socket and can show diffs inline, with no file written to disk and
nothing to poll. That's not a tuning change to the existing bridge, it
removes the mechanism that caused the bugs.

**Trade-off:** this would replace `claude_cli.lua` and
`mcp/nvim_context_server.py` outright rather than extend them, and it adds a
dependency on `folke/snacks.nvim` (not currently in this config, see #3).
The custom panel's specific behavior documented in `claude_cli.lua` —
streamed responses, visual-selection sending via `getregion()`, the
50ms-throttled append-only render — would need to be checked against what
claudecode.nvim already provides before assuming it's a strict upgrade with
no regressions.

**Worth doing if:** willing to retire the custom bridge in favor of a
maintained implementation of the real protocol.

## 3. `folke/snacks.nvim` — consolidate small utility plugins

**Gap it closes:** this config already depends on five other folke plugins
(`flash.nvim`, `persistence.nvim`, `todo-comments.nvim`, `trouble.nvim`,
`which-key.nvim`). `snacks.nvim` is his newer all-in-one utility collection;
individual modules could replace single-purpose plugins currently pulled in
separately — `snacks.indent` for `lukas-reineke/indent-blankline.nvim`,
`snacks.notifier` for `rcarriga/nvim-notify`, `snacks.bigfile` for handling
pathologically large files (not currently handled at all).

**Trade-off:** lowest-stakes item here — no bug or measured pain point behind
it, just fewer total dependencies under one more actively maintained author/
project. Also the dependency `coder/claudecode.nvim` (#2) would pull in on
its own if that one is adopted.

**Worth doing if:** picked up as a side effect of adopting #2, or purely as
housekeeping — not worth a dedicated migration on its own.

## Deliberately not suggested

AI-coding plugins that dominate most "new Neovim plugins 2026" lists —
`avante.nvim`, `codecompanion.nvim`, `gen.nvim` — are skipped here. This
config already has a bespoke Claude integration; #2 above is the relevant
upgrade path for that specific niche, not a generic chat-in-editor plugin
layered on top of it.
