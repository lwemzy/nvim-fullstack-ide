# Tests

Unit and integration tests for this Neovim config, run with
[plenary.busted](https://github.com/nvim-lua/plenary.nvim) inside real headless
Neovim processes.

```sh
make test              # everything
make test-unit         # fast: no plugins, no language servers
make test-integration  # boots the real config
make test-slow         # also runs the specs gated on real language servers
make lint              # every Lua file in the repo parses

tests/run.sh unit jdk           # only specs whose path matches "jdk"
tests/run.sh integration inlay
NVIM_TEST_BIN=/path/to/nvim tests/run.sh
```

Exit code 0 means every spec file passed. The runner prints one section per spec
file and a summary at the end.

Two things in that summary matter as much as the pass count:

- **`skipped assertions: N`** counts `H.skip()` lines. plenary has no runtime
  skip, so a spec that returns early because mason is missing a package still
  prints `Success` — without this count a green suite on a bare machine would
  look like it proved something.
- **`TIMEOUT:`** means the file was killed (default 180s, `NVIM_IDE_TEST_TIMEOUT`).
  Headless nvim still waits on interactive prompts and prints nothing while it
  does, so a hang is otherwise silent and unbounded.

## Two tiers

|                  | `tests/unit/`                    | `tests/integration/`               |
| ---------------- | -------------------------------- | ---------------------------------- |
| init             | `minimal_init.lua`               | `full_init.lua`                    |
| lazy.nvim        | never set up                     | the real `lazy.setup("plugins")`   |
| plugins          | none loaded                      | loaded (force one with `H.load_plugin`) |
| language servers | none                             | fake, in-process (`helpers.fake_lsp`) |
| speed            | ~1s per file                     | seconds                            |

`minimal_init.lua` deliberately does **not** source `../init.lua`. A unit spec
that passes there cannot be passing because some plugin happened to be present.

`full_init.lua` does the opposite — it `dofile`s the real `init.lua`, so
lazy.nvim's own merge and ordering rules and every plugin's `config` function
are part of what is under test. Anything reconstructed by hand there would be
testing a copy of the config instead of the config.

The tier split is about plugins and language servers, not about staying in
process: `mcp_server_spec` is a unit spec that runs `mcp/nvim_context_server.py`
as a real subprocess, because the framing it has to get right (newline-delimited
JSON, and *nothing else*, on stdout) is exactly what calling `handle()` directly
would not check. What a unit spec must not do is need a plugin.

One nvim process per spec file. These specs install autocmds, replace
`vim.lsp.handlers` entries and start LSP clients; per-file isolation is what
keeps a failure from depending on file order, and stops one hung server from
taking the whole suite down.

## Layout

```
tests/
  run.sh              runner (suite + optional path pattern)
  minimal_init.lua    unit tier init
  full_init.lua       integration tier init
  helpers/
    init.lua          H.* — stubs, temp files, buffers, keymaps, waiting, cleanup
    fake_lsp.lua      in-process fake language server
    specs.lua         static loader for lua/plugins/*.lua (no plugin loaded)
  fixtures/           minimal project trees (see fixtures/README.md)
  unit/
  integration/
```

## Writing a spec

`tests/unit/jdk_spec.lua` and `tests/integration/inlay_hint_spec.lua` are the
two exemplars — read one before adding a file.

```lua
local H = require("helpers")            -- package.path is set up by the init

describe("thing", function()
  after_each(function() H.cleanup() end)  -- always

  it("does the thing", function()
    ...
  end)
end)
```

`H.cleanup()` undoes every stub, temp directory, buffer, LSP client and augroup
the helpers created. Call it from `after_each` in every `describe` block that
creates state — a spec that leaks a stubbed `vim.fn` function would otherwise
silently decide the outcome of a later spec in the same file.

## Shared helpers

`require("helpers")` — every one of these exists because a spec got it wrong
first. Check here before writing a local equivalent.

| Helper | Use it because |
| --- | --- |
| `H.stub` / `H.spy` | undone by `H.cleanup`; `spy` returns the call log with `.count` |
| `H.capture_notifications(fn, {settle_ms})` | `settle_ms` is required for `vim.schedule`d notifies (lazy config errors, conform's async format) |
| `H.capture_ex(fn)` / `H.ran_ex` | the only observable for code whose job is deciding whether to reach `silent! write` / `silent! checktime` |
| `H.tmpdir` / `H.write` / `H.read` / `H.read_text` | `H.read` returns nil for a missing file, so "was not written" reads like "was written" |
| `H.touch` / `H.external_write` | `getftime()` is second-resolution: a same-second rewrite is indistinguishable from no change, so mtime must be stamped, not slept for |
| `H.fixture(name)` | copies the tree to a temp dir (the config auto-saves on `BufLeave`) and creates `.git` |
| `H.scratch({scratch=false})` | unnamed-normal and unnamed-`nofile` are two *different* auto-save exclusions |
| `H.named_buf(path)` | a name with no load: no filetype detected, no server started, and root detection sees exactly what it would |
| `H.quiet_buffer(path, ft)` | loaded and current with `ft` set, `FileType` suppressed — the way to touch `java`/`typescript` without launching jdtls or ts_ls |
| `H.buf_keymap` / `H.has_buf_keymap` | `maparg` falls back to the *global* mapping, which silently turns every absence assertion into a no-op |
| `H.disable_autosave()` | any spec that opens a file and is not about auto-save |
| `H.load_plugin(name)` | force a lazy-loaded plugin now, via `lazy.core.loader` |
| `H.has_plugin(module)` | declared ≠ installed; skip rather than fail on a bare machine |
| `H.wait_for(label, fn)` | fails with the label instead of hanging |
| `H.track_buf` / `H.track_client` / `H.track_augroup` | hand `H.cleanup` something it did not create |

`helpers.fake_lsp` starts a real `vim.lsp.Client` over an in-process transport —
real capability resolution, real `LspAttach`, real dynamic registration, no
binary and no project. `helpers.specs` loads `lua/plugins/*.lua` statically, for
assertions about the spec tables themselves.

Conventions worth following:

- **Comment why an assertion matters**, not what the code does. The useful
  comment is the one that says what breaks in the editor if the assertion fails.
  Most of these tests exist because something was actually broken once.
- **Assert current behaviour, not intended behaviour**, when you find a bug —
  and say so in the test's comment. A test that fails for a known reason trains
  people to ignore the suite.
- **Prefer real filesystem calls over mocks.** `jdk_spec` builds real JDK-shaped
  directories and fakes only `vim.fn.glob`, because glob's patterns are absolute
  system paths a test cannot create. That keeps the parsing and path-resolution
  logic under test against the real `filereadable`/`executable`.
- **Never write outside `H.tmpdir()`.** The config auto-saves on `BufLeave`, so a
  spec that opened a file in place would rewrite it. `H.fixture(name)` copies the
  fixture tree to a temp dir for the same reason. Call `H.disable_autosave()` in
  any spec that opens files and is not about auto-save.

## Gotchas, all learned the hard way

- **Do not set a buffer's filetype to `java`.** That runs `ftplugin/java.lua`
  and launches the real jdtls: tens of seconds, and machine-dependent. A `.ts`
  buffer likewise starts ts_ls/angularls. Keep filetypes neutral unless the
  filetype *is* the subject; `java_ftplugin_spec.lua` shows the alternative —
  spy on `jdtls.start_or_attach` and assert on the config it would have used.
- **`vim.lsp.start` reuses an existing client whose config matches**, so `cmd` is
  never called again and a fake server's dispatchers stay `nil`. Give every fake
  a unique `root_dir = H.tmpdir(...)`.
- **A fake transport must call `dispatchers.on_exit`** or `client:stop()` never
  completes. `helpers/fake_lsp.lua` does this in `terminate`.
- **`require("lazy").load` errors in a headless session** (it routes through
  `lazy.manage`, whose task module reads `Config.options.headless` at require
  time). Use `H.load_plugin`, which goes via `lazy.core.loader`.
- **`--noplugin` breaks integration runs.** It clears `loadplugins`, and
  `lazy.setup()` returns immediately when that is off, so the plugin spec is
  silently never parsed. The runner passes it for unit specs only.
- **`vim.cmd("edit")` is a table call, not `vim.cmd.edit`** — spying on the field
  does not intercept it.
- **Headless Neovim never redraws**, so decoration-provider errors (the class of
  bug `inlay_hint_spec.lua` guards against) can never surface here. That spec
  asserts the *stored state* that makes the crash unreachable instead. Verifying
  the rendering itself needs a pty.
- **`cmp.visible()` is always false headless.** Assert on cmp's configuration and
  mapping table, not on popup state.
- **`nvim_win_set_cursor` clamps to end-of-line** in normal mode; set
  `virtualedit = "onemore"` if a spec needs a column past the last character.
- **A missing tool is not a config bug.** If a mason package, a treesitter parser
  or a JDK is absent, `H.skip("reason")` and move on rather than failing the
  suite for an environment problem. Specs that need a real language server are
  gated behind `NVIM_IDE_TEST_SLOW`.
- **`maparg` falls back to the global mapping.** Use `H.buf_keymap` for anything
  buffer-local — nvim ships global `gr*`/`K` LSP defaults and `config/keymaps.lua`
  owns most of `<leader>`, so a naive absence check passes for the wrong reason.
- **Registering a capability dynamically does not re-run `on_attach`.** nvim's
  `client/registerCapability` handler only calls `vim.lsp._set_defaults` and
  re-attaches the internal `vim.lsp._capability` providers, so `LspAttach` never
  fires a second time. Anything gated on `server_capabilities` at attach time
  never appears for a server (jdtls) that registers later.
- **`:checktime` from inside an autocmd is postponed** until the main loop is in
  a safe state, which a headless `-c` command never reaches. Assert the ex-command
  (`H.capture_ex`) and the event subscription separately, or call the registered
  callback directly.
- **nvim's own ftplugins call `vim.treesitter.start()` unconditionally** for
  `lua`, `markdown`, `help` and `query`, so a large-file opt-out cannot be tested
  with those filetypes. `treesitter_spec` uses `toml`/`xml`.
- **cmp normalises mapping keys**: `<C-k>` is stored as `<C-K>`. Asserting the
  un-normalised form proves nothing.
- **`vim.lsp.start` consumes the config it is handed verbatim**; only the
  `vim.lsp.enable` path reads `vim.lsp.config[name]`. A fake server therefore
  never sees the wildcard config — assert on `vim.lsp.config["*"]` and on the
  resolved per-server config instead of on `initialize` params.
- **`:w` on a file that changed on disk prompts** (`W12`) and hangs the run. Use
  `:w!`, or assert the ex-command rather than performing the write.
- **`vim.fs.find` searches the starting directory *before* it starts comparing
  parents against `stop`**, and the comparison is raw string equality against
  `vim.fs.dirname`-normalised paths. So a bound only bites when both sides are
  normalised and symlink-resolved the same way (macOS's `/var` is really
  `/private/var`, and `fs_realpath` returns nil for a directory that does not
  exist yet), and the starting directory needs a guard of its own.
- **nvim switches inlay hints off itself on `LspDetach`** once no attached client
  supports them (`runtime/lua/vim/lsp/inlay_hint.lua`). Any per-buffer state a
  config keeps alongside that has to be reset with it.
- **A `workspace/didChangeWatchedFiles` registration needs `registerOptions`** —
  nvim's handler dereferences it, so a bare `{ id, method }` from `fake_lsp`
  errors. Use a method nothing internal handles when you just need filler.
- **`vim.tbl_filter` iterates with `pairs`**, and `H.spy`'s log carries a
  non-integer `original` key — so the predicate gets handed a function. Count a
  spy log with `ipairs`.
- **nvim's LSP file watcher is a different implementation per OS.**
  `vim/lsp/_watchfiles.lua` picks recursive `fs_event` on macOS/Windows,
  `inotifywait` on Linux when that binary exists, and per-directory `fs_event`
  otherwise. Anything asserting on watch behaviour passes or fails by OS unless
  it stubs `_watchfunc`, and the fallback is why "a new `.java` file has no
  completion" reproduces only on Linux.
- **Anything reading the environment must be stubbed, or the suite passes by
  accident on one OS.** `config.jdk` now considers bare `java` on PATH: on macOS
  `/usr/bin/java` is a stub with no `release` file and is discarded, but on Linux
  it is a symlink into a real JDK — so `jdk_spec`'s harness stubs `exepath`.
  `health_spec` replaces `config.jdk` outright for the same reason: it caches its
  scan, so the machine's real JDKs would decide the expectations.
- **An empty augroup is invisible to `nvim_get_autocmds`.** nvim has no API that
  lists augroups, and `nvim_get_autocmds({group = ...})` only returns groups that
  still *have* autocmds — which is why a per-buffer augroup name could leak one
  dead group per file opened without any assertion noticing. The discriminator is
  `pcall(vim.api.nvim_get_autocmds, {group = name})`: it errors iff the group does
  not exist. `H.autocmds` swallows that error deliberately, so assert on the raw
  `pcall` when the question is *existence*.
- **nvim deletes a wiped buffer's buffer-local autocmds, not the group they were
  in.** Measured: after wiping 500 buffers, `java_ftplugin_2` had zero autocmds
  and still existed. The shared-group pattern
  (`nvim_create_augroup(name, {clear = false})` + `nvim_clear_autocmds({group,
  buffer})`) has identical replace-not-stack semantics per buffer; `clear = false`
  is load-bearing, since `clear = true` would wipe every *other* buffer's
  autocmds.
- **There is no API to delete a namespace.** Measured: 500 distinct namespace
  names left 502 namespaces, surviving `nvim_buf_delete` and a full
  `collectgarbage`. A fixed name is idempotent (200 calls → 1 namespace), so any
  namespace built from a bufnr leaks for the life of the session. `nvim_get_namespaces()`
  is the observable.
- **nvim never stops an LSP client on its own.** `Client:_on_detach` only clears
  `attached_buffers[bufnr]`, and the only internal `client:stop()` calls are
  `vim.lsp.enable(name, false)` and `VimLeavePre`. A spec about client lifetime is
  therefore a spec about *our* code; `lsp_reap_spec` drives it by passing the clock
  into `sweep()` rather than waiting out a five-minute timer.
- **`LspDetach` fires before `attached_buffers[bufnr] = nil`** and is guarded by
  `nvim_buf_is_valid`, so `:bwipeout` can retire a buffer without it arriving at
  all. Prefer re-deriving state from `attached_buffers` (which nvim's own
  deprecation notice for `get_buffers_by_client_id` names as the supported read)
  over bookkeeping from events. All three retirement routes — `:bwipeout`,
  `:bdelete`, `:bunload` — empty it, but only `:bwipeout` also invalidates the
  buffer, so a check written on validity alone misses two of the three.
- **nvim never recycles a buffer number**, so a table keyed by bufnr cannot be
  poisoned by a *wiped* buffer's leftover entry. `:bdelete` is the case that bites:
  it keeps the buffer in the list, so re-editing that path hands back the same
  bufnr and stale per-buffer state applies to a different file's contents.
  `autocmds_spec`'s abandoned-`.java` case asserts the premise (`assert.equals(buf,
  reopened)`) rather than assuming it.
- **`nvim_create_buf(false, true)` gives `bufhidden = "hide"`, not `"wipe"`** — a
  float's buffer stays valid *and* loaded after `nvim_win_close`. Assert
  `vim.bo[buf].bufhidden` and then that closing the window invalidates the buffer;
  the first assertion alone passes on a config that never opens a window.
- **toggleterm with `close_on_exit = false` orphans the terminal.**
  `__handle_exit` does nothing while toggleterm's own `TermClose` autocmd still
  drops the entry from the registry, so the buffer survives with its full
  scrollback *and* is unreachable from `get_all()`. `Terminal:close()` only hides
  the window; `Terminal:shutdown()` is what closes the window, deletes the buffer
  and drops the registry entry. `terminal_spec` runs real processes (`true`,
  `sleep 30`) because the reaping keys off `vim.fn.jobwait`, so a faked job would
  only test the fake — and force-deletes every terminal buffer it made in
  `after_each`, or the live job keeps the headless session alive.
- **`vim.fn.jobwait({id}, 0)[1] == -1` means still running**; anything else (an
  exit code, or `-3` for an invalid id) means it has exited.
- **A visual-mode Lua callback runs while visual mode is still active, so `'<`
  and `'>` have not been written yet.** Measured through a real `x`-mode mapping:
  `mode()` is `v`, and `getpos("'<")` and `getpos("'>")` are both `{0,0,0,0}`.
  Read the live selection with
  `vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })`,
  which also handles linewise/blockwise and multibyte text that `string.sub`
  slicing cuts in half. This is why `claude_cli_spec` drives the visual commands
  with `nvim_feedkeys` through a real mapping instead of `H.run_keymap`:
  `run_keymap` calls the callback from normal mode, which is precisely the harness
  artefact that hid the bug.
- **Feeding a blockwise selection needs the `<C-v>` termcode, not a raw `\22`
  byte.** A raw byte silently does not enter blockwise mode, the mapping never
  fires, and the assertion then fails against whatever the previous case left
  behind — which reads as a module bug.
- **`vim.fn.termopen` and `vim.fn.jobstart` *throw* `E475: Invalid value for
  argument cmd` for a missing binary**, they do not return `-1`. Any "the CLI
  isn't installed" branch written around the exit code is unreachable, and a
  buffer created before the call is orphaned by the throw.
- **`nvim_win_close` on the only window throws `E444`.** Replacing the buffer is
  the way to make that window stop showing what it was showing — but with an
  explicitly created buffer, because **`:enew` reuses the current buffer when it
  is already empty and unnamed** (measured: `nvim_win_get_buf` returned the same
  bufnr afterwards), so `:enew` is not a reliable way to swap a buffer out.
- **`vim.bo[buf].buftype = "terminal"` is rejected (E474)**, so a spec cannot fake
  a terminal buffer. A `nofile` scratch buffer is the closest stand-in and
  satisfies a `buftype ~= ""` guard for the same reason a real terminal does —
  but it is also unnamed, so pin a name-plus-buftype guard on a *named* scratch
  buffer (`H.scratch({ name = "NvimTree_1", scratch = true })`) instead.
- **Async `vim.uv.fs_rename` calls can complete out of order**, so several
  in-flight writes to one path do not settle on the last one queued. Measured: 80
  rapid buffer switches ending on `other.py` left the file reading `Real.java`.
  Testing the fix needs the libuv callbacks *queued* rather than run inline —
  `claude_cli_spec`'s `capture_ctx({ manual = true })` — because a stub that calls
  back synchronously makes every write finish before the next one starts, which is
  the one interleaving that cannot go wrong.
- **`vim.uv.fs_open` and friends dispatch ~800× faster than `io.open`** for the
  same small write (0.8µs vs 652.9µs measured), so a per-`BufEnter` write is not
  something to reach for `io.open` for.
- **nvim's LuaJIT has no `table.pack` or `table.unpack`** (both are `nil`; the
  global `unpack` is what exists). Use `{ n = select("#", ...), ... }` and
  `unpack(args, 1, args.n)`. A call to the missing one throws from inside a stub,
  where an autocmd callback swallows it and the spec fails somewhere unrelated.
- **`jobstart`'s `on_stdout` hands back the fragment after the last newline as the
  final element**, so a complete line arrives as `{ line, "" }`. A fixture that
  omits the `""` means "this line is not finished yet" and the code under test is
  right to hold it — an easy way to write a test that fails against working code.

## Config bugs these tests found

### Fixed, and now asserted the other way round

Each was first pinned as current behaviour, then fixed; the specs listed are the
ones that would fail if it came back.

- `<F1>` was mapped to `:LspLog`, which **does not exist** on Neovim 0.12:
  nvim-lspconfig's `plugin/lspconfig.lua` returns early when `:lsp` exists, so it
  registers no `Lsp*` command at all, and 0.12's own `:lsp` takes only
  `enable|disable|restart|stop` — there is no `log` subcommand. It now opens
  `vim.lsp.log.get_filename()` directly, in a new tab and `readonly` +
  `nomodifiable` — auto-save writes any modified normal buffer on `BufLeave`, so
  one stray keystroke in a log would be written back over the file the server is
  still appending to. (`:checkhealth vim.lsp` replaced `:LspInfo`.) —
  `keymaps_spec`, `plugins_load_spec`
- `auto_create_dir` fed URL-ish buffer names straight to `mkdir`, creating a
  cwd-relative junk tree (`./oil:/tmp/...`) whenever an `oil://`/`fugitive://`
  buffer was written. It now returns early on any non-empty `buftype`. —
  `autocmds_spec`, `editing_spec`
- `has_prettier_config` and `is_spring_boot_project` searched upward with no
  `stop` bound, so a `.prettierrc` or `pom.xml` above the project (e.g. in
  `$HOME`) changed behaviour for every project on the machine. Both now go
  through `config.project.find_upward`, bounded at the VCS root — which also
  fixed multi-module Maven builds, where the parent POM that declares
  spring-boot sits above the module. — `project_spec`, `conform_spec`,
  `project_gating_spec`
- `on_attach` gated on `client.server_capabilities`, which never gains
  dynamically registered methods — and jdtls registers most of its capabilities
  that way, so `<leader>rn`, `<leader>ca` and `gr` never appeared in a Java
  buffer. It now gates on `client:supports_method(method, bufnr)` and re-runs
  from the `client/registerCapability` wrapper. — `lsp_attach_spec`
- Nine mappings in `config/keymaps.lua` had no `desc` (split resize, centred
  scroll/search, `<Esc>`), so which-key showed them unlabelled. — `keymaps_spec`

### Found by code review of those fixes, fixed and pinned here

The first round of fixes above introduced or left these; the specs named are the
ones that fail if they come back.

- `on_attach` only ever *added* a capability-gated mapping, so
  `client/unregisterCapability` left a dead key behind — pressing it reported
  "server does not support …", which is what a *missing* mapping would have said
  honestly. The handler is now wrapped in both directions, and the removal
  predicate ignores capabilities another attached client still answers. —
  `lsp_attach_spec`
- The inlay-hint re-enable inferred "hints were never on here" from
  `is_enabled()`, which is equally false after a `<leader>uh` toggle-off — so
  every later jdtls registration switched them back on. `on_attach` now tracks
  first-enable per buffer, re-requests only when a provider actually joins, and
  resets that state when nvim's own `LspDetach` disable fires. —
  `inlay_hint_spec`
- A burst of registrations (jdtls sends several; ts_ls and eslint register two at
  startup) re-ran `on_attach` once per registration — a full `supports_method`
  sweep plus ~14 keymap calls each, per attached buffer. Now collapsed to one
  re-run per buffer per tick. — `lsp_attach_spec`
- `config.project` resolved symlinks in `$HOME` but not in the VCS root or the
  buffer's own directory, and `vim.fs.find` compares `stop` by raw string
  equality — so on macOS (`/var` → `/private/var`), for a project reached through
  a symlink, or for a file in a directory that does not exist yet, the bound
  matched nothing and the walk ran to `/` again. Every path now goes through one
  `resolve()`. — `project_spec`, `conform_spec`
- The prettier check read only the *nearest* `package.json`, so a monorepo
  workspace package got the Google fallback while the repo root's `"prettier"`
  key (and CI) said otherwise. — `conform_spec`

### Found by running the config on a second machine (Linux), fixed here

Both were invisible on the machine the config was written on, which is the point:
they are environment differences, not logic errors, so only a second machine or a
health check surfaces them.

- `config.jdk` probed only `~/.sdkman/candidates/java/current`, so a machine with
  21 installed and 17 *selected* reported no JDK 21 at all — and jdtls refuses to
  launch below 21, so Java completion silently never worked. Every installed
  sdkman JDK is now a candidate, plus `~/.jdks` (IntelliJ), mise/asdf install
  dirs, `$JDK_HOME`, and bare `java` on PATH as the catch-all. — `jdk_spec`
- With no JDK 21+, `ftplugin/java.lua` warned and started jdtls anyway. The
  launcher then aborted itself, leaving a client that attached and immediately
  exited: the visible symptom was completion absent with a one-line startup
  warning as the only clue. It is now fatal and loud, which is safe precisely
  because PATH `java` is a candidate — nil really does mean nothing on the
  machine can run jdtls. — `java_ftplugin_spec`

`:checkhealth nvim-ide` (`lua/nvim-ide/health.lua`, tested by `health_spec`) exists
for this whole class: it reports the JDKs found, which one jdtls will launch on,
the mason payloads whose absence removes a feature silently, and which LSP file-
watching backend this OS gave Neovim.

### Found by auditing memory use, fixed here

Every one of these is unbounded in the number of files or keypresses in a session,
which is what makes them worth fixing however small the per-instance cost: a
per-instance cap is no help when the count is what grows. All were measured, not
inferred.

- `<F3>`/`<M-r>` built a toggleterm `Terminal` per keypress with
  `close_on_exit = false`, so every finished run orphaned its buffer *with the full
  scrollback* (10 000-line default, and libvterm keeps a cell grid per row — a
  `bootRun` saturates that) and unreachable from toggleterm's registry. Finished
  runs are now reaped when the next one starts; live ones are left alone, so
  `npm run watch` alongside a build still works. — `terminal_spec`
- The Claude panel's `on_exit` nil'd `state.buf`/`state.win` and nothing else, so
  `claude` exiting (`/exit`, Ctrl-D, an auth timeout) left both the terminal buffer
  and its window behind — while `panel_is_open()` started reporting false, so the
  next `<C-g>` opened a *second* split with a *second* terminal on top of the
  stale one. `buflisted = false` kept it out of `:ls`. — `claude_cli_spec`
- `M.ask`'s float relied on `nvim_create_buf`'s scratch flag for cleanup, which
  gives `bufhidden = "hide"`: one full response buffer retained per
  `<C-a>`/`<C-1>`…`<C-6>` press, forever. And dismissing the float early left
  `claude -p` running to completion, still appending into a buffer nobody can see;
  a `BufWipeout` handler now stops the job. — `claude_cli_spec`
- Nothing ever stopped a language server, so visiting N Java projects in a session
  ended with N jdtls JVMs *plus* N boot-ls JVMs resident long after their last
  buffer closed. On Linux that ends at the OOM killer, which picks the largest RSS
  — jdtls — so it surfaced as Java completion dying mid-session with nothing in
  nvim to explain it. `config.lsp_reap` now stops the JVM servers only, after five
  idle minutes, and announces it. — `lsp_reap_spec`
- `ftplugin/java.lua` created `java_codelens_<bufnr>` per buffer. Namespaces are
  process-global with no delete API, so that was a permanent entry per Java file
  opened. One shared name is safe because every call was already scoped to `bufnr`.
  Same shape for `java_ftplugin_<bufnr>` and `eslint_fix_<bufnr>`, now shared
  groups cleared per buffer. — `java_ftplugin_spec`, `lsp_attach_spec`
- Abandoning a new `.java` file left its entry in the new-file tracking table.
  With `:bd` that is a wrong answer rather than dead weight: the same bufnr comes
  back on re-edit, and if the file exists by then `BufNewFile` does not re-fire, so
  an ordinary `:w` paid a full `java.projectConfiguration.update`. —
  `autocmds_spec`
- jdtls ran on the launcher's default heap. `-Xmx` is now sized from the machine,
  honouring `vim.uv.get_constrained_memory()` so a container's cgroup limit is
  what counts rather than the host's RAM. — `java_ftplugin_spec`

Reported by the same audit and deliberately *not* fixed: handler-chain deepening
on `:Lazy reload` (session-safe as written), and nvim-notify's append-only history
(tens of KB).

### Found by auditing the Claude/MCP integration, fixed here

The audit raised 44 findings; 24 did not survive being reproduced. These are the
ones that did. Every one was reproduced before it was fixed and re-measured after,
and each is now pinned by a case that fails when the fix is reverted.

- **The visual AI commands sent the wrong code, or none.** The maps are plain Lua
  callbacks with no `:<C-u>`, so they run with visual mode still active and the
  `'<`/`'>` marks unwritten: the first visual command of every session reported "No
  text selected" and sent nothing, and every one after it silently sent the
  *previous* selection. Now reads the live selection with `getregion`, which also
  fixed blockwise `<C-v>` sending whole lines and byte slicing cutting multibyte
  characters in half. — `claude_cli_spec`
- **`mcp/nvim_context_server.py` was registered nowhere.** No `.mcp.json` in the
  repo or `$HOME` and no `claude mcp add` entry, so `get_current_file` was not
  callable, the system prompt told Claude to call a tool that did not exist, and
  every `BufEnter` wrote a file nothing ever read. Registered inline via
  `--mcp-config` on the panel's own invocation, so pulling the repo is the whole
  install. — `claude_cli_spec`
- **The context file was `/tmp/nvim-claude-ctx`** — a fixed name in a
  world-writable directory shared by every account on the machine, where another
  user can pre-create the path as a symlink and receive the name of every file you
  open. Now under `$XDG_RUNTIME_DIR` (falling back to `stdpath("cache")`), mode
  0600, and written to a per-pid temp file that is `rename`d into place so a
  concurrent read cannot catch it truncated. — `claude_cli_spec`, `mcp_server_spec`
- **Answers appeared all at once, at the end.** `--output-format text` buffers the
  whole response; the float sat on "Asking Claude…" for the length of the request.
  Now `stream-json --include-partial-messages --verbose`, rendered append-only
  behind a 50ms throttle. Measured on a real request: first text at 3.9s growing in
  ~100–160 character steps, against nothing at all until 11.3s. — `claude_cli_spec`
- **One-shot prompts started every MCP server the user has.** `--strict-mcp-config`
  with an empty server set saves 0.8s per keypress-driven request (3.15s → 2.32s
  measured). The panel deliberately does *not* pass it: that is a conversation, and
  silently disabling the user's own servers for its duration would be a surprise. —
  `claude_cli_spec`
- **A missing `claude` binary produced a stack trace out of the keymap**, plus an
  empty float or an orphaned buffer, because `jobstart`/`termopen` throw for a
  missing executable rather than returning an error code — so the exit-code branch
  advising "check that claude is installed" could never run. Both entry points now
  check first, and the panel's spawn is `pcall`'d as well (a binary on `$PATH` can
  still fail to exec). — `claude_cli_spec`
- **The panel became permanently unclosable if the code window went away.**
  Closing the only window is `E444`, and the throw escaped *before* `state.win` was
  cleared, so `panel_is_open()` kept returning true and every later `<C-g>` hit the
  same error. Reached by `:q` in the code window, `<C-w>c`, or `:only` from the
  panel. — `claude_cli_spec`
- **`botright 80vsplit` left the code window zero columns wide** on an 80-column
  terminal — a bare ssh session, a split tmux pane — so opening the panel hid the
  file you wanted to ask about. Now 40% of `columns` (the same proportion
  `lua/plugins/terminal.lua` already uses) capped at 80. — `claude_cli_spec`
- **Entering the file tree, a terminal, a help page or the chat panel itself
  rewrote the context record**, because the guard only checked that the buffer had
  a name. Glance at the tree, ask "explain this file", and Claude was told the tree
  was your file. `buftype == ""` is the check, and it subsumes the panel's own
  special case. — `claude_cli_spec`
- **An empty context file came back from the MCP tool as an empty text block with
  `isError` false** — a successful answer that said nothing. Now the same reply as
  a missing file. — `mcp_server_spec`
- **The server answered any tool name at all with the context**, so a client's typo
  or a stale tool list looked like a working call; and it answered every unknown
  *method* with an empty success, which is a schema violation for anything whose
  result has required fields (`resources/list` needs a `resources` array). Now
  `-32602` and `-32601`. — `mcp_server_spec`
- Found while fixing the above, not by the audit: **serializing the context writes
  was itself a bug at first.** A unique temp name per write let the renames complete
  out of order — 80 rapid switches ending on `other.py` left the file reading
  `Real.java`. One write in flight, newest pending content wins. And the first
  streaming version blanked the placeholder on the CLI's session-init events,
  seconds before any token, which reads as a hang rather than as progress. —
  `claude_cli_spec`

### Still pinned, deliberately not fixed

Asserted as current behaviour with a `known bug` comment so that fixing one shows
up as a failing expectation rather than passing unnoticed.

- `n <C-w>` is mapped to buffer-delete, shadowing the whole native
  window-command prefix. Kept: it is the deliberate VS Code-style binding.
- The large-file treesitter opt-out does not apply to `lua`/`markdown`/`help`/
  `query` (nvim's own ftplugins start the parser first).
- A failed auto-save on a `readonly` buffer is silent (`silent! write` swallows
  E45), and the mtime-guard message advises `:w` where only `:w!` works.
