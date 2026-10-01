# Suggestions

Candidates found by scanning the current Neovim ecosystem (2026) and
cross-checking against what this config already runs — not a generic "trending
plugins" list, only things that address a real, identifiable gap already present
here.

**Status: researched and measured, 2026-09-30.** The first version of this file
argued three cases from reading the code. Two of the three premises did not
survive being measured, and the numbers also turned up a much larger win that was
not on the list at all. This file is now the decision record rather than the
shortlist; the original arguments are kept alongside what was wrong with them,
because the reasoning is the part worth not repeating.

| # | Candidate | Verdict |
|---|-----------|---------|
| 1 | `saghen/blink.cmp` | **Deferred.** The Lua matcher it replaces is ~1-2ms of a ~70ms round trip. |
| 2 | `coder/claudecode.nvim` | **Branch trial only.** Real upside, but the case made for it here rested on three claims that are not true of this code. |
| 3 | `folke/snacks.nvim` | **Declined as a swap; the one real gap in it is closed in-tree.** Large-file handling now lives in `lua/config/bigfile.lua`. |

## What was actually slow

Measured on this machine before any of the above was considered, because none of
the three candidates turned out to be where the time was going.

**Startup — the big one, and it was not a plugin choice.** 27 of 49 top-level
plugin specs had no lazy-load trigger and were loaded during startup, with
`init.lua` alone accounting for ~275ms of a 285-447ms boot. Telescope was the
single most expensive (~30ms of `require`s) and nothing needs it until a finder is
opened. Giving every spec a real trigger (`event`/`cmd`/`ft`/`keys`, or `lazy =
true` where another module's `require` is already the trigger) took that from 27
start plugins to 1 — the colorscheme:

| | before | after |
|---|---|---|
| `nvim` (no file) | 334ms | **31ms** |
| `nvim Play.java` | 541ms | **318ms** |

Minimum of 9 runs each, interleaved so both sides saw the same machine load.

**Completion latency — where the remaining time goes.** Per keystroke, against a
real Spring Boot project:

| component | cost |
|---|---|
| this config's `debounce` + `throttle` | 30ms (deliberate) |
| jdtls round trip, member access | median 27.6ms (13.6-94.3) |
| jdtls round trip, bare cursor | median 41.4ms (29.0-69.9) |
| nvim-cmp filtering + sorting, 1000 items | 0.8-1.9ms |

(`cmp.visible()` is always false headless — see `tests/README.md` — so cmp's cost
was measured by driving `source:get_entries` and the comparator chain directly on
real `cmp.Entry` objects. First completion after jdtls attaches is ~978ms, which
is the server indexing, not the editor.)

## 1. `saghen/blink.cmp` — replace `nvim-cmp`

**Deferred.** The premise does not hold.

The original argument: ts_ls returns ~1000 completion items for a bare cursor and
cssls ~890, cmp sorts and renders the whole set through its comparators on every
keystroke, and `max_view_entries = 25` only caps the *view* — so the per-keystroke
sort/match cost stays in Lua, and blink's native Rust matcher would remove it.

Every factual part of that is right, including the detail that `max_view_entries`
caps rendering only: `cmp/view.lua` sorts the full candidate set and *then* slices
to that number. (The `nvim-cmp` comment in `lua/plugins/lsp.lua` claimed this
saved ~8x of per-keystroke work; it does not, and that comment has been
corrected.)

What's wrong is the conclusion. Measured, that Lua cost is 0.8-1.9ms out of a
~70ms keystroke-to-menu budget — about 3%. blink advertises a 0.5-4ms matcher,
which means cmp's Lua matcher is already *inside* blink's own advertised range.
The migration is real work (different config surface; the custom
`<CR>`/`<Tab>`/`<S-Tab>` logic in `lua/plugins/lsp.lua` would have to be
re-derived rather than copied) in exchange for a few milliseconds nobody can
perceive.

**Revisit if:** the server round trip stops being the dominant term — i.e. a
local, fast source becomes the common case rather than jdtls/ts_ls.

## 2. `coder/claudecode.nvim` — replace the custom Claude bridge

**Branch trial only, not a planned migration.** The upside is genuine:
`claudecode.nvim` implements the WebSocket MCP "IDE companion" protocol that ships
with Claude Code and that the official VS Code/JetBrains extensions use, so Claude
reads the live buffer, selection and diagnostics over a socket, with inline diffs.
Against a maintained implementation of the real protocol, a bespoke bridge is a
maintenance liability regardless of how well it works.

But the case originally made for it here rested on three claims that are not true
of this code, and they are worth recording so the trial is judged on its merits:

1. **"Writes files to disk and polls for changes (`:checktime` on
   `FocusGained`/`BufEnter`/`CursorHold`/`TermLeave`)."** The bridge's
   `write_context()` (`lua/claude_cli.lua`) writes three lines of *metadata* —
   `File:`, `Language:`, `Line:` — not buffer contents. And the `:checktime`
   autocmds are `config.autocmds`' `auto_reload` group, which exists for external
   edits by *anything* (git, a formatter, another editor) and predates the bridge.
   `claude_cli.lua` itself notes that its own 2s polling timer was removed, and
   why. There is no bridge-specific poll to remove.
2. **"The jdtls folding-range crash fixed in commit `fc6fe4c` was reachable
   because a reload could race an in-flight LSP request."** `fc6fe4c` is the spec
   for that fix; the routing change was `7217125`. More importantly the underlying
   JDT-core Scanner bug is document-dependent, not a race — it reproduces from the
   document's own content, with no reload involved. Removing the disk round trip
   would not have prevented it.
3. **"Adds a dependency on `folke/snacks.nvim`."** Optional. Its terminal
   providers are `snacks`, `native`, `external`, `custom` and `none`.

**Worth doing if:** a trial branch shows claudecode.nvim already covers what the
custom panel documents it does — streamed responses, visual-selection sending via
`getregion()`, the 50ms-throttled append-only render — rather than assuming a
strict upgrade.

## 3. `folke/snacks.nvim` — consolidate small utility plugins

**Declined as a swap. The one real gap it named is now closed in-tree.**

Of the three modules suggested, two were pure housekeeping with no pain point
behind them (`snacks.indent` for `indent-blankline.nvim`, `snacks.notifier` for
`nvim-notify`) — both are working, configured, and lazy-loaded; swapping them buys
nothing.

The third was a real finding: `snacks.bigfile`, for "handling pathologically large
files (not currently handled at all)". Nearly right — there *was* exactly one size
guard, on treesitter highlighting in `lua/config/autocmds.lua`, and nothing else
was bounded. Adding a new dependency for one module to fix it was the wrong shape
when the guard already existed and needed extending, so instead `lua/config/bigfile.lua`
now owns the thresholds and the opt-outs:

- Two tiers, not one. The decoration tier (10k lines / 512KB) drops treesitter,
  indent guides, colour swatches and fold providers, and bounds `synmaxcol`. The
  LSP tier is deliberately far higher (40k lines / 4MB) and *notifies* when it
  fires, because a 10k-line Java class is an ordinary thing to find and silently
  detaching its language server is indistinguishable from completion being broken.
- Regex syntax stays on. It is what keeps a large file readable and is not re-run
  per keystroke; the pathological case is the regex engine on one enormous minified
  line, which `synmaxcol` bounds directly.
- vim-illuminate uses its own `large_file_cutoff`/`large_file_overrides` instead,
  reading the same threshold — it can keep the cheap LSP provider and drop only the
  two that re-scan the buffer locally.

**Worth revisiting if:** #2 is adopted *and* its snacks terminal provider turns out
to be the one worth using — then the other modules come along for free and the
housekeeping argument gets stronger.

## Deliberately not suggested

AI-coding plugins that dominate most "new Neovim plugins 2026" lists —
`avante.nvim`, `codecompanion.nvim`, `gen.nvim` — are skipped here. This config
already has a bespoke Claude integration; #2 above is the relevant upgrade path
for that specific niche, not a generic chat-in-editor plugin layered on top of it.
