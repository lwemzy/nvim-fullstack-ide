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
| 4 | `antosha417/nvim-lsp-file-operations` | **Adopted.** jdtls does implement `willRename` — but only if the client asks, which this config did not. Needed one thing the plugin does not do: writing the edits to disk. Fixes file and package-directory renames; a single-file move across packages is a jdtls gap. |
| 5 | `Rahularya01/tether.nvim` | **Researched, not yet trialed.** A second, newer candidate for the same slot as #2 — same IDE protocol, plus edits land as an explicit accept/reject diff instead of writing straight to disk. |
| 6 | `janbuchar/difftsigns.nvim` | **Researched, not yet trialed.** Small `gitsigns.nvim` complement — dims pure-reformat noise in the gutter using difftastic. |
| 7 | `Mestane/blink-cmp-deps` | **Not actionable now.** Maven/Gradle coordinate completion, but it's a `blink.cmp` source, and #1 is deferred. |
| 8 | Build output → quickfix (SpaceVim `problemMatcher`) | **Adopted.** `lua/config/problems.lua`, on `<M-q>`. Error formats are Neovim's own from `$VIMRUNTIME/compiler`, not hand-written. Needed a dedup nobody would predict: Gradle prints each javac error twice. |
| 9 | jdtls `source.generate.*` keymaps (SpaceVim `SPC l g`) | **Adopted.** Nine keys under `<leader>jg`, all verified against a running jdtls. Getters/setters needed the handler nvim-jdtls is missing (`lua/config/java_source.lua`). |
| 10 | Alternate file, class ↔ test (SpaceVim `a.vim`) | **Adopted.** `lua/config/alternate.lua`, on `<leader>fa` and `:A`. Not `<M-o>` — neotest already owns it, silently. |
| 11 | `Trouble symbols` outline sidebar (SpaceVim `tagbar`) | **Adopted.** One keymap, `<leader>lo`, gated on `textDocument/documentSymbol`. No new plugin. |
| 12 | Task picker with auto-detection (SpaceVim tasks) | **Adopted.** `lua/config/tasks.lua`, on `<leader>rt`. Gradle discovery is async with an on-disk cache keyed on the build files, as the condition below required. |
| 13 | `mbbill/undotree` | **Adopted.** `cmd`-triggered, `<leader>uu`. `g:undotree_*` in `init`, not `config` — the vimscript plugin reads them at source time. |

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

**What that table does and does not measure.** It is `nvim --headless
--startuptime`, read at the `editing files in windows` line — startup up to the
first paint. Headless never fires `UIEnter`, so it never fires `VeryLazy` either,
and the `VeryLazy` burst is where 23 of the now-lazy plugins actually load
(lualine, bufferline, which-key, notify, surround, mason-tool-installer and the
rest). Measured separately in a real TTY, minimum of 5 runs:

| | min | typical |
|---|---|---|
| to `UIEnter` (first paint) | 74ms | 105-160ms |
| to the `VeryLazy` burst finishing | ~230ms | 330-460ms |

So the honest claim is that the editor *appears* in ~31-74ms instead of ~334ms,
and is fully furnished at ~230ms instead of ~334ms. The first number is the one
that changes how starting the editor feels; the second is why the win is ~1.5x
rather than ~10x. Both are improvements and only the first is dramatic — quoting
31ms on its own would be measuring the part of the work that was moved rather
than the part that was removed.

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

## 4. `antosha417/nvim-lsp-file-operations` — LSP-aware file ops from nvim-tree

**Adopted** (`lua/config/file_ops.lua`, `lua/config/capabilities.lua`). Found
scanning r/neovim's new-plugin feed (2026-10-07). The open question — "jdtls
isn't in the README's tested list" — was settled by reading jdtls's own bytecode
rather than by trialing it, and the answer changed what had to be built.

Subscribes to `nvim-tree.lua`'s file events (create/delete/rename) and
forwards them to attached language servers as the LSP workspace file-operation
notifications (`workspace/willRenameFiles`/`didRenameFiles` and the
create/delete equivalents). Concretely: renaming a `.java` file in the explorer
does not currently touch the class name inside it or any reference to that
class — jdtls only reacts to the content of a `didChange`, not a file move it
wasn't told about. This plugin is the missing notification. Its README lists
rename tested against
lua-language-server, vtsls, basedpyright, metals, rust-analyzer and
typescript-language-server — covering the TS/Angular side of this config too,
though jdtls itself isn't in that tested list.

**What jdtls actually implements** (read out of
`org.eclipse.jdt.ls.core_1.60.0`, since the README could not answer it):
`FileEventHandler.handleWillRenameFiles` → `computeFileRenameEdit` for a file
(rename the type, update every reference) and `computePackageRenameEdit` for a
folder (fix the `package` declarations).

Measured end-to-end against a real gradle project rather than trusted from the
jar, because the three cases do not behave alike:

- **Renaming a `.java` file in place works.** `parts/Widget.java` →
  `parts/Gadget.java` renamed `class Widget` and rewrote the importer's `import`
  and its `new Widget()` — all on disk.
- **Renaming a package directory works.** `parts/` → `widgets/` rewrote
  `package com.example.demo.widgets;` and `import com.example.demo.widgets.Widget;`.
- **Moving a single `.java` file to a different directory does not.**
  `parts/Gadget.java` → `core/Gadget.java` left `package com.example.demo.parts;`
  in place and the importer untouched: jdtls returns no package edit for that
  shape. A server-side gap, not a wiring one — the request goes out with the
  right `oldUri`/`newUri` and comes back empty. So the headline "move across
  packages" case is still broken; rename the directory, or use an LSP code
  action, when that is what you meant.

Two further caveats the jar settled:

- `willRename` is the **only** file operation jdtls has — no create or delete
  handlers exist. Nothing is lost by that: the plugin's other five operations
  are still advertised for the TS/Angular servers, which do implement them.
- `InitHandler` only advertises it behind `isWorkspaceWillRenameFilesSupported`,
  i.e. **only if the client asked first** — and this config asked for neither.
  Capabilities were built in two duplicated places, and jdtls is the one client
  that does not go through `vim.lsp.config("*")` (`ftplugin/java.lua` starts it
  through nvim-jdtls), so the jdtls copy is exactly the one a change like this
  would miss. Hence `lua/config/capabilities.lua`: one table, both call sites.

**What the plugin does not do, and had to be added.** On nvim 0.12.4
`vim.lsp.util.apply_text_edits` `bufload`s each referencing file and edits it in
memory; it never writes. This config's auto-save only writes the *current* buffer
(`FocusLost`/`BufLeave`), so those buffers stay modified and hidden forever — the
imports would be fixed inside nvim while `:Run` and gradle compiled the stale
files on disk. That is the worst available failure mode: the feature looks like
it worked. `lua/config/file_ops.lua` closes it by snapshotting which buffers were
already dirty on `WillRenameNode` and writing only the ones the refactor touched
on `NodeRenamed` — not a blanket `:wall`, since a rename is no reason to write
unrelated work in progress. The write itself is the existing auto-save path
(`lua/config/autosave.lua`, extracted for this), staleness guard included.

The plugin does have an `auto_save` option aimed at the same problem, and it is
off on purpose. It works by replacing `vim.lsp.util.apply_workspace_edit`
globally for the rest of the session, so *every* workspace edit starts
auto-writing — rename symbol, organize-imports, any multi-file code action — and
its write has no equivalent of the `vim.b.autosave_mtime` guard, which is in this
config specifically because a silent write does not suppress the "changed since
reading it" prompt. One write path with one guard was worth ~40 lines.

Also worth recording: `:checkhealth nvim-ide` now reports the negotiated
`workspace.fileOperations.willRename` per client, because that capability is the
single point where the whole feature degrades to silence.

## 5. `Rahularya01/tether.nvim` — second candidate for the Claude bridge slot

**Researched, not yet trialed.** Same source and date as #4. Supersedes #2 as
the one to evaluate first if that slot gets revisited, not an addition
alongside it.

Implements the same WebSocket MCP "IDE companion" protocol as
`coder/claudecode.nvim` (#2) — live buffer/selection/diagnostics, no
`claude_cli.lua`-style bridge — but adds one thing #2 doesn't: edits Claude
proposes land as an explicit diff (`:TetherAccept`/`:TetherReject`) instead of
writing to disk immediately. It's also multi-agent (Gemini CLI, Codex,
OpenCode), which is not a requirement here but costs nothing if unused.

**Worth doing if:** #2's branch trial happens — trial this instead, or
alongside it, before picking one. The diff-review step is a real behavioral
difference from both #2 and the current bridge, not just a reimplementation.

Two frictions found while checking it, so the trial starts informed: its default
review keymaps are `ga` / `gr` / `gc`, which collide with Neovim's built-in `ga`,
this config's `gr` (LSP references) and the `gc` comment operator — all three
need remapping, not just one. And it ships `lazy = false`, which has to be
overridden to keep startup where `## What was actually slow` left it.

## 6. `janbuchar/difftsigns.nvim` — quieter gitsigns gutter

**Researched, not yet trialed.** Same source and date as #4.

Small, standalone complement to `gitsigns.nvim` (already installed, already
configured): uses `difftastic` to recognize pure reformatting/reindentation in
a hunk and dim it in the gutter, so a real change doesn't read as "half the
file changed" after a formatter run. No migration, no config surface overlap
with anything existing.

**Blocked on a binary, not declined on merit.** It needs `difftastic` 0.70 or
0.71 on `PATH` — the version check is pinned to those two releases. `difft` is
not installed here and is **not a mason package**, so mason-tool-installer
cannot fetch it and every machine running this config would need it installed by
hand; absent, the plugin does nothing. It also debounces 400ms per buffer.

**Worth doing if:** `difftastic` becomes something this config can install
itself. Until then the cost is a per-machine manual step for a gutter nicety.

## 7. `Mestane/blink-cmp-deps` — Maven/Gradle completion, blocked on #1

**Not actionable now.** A `blink.cmp` completion source for Maven/Gradle
dependency coordinates in `build.gradle`/`pom.xml` — exactly on-target for
this project's stack, but it's a source, not a standalone plugin, and #1
(`blink.cmp` itself) is deferred. Recorded here so it isn't lost: if #1 is
ever revisited, this is a concrete point in its favor, found after that
verdict was written.

There is an unblocked path to the same capability that does not involve #1:
`lemminx` + lemminx-maven gives `pom.xml` coordinate completion with no blink
anywhere. Noting it because this config currently has **no** XML language server
at all — `emmet_language_server` was extended to the `xml` filetype
(`lua/plugins/lsp.lua`), so what `pom.xml` gets today is HTML tag abbreviations.
That is a separate proposal from this one, and Gradle would still be uncovered.

# Mined from SpaceVim (2026-10-07)

`wsdjeg/SpaceVim` read at `master`. It is a VimL-era distribution — its plugin
list is mostly superseded here (denite, unite, ctrlp, leaderf, neomake, ale,
deoplete, vim-javacomplete2, tagbar, nerdtree), so **none** of its plugin choices
are worth importing. Its *feature* design is a different matter: it has spent a
decade being an IDE for Java and web work specifically, and six of its ideas land
on things this config does not do at all. Those are #8–#13.

Each was checked against the code here before being written down, and two of them
turned up a verified caveat that changes the shape of the work.

## 8. Build output → quickfix — SpaceVim's `problemMatcher`

**Adopted** (`lua/config/problems.lua`, `<M-q>`). Three things the research below
did not anticipate, all found by running it:

* **Gradle prints every javac diagnostic twice** — once as the task's own output
  and again indented two spaces under `* What went wrong:` — and vim's
  errorformat skips leading whitespace, so both copies match. One missing
  semicolon read as "2 problems (2 errors)", the second row with its column two
  further right because the `%p^` caret line is indented with it. `M.parse` now
  dedups on file+line+severity+text, keeping the first (correctly-columned) copy.
* **The output is read from the terminal *buffer* on exit, not through
  `on_stdout`.** The job is a pty, so `on_stdout` delivers ANSI colour, cursor
  moves and Gradle's carriage-return progress bar as raw bytes; libvterm has
  already undone all of that by the time the lines are in the buffer.
* **`getqflist({ lines, efm })` resolves `%f` against Neovim's cwd**, not the
  directory the build ran in, so every relative `tsc` path pointed at the wrong
  file. Fixed with make's own directory-stack convention — a synthetic
  `Entering directory '…'` line prepended to the output.

It also does *not* open the quickfix window: the build's terminal is on screen
and usually focused, and stealing focus out of a terminal mid-keystroke is worse
than a notification naming the key. A clean build clears the list, but only if
the list it would clear is one of its own (title prefix `Build: `) — `grug-far`,
`Telescope quickfix` and `:Trouble qflist` all share that list.

`vim-unstack`'s stack-trace half is **not** done and is still a real gap.

The original case for it:

SpaceVim's task definitions carry a `problemMatcher` — either an `errorformat` or
a `{ regexp, file, line, column, message }` mapping — and the task's output is
parsed through it into the quickfix list (`autoload/SpaceVim/plugins/tasks.vim`,
`.SpaceVim.d/tasks.toml`). It is VSCode's `tasks.json` idea, in Vim.

Here, `lua/config/runner.lua` streams `gradlew bootRun` / `mvn spring-boot:run` /
`npm start` into a toggleterm buffer and that is where it ends. Grepped the whole
of `lua/`: there is no `errorformat`, no `setqflist`, no `copen` anywhere in this
config. So a Java compile error or a `tsc` type error is **text in a terminal** —
readable, not navigable. The IDE move it blocks is the common one: build fails,
jump to the first error, fix, rebuild.

The work: an `errorformat` per target kind in `config.runner` (javac/gradle for
Java, `tsc`'s own for the web targets), parse the terminal job's output into
quickfix, and open it only on a non-zero exit. Two things to get right —
`run_in_terminal` currently owns the output and the scrollback cap it documents,
so the parse has to tee rather than replace; and Gradle interleaves its progress
lines with compiler output, so the matcher needs to be anchored, not greedy.

A near relative worth taking at the same time: SpaceVim bundles `vim-unstack`,
which turns a pasted Java stack trace into jumpable locations. For Spring work
that is the same gap from the other end — a failing test prints a trace into the
terminal and there is no way to jump into it. `nvim-jdtls` already parses JUnit
traces for `test_nearest_method` (`lua/jdtls/junit.lua`), but only for tests it
launched itself; a `gradlew test` run gets nothing.

## 9. jdtls `source.generate.*` — SpaceVim's `SPC l g` "Generate" group

**Adopted** (`lua/config/java_source.lua`, nine keys under `<leader>jg` in
`ftplugin/java.lua`). It was not the cheapest item after all — the accessors
caveat below turned out to need a whole LSP command handler:

* **`java.action.generateAccessorsPrompt` has no handler in nvim-jdtls**, so
  Neovim fell back to sending it to the server as `workspace/executeCommand`,
  which jdtls does not implement for the `*Prompt` commands — they exist
  precisely to hand control back to the client. Getters/setters, the most-wanted
  generator, silently did nothing. `M.setup` registers the missing handler,
  built from the two requests vscode-java uses
  (`java/resolveUnimplementedAccessors` → `AccessorField[]`, then
  `java/generateAccessors` → `WorkspaceEdit`), with the shapes read out of the
  jar rather than copied from vscode-java's TypeScript.
* **No capability change is needed.** `ClientPreferences.isSupportedCodeActionKind`
  is a `startsWith` against the client's `codeActionKind` valueSet, which
  `vim.lsp.protocol.make_client_capabilities()` already fills with `source`.
* **`source.generate.finalModifiers` and `source.sortMembers` look like dead
  keys and are not.** Against a running jdtls they answer with *no action at all*
  in a class with nothing to do, at every cursor position and selection — because
  `CompilationUnitSorter.sort` returns null when sorting would change nothing,
  and Eclipse's comparator orders by *category* (fields, constructors, methods)
  rather than alphabetically, so `void b()` above `void a()` is already sorted.
  Both appear as soon as the file needs them. Neovim itself notifies "No code
  actions available" in the empty case, so nothing here reports it.

All nine kinds were checked against a real jdtls 1.60.0 on a Spring Boot project,
not just against the jar, and `<leader>jga` was confirmed to generate four real
accessors and reach disk.

The original case for it:

SpaceVim's Java layer has a whole `SPC l g` group — generate constructor, default
constructor, `toString`, `equals`/`hashCode`, getters, setters, abstract methods
(`autoload/SpaceVim/layers/lang/java.vim`). It drives it through
`vim-javacomplete2`, which is obsolete. But **jdtls implements all of it**, and
this config binds exactly one of them.

Read out of the installed `org.eclipse.jdt.ls.core_1.60.0` rather than taken from
docs — the source action kinds present in the jar are:

```
source.generate.accessors        source.generate.hashCodeEquals
source.generate.constructors     source.generate.toString
source.generate.delegateMethods  source.overrideMethods
source.generate.finalModifiers   source.sortMembers
source.organizeImports     ← the only one ftplugin/java.lua binds (<F9>)
```

Each is reachable with no plugin at all:

```lua
vim.lsp.buf.code_action({ context = { only = { "source.generate.toString" } }, apply = true })
```

Today these are only reachable by opening `<leader>ca` and reading a list, which
is why they go unused.

**The caveat, verified:** jdtls answers these with a `java.action.*Prompt`
command that the client has to handle, and `nvim-jdtls` registers handlers for
five of the six — `generateToStringPrompt`, `hashCodeEqualsPrompt`,
`generateConstructorsPrompt`, `generateDelegateMethodsPrompt`,
`overrideMethodsPrompt` (`lua/jdtls.lua:801-809`). There is **no**
`generateAccessorsPrompt` handler; grepping the whole plugin for "accessor" finds
only an unrelated stack-trace pattern. So getters/setters — the one a Java
developer reaches for most — is the one that needs a handler written here, or
omitting. Worth knowing before the group gets bound as if it were six for one.

## 10. Alternate file: class ↔ test — SpaceVim's `a.vim`

**Adopted** (`lua/config/alternate.lua`, `<leader>fa` and `:A`). The one thing
worth recording is the key, because it cost a debug run: this was `<M-o>`
("other file") first, and **neotest already owns `<M-o>`** through a lazy `keys`
spec (`lua/plugins/testing.lua`). A lazy `keys` entry creates its stub mapping
when `lazy.setup` runs — *after* `init.lua` has sourced `lua/config/keymaps.lua`
— so the collision silently replaced the mapping with no warning: the key
registered, reported neotest's `desc`, and opened neotest's output panel.
`tests/unit/plugin_specs_spec.lua` now fails on that whole class of collision
rather than leaving it to be noticed.

IntelliJ's own `Ctrl+Shift+T` was rejected up front for a different reason:
Ghostty and most terminal emulators bind it to "new tab" and never forward it.

The original case for it:

SpaceVim ships `:A`, driven by a `.project_alt.json` of glob
patterns with a `{}` capture (`autoload/SpaceVim/plugins/a.vim`), so `:A` jumps
`src/foo.c` ↔ `include/foo.h` and `:A doc` goes somewhere else again.

This config has `neotest` to *run* a test and `telescope` to *find* a file by
name, but no "take me to this class's test" — which in a Maven/Gradle layout is a
pure path transform:

```
src/main/java/com/example/demo/Foo.java  ↔  src/test/java/com/example/demo/FooTest.java
foo.component.ts                          ↔  foo.component.html / .scss
foo.ts                                    ↔  foo.spec.ts
```

~40 lines in a `lua/config/alternate.lua`, no plugin, and the Angular triple is
worth more here than the Java pair: component/template/styles is a three-way jump
that happens constantly and currently needs the file tree. SpaceVim's generalised
JSON config is more than is needed — the three transforms above are the config's
actual stack, and a per-project JSON file nobody writes is the usual fate of that
feature.

## 11. `Trouble symbols` — SpaceVim's `tagbar`, with a plugin already installed

**Adopted**, and it did cost exactly one keymap: `<leader>lo` →
`Trouble symbols toggle focus=false win.position=right`, in `lua/plugins/lsp.lua`'s
`on_attach` and gated on the server advertising `textDocument/documentSymbol`
(the same gate as `<leader>ls`), so it is not bound in a buffer where it could
only fail. Verified against a real jdtls: the outline lists the file's symbols,
opens at column 170 of 200 (the right-hand side), and leaves the cursor in the
code.

The original case for it:

SpaceVim's `tagbar` is a persistent
symbol outline. This config has no outline panel — only
`<leader>ls` → `Telescope lsp_document_symbols`, a transient picker, and
`barbecue`/`navic`, which show the path to the cursor rather than the file's
shape. Navigating a 400-line Spring `@RestController` means scrolling.

`folke/trouble.nvim` is already installed here and already `cmd`-triggered, and
`symbols` (`mode = "lsp_document_symbols"`) is one of its built-in modes
(`lua/trouble/config/init.lua:132`). So this is `<leader>o` →
`Trouble symbols toggle focus=false win.position=right` and nothing else —
no new plugin, no startup cost, the trigger it already has. `Trouble lsp` gives a
references/implementations sidebar on the same terms.

## 12. Task picker with auto-detection — SpaceVim's task providers

**Adopted** (`lua/config/tasks.lua`, `<leader>rt`), and the performance condition
below was the design. Gradle discovery runs `tasks --all --console=plain -q`
asynchronously, caches the result on disk under `stdpath("cache")` keyed on a
stamp over `build.gradle`/`settings.gradle`, and is guarded against a second
in-flight run, so three presses start one daemon rather than three. Until the
cache fills, the picker shows a curated list immediately instead of blocking.
Maven's phases are a fixed list and need no discovery; npm reads `package.json`.

Two details found while building it: a subproject task is printed as either
`api:build` or `:api:build` depending on the Gradle version and where the report
was run from, and both are valid to pass back — so the parser accepts a leading
colon. And the picker deliberately does *not* register its runs in the runner's
`jobs` table: a task is a one-shot build, not the long-lived process the
Run/Stop/Restart toolbar owns.

The original case for it:

SpaceVim's task manager takes
*providers*: functions that return discovered tasks. It ships one for npm — parse
`package.json`, turn every entry in `scripts` into a task named `npm:<script>` —
and documents registering more (its example is a `make` provider reading
`Makefile` targets).

`lua/config/runner.lua` already does the harder half of this well: it walks up for
`pom.xml`/`build.gradle`/`package.json`, prefers `mvnw`/`gradlew` over the system
tool, reads the lockfile to pick npm/pnpm/yarn, and detects Spring Boot. What it
deliberately does not do is *enumerate*: it resolves **one** run target and one
debug target, so `npm run build`, `npm run lint`, `gradlew test`,
`mvn dependency:tree` are all unreachable without typing them into a terminal.

The addition is a picker over `config.runner`'s existing detection — every script
in `package.json`, the Maven lifecycle phases, the Gradle tasks — handing the
chosen command to `runner.run_in_terminal`, which already exists. It pairs with #8:
a task that fails should leave a quickfix list.

**The condition** (standing snappiness priority): npm scripts are a file read and
free, but Gradle task discovery means `gradlew tasks --all`, which spins up the
daemon and takes seconds. That has to be cached on disk keyed by `build.gradle`'s
mtime and populated asynchronously, or the picker becomes the slowest key in the
config. Maven's phases are a fixed list and need no discovery at all.

## 13. `mbbill/undotree` — SpaceVim's `vim-mundo` slot

**Adopted** (`lua/plugins/editor.lua`, `<leader>uu`), and it was as small as
advertised. One non-obvious thing: the `g:undotree_*` options go in the spec's
`init`, not its `config`. It is a vimscript plugin and `plugin/undotree.vim`
reads every one of them at source time — lazy sources `plugin/` files *before*
calling `config`, so a `config` function would set them one step too late and
they would be silently ignored. Layout 2 (tree left, diff beneath it) rather
than the default, which splits the diff off the *editing* area and rearranges
the code you are comparing against while you read it.

The original case for it:

`lua/config/options.lua` already sets
`undofile = true` with an `undodir`, so this config persists full undo history
across sessions and then offers no way to look at it — `u`/`<C-r>` walk one
branch of a tree. SpaceVim carries `vim-mundo`/`undotree` for exactly this.
`cmd = "UndotreeToggle"` means it costs nothing until used.

## From SpaceVim, considered and declined

- **`andymass/vim-matchup`.** SpaceVim bundles it for `%` on `if`/`end` and
  HTML tags. Checked: Neovim ships matchit enabled by default — `vim.g.loaded_matchit`
  is `1` in this config with no configuration — so `%` already does the keyword
  and tag jumps. What matchup adds beyond that is *highlighting* the match, which
  runs on `CursorMoved` for every buffer. That is the same cost profile as the
  inlay-hint and illuminate work already tuned here, bought for a cosmetic.

- **Window numbers in the statusline + `SPC 1`…`SPC 9` to jump** (SpaceVim's
  signature window model, with `vim-choosewin`). `lua/config/keymaps.lua` binds
  `<C-h/j/k/l>` to directional window moves. SpaceVim needs numbers *because* it
  leaves directional navigation to raw `<C-w>`; with the directional maps there is
  nothing left for a number to reach faster, and it would mean a statusline
  segment on every redraw.

- **`FlyGrep` / `denite` / `unite` / `ctrlp` / `LeaderF`** — five fuzzy finders
  across the bundle, all predating `telescope` + `telescope-fzf-native`, both
  installed here. `grug-far` covers the project-wide replace that FlyGrep does not.

- **`iedit` mode** (SpaceVim's own simultaneous-editing implementation) —
  `mg979/vim-visual-multi` is installed and does more.

- **`ale` / `neomake`** — external linter frameworks from before LSP. Diagnostics
  come from the servers and `conform` here.

- **`pmd.vim`** — PMD static analysis for Java. A real tool, but it is a linter
  *choice*, not a config idea: it would be an `nvim-lint` entry plus a mason
  package, and jdtls already surfaces ECJ's warnings inline. Separate proposal.

- **`repl.vim` + `SPC l s` send-to-REPL** (jshell for Java) — marginal for Spring
  work, where the unit of iteration is a test or a `bootRun` restart, both of
  which the toolbar already has.

- **The layer system itself** (`.SpaceVim.d/init.toml`, `SpaceVim#layers#load`) —
  enable/disable feature groups by name. The equivalent here is lazy.nvim's spec
  files plus their load triggers, which is the same idea with per-plugin
  granularity and a lazy-loading story SpaceVim does not have.

## Measured and rejected

Small optimisations that looked right on paper and did not survive a measurement.
Recorded so they do not get re-proposed.

- **Caching the on-disk size in a buffer variable so `config.bigfile` stats a file
  once per open instead of two or three times.** `vim.fn.getfsize` costs 1.9µs
  here (10,000 calls, warm page cache — the file was just read), against 0.026µs
  for `nvim_buf_line_count`. The whole saving is ~6µs per file opened, and the
  cache would have to go stale for a file that grows while open, which is exactly
  the log-tailing case the guard is for. Not worth a buffer variable.

- **`defaults = { lazy = true }` in `init.lua`.** It would make a spec added with
  no trigger silently never load, which is a worse failure than the one it
  prevents: a plugin that does nothing and reports nothing, versus a plugin that
  costs startup time and is visible in `--startuptime`. The guard is a test
  instead — `plugin_specs_spec.lua`, "gives every top-level spec an explicit load
  trigger" — so the decision stays visible in review.

## Deliberately not suggested

AI-coding plugins that dominate most "new Neovim plugins 2026" lists —
`avante.nvim`, `codecompanion.nvim`, `gen.nvim` — are skipped here. This config
already has a bespoke Claude integration; #2 above is the relevant upgrade path
for that specific niche, not a generic chat-in-editor plugin layered on top of it.
