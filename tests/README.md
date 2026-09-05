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

### Still pinned, deliberately not fixed

Asserted as current behaviour with a `known bug` comment so that fixing one shows
up as a failing expectation rather than passing unnoticed.

- `n <C-w>` is mapped to buffer-delete, shadowing the whole native
  window-command prefix. Kept: it is the deliberate VS Code-style binding.
- The large-file treesitter opt-out does not apply to `lua`/`markdown`/`help`/
  `query` (nvim's own ftplugins start the parser first).
- A failed auto-save on a `readonly` buffer is silent (`silent! write` swallows
  E45), and the mtime-guard message advises `:w` where only `:w!` works.
