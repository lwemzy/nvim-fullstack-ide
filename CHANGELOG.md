# Changelog

Every notable change to this Neovim config, newest first. Built from the
full git history on 2026-10-09, then maintained going forward — see
CLAUDE.md: every commit that changes behavior gets an entry here in the
same commit.

## 2026-10-09

- **Fix the spring-boot.nvim crash and quiet harper_ls** (`8ebe50f`)
  - spring-boot.nvim updated to Neovim's native vim.lsp.config/vim.lsp.enable framework and dropped launch.start/update_ls_config entirely, so every java/yaml/jproperties buffer crashed with "attempt to call field 'update_ls_config' (a nil value)". Rewire java.lua onto the new API, keeping the java-only Spring Boot gate via a root_dir wrapper (same idiom as angularls), and rewrite project_gating_spec.lua's spring-boot tests against the new vim.lsp.config["spring-boot"].root_dir seam.
  - harper_ls was logging "Settings must be an object" on every config push because no settings table was ever given it; an explicit empty one quiets it.
  - This commit's own message additionally (and wrongly) blamed a specific runner_spec.lua test for 40 leaked, never-stopped vscode-spring-boot-tools JVM processes found during this work (12GB+ RAM). That test turned out not to reach the real gate at all — `H.quiet_buffer` suppresses FileType for the whole load, not just the explicit filetype assignment. See the correction below.
- **Add CHANGELOG.md seeded from full git history, correct an earlier diagnosis** (`e9028b9`)
  - A regression assertion added to the above test (`lsp_starts.count > 0`) immediately failed, proving the gate never fires there — the stub and assertions were removed again as factually wrong, not shipped.
  - A direct probe (a real `.java` buffer opened via `tests/full_init.lua`, no test harness involved) confirmed the actual mechanism is real: it spawned a live vscode-spring-boot-tools process in ~200ms. But no spec in the current suite reaches that path unsuppressed — project_gating_spec.lua stubs the launch, java_ftplugin_spec.lua deliberately avoids the Spring fixture. The 40 processes most likely came from real manual TTY verification sessions during this feature's development (this repo's own commit history is full of "verified end-to-end in a real TTY against a real Spring Boot project"), not from `make test`.
  - tests/helpers/init.lua's H.cleanup() now force-stops any untracked real "spring-boot" client at the end of every spec file regardless of which test started it, as defense in depth — nothing in this suite currently relies on one surviving, unlike the jdtls specs it deliberately leaves alone.
  - Added tests/integration/harper_ls_spec.lua: regression coverage for the harper_ls settings fix above, which previously had none.

## 2026-10-08

- **Make the JS/TS fallback style the one the work codebases enforce** (`2d73c17`)
  - The fallback formatter for projects with no prettier config of their own was Google's JS/TS style guide, which was a guess at a house style rather than one anybody here is held to. Replace it with the style commerce-api actually enforces, read off its eslint.config.mjs and confirmed with `eslint --print-config` (128 rules resolved) rather than from the file, and matching the four legacy .eslintrc.yml copies in that repo.
  - prettier_google -> prettier_house, with five flags for the five rules prettier can express: quotes/single, indent/2, max-len/120, comma-dangle/never, arrow-parens/as-needed. semi, object-curly-spacing, jsx-quotes, brace-style and eol-last are already prettier defaults and stay unspelled.
  - The editor half was the necessary other change, not cosmetics. The global settings are 4-wide hard tabs for Java's sake, so JS/TS buffers inherited those while the formatter wrote spaces — which is why the old fallback passed --use-tabs --tab-width=4 to paper over it. js_ts_settings now puts both sides on 2-space soft tabs, with colorcolumn matching --print-width instead of sitting at the global default.
  - One rule has no prettier flag: space-before-function-paren/never wants `async(item, ctx) =>` and prettier always writes `async (item, ctx) =>`. Pinned as a test so it stays a recorded limitation. `eslint --fix` closes it, which is that repo's only enforcement path anyway — it ships no prettier at all, just eslint on pre-push and post-commit.
  - Tests assert on real prettier output for all five flags, not just argv: prettierd would silently swallow every one of them. Verified end to end in a TTY session — indent settings on real .ts/.js/.tsx/.jsx buffers, commerce-api itself resolving to prettier_house, and format-on-save landing the formatted result on disk (format_after_save is async, so an in-buffer check passes before the write does).
- **Add the six SpaceVim-derived features: build problems, Java generate, and four more** (`a7b021c`)
  - Implements SUGGESTIONS.md #8-#13, all Linux/Windows-first and all verified against a real Spring Boot project in a real TTY rather than only under test.
  - #8  lua/config/problems.lua  <M-q>        build output -> quickfix #9  lua/config/java_source.lua <leader>jg* jdtls source.generate.* keys #10 lua/config/alternate.lua  <leader>fa   class <-> test, component <-> template #11 lua/plugins/lsp.lua       <leader>lo   Trouble symbols outline #12 lua/config/tasks.lua      <leader>rt   task picker over the runner's target #13 lua/plugins/editor.lua    <leader>uu   undotree
  - Four findings that the static research did not predict, each recorded where it belongs:
  - Gradle prints every javac diagnostic twice -- once as task output, once indented under "What went wrong" -- and vim's errorformat skips leading whitespace, so both copies matched. One missing semicolon read as "2 problems (2 errors)". problems.parse now dedups on file+line+severity+text.
  - <M-o> was already neotest's. A lazy `keys` stub is created when lazy.setup runs, i.e. after init.lua has sourced config/keymaps.lua, so the collision silently replaced the mapping: the key registered, carried neotest's desc and did the wrong thing. The counterpart jump moved to <leader>fa, and plugin_specs_spec.lua now fails on that whole class of collision.
  - nvim-jdtls registers no handler for java.action.generateAccessorsPrompt, so getters/setters fell back to workspace/executeCommand, which jdtls does not implement for *Prompt commands. java_source.setup registers it, built from the two requests read out of org.eclipse.jdt.ls.core_1.60.0.
  - source.generate.finalModifiers and source.sortMembers return no action in a class with nothing to do, which reads as two dead keys and is not: Eclipse's comparator sorts by category, not alphabetically, so an already-categorised file sorts to null. Neovim itself notifies "No code actions available".
  - No new startup cost: every module is require-driven, undotree is cmd-triggered, startup stays at 29.7-33.4ms against a 28.1-35.1ms baseline with one start plugin. make lint clean; 33 spec files pass, 0 fail.

## 2026-10-07

- **Make explorer renames LSP-aware, and get the edits to disk** (`2b29086`)
  - Renaming a .java file in nvim-tree was a rename on disk and nothing else: the class inside kept its old name and every reference to it kept pointing at a type that no longer existed, with nothing on screen to say so.
  - jdtls does implement workspace/willRenameFiles — but InitHandler advertises it only behind isWorkspaceWillRenameFilesSupported, i.e. only if the client asks, and this config asked for neither. Capabilities were built in two duplicated places and jdtls is the one client that does not go through vim.lsp.config("*"), so lua/config/capabilities.lua now owns that table for both call sites.
  - nvim-lsp-file-operations supplies the nvim-tree -> LSP wiring, but stops one step short: vim.lsp.util.apply_text_edits bufloads each referencing file and edits it in memory, never writing, and the auto-save autocmd only ever writes the current buffer. The imports would have been fixed inside nvim while gradle and :Run compiled the stale files. file_ops snapshots which buffers were already dirty on WillRenameNode and writes only the ones the refactor touched on NodeRenamed — not a :wall, since a rename is no reason to write unrelated work in progress. The write is the existing auto-save path, extracted to lua/config/autosave.lua so there is still one guarded write and one warning rather than two.
  - The plugin's own auto_save option is off deliberately: it replaces vim.lsp.util.apply_workspace_edit globally for the session, so every multi-file code action starts auto-writing, and its write has no equivalent of the vim.b.autosave_mtime staleness check.
  - Measured end-to-end against a real gradle project, which is also how the limits got documented: renaming a file fixes the type and its references, renaming a package directory fixes the package declarations and importers, and moving a single file to another directory fixes nothing — jdtls returns no edit for that shape. checkhealth now reports the negotiated capability per client, since that is the one point where the whole feature degrades to silence.
  - Startup is unchanged at 28ms with two start plugins: the plugin is declared lazy with no config, so the capability require does not drag nvim-tree off its cmd-only trigger.
  - Also fixes a shared-helper bug this work exposed: H.cleanup's client:stop(true) is asynchronous, so fake servers stayed attached for the rest of a spec file and answered requests with URIs from tests that had already finished.
- **Add a format-on-save toggle, on by default** (`d098121`)
  - Format-on-save behaves as it always did; leader+uf now turns it off and on for the session, and reports which way it went. Alt+L still formats on demand and is unaffected either way.
  - leader+uf rather than another Alt chord because plugins/ui.lua already declares a leader+u "ui toggles" which-key group, with leader+uh for inlay hints next to it.
  - The state lives in lua/config/format.lua rather than in a vim.g read at each call site, because three places need to agree on the precedence rule: vim.b.autoformat if set, else vim.g.autoformat, else on. Spelling that out three times is how two of them end up disagreeing about what an unset variable means — and `false` has to be distinguishable from unset, so it tests `~= nil` rather than truthiness. That buys a per-buffer opt-out (a generated or vendored file in a session that formats) for free. toggle() clears the buffer-local override as it writes the global, or pressing the key in a buffer that had opted out would announce "enabled" while that buffer's own `false` still won.
  - Both save-time hooks read it, since both rewrite the buffer on save: conform's format_after_save (lua/plugins/editor.lua) and eslint's LspEslintFixAll (lua/plugins/lsp.lua). Leaving eslint out would mean turning the toggle off still reformatted JS and TS files. Returning nil is conform's own documented skip (`if format_args then`, conform/init.lua), so the autocmd stays registered and a write with formatting off costs one table lookup.
  - Verified in a real TTY against a deliberately ugly .js file, driving the mapping with nvim_feedkeys rather than calling toggle() directly so a missing mapping would fail: pressing it once left a real :write completely unformatted, pressing it again restored prettier's rewrite, and Alt+L formatted with the toggle off. keymaps_spec's exhaustive MAPPINGS list caught the new binding, as designed.
- **Add four candidates found on r/neovim's new-plugins feed (2026-10-07)** (`af0c89e`)
  - nvim-lsp-file-operations, tether.nvim, difftsigns.nvim, blink-cmp-deps. All researched and cross-checked against the current config, none trialed yet. tether.nvim supersedes claudecode.nvim (#2) as the one to evaluate first for the Claude bridge slot if that gets revisited — same IDE protocol, plus an explicit accept/reject diff step neither #2 nor the current claude_cli.lua bridge has.

## 2026-10-01

- **Correct the startup headline, and record two rejected optimisations** (`43928e1`)
  - The 334ms -> 31ms table is `nvim --headless --startuptime`, and headless never fires UIEnter, so it never fires VeryLazy either — which is where 23 of the now-lazy plugins actually load. Quoting 31ms alone measured the part of the work that was moved rather than the part that was removed. Measured in a real TTY (min of 5): first paint 74ms, VeryLazy burst finished ~230ms. So the editor appears in ~31-74ms instead of ~334ms and is fully furnished at ~230ms instead of ~334ms; the win is ~1.5x overall and dramatic only for time-to-first-paint.
  - Also recorded as measured-and-rejected, so they are not re-proposed: caching the on-disk size per buffer (getfsize is 1.9us against 0.026us for a line count — ~6us saved per file open, for a cache that goes stale on the log-tailing case the guard exists for), and `defaults = { lazy = true }` (it makes an untriggered spec silently never load; the plugin_specs_spec test added earlier is the better guard).
- **Prepend mason's bin dir exactly once, on the PATH that decides availability** (`c27f533`)
  - conform decides a formatter exists with a bare vim.fn.executable() against the *process* PATH (conform/init.lua: get_formatter_info) and never reads the formatter's own `env`. So the per-formatter `env = { PATH = mason/bin .. ... }` on prettierd and prettier_google was the wrong lever: it made the spawned process resolve while leaving conform convinced prettier did not exist, and an unavailable formatter is skipped silently — JS/TS/JSON/CSS/YAML/MD quietly not formatting on save. config.options prepends it to the process PATH at startup instead, and both formatters inherit that, so the two copies are gone.
  - The other half is PATH = "skip" in mason.setup(). mason's own prepend is unconditional (mason-core/installer/InstallLocation.lua), so with both in place the same directory landed in PATH a second time on every mason load — harmless to resolution, but PATH grew per load and no longer matched what the config set, and no guard in config.options can prevent it from there. The comment and the test name both claimed the guard covered this; they now say which half does what.
  - Verified in a real TTY: mason/bin appears once and first before mason loads and once after forcing it to load, and conform reports both prettier_google and prettierd available.
- **Make the big-file guard actually turn things off** (`9110e1a`)
  - Four of the opt-outs in the big-file path had never once run, and the two that did were partly undone by the plugin they were meant to stop. All of it was invisible headless and found by opening generated files in a real TTY.
  - Timing. config.autocmds is required from init.lua before lazy.setup, so its FileType callback runs ahead of every other FileType handler in the session — including Neovim's own runtime ftplugins, whose `filetypeplugin` group is created while the runtime is sourced, i.e. after the user config. So an inline detach detaches nothing and the attach happens a moment later. Measured both ways: colorizer stayed attached to a 12000-line CSS file, and a 20002-line .lua file came out of the guard with the treesitter highlighter active and 'syntax' empty — no highlighting of either kind, which is worse than doing nothing. The whole teardown, treesitter included, now runs from vim.schedule.
  - rainbow-delimiters was gated on package.loaded["rainbow-delimiters"], which is never set: the plugin attaches from a FileType autocmd in its own plugin/ dir that requires only `rainbow-delimiters.config` and `.lib`. Measured — the top-level key was nil on a 20k-line Lua file with rainbow-delimiters active and 40,000 extmarks placed. Gated on `.lib` now; the call still goes through the public module.
  - illuminate's large_file_cutoff was paired with large_file_overrides on the belief that the cutoff needs it. config.get() returns the overrides *instead of* the config rather than merged over it, so `{ providers = { "lsp" } }` made big files worse, not better: delay fell from 200ms to the 17ms floor and the denylist was emptied, so a 10k-line buffer got a documentHighlight request every 17ms of cursor movement where it had had none. The cutoff alone is what disables it.
  - Detection is now split in two, because neither event sees both halves. BufReadPre judges the file on disk (the buffer still holds the outgoing contents there, so a 3-line file reloaded after 20k lines were pasted into it was being read as big), and it reassigns rather than merely sets, so a file that has since shrunk recovers. BufReadPost covers the files FileType never fires for — a .dump or a no-extension blob — which is the worst case, not an edge case: a 3MB single-line dump was measured coming out of the guard with synmaxcol still at 3000.
  - And a second, much higher tier for the LSP features that scale with document size rather than with the edit. The client stays attached, deliberately: detaching it was the first implementation and it broke three things. lsp_reap derives idleness from client.attached_buffers, so emptying it got the JVM stopped five minutes later with a "no open buffers" toast about a file still on screen; the LspAttach handler binds gd/gr/K synchronously and barbecue attaches navic, so a detach one tick later left those pointing at a client that was gone; and Client:on_attach queues its capability init after firing LspAttach, so our scheduled detach ran first (FIFO) and leaked the augroup it would have removed. Turning off inlay hints, semantic tokens and reference highlighting instead keeps completion, diagnostics and go-to working — big rather than broken — with one WARN per buffer saying so.
  - Verified in a real TTY on generated files. big.lua (20002 lines): ts_hl false, syntax lua, synmaxcol 200, undofile off, colorizer detached, rainbow disabled, illuminate off. big.css (12000): same. blob.dump (3MB, one line, no filetype): synmaxcol 200. small.lua: untouched — ts_hl true, colorizer attached, synmaxcol 3000. Plus 42/42 runtime checks and the unit specs, which now drain the scheduler before asserting.
- **Close the lazy-load gaps the trigger pass left behind** (`0b132b0`)
  - Every one of these is a capability that the previous commit's `cmd`/`keys`/ `event` triggers did not actually cover, found by driving the real config in a TTY rather than headless (headless never fires UIEnter, so VeryLazy never fires and none of this is visible).
  - nvim-tree: `nvim .` / `nvim src/` is not a command. hijack_directories only exists once setup() has run, so waiting for :NvimTreeToggle meant a directory argument opened netrw (measured: `window fts: netrw`). Load it from `init` when argv is a single directory. Six more of its commands were missing too.
  - telescope: vim.ui.select is a third entry point and nobody's keymap. On `cmd` alone, a code action, jdtls's Generate menu or the debug-config picker taken before any finder had been opened got the stock numbered prompt for the rest of the session. A shim loads telescope on first use and forwards; the identity check keeps a failed load_extension from recursing.
  - telescope's notify extension was registered with pcall, which swallowed the failure when a Telescope invocation beat VeryLazy and left `:Telescope notify` broken for the session. require("notify") first instead.
  - nvim-treesitter: TSInstallSync does not exist on the `main` branch. A cmd name that does not exist is worse than a missing one — lazy's stub loads the plugin, deletes itself, then E492s. Replaced with the five commands the branch defines.
  - Comment.nvim: gco/gcO/gcA are created by setup() and keymaps.lua does not own them. Without a trigger they are not unmapped keys that beep; Neovim 0.12 ships its own `gc` operator, so `gc` + `o` comments a different range than asked for.
  - gitsigns: keymaps.lua types `:Gitsigns blame_line`, so a session that never reads a file had the keymaps and not the command — a guaranteed E492. Its BufReadPre rationale was also wrong (setup() does attach to open buffers); corrected to the real one.
  - mason-lspconfig: automatic_enable is off. mason-tool-installer require()s this module at VeryLazy, which could enable servers while nvim-lspconfig was not yet on the runtimepath — measured `is_enabled ts_ls=true` with `cmd=nil`, and vim.lsp.enable's can_start() then rejects them silently.
  - mason-tool-installer: its run_on_start fires from a VimEnter autocmd in its own plugin/ dir, so loading at VeryLazy registered it for an event that had passed and ensure_installed never ran. Call it by hand and drop the dead augroup.
  - Plus a test that keeps the hole from reopening: every top-level spec must declare event/cmd/keys/ft or an explicit `lazy`. A test rather than `defaults = { lazy = true }`, because that default makes an untriggered spec silently never load, which is worse than loading it eagerly.
  - Verified in a real TTY: 42/42 runtime checks, and a probe confirming the directory argument opens NvimTree, :Gitsigns exists with no file read, gco/gcO/ gcA are mapped, vim.ui.select routes through the shim, mti_start is consumed, and no server is enabled before nvim-lspconfig has set its config.

## 2026-09-30

- **Turn SUGGESTIONS.md into a decision record, and correct the cmp comment** (`fbfe72a`)
  - SUGGESTIONS.md proposed three plugin swaps on unmeasured performance claims. It is now a dated record of what was measured and what was decided, so a later reader does not re-open settled questions:
  - 1. blink.cmp -- deferred. It targets completion-engine time, which measurement puts at 0.8-1.9ms (filter + sort of 1000 items) against jdtls round trips of median 27.6ms on member access and 41.4ms on a bare cursor. ~3% of the latency, for a rewrite of every completion mapping and source. 2. claudecode.nvim -- branch trial only. Three factual corrections to the case made for it are listed inline. 3. snacks.nvim -- declined as a swap; the one real gap it named (no big-file guard beyond treesitter) is closed in-tree by config.bigfile instead of by adopting a 20-module collection to use one of them.
  - The cmp `performance` comment claimed max_view_entries cut per-keystroke work ~8x. It does not: cmp/view.lua sorts the full candidate set through all nine comparators and only then slices to that number, so it caps rendering, not sorting. Replaced with what the measurement actually supports -- the debounce/throttle pair is the half that shortens the keystroke-to-menu gap, since cmp's stock 90ms of deliberate waiting was larger than the round trip it was waiting on.
- **Extend the big-file guard into config.bigfile, with an LSP tier** (`cde24df`)
  - The config had one size guard: an inline treesitter check in autocmds.lua. It turned off TS highlighting on a large file and left everything else -- ufo's fold provider, indent-blankline, colorizer, illuminate's regex scan of the whole buffer on every CursorMoved -- running on it, and the LSP had no bound at all.
  - Two tiers rather than one threshold, because the right answer differs:
  - decoration (10k lines / 512KB): losing treesitter highlight, folds, indent guides and colour swatches on a 600KB file is cosmetic.
  - LSP (40k lines / 4MB): detaching the server from a 10k-line Java class would look exactly like broken autocomplete, so that tier is set four times higher -- 40000 lines is gitsigns' own max_file_length default, i.e. the ecosystem precedent. The detach notifies, so it never looks like a bug.
  - Lines *and* bytes, because minified and generated files have few of the former and lots of the latter. Detection runs twice for the same reason: at BufReadPre the buffer is still empty so only the on-disk size is knowable, and the line count only exists from FileType onward.
  - Each plugin is switched off through its own documented per-buffer API, and illuminate through its native large_file_cutoff -- which needs large_file_overrides set alongside it or illuminate never consults it (illuminate/config.lua). That pair keeps illuminate's LSP provider (the server already has the document indexed) and drops only the two that re-scan locally.
  - bigfile.limit() checks package.loaded instead of pcall(require, ...) on purpose: require() is itself a lazy.nvim load trigger, so asking a plugin to do less would otherwise drag it into the session to do nothing. There is a test for exactly that.
  - The LspAttach detach is scheduled, and that is load-bearing: Client:on_attach fires LspAttach and *then* sets attached_buffers[bufnr] as its last statement (runtime/lua/vim/lsp/client.lua), so a synchronous buf_detach_client is silently undone a moment later -- the server keeps the document and the notification still claims it was detached. Found by probing it, not by reading it: the first version printed the warning while the client was still attached.
  - Verified live on a generated 20k-line JSON file: flagged, synmaxcol 200, treesitter highlighter absent.
- **Put mason's bin dir on PATH from config.options, not mason.setup()** (`677807c`)
  - Fallout from lazy-loading mason in the previous commit: the PATH prepend was a side effect of mason.setup(), so with mason deferred behind `:Mason`, nothing mason installed was findable in a normal session.
  - It showed up as prettier silently not formatting on save. conform decides whether a formatter exists with a bare vim.fn.executable(command) against the *process* PATH (conform/init.lua, get_formatter_info) and ignores the formatter's own config.env.PATH -- so the env.PATH this config already sets on prettierd/prettier_google makes the spawned process resolve, but cannot make conform consider the formatter available. An unavailable formatter is skipped with no error, i.e. JS/TS/JSON/CSS/YAML/MD quietly not formatting.
  - Prepended, matching mason's own default (PATH = "prepend"), so resolution order is exactly what it was before; guarded against double-prepending because mason.setup() still does this when the installer eventually loads, and this PATH is inherited by every job the editor spawns.
  - Caught by the test suite (two new SKIPs: "prettier not installed"), which is why the two specs assert on both halves -- that the dir is there, and that it is there exactly once after three loads.
- **Lazy-load the 27 start plugins: 334ms -> 31ms startup** (`d1cf702`)
  - Every plugin in this config was a start plugin except the ones that already declared keys or cmd, so `nvim` paid for lualine, bufferline, telescope, nvim-tree, mason, treesitter, cmp and the rest before drawing anything.
  - Each spec now declares the trigger that matches when its own user-visible behaviour first has to exist, which is the part worth reviewing per plugin -- the comments in each spec give the reasoning where the choice is not obvious. The pattern:
  - VeryLazy for the always-on UI (lualine, bufferline, nvim-notify, toggleterm, neoscroll, harpoon, which-key, visual-multi, emmet, dotenv, mason-tool-installer)
  - BufReadPre/BufNewFile for anything that attaches per buffer (lspconfig, treesitter, rainbow-delimiters, gitsigns, barbecue, ufo, indent-blankline)
  - cmd for the on-demand UIs (nvim-tree, telescope, trouble, mason)
  - InsertEnter + CmdlineEnter for cmp -- CmdlineEnter too, or ":" and "/" completion would only start working after the first insert
  - BufWritePre + ConformInfo for conform; lazy = true for Comment.nvim, which lua/config/keymaps.lua already loads through require()
  - Measured min-of-9, interleaved against baseline, same machine: empty `nvim` 334ms -> 31ms (10.6x); `nvim Play.java` 541ms -> 318ms (1.7x).
  - Verified at runtime rather than by reading the specs: a headless probe drives the real config through each entry point (VeryLazy, opening a Java file, InsertEnter, each command, the <C-/> keymap, a write) and asserts the plugin arrived *and* did its job -- treesitter highlighting active, gitsigns' ]g bound in the buffer, jdtls answering textDocument/completion with real items, conform's BufWritePost hook installed by the pre half of the first write.
- **Add SUGGESTIONS.md: plugin research findings** (`74a42a6`)
  - Shortlist from scanning the current Neovim ecosystem against what this config already runs and already struggles with: blink.cmp (addresses the completion-performance workaround already in lsp.lua), claudecode.nvim (replaces the disk-write-and-poll Claude bridge that caused the reload- race bugs fixed earlier, including the jdtls folding crash in fc6fe4c), and snacks.nvim (lower-priority consolidation of small utility plugins). Not implemented — a reference for a later decision.
- **Add harper_ls for spell/grammar checking in code and prose** (`7a2370d`)
  - Wired the same way as the other servers: mason-lspconfig ensure_installed, vim.lsp.enable, and a filetypes extension (javascriptreact, the one gap in lspconfig's defaults for this stack). No separate on_attach needed — diagnostics and quick-fix code actions ride the existing wildcard on_attach/gate machinery.
  - harper_ls splits identifiers on case/underscore before checking spelling, so getUserId and get_user_id are both read as "get user id" rather than flagged whole.

## 2026-09-20

- **Indent with 4-wide hard tabs instead of 2 spaces** (`5921fa6`)
  - Tab now inserts a tab character (VS Code style), tabstop/shiftwidth 4, softtabstop -1 so Backspace follows shiftwidth. The formatters would otherwise turn tabs back into spaces on save, so they follow suit: java-google-style.xml uses tabulation.char=tab size 4 (continuation indent 2 -> 1 unit so wraps stay 4 columns deep), and the prettier_google fallback passes --use-tabs --tab-width=4. Projects with their own prettier config are unaffected. YAML stays on 2 spaces since it forbids tab indentation. Specs that pinned 2-space indent are updated.

## 2026-09-07

- **Pin Java folding off the LSP provider** (`fc6fe4c`)
  - 7217125 routed Java folding through treesitter instead of jdtls, for a good reason with no test behind it: jdtls's FoldingRangeHandler hits a long-standing JDT-core Scanner bug (source index -1 out of bounds) on some documents (eclipse.jdt.ls #990, #1419, #1815), and ufo cannot survive it. Its LSP client turns only RequestCancelled/ContentModified/ RequestFailed into the internal UfoFallbackException, so an InternalError — which is what a JDT exception arrives as — is re-raised untouched, and nothing in the fold chain catches it (provider/lsp/nvim.lua, provider/init.lua's needFallback, fold/init.lua). The user gets a "Press ENTER to continue" dump mid-edit and folding never recovers for that buffer.
  - The pin is behavioural and points both ways. Java's chain must not contain "lsp"; typescript/javascript must keep it, since ts_ls and angularls fold correctly and a future blanket "just use treesitter" would quietly downgrade the whole TS/Angular half of this config; and the treesitter provider must actually return folds for a real Java buffer, asserted by which lines fold rather than just how many. A chain pointing at a provider that yields nothing would mean no folding at all, which is not what was traded for.
- **Format Java once per save, not three times** (`48ffd1e`)
  - ftplugin/java.lua registered a BufWritePre hook calling vim.lsp.buf.format on the attaching jdtls client — and conform.nvim (plugins/editor.lua's format_after_save) already formats every written buffer. Java has no entry in formatters_by_ft, so conform's `lsp_format = "fallback"` sends textDocument/formatting to that same client: the identical request the ftplugin hook was making. Measured on a Spring project with the jdtls client's request/request_sync wrapped, one :write of one Java file cost THREE formatting round trips — the slowest request jdtls serves. It is one now.
  - The ftplugin copy is the one to lose, and not only because conform's runs async. vim.lsp.buf.format's synchronous path applies whatever edits come back with no staleness check at all, while conform compares the buffer's changedtick before applying (conform/lsp_format.lua) and drops a result a later edit has already invalidated — the difference between reformatting the buffer and silently reverting a keystroke that landed mid-format. conform then re-writes the buffer itself (vim.cmd.update), so a save still leaves formatted content on disk; verified end to end.
  - Also spells the option `lsp_format = "fallback"` in both places it appears, not the old `lsp_fallback = true`. conform still translates the old key in a "For backwards compatibility" block (conform/init.lua) but no longer documents it, so the release that drops it would silently stop formatting exactly the filetypes that depend on it — Java, XML, Lua — with nothing in the logs to say why.
- **Drop core's gr-prefixed LSP defaults, so `gr` fires instantly** (`bf463c2`)
  - Neovim 0.11 started mapping grn/gra/grr/gri/grt/grx itself, in runtime/lua/vim/_defaults.lua. Every one of them shares a prefix with this config's own `gr` (LSP references, bound per-buffer in plugins/lsp.lua's on_attach), which makes `gr` an *ambiguous* prefix: nvim then has to wait out the full 'timeoutlen' — 300ms here — on every press to learn whether a second key is coming. The most-used LSP jump in the config stalled first, every single time, and it looked like a slow language server rather than a keymap collision.
  - Nothing is lost by deleting them. Each already has an equivalent bound here or in plugins/lsp.lua: grn -> <leader>rn (and <F2>), gra -> <leader>ca (and <F4>/<C-.>), grr -> gr, gri -> gi, grt -> <leader>lt, grx -> <leader>cl (ftplugin/java.lua's own cursor-line code-lens runner; nothing in this config renders lenses through vim.lsp.codelens, so core's grx had nothing to run in the first place).
  - pcall rather than a bare vim.keymap.del: deleting a mapping that was never set raises E31, and these only exist from 0.11 onwards.
  - The second spec case pins the property rather than the six names — that nothing longer than `gr` is left sharing its prefix, whoever adds it.
- **Route Java code folding through treesitter, not jdtls** (`7217125`)
  - nvim-ufo's provider_selector asked jdtls for Java folding ranges. Its FoldingRangeHandler hits a long-standing JDT-core Scanner bug (source index -1 out of bounds on certain documents) — eclipse.jdt.ls #990, #1419, #1815, vscode-java #1644. ufo's lsp provider does not catch a live RPC error from that request (it only falls back to indent when the server lacks the capability at all), so the crash surfaced client-side as an unhandled promise rejection dump ("Press ENTER to continue").
  - Switch java to {"treesitter", "indent"}, same shape already used for lua two lines below it. No new dependency: java is already in nvim-treesitter's ensure_installed list. This avoids the buggy request entirely rather than trying to patch around ufo's missing error handling.

## 2026-09-05

- **Add a persistent Run / Restart / Stop / Debug toolbar** (`b278929`)
  - Replaces the single <F3> "Spring Boot: Run" mapping with lua/config/runner.lua, which detects what the open buffer belongs to and offers the four actions for it on the lualine statusline — always visible, clickable, and with Restart/Stop present only while something is really running (polled from job state, so a build that fails on its own takes them away with no keypress). No new plugin and no extra screen line: the statusline is already global, and each button is its own component because lualine's on_click is per component.
  - Also reachable from <leader>rr/rR/rs/rd/ra, <F3>, and :Run / :RunRestart / :RunStop / :RunDebug / :RunAttach with completion over the targets found here.
  - Detects, from the buffer upward with the nearest project winning in a monorepo: Spring (mvnw spring-boot:run / gradlew bootRun), plain Java (main class through jdtls, which is the only thing that knows the classpath), Angular and node (the project's own start/dev/serve script, or npx ng serve, run with the package manager the lockfile names). Debug is one action: Spring starts with JDWP and is attached to as soon as the port opens; Angular starts the dev server, waits for its port, then attaches Chrome; Attach alone works with no project at all, which is what "remote JVM debug" means in an IDE.
  - What the old mapping got wrong, and what building this surfaced:
  - It chose between mvnw and gradlew with a CWD-relative filereadable(), so nvim opened one level above the project — or anywhere in a multi-module build, where the wrapper is at the repository root — ran the wrong wrapper or refused to run while the project was plainly open. The wrapper is now absolute and quoted, and the command runs in the module directory.
  - It kept no process handle, so there was no Restart and no Stop at all.
  - Detection went blank inside the run's own terminal: Run moves focus there, that buffer HAS a name (term://<cwd>//<pid>:<cmd>), so a name-only "is this a file?" check accepted it and the upward search walked a path that does not exist. Stop answered "No run target here" with the build on screen while the process kept running. Found by running a real gradlew bootRun by hand, after 45 headless assertions passed. buftype == "" is the load-bearing check, with a fallback chain of alternate file -> any window's file buffer -> cwd.
  - The build inherited nvim's JAVA_HOME and died before reading the project: with no JAVA_HOME and a Java 8 on PATH, gradlew bootRun fails with "Gradle requires JVM 17 or later to run" while jdtls indexes the same project on a Java 25 it found for itself, and nothing in that message suggests the editor could have fixed it. config.jdk gains env_major() ("what would a child process actually run on"), and the run terminal is given a JAVA_HOME only when the inherited one cannot work — a deliberate one is left alone.
  - Snappiness: detection is cached per buffer and per directory and invalidated only on a build-file write, DirChanged or buffer deletion; running state is one non-blocking jobwait; highlight lookups are cached and cleared on ColorScheme; no plugin is required at module load. Finished run terminals are reaped with shutdown() rather than left orphaned with their scrollback, and cache entries are dropped on BufWipeout/BufDelete.
  - Tests: 29 unit cases for detection and the toolbar, 22 integration cases running real processes for the lifecycle, plus new config.jdk and config.project cases. Verified live against a copy of a real Spring Boot 4 project (33 checks), against a real JVM on JDWP through real jdtls (15 checks: attach succeeded, initialized and configurationDone, and disconnect left the JVM alive), and against a real dev server for the port wait (9 checks). Every fix was sabotage-checked.
- **Run the language servers on the newest LTS JDK, not the newest JDK** (`55f9d92`)
  - jdtls and boot-ls were handed whichever JDK on the machine had the highest major version. On this machine that meant jdtls ran on Java 26 while 25 was sitting right next to it: a long-lived Eclipse/OSGi JVM on a release that gets six months of updates and is where JEP removals land first (sun.misc.Unsafe's memory-access methods are the live example, warned in 24 and going away — and JDT's dependency chain is exactly the kind of code that uses them).
  - config.jdk.newest is now config.jdk.server_jdk, which picks the newest LTS that meets the caller's floor and falls back to the newest JDK of any kind when no LTS does. The fallback matters as much as the preference: on a machine whose only JDK is 26 it is the difference between a working server and none.
  - This caps only the JVM the *server* runs on. Every JDK found is still registered in java.configuration.runtimes with the newest as default, so a project targeting the newest release still compiles against it — verified on this machine: runtimes JavaSE-26*, JavaSE-25, JavaSE-21, JavaSE-17 with the host on 25.
  - LTS is a rule and not a list — 8, 11, 17, then every fourth release from 21 — so 29 in 2027 does not need a code change.
  - :checkhealth now says why the newest JDK is not the one being used, because otherwise the report reads as a discovery bug: the newer JDK is listed two lines above and the server is not on it.
  - Verified end to end against a real Spring Boot project (a copy — this config auto-saves on BufLeave): jdtls launched with --java-executable=.../25.0.4-tem/bin/java, reported openjdk 25.0.4 LTS, imported the Gradle project and returned 14 completions for SpringApplication. including run(). Sabotage-verified: dropping the LTS preference, the fallback, or the cadence rule each fails the case that pins it.
- **Make the Claude/MCP integration work, and make it feel instant** (`da63dca`)
  - The MCP half was dead on arrival: mcp/nvim_context_server.py was registered nowhere — no .mcp.json, no `claude mcp add` — so get_current_file was never callable, the panel's system prompt told Claude to call a tool that did not exist, and every BufEnter wrote a context file nothing ever read. It is now registered inline via --mcp-config on the panel's own invocation, so pulling this repo is the whole install.
  - The visual commands sent the wrong code, or none at all. The maps are plain Lua callbacks with no :<C-u>, so they run with visual mode still active and the '< / '> marks unwritten: measured, getpos("'<") is {0,0,0,0} inside the callback. The first visual AI command of a session reported "No text selected" and sent nothing; every one after it silently sent the PREVIOUS selection. getregion() reads the live selection and also fixes blockwise <C-v> sending whole lines and byte slicing cutting multibyte characters in half.
  - Snappiness, all measured rather than guessed:
  - Answers streamed instead of buffered. --output-format text held the whole response to the end: nothing but "Asking Claude…" until 11.3s on a real request, against first text at 3.9s growing in ~100-160 char steps now. Rendered append-only behind a 50ms throttle rather than re-sending the whole buffer per chunk.
  - One-shot prompts no longer start the user's MCP servers: 3.15s -> 2.32s per request. The panel deliberately keeps them — that is a conversation.
  - The per-BufEnter context write went from a 653us synchronous io.open to an async vim.uv chain (0.8us to dispatch), is skipped entirely until the panel has been opened, and is skipped again when nothing changed.
  - Also fixed, each reproduced first and pinned by a test that fails when the fix is reverted:
  - The context file was /tmp/nvim-claude-ctx: a fixed name in a world-writable directory, where another account can pre-create the path as a symlink and collect the name of every file you open. Now under $XDG_RUNTIME_DIR (falling back to stdpath("cache")), mode 0600, written to a per-pid temp file and renamed into place so a concurrent read cannot catch it truncated.
  - A missing `claude` binary threw out of the keymap instead of explaining itself: jobstart/termopen throw E475 for a missing executable, so the exit-code branch advising "check that claude is installed" was unreachable.
  - The panel became permanently unclosable if the code window went away (E444 on closing the only window, thrown before state.win was cleared).
  - botright 80vsplit left the code window zero columns wide on an 80-column terminal, hiding the file you wanted to ask about. Now 40% capped at 80.
  - Entering the file tree, a terminal or the panel itself overwrote the context record, because the guard only checked that the buffer had a name.
  - The MCP server answered any tool name at all with the context, answered unknown methods with an empty success (a schema violation for anything whose result has required fields), and returned an empty text block for an empty context file.
  - Tests: mcp_server_spec is new (14 cases, driving the server as a real subprocess so the stdout framing is part of what is checked), claude_cli_spec is 68. Both sabotage-verified — 16 deliberate regressions, each caught by the case that should catch it. Full suite green in both tiers.
- **Stop leaking buffers, namespaces, augroups and JVMs per file opened** (`50591a3`)
  - Everything here is unbounded in the number of files or keypresses in a session, which is what makes it worth fixing however small the per-instance cost: capping each instance is no help when the count is what grows. Written Linux-first — the OOM killer picks the largest RSS, so on Linux this class of leak presents as Java completion dying mid-session with nothing in nvim to explain it, where macOS just swaps and gets slow.
  - Every claim below was measured, not inferred.
  - <F3>/<M-r> built a toggleterm Terminal per keypress with close_on_exit = false, so each finished run orphaned its buffer with the full scrollback AND unreachable from toggleterm's registry (__handle_exit does nothing while toggleterm's own TermClose still drops the entry). Finished runs are now reaped when the next starts, via jobwait; live ones are untouched, so a watch task alongside a build still works. shutdown(), not close(): close() only hides the window, which is what left the buffer behind.
  - The Claude panel's on_exit nil'd its handles and nothing else, so claude exiting left the terminal buffer and its window behind while panel_is_open() began reporting false — the next <C-g> opened a second split with a second terminal on top of the stale one.
  - M.ask relied on nvim_create_buf's scratch flag for cleanup, which gives bufhidden = "hide": one whole response retained per press, forever. And dismissing the float early left `claude -p` running, still appending into a buffer nobody can see; a BufWipeout handler now stops the job.
  - Nothing ever stopped a language server: nvim's Client:_on_detach only clears attached_buffers[bufnr], and the only internal client:stop() calls are vim.lsp.enable(name, false) and VimLeavePre. So visiting N Java projects ended with N jdtls JVMs plus N boot-ls JVMs resident. New config.lsp_reap stops the JVM servers only, after five idle minutes, and says so — a jdtls start is a ~30s import, so eager reclaiming costs more than the RAM it frees. It re-derives idleness from attached_buffers each pass rather than bookkeeping from events, because LspDetach fires behind an nvim_buf_is_valid guard and :bwipeout can skip it entirely. A module rather than an inline block so sweep() can take the clock as an argument.
  - java_codelens_<bufnr>: namespaces are process-global and there is no API to delete one, so that was a permanent entry per Java file opened (500 buffers -> 500 namespaces, surviving buf_delete and collectgarbage). Now one shared name, which is safe because every call was already scoped to bufnr. Same for java_ftplugin_<bufnr> and eslint_fix_<bufnr>: nvim reclaims a wiped buffer's autocmds but not the group holding them, so those leaked an invisible empty group each — invisible because nvim_get_autocmds only returns groups that still have autocmds.
  - Abandoning a new .java file left its entry in the new-file tracking table. With :bd that is a wrong answer, not just dead weight: the same bufnr comes back on re-edit, and if the file exists by then BufNewFile does not re-fire, so an ordinary :w paid a full projectConfiguration.update.
  - jdtls ran on the launcher's default heap; -Xmx is now sized from the machine, honouring get_constrained_memory() so a container's cgroup limit is what counts rather than the host's RAM.
  - New specs: lsp_reap_spec (11), terminal_spec (4), plus cases in claude_cli_spec, autocmds_spec, java_ftplugin_spec and lsp_attach_spec. Each was sabotage-verified — the fix reverted, the new assertions confirmed failing — and one sabotage that did NOT fail corrected a false claim in lsp_reap's own comment about attached_buffers. Both tiers pass: 19/19 spec files.
- **Find JDKs the Linux way, and fail loudly when there is none** (`b4dba1d`)
  - Java completion worked on the machine this config was written on and was silently absent on a second (Linux) one. Two independent causes, both environment differences rather than logic errors — which is why only a second machine surfaced them.
  - config.jdk probed only ~/.sdkman/candidates/java/current, so a machine with 21 installed and 17 *selected* reported no JDK 21 at all. jdtls refuses to launch below 21, so that alone turns Java completion off. Every installed sdkman JDK is now a candidate (current still first, so an explicit `sdk use` still wins the same-major dedupe), plus:
  - ~/.jdks/* — IntelliJ's own downloads, very often the only JDK on a Linux dev box and invisible to every system path we globbed
  - ~/.local/share/mise/installs/java/*, ~/.asdf/installs/java/* — by install dir, because these managers put a wrapper *script* on PATH whose ../.. is not a JDK home
  - $JDK_HOME, which several installers set instead of $JAVA_HOME
  - bare `java` on PATH, via its real home: the catch-all for Nix, a hand-unpacked tarball, or any distro layout not globbed. It is also exactly what the mason jdtls launcher falls back to when handed no --java-executable, so including it stops our answer and the launcher's from disagreeing.
  - That last one makes the second fix safe. ftplugin/java.lua used to warn about a missing JDK 21+ and start jdtls anyway; the launcher then aborted itself ("jdtls requires at least Java 21"), leaving a client that attached and immediately exited. The symptom was completion absent with one scrolled-past startup warning as the only clue. Now that PATH java is a candidate, nil means nothing on the machine can run jdtls, so it is fatal, loud, and carries the per-platform install command.
  - Adds :checkhealth nvim-ide (lua/nvim-ide/health.lua) for this whole class: the JDKs found, the one jdtls will launch on, the mason payloads whose absence removes a feature with no error (Lombok, java-debug-adapter, java-test, vscode-spring-boot-tools), and which LSP file-watching backend this OS gave Neovim. That last one is the sharpest platform difference in the stack and it is Neovim's, not ours: recursive fs_event on macOS and Windows, inotifywait on Linux when present, per-directory fs_event otherwise — and under the fallback jdtls can miss a newly created .java file, so completion in it stays empty.
  - Tests: jdk 27, java_ftplugin 32, health 11 (new). The jdk harness now stubs exepath, because on Linux /usr/bin/java is a symlink into a real JDK and would have injected one into every expectation — the same kind of accident that makes a suite pass on one OS only.
  - make lint clean; both tiers green (17 files, 5 skips / 4 slow).
- **Fix nine issues found reviewing the autocomplete/LSP fixes** (`5b200d9`)
  - A code review of 9795b80 turned up nine defects in that round of fixes. Each is fixed here with a spec that fails without it.
  - lua/plugins/lsp.lua
  - on_attach only ever *added* a capability-gated mapping, so client/unregisterCapability left a dead key behind: pressing it reported "server does not support ...", which is what a *missing* mapping would have said honestly. Both handlers are now wrapped and the twelve gated maps go through one `gate()` that adds or removes. Removal ignores any capability another attached client still answers, so eslint cannot take away what ts_ls installed on the same buffer.
  - The inlay-hint re-enable inferred "hints were never on here" from is_enabled(), which is equally false after a <leader>uh toggle-off — so every later jdtls registration switched them back on. First-enable is now tracked per buffer, a re-request happens only when a provider actually joins, and the sentinel is reset when nvim's own LspDetach disable fires (:LspRestart hands the same server a new client id).
  - A burst of registrations (jdtls sends several; ts_ls and eslint register two at startup) re-ran on_attach once per registration — a full supports_method sweep plus ~14 keymap calls each, per attached buffer. Now coalesced to one re-run per buffer per tick.
  - lua/config/project.lua
  - Symlinks were resolved in $HOME but not in the VCS root or the buffer's own directory, and vim.fs.find compares `stop` by raw string equality — so on macOS (/var -> /private/var), for a project reached through a symlink, or for a buffer in a directory that does not exist yet, the bound matched no parent and the walk ran to `/` again. Every path now goes through one resolve(), which descends to the deepest existing ancestor so a not-yet-created directory still compares.
  - The ceiling could sit above $HOME (a `~/.git` dotfiles repo, or `/` under version control), putting $HOME inside the searched range. It is now clamped, including when the root is an ancestor of $HOME.
  - lua/plugins/editor.lua, lua/plugins/java.lua
  - The prettier check read only the nearest package.json, so a monorepo workspace package got the Google fallback while the repo root's "prettier" key (and CI) said otherwise. It now reads every package.json up to the bound, and package.json / the build files double as fallback root markers for projects with no VCS root.
  - lua/config/keymaps.lua
  - <F1> and <C-S-l> duplicated their open-a-log logic; shared as one open_log() that opens in a new tab, readonly and nomodifiable, so auto-save cannot write a stray keystroke back over a file a server is still appending to.
  - tests: project 19, keymaps 23, lsp_attach 17, inlay_hint 10, conform 19. make lint clean; both tiers green (16 files, 5 skips / 4 slow). tests/README.md records the five nvim behaviours these turned up.
- **Fix the four config bugs the test suite pinned** (`9795b80`)
  - on_attach gated its LSP keymaps on client.server_capabilities, which only ever holds the initialize response. jdtls advertises almost nothing there and registers rename, code action and most of the rest once the project is imported, so <leader>rn, <leader>ca and gr were never created in a Java buffer at all. Verified against real jdtls on a Spring project: renameProvider and codeActionProvider are both nil at initialize. Gate on client:supports_method(method, bufnr) and re-run on_attach from the existing client/registerCapability wrapper — keymap.set overwrites, so it is idempotent. That wrapper's inlay-hint re-request folds into the same call, guarded so an unrelated registration does not re-request every hint and a re-run does not undo a <leader>uh toggle-off.
  - <F1> was mapped to :LspLog, which does not exist on Neovim 0.12: nvim-lspconfig's plugin/lspconfig.lua returns early when :lsp already exists, so it registers no Lsp* command at all, and 0.12's own :lsp takes only enable|disable|restart|stop. Open vim.lsp.log.get_filename() directly.
  - auto_create_dir fed URL-style buffer names straight to mkdir. fnamemodify(":p:h") leaves a scheme alone, so writing an oil:// buffer created a cwd-relative junk tree inside whatever project was open. Return early on any non-empty buftype.
  - has_prettier_config and is_spring_boot_project searched upward with no stop bound, so a single ~/.prettierrc or ~/pom.xml changed behaviour for every project on the machine. Both now go through config.project.find_upward, bounded at the VCS root's parent. Bounding there rather than at the nearest build file also fixes multi-module Maven builds, where the POM declaring spring-boot sits above the module.
  - Plus the nine keymaps that had no desc (split resize, centred scroll/search, <Esc>), which which-key showed unlabelled.
  - n <C-w> shadowing the native window-command prefix is left as-is: it is the deliberate VS Code-style binding.
  - Tests: every spec that pinned one of these flips to assert the fix, and tests/unit/project_spec.lua covers the new search bound directly. 16 files, 346 assertions, green on both the normal and NVIM_IDE_TEST_SLOW tiers.
- **Drop Gradle/Buildship artifacts from the test fixtures** (`d9b465b`)
  - .gradle/, .project and .settings/ were left in java-plain and spring-gradle by earlier debugging sessions that ran real jdtls and Gradle against those trees, and went in with the suite.
  - Not just noise: jdtls treats a tree with a .project as an already-imported Eclipse project, so a spec's behaviour could depend on whatever state one of those sessions happened to leave behind. Fixtures are inputs only.
  - The suite passes without them and a full run does not recreate them, so nothing was relying on them. .gitignore keeps it that way.
- **Add unit and integration test suite** (`fc5b2d6`)
  - 15 spec files, 328 assertions, ~20s for the whole run. plenary.busted inside real headless nvim processes, one process per spec file so a spec that installs autocmds or starts an LSP client cannot decide a later file's outcome.
  - make test / test-unit / test-integration / test-slow / lint tests/run.sh [unit|integration|all] [pattern]
  - Two tiers. Unit specs run under tests/minimal_init.lua, which deliberately does not source init.lua — a passing unit spec cannot be passing because some plugin happened to be loaded. Integration specs boot the real config, so lazy.nvim's merge and ordering rules and every plugin's config function are part of what is under test.
  - Language servers are faked in-process (tests/helpers/fake_lsp.lua): vim.lsp accepts a function as `cmd` and uses it as the transport, which gives a real vim.lsp.Client with real capability resolution, real LspAttach and real dynamic registration, with no binary and no project. That is what makes the capability-gated behaviour (which keymaps appear, which client may supply inlay hints) testable at all — the real servers take tens of seconds and decide those things for themselves.
  - Covered: options, keymaps (cross-checked against the source text in both directions so the expectation table cannot rot), autocmds including every auto-save guard, claude_cli, the JDK search, the plugin spec tables, that all 71 plugins load, LSP on_attach, nvim-cmp, conform's formatter selection, angularls and spring-boot project gating, the jdtls config assembled by ftplugin/java.lua, treesitter, and the inlay-hint ownership rule as a regression suite for the redraw crash.
  - The suite pins several known config bugs as current behaviour rather than quietly fixing them, each commented so that fixing one surfaces as a failing expectation. tests/README.md lists them, along with the traps that cost the most time here — maparg falling back to global mappings, --noplugin silently making lazy.setup() a no-op, dynamic capability registration not re-running on_attach, and nvim's own ftplugins starting treesitter regardless of the size guard.
- **Fix autocomplete correctness and latency across all configured languages** (`a4c8049`)
  - Autocomplete was broken or laggy in several distinct ways. Each fix is commented in place with the symptom it produces; the headlines:
  - Inlay hints crashed on every redraw. nvim 0.12 stores hints per client but tracks staleness with a single per-buffer version stamp, so any second provider's response — including an empty one — re-validates the first provider's stale columns and the decoration provider then raises "inlay_hint.lua:362: Invalid 'col': out of range" continuously. Hints are now single-owner per buffer, with a rank so jdtls/ts_ls can take over from a server that answered first with nothing, and released on LspDetach/BufWipeout.
  - JDK discovery. jdtls and the Spring Boot LS only honoured $JAVA_HOME or bare `java` on PATH, so a Homebrew keg-only JDK was never found and Java completion silently did not work. lua/config/jdk.lua globs the real install locations on macOS, Linux and Windows, and both servers now pin an explicit JDK (21+ for jdtls, 17+ for boot-ls) instead of inheriting whatever `java` resolves to.
  - Auto-save and auto-reload fought the completion engine. Auto-save on InsertLeave wrote on every exit from insert mode, which triggered conform's async format-after-save and rewrote the buffer ~130ms later — after typing had resumed. Auto-reload on CursorHoldI reloaded buffers from disk while in insert mode, destroying the completion context. Both events are removed, the mode guard is widened, and auto-save now skips (with a warning) rather than stalling on the invisible "changed on disk" prompt.
  - Treesitter highlighting is now size-guarded: an incremental reparse is paid on every keystroke before cmp debounces, so a 20k-line file read as the completion menu lagging.
  - Visual-mode mappings were bound with "v", which also covers SELECT mode — where LuaSnip puts the cursor on a snippet placeholder and any printable key should replace the selection. Typing J, K or a digit over a placeholder ran these commands instead. All are "x" now.
  - Also: winborder set once instead of per-call-site (cmp's bordered() returns "none" without it), vim.diagnostic.jump instead of the deprecated goto_next/ goto_prev, and vim.g.navic_silence to quiet the cosmetic barbecue/navic warning that had previously been "fixed" by disabling ts_ls in Angular projects.

## 2026-08-09

- **Add inline git blame that appears after the cursor rests on a line** (`0ab0aeb`)
  - gitsigns.nvim already had this built in (current_line_blame), just unused. Shows "<author>, <relative time>" as virtual text after a 500ms delay on the current line — matches the GitLens-style inline blame shown as a reference (VS Code). Only ever activates on git-tracked buffers, same as the rest of gitsigns. leader+gb (blame_line) stays as the on-demand full popup for the complete commit message.
  - Verified the rendered extmark text directly against this repo: "You, 2 months ago", not just assumed the config took effect.
- **Auto-reveal current file in the file explorer on every buffer switch** (`0b8c91e`)
  - nvim-tree's update_focused_file was off — Ctrl+Shift+e already did a manual reveal, but switching files otherwise left the tree wherever it was. Enabled it so every buffer switch auto-expands and focuses the current file's path in the tree, without force-collapsing other folders you have open. Verified end-to-end: opening a file in a subdirectory correctly expands into it and focuses the tree cursor on that file.

## 2026-08-08

- **Ctrl+\ terminal opens/cd's to the current file's directory** (`6abae6c`)
  - Previously used toggleterm's default open_mapping, which just opens in whatever directory Neovim itself was launched from and never changes. Replaced with a dedicated Terminal instance + custom toggle:
  - First open: sets .dir before spawning, so termopen()'s initial cwd is correct (verified via the real process's /proc/<pid>/cwd, not assumed).
  - Already-running shell: calls the built-in Terminal:change_dir(), which sends an actual `cd` to the live shell — process stays alive (history, env, running jobs preserved), just navigates. Also verified via /proc/<pid>/cwd that the shell's real cwd actually changes when switching files and re-toggling.
  - Guarded on buftype ~= "terminal" so pressing Ctrl+\ from inside the terminal itself (to close it) doesn't try to cd based on the terminal buffer's own non-path "filename".

## 2026-08-07

- **Only start Spring Boot LS on actual Spring Boot projects** (`21e8071`)
  - spring-boot.nvim's own autocmd starts boot-ls on *every* .java file unconditionally — it only filename-gates .yaml/.jproperties (checking they're actually application.yml/application.properties), nothing gated .java on whether the project has Spring Boot as a dependency at all. That meant boot-ls was attaching (and wasting resources) on plain Java/Gradle projects like JavaAlgo.
  - Disabled the plugin's own autocmd (autocmd=false) and replaced it with a gated version: for .java files specifically, checks whether any build.gradle/build.gradle.kts/pom.xml from the buffer's directory up to the project root actually mentions org.springframework.boot before starting boot-ls. yaml/jproperties keep the plugin's own existing checks unchanged (delegated to launch.update_ls_config/start as before).
  - Hit two more real bugs while getting this working, not just assumed it worked on the first pass:
  - The FileType event that lazy-loads this plugin fires *before* an autocmd registered inside its own config() can see it, so the very buffer that triggered the load was silently skipped — fixed by also calling the same start logic directly on the current buffer, not just relying on the autocmd for future ones.
  - setup()'s return value has no cmd/root_dir; those only get computed by launch.update_ls_config(), which the plugin's original autocmd always called before start() and which I'd skipped — silently passing cmd=nil to vim.lsp.start(), a no-op with no error.
  - Verified end-to-end against two real projects: a plain Gradle project (JavaAlgo) shows only jdtls attached; an actual Spring Boot project (spring-boot-3-jwt-security) shows both spring-boot and jdtls attached.
- **Fix telescope-ui-select crash on Ctrl+./F4 code actions** (`f9f734c`)
  - The global layout_config = { preview_width = 0.55 } added in the last commit was flat/top-level, which the "horizontal" strategy (find_files, live_grep, etc.) accepts fine but "center" (what get_dropdown() — and therefore telescope-ui-select — forces) strictly rejects with "Unsupported layout_config key for the center strategy: preview_width", crashing every vim.ui.select call including code actions.
  - Nested preview_width under horizontal specifically instead, matching Telescope's own per-strategy config convention, so it only applies to the strategy that actually supports it. Verified by directly invoking vim.ui.select() (no error, was reliably crashing before) and confirming find_files still resolves its preview_width correctly.
- **Replace plain-list code action picker with a navigable Telescope window** (`3e1dc2d`)
  - vim.lsp.buf.code_action() (Ctrl+./F4) was falling back to Neovim's default vim.ui.select UI — a flat numbered list at the bottom you type a number into, not something you can navigate. Added telescope-ui-select.nvim, which redirects vim.ui.select() through a real floating Telescope dropdown instead — same fix applies to jdtls's other vim.ui.select-based menus (Generate Constructors, Override/Implement Methods, this repo's own run-without-debug/code-lens pickers in ftplugin/java.lua). Verified vim.ui.select's resolved source is actually telescope-ui-select's implementation, not the stock default.
- **Apply Google JS/TS style guide as the no-config Prettier fallback** (`a192f4e`)
  - Fetched both style guides directly (jsguide.html, tsguide.html) rather than relying on memory. Confirmed: Prettier's stock defaults already match nearly everything both guides state explicitly (2-space indent, 80-col wrap for JS, semicolons, trailing commas, K&R braces). The one real, confirmed mismatch is quote style — both guides explicitly mandate single quotes; Prettier defaults to double.
  - Projects with their own prettier config are untouched — still exactly respected as before (verified: a project's double-quote/4-space config still produces double-quote/4-space output, unchanged).
  - Projects with no prettier config now fall back to a new prettier_google formatter (plain prettier + --single-quote) instead of skipping Prettier entirely. prettierd can't take this override — it doesn't accept ad-hoc CLI args — so mason-tool-installer now also installs plain prettier alongside it.
  - Note: naming/language-feature rules (no var, interfaces over type aliases, etc.) are ESLint's domain, not Prettier's, and need Google's own eslint-config-google/gts installed per-project — there's no editor-global equivalent the way jdtls's formatter profile works for Java, since the eslint language server needs a real project config to have any rules to check against.
  - Hit and fixed two real bugs while verifying this, not just assumed it worked: prepend_args is silently inert on a new (non-built-in-override) formatter name — conform only reads it via its override-merge path — so args had to be wrapped directly instead; and plain prettier wasn't actually installed anywhere on this machine (only prettierd was, via Mason), which the first end-to-end test caught immediately.
- **Implement Google Java Style Guide formatting** (`7ef915c`)
  - jdtls's format.settings had no url set, so it was silently using Eclipse's own default formatter profile — not Google style, despite a stale comment claiming otherwise (different import layout, no enforced 100-col wrap).
  - Added java-google-style.xml: Google's own official Eclipse formatter profile (google/styleguide, gh-pages branch), wired via format.settings.url + profile = "GoogleStyle".
  - importOrder simplified to a single ungrouped block — Google style (§3.3.3) sorts all imports as one ASCII-sorted block, not grouped by package prefix with blank-line separators.
  - Java indent changed 4->2 spaces (§4.2) and colorcolumn=100 added (§4.4), so what you type before format-on-save already matches the formatter's actual output instead of visually fighting it.
  - Verified end-to-end against a real jdtls session: format-on-save produces correct 2-space/K&R-brace output, and Organize Imports (F9) now sorts ArrayList before List per ASCII order instead of leaving file order.
- **Add Ctrl+. as a code-action alias for VS Code muscle memory** (`39b4386`)
  - F4/leader+ca already trigger code actions; extracted the shared guard logic (warns if no LSP is attached instead of erroring) into a local function and bound Ctrl+. to it too, since that's the familiar Quick Fix shortcut from VS Code and other editors.
- **Remap live grep off Ctrl+Shift+F — terminals claim it as their own find** (`3044bf5`)
  - User hit this directly: pressing the old Ctrl+Shift+F binding opened the terminal emulator's own "Find in terminal" overlay instead of Telescope, since the terminal intercepts that combo before Neovim ever sees the keypress. Moved to leader+/ — Space has no modifier key for a terminal to claim, so it's structurally immune to this class of collision. Updated the keymap reference doc/Artifact to match.
- **Resync keymap reference doc; use vim.uv instead of deprecated vim.loop** (`996ebb3`)
  - docs/keymaps.html was last regenerated before ~10 commits worth of keymap changes. Added: call hierarchy (leader+lc/lC), global symbol search (leader+ls/lw), conditional breakpoint (Shift+F9) and run-last (Ctrl+F5), diffview (leader+gv/gh), session management (leader+uqs/ql/qd), Flash/illuminate navigation, normal-mode line move (Alt+j/k), and the Ctrl+w behavior change (bufdelete.nvim). 138 shortcuts across 16 categories now, up from the original page. Republished to the same Artifact URL so "load up keymaps" still resolves correctly.
  - init.lua: vim.loop is the long-deprecated alias for vim.uv.

## 2026-08-06

- **Guard AI panel against empty selections and silent failures** (`e55af8f`)
  - Explain/Refactor/Fix/Generate Tests/Generate Docs/Ask About now warn and bail if there's no real visual selection, instead of sending an empty-code prompt.
  - M.ask's floating window now surfaces a clear error if the claude CLI exits non-zero with no output (e.g. not authenticated), instead of hanging on "Asking Claude…" forever. Had to check for actual content via table.concat + match, not just #output == 0 — jobstart's on_stdout fires once with data={""} on stream close even when there's no real output, which defeated a naive empty-table check.
- **Add call hierarchy, conditional Prettier, fix angularls attaching everywhere** (`5607411`)
  - Call hierarchy (<leader>lc incoming / <leader>lC outgoing), via Neovim's built-in vim.lsp.buf.*_calls — capability-gated in the shared on_attach, and mirrored into jdtls's separate on_attach since it doesn't go through the shared lspconfig path.
  - conform.nvim: javascript/typescript formatters now skip Prettier entirely in projects with no .prettierrc*/prettier.config.*/"prettier" key in package.json, falling back to LSP formatting instead. Running Prettier unconditionally applies its own defaults (e.g. double quotes), which can fight a project's ESLint style rules and undo its fix-on-save right after it runs. Scoped to JS/TS only — CSS/JSON/YAML/Markdown keep unconditional Prettier since nothing there governs their style.
  - lsp.lua: angularls's own root_markers (angular.json/nx.json) only governed the *cmd* it built, not whether it attached at all — it fell back to cwd as a "single file" root and attached to every TypeScript file, Angular project or not, duplicating ts_ls's diagnostics and causing the same navic "already attached" conflict as the ts_ls exclusion above exists to prevent, just backwards. Mirrored that exclusion onto angularls so it only starts when angular.json/nx.json is actually present.
- **Wire up unused LSP capabilities, fix treesitter/navic bugs, smarter buffer close** (`82f9720`)
  - lsp.lua: document/workspace symbol search and inlay-hint toggle now apply to every LSP server (previously Java-only); TS/JS inlay hint settings were configured but never actually enabled.
  - editor.lua: scss/less now get prettierd formatting on save (Angular component stylesheets were silently unformatted).
  - debug.lua: conditional breakpoint (Shift+F9) and run-last (Ctrl+F5), both plain nvim-dap API calls that had no keymap.
  - java.lua: stop the Spring Boot LS from claiming documentSymbolProvider, fixing a recurring "nvim-navic: Failed to attach to spring-boot ... Already attached to jdtls" warning from barbecue's winbar breadcrumbs.
  - treesitter.lua: this config runs nvim-treesitter's main branch, whose setup() dropped `ensure_installed`/`auto_install` (only `install_dir` remains) — those options were silently no-ops. Replaced with an explicit install() call plus a FileType autocmd to restore auto-install behavior. Also dropped `jsonc`, which isn't a real parser (core already maps it onto `json`) and was failing to install silently.
  - options.lua: relativenumber off, per feedback.
  - ui.lua/keymaps.lua: added bufdelete.nvim and wired it into bufferline's close_command and <C-w> — plain :bdelete doesn't pick a sibling buffer before closing, which was letting other splits expand into the gap instead of showing the next open tab.

## 2026-08-05

- **Add fidget, treesitter-context, diffview; fix LazyGit float crash** (`2784c92`)
  - fidget.nvim: visible LSP progress messages (e.g. jdtls workspace build %)
  - nvim-treesitter-context: sticky function/class signature while scrolling
  - diffview.nvim: full diff view (<leader>gv) and file history (<leader>gh)
  - terminal.lua: LazyGit float_opts width/height were fractional numbers passed straight to nvim_open_win, which requires integers ("Invalid 'width': Number is not integral"). Resolve them via functions instead.

## 2026-07-28

- **Restyle matching bracket highlight, drop active-scope indent guide** (`9f05512`)
  - MatchParen: replace default underline with an ayu-mirage selection-bg box highlight, so cursor-on-bracket pairs stand out like VS Code's bracket-pair highlight.
  - ibl scope (brace-to-brace indent line) tried and disabled per feedback.

## 2026-07-25

- **Add flash, illuminate, colorizer, persistence; normal-mode line move** (`109f411`)
  - flash.nvim: fast jump-to-any-location motions (s/S/r/R)
  - vim-illuminate: highlight refs to symbol under cursor, ]]/[[ to jump
  - nvim-colorizer.lua: inline hex/rgb swatches for css/scss/html/ts/js/lua
  - persistence.nvim: per-project session save/restore under <leader>uq
  - keymaps: Alt+j/Alt+k move current line in normal mode (no selection needed)

## 2026-07-18

- **Revert updateBuildConfiguration to automatic** (`6b257d5`)
  - "interactive" (from the CPU-tuning commit) traded a rare, cheap cost for real friction: new dependencies (e.g. adding Lombok to a project) silently stopped resolving until a reimport was manually triggered via :JdtUpdateConfig, with no obvious signal why. The reimport only runs when a build file is actually saved, so "automatic" isn't a continuous cost — just a per-save one, which is when you actually want it to happen anyway.

## 2026-07-16

- **Merge pull request #2 from lwemzy/java-angular-spring-tooling** (`f53fcd5`)
  - Java angular spring tooling
- **Reduce jdtls background CPU: interactive build config, drop CursorHold refresh** (`b5ddedc`)
  - updateBuildConfiguration: "automatic" -> "interactive". Automatic mode silently reimports the whole Gradle project model in the background on every build-file-adjacent change; interactive prompts instead.
  - Code lens no longer refreshes on CursorHold. It was firing every ~4s (default updatetime) of no cursor movement, making jdtls redo a references+implementations search across the whole visible file while idly reading code. Still refreshes on BufEnter/InsertLeave/BufWritePost.
  - Prompted by a separate system-resource-usage session flagging sustained ~40% CPU from the jdtls process; these are two verified, recurring, avoidable costs in this config, though not confirmed as the sole cause.
- **Fix Java run/debug reliability issues and add keymap reference doc** (`ef68c36`)
  - ftplugin/java.lua: bump jdtls heap 2G -> 4G (OOM was corrupting the JDT search index, breaking vscode.java.resolveMainClass and causing "No configuration found for `java`" on <F5>). Switch the debug console to internalConsole so output routes through dapui instead of a separate run_in_terminal split, which was getting evicted by dapui's own layout reorganization on session start and silently orphaning a terminal buffer per run. <leader>dR now also opens dapui explicitly, since noDebug launches don't reliably fire the event_initialized listener that normally does this.
  - lua/plugins/debug.lua: dapui no longer auto-closes on session terminate/exit for noDebug sessions specifically — a quick console app can finish in under a second, so the old unconditional auto-close was tearing the panel down before its output was ever visible.
  - lua/plugins/java.lua: fix spring-boot.nvim's root_dir being computed once as a static string at plugin-config time (possibly before any .java buffer existed), which could resolve to an empty string and bake a malformed "file://" URI into the server config, crashing it on every document event for the rest of the session. Let it use its own per-call root_dir fallback instead.
  - docs/keymaps.html: searchable reference of every keymap in this config, synced with the version published as a Claude Artifact.

## 2026-07-12

- **Merge pull request #1 from lwemzy/java-angular-spring-tooling** (`c17847b`)
  - Add Spring Boot/Angular support, run-without-debug, and fix code lens…

## 2026-07-11

- **Add Spring Boot/Angular support, run-without-debug, and fix code lens rendering** (`296feb3`)
  - ftplugin/java.lua: extendedClientCapabilities, <leader>dR run-without-debug (jdtls main-class discovery with noDebug), <leader>dB conditional breakpoints, <leader>dr REPL toggle, document/workspace symbol keymaps, format-on-save, and a custom inline code lens renderer that shows references/implementations counts only on the cursor's line (bypasses vim.lsp.codelens's default virt_lines-above rendering, and resolves unresolved lenses via codeLens/resolve). JdtlsClean now waits for a real LspDetach event instead of a fixed 3s timer. Wires spring-boot.nvim's jdtls extension jars into the existing bundle builder.
  - lua/plugins/java.lua: add JavaHello/spring-boot.nvim for Spring Boot Language Server <-> jdtls classpath sync.
  - lua/plugins/lsp.lua: add angularls and vscode-spring-boot-tools; scope ts_ls off in projects with angular.json so angularls is the sole TS server there (fixes duplicate diagnostics and an nvim-navic attach error).
  - lua/plugins/debug.lua: add a pwa-chrome dap config for debugging `ng serve` in Chrome, reusing the existing js-debug-adapter server.
  - lua/plugins/treesitter.lua: add the angular parser.
  - lua/plugins/theme.lua: rainbow-delimiters colors now sourced from ayu-mirage's own syntax palette instead of arbitrary hex values (fixes a harsh red and makes brackets read as part of the theme). The real prior bug was that Treesitter parsers were never actually installed on disk, which silently broke rainbow-delimiters entirely regardless of colors.

## 2026-07-02

- **Add rainbow delimiters, fix jdtls errors, load DAP adapters at startup** (`2f3ad67`)
  - Add HiPhish/rainbow-delimiters.nvim with ayu-mirage colour overrides
  - Register _java.reloadBundles.command handler so jdtls doesn't error on workspace/executeClientCommand calls when debug bundles are present
  - Add Java debug keymaps (<leader>db/dt/du) since F9/F10/F11 are taken by Java-specific tools in the ftplugin
  - Load nvim-dap on VeryLazy so mason-nvim-dap installs java-debug-adapter and java-test at startup rather than waiting for a debug keypress

## 2026-06-21

- **Re-add reload timer; skip during terminal streaming to fix cursor** (`212a8d4`)
  - Timer runs every 2s but skips checktime when mode is 't' (terminal insert) so it doesn't interrupt Claude while streaming output. Fires normally when the user has switched to a code buffer or is in terminal normal mode.
- **Fix cursor breaking in Claude panel; improve file reload trigger** (`40bb422`)
  - Remove periodic checktime timer (was disrupting terminal cursor rendering). Add TermLeave to auto_reload autocmd so checktime fires precisely when switching away from the Claude terminal — no more cursor corruption.
- **Auto-reload buffers while Claude panel is open** (`7333135`)
  - Poll checktime every 2s when the panel is open so any file Claude edits on disk is reflected immediately in the open Neovim buffers without the user having to manually switch windows or trigger a reload.
- **Add silent MCP-based file context for Claude panel** (`c840cb8`)
  - Add nvim_context_server.py: minimal MCP server exposing get_current_file tool
  - Register server in ~/.claude.json as nvim-context MCP server
  - On every BufEnter, write current file/language/line to /tmp/nvim-claude-ctx
  - Claude panel starts with --append-system-prompt to auto-call the tool
  - File switches update context silently with zero UI noise
  - Keep file_prefix() for floating window commands (explain/refactor/fix etc.)
- **Fix deprecation warnings and save errors** (`e160b70`)
  - Replace vim.loop with vim.uv in auto_create_dir (removed in nvim 0.11)
  - Replace vim.lsp.set_log_level with vim.lsp.log.set_level (nvim 0.11)
  - Replace vim.lsp.with handlers with vim.lsp.config wildcard handlers
  - Wrap EslintFixAll in pcall to suppress errors when no eslint config present
  - Switch conform format_on_save async to format_after_save
  - Add autoread + checktime autocmd for external file change detection
  - Add lspkind codicons preset for completion menu icons

## 2026-06-15

- **Fix jdtls stability, log errors, and completion icons** (`bec39b6`)
  - Move jdtls.setup_dap() before start_or_attach to fix _java.reloadBundles.command error
  - Pre-create workspace dir to fix LaunchingPlugin.writeInstallInfo crash
  - Enable autobuild for MapStruct/Lombok annotation processing
  - Add Gradle auto-refresh and new Java file reindex autocmds
  - Fix capability checks in on_attach to prevent MethodNotFound errors
  - Exclude jdtls from mason-lspconfig automatic_enable to prevent duplicate instances
  - Add Spring Boot YAML schema mapping
  - Add log keymaps (F1, C-S-n, C-S-l)
  - Switch completion icons from Material icons to lspkind (VS Code codicons)
  - Increase prettierd format timeout to 5s
  - Fix neoscroll C-b conflict with Telescope buffers
  - Add render-markdown.nvim for in-editor markdown preview

## 2026-06-01

- **Initial Neovim full-stack IDE configuration** (`cfb402a`)
  - TypeScript + Java/Spring Boot IDE with LSP, DAP, treesitter, completion, formatting (conform + prettierd), testing (neotest), git UI (lazygit + gitsigns), Claude CLI integration, Ayu Mirage theme, and FiraCode Nerd Font.

