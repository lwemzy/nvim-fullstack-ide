-- conform.nvim's formatter selection in lua/plugins/editor.lua.
--
-- The interesting part of that config is one function: `prettier_or_none`, which
-- decides per-buffer whether a JS/TS project has an opinion of its own about
-- formatting. If it says "yes" wrongly, this IDE silently overrides a project's
-- own prettier config with Google's style and every save produces a diff the
-- project's CI rejects. If it says "no" wrongly, the Google fallback never
-- applies and double quotes come back.
--
-- No LSP client is started anywhere in here, deliberately. formatters_by_ft
-- entries for JS/TS ARE that function, so `formatters_by_ft.typescript(bufnr)`
-- is the whole decision and can be called directly; and the function only reads
-- the buffer's *name*, so an unloaded buffer created with vim.fn.bufadd is
-- enough. Opening a real .ts buffer would set filetype=typescript and start
-- ts_ls/angularls, which is slow, machine-dependent, and tests nothing here.

local H = require("helpers")

--- The exact table prettier_or_none returns when a project HAS its own config.
--- prettierd first (it is the daemon, so it is the fast path) with plain
--- prettier as the fallback, and stop_after_first so only one of them runs.
local PROJECT_PRETTIER = { "prettierd", "prettier", stop_after_first = true }
--- ...and when it does not: the Google-style wrapper defined in the same config.
local GOOGLE_FALLBACK = { "prettier_google", stop_after_first = true }

describe("conform formatter selection", function()
  local conform
  before_each(function()
    H.load_plugin("conform.nvim")
    conform = require("conform")
    -- Several cases below write real files; the config saves on BufLeave and
    -- would rewrite them out from under the assertions.
    H.disable_autosave()
  end)

  after_each(function() H.cleanup() end)

  --- Named but never loaded, so no filetype is detected and no language server
  --- attaches — and a name is all prettier_or_none looks at.
  local named_buffer = H.named_buf

  --- What the config would run for a typescript buffer in `fixture`.
  local function selection_in(fixture)
    local dir = H.fixture(fixture)
    return conform.formatters_by_ft.typescript(named_buffer(dir .. "/src/index.ts")), dir
  end

  describe("prettier_or_none", function()
    it("defers to a project that ships a .prettierrc", function()
      -- The project has said how it wants to be formatted, so this IDE must add
      -- nothing: plain prettierd/prettier with no CLI overrides at all.
      assert.same(PROJECT_PRETTIER, selection_in("prettier-configured"))
    end)

    it("defers to a prettier key in package.json", function()
      -- The case a naive `.prettierrc` existence check misses. package.json's
      -- "prettier" key is a first-class prettier config location, and treating
      -- such a project as unconfigured would hand it --single-quote on every
      -- save while its own config (and its CI) says otherwise.
      assert.same(PROJECT_PRETTIER, selection_in("prettier-pkgjson"))
    end)

    it("falls back to prettier_google when the project has no opinion", function()
      -- package.json present but with no "prettier" key: the decision must key
      -- off the key, not off the file's existence, or this branch is dead code.
      assert.same(GOOGLE_FALLBACK, selection_in("prettier-none"))
    end)

    it("ignores a prettier config above the project's VCS root", function()
      -- The whole-machine failure the search bound exists for. `.prettierrc` and
      -- a package.json with a "prettier" key are dotfile-shaped things people
      -- keep in $HOME; an unbounded upward walk found them from any project and
      -- disabled the Google fallback everywhere, with nothing on screen to say
      -- why. The fixture's own .git makes its parent the ceiling, and $HOME's
      -- role in the real bug is what that parent stands in for here.
      -- Built by hand rather than with H.fixture: the parent has to hold the
      -- planted dotfiles, and H.fixture's parent is a temp directory shared with
      -- every other fixture in the process.
      local above = H.tmpdir("prettier-above")
      local dir = above .. "/repo"
      vim.fn.mkdir(dir .. "/.git", "p")
      H.write(dir .. "/package.json", { '{ "name": "repo" }' })
      H.write(above .. "/.prettierrc", { "{}" })
      H.write(above .. "/package.json", { '{ "prettier": { "singleQuote": false } }' })

      local bufnr = named_buffer(dir .. "/src/index.ts")
      assert.same(GOOGLE_FALLBACK, conform.formatters_by_ft.typescript(bufnr))
      -- Both really are one directory up, so the result cannot be an artefact of
      -- a fixture that failed to write them.
      assert.equals(1, vim.fn.filereadable(above .. "/.prettierrc"))
      assert.equals(1, vim.fn.filereadable(above .. "/package.json"))
    end)

    it("finds a monorepo root's prettier config from a nested package", function()
      -- The other half of the same bound: it is the VCS root's parent, not the
      -- nearest package.json, precisely so a workspace package still inherits
      -- the config at the repository root it belongs to.
      local dir = H.fixture("prettier-none")
      H.write(dir .. "/.prettierrc", { "{}" })
      vim.fn.mkdir(dir .. "/packages/web/src", "p")
      local bufnr = named_buffer(dir .. "/packages/web/src/index.ts")
      assert.same(PROJECT_PRETTIER, conform.formatters_by_ft.typescript(bufnr))
    end)

    it("reads a monorepo root's prettier key past the nearest package.json", function()
      -- The package.json search asks for EVERY match up to the root, not just the
      -- nearest. In a monorepo the workspace package has no "prettier" key and
      -- the repo root does — and the nearest-match default would stop at the
      -- workspace, hand the whole package --single-quote, and disagree with the
      -- CI that runs prettier from the root config.
      local dir = H.fixture("prettier-none")
      H.write(dir .. "/package.json", { '{ "name": "root", "prettier": { "singleQuote": false } }' })
      vim.fn.mkdir(dir .. "/packages/web/src", "p")
      H.write(dir .. "/packages/web/package.json", { '{ "name": "web" }' })

      local bufnr = named_buffer(dir .. "/packages/web/src/index.ts")
      assert.same(PROJECT_PRETTIER, conform.formatters_by_ft.typescript(bufnr))
    end)

    it("never returns both prettier and the Google wrapper", function()
      -- stop_after_first makes conform run one formatter, but the two branches
      -- must also be mutually exclusive by name: prettier_google appends
      -- --single-quote, so running it *after* a project's own prettier would
      -- re-quote a project that explicitly chose double quotes.
      for _, fixture in ipairs({ "prettier-configured", "prettier-pkgjson", "prettier-none" }) do
        local names = selection_in(fixture)
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        assert.is_true(set.prettier_google == nil or set.prettier == nil)
        assert.is_true(names.stop_after_first)
      end
    end)
  end)

  describe("formatters_by_ft", function()
    it("maps every configured filetype to a non-empty formatter list", function()
      -- An empty list is not a no-op: conform reports "Formatters unavailable"
      -- for the filetype and the entry is a lie about what will run on save.
      local configured = H.fixture("prettier-configured")
      local unconfigured = H.fixture("prettier-none")
      for ft, entry in pairs(conform.formatters_by_ft) do
        if type(entry) == "function" then
          -- Exercised in BOTH project shapes: a function that returned {} down
          -- one branch would otherwise pass on the other.
          for _, dir in ipairs({ configured, unconfigured }) do
            local got = entry(named_buffer(dir .. "/src/index.ts"))
            assert.is_true(#got > 0, ("%s returned no formatters in %s"):format(ft, dir))
          end
        else
          assert.is_true(#entry > 0, ft .. " maps to an empty list")
        end
      end
    end)

    it("shares one prettier_or_none across all four JS/TS filetypes", function()
      local ts = conform.formatters_by_ft.typescript
      assert.equals("function", type(ts))
      -- Identity, not just equivalent behaviour: four copies of this logic is
      -- how javascript and typescript drift apart, and it is also what makes
      -- the single-fixture assertions above cover all four filetypes.
      assert.equals(ts, conform.formatters_by_ft.javascript)
      assert.equals(ts, conform.formatters_by_ft.javascriptreact)
      assert.equals(ts, conform.formatters_by_ft.typescriptreact)
    end)

    it("keeps non-JS/TS filetypes on unconditional prettier", function()
      -- css/json/yaml/markdown have no project-level style opinion that could
      -- fight prettier, so they must NOT go through the gate — a fallback with
      -- --single-quote would be actively wrong for JSON.
      for _, ft in ipairs({ "json", "jsonc", "css", "scss", "less", "html", "yaml", "markdown" }) do
        assert.same(PROJECT_PRETTIER, conform.formatters_by_ft[ft], ft .. " is not plain prettier")
      end
    end)
  end)

  describe("prettier_google", function()
    --- The formatter table conform itself would resolve, plus the ctx conform
    --- itself would build. Reusing conform's own resolution rather than reading
    --- require("conform").formatters directly is the point: prettier_google
    --- inherits from the built-in prettier config, and only get_formatter_config
    --- applies that inheritance.
    local function resolve(bufnr)
      local config = assert(conform.get_formatter_config("prettier_google", bufnr))
      return config, require("conform.runner").build_context(bufnr, config)
    end

    it("adds --single-quote on top of the built-in prettier args", function()
      local dir = H.fixture("prettier-none")
      local buf = named_buffer(dir .. "/src/index.ts")
      local config, ctx = resolve(buf)
      local args = config.args(config, ctx)

      -- --stdin-filepath must survive: prettier infers its parser from that
      -- path, and dropping it makes prettier fail on every buffer.
      assert.same({ "--stdin-filepath", "$FILENAME", "--single-quote" }, args)
      -- The wrapper is documented as adding exactly one difference from
      -- prettier's stock defaults (both Google style guides mandate single
      -- quotes; everything else prettier already does). Anything more here
      -- would be this IDE inventing a style nobody asked for.
      local base = require("conform.formatters.prettier")
      assert.same({ "--stdin-filepath", "$FILENAME" }, base.args(base, ctx))
    end)

    it("runs plain prettier, not the prettierd daemon", function()
      local dir = H.fixture("prettier-none")
      local buf = named_buffer(dir .. "/src/index.ts")
      local config, ctx = resolve(buf)
      local command = config.command
      if type(command) == "function" then command = command(config, ctx) end

      -- This is the entire reason the fallback exists as a separate formatter:
      -- prettierd is a daemon and ignores ad-hoc CLI overrides, so
      -- --single-quote passed to prettierd would be silently dropped and the
      -- Google style would never be applied.
      assert.is_truthy(command:match("prettier$"), "command is " .. tostring(command))
      assert.is_nil(command:match("prettierd"))
      -- mason installs prettier outside the system PATH, so the formatter has
      -- to carry mason's bin dir or it is "available = false" on save.
      assert.is_truthy(config.env and config.env.PATH:find("mason", 1, true))
    end)

    it("is actually available on this machine", function()
      -- conform silently skips an unavailable formatter, so a fallback that
      -- resolves correctly but is not installed still leaves JS/TS unformatted.
      -- mason-tool-installer lists plain `prettier` for exactly this reason.
      local info = conform.get_formatter_info("prettier_google", named_buffer(H.tmpdir("pg") .. "/x.ts"))
      if not info.available then
        return H.skip("prettier not installed (" .. tostring(info.available_msg) .. ")")
      end
      assert.is_true(info.available)
    end)

    it("really rewrites double quotes to single quotes", function()
      local info = conform.get_formatter_info("prettier_google")
      if not info.available then return H.skip("prettier not installed; cannot run end to end") end

      -- A buffer with a .ts name but no filetype: prettier picks its parser
      -- from --stdin-filepath, so the name is enough, and leaving filetype
      -- unset keeps ts_ls/angularls out of an assertion about a CLI flag.
      local path = H.tmpdir("pg-e2e") .. "/quotes.ts"
      local buf = H.scratch({ name = path, lines = { 'const greeting = "hi"' } })
      conform.format({ bufnr = buf, formatters = { "prettier_google" }, async = false, timeout_ms = 15000 })

      -- The whole point of the fallback, observed on real output rather than on
      -- the argv: prettier's own default is double quotes.
      assert.same({ "const greeting = 'hi';" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)
  end)

  describe("save wiring", function()
    it("formats after save (async), not before it", function()
      -- format_on_save is a BufWritePre hook and blocks the write for as long
      -- as the formatter takes. The config deliberately uses format_after_save,
      -- which runs async and re-saves — so typing is never blocked by prettier.
      assert.equals(0, H.count_autocmds("BufWritePre", "Conform"))
      assert.equals(1, H.count_autocmds("BufWritePost", "Conform"))
    end)

    it("passes timeout_ms=5000 and lsp_fallback=true on every write", function()
      local path = H.write(H.tmpdir("aftersave") .. "/note.md", { "# hi" })
      local buf = H.scratch({ name = path, lines = { "# hi" } })
      -- Spy on conform's own entry point rather than running a formatter: the
      -- assertion is about the *options* the config supplies, and the real call
      -- would spawn prettier and rewrite the buffer.
      local formats = H.spy(conform, "format")

      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, group = "Conform" })

      assert.equals(1, formats.count)
      local opts = formats[1][1]
      -- 5000ms, not conform's 1000ms default: prettierd's first invocation pays
      -- for daemon startup and a 1s timeout aborts it mid-format.
      assert.equals(5000, opts.timeout_ms)
      -- lsp_fallback keeps filetypes with no CLI formatter (Java via jdtls,
      -- Lua via lua_ls) formatting on save at all.
      assert.is_true(opts.lsp_fallback)
      -- async is forced by format_after_save; async=false there is an error
      -- conform notifies about on every single save.
      assert.is_true(opts.async)
    end)
  end)

  describe("error handling", function()
    it("notifies on formatter errors", function()
      -- Left at conform's default of true on purpose: a formatter that crashes
      -- silently looks exactly like a file that was already formatted.
      assert.is_true(conform.notify_on_error)
    end)

    it("does not throw on write when the filetype has no formatter", function()
      local path = H.write(H.tmpdir("noformatter") .. "/notes.txt", { "plain text" })
      -- A real :edit'd buffer, not a named scratch: :write refuses to overwrite
      -- a file the buffer was never read from (E13), and the point is the real
      -- write path.
      local buf = H.edit(path)
      assert.is_nil(conform.formatters_by_ft[vim.bo[buf].filetype])
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain   text" })

      -- Every save of every unformattable file goes down this path, so an error
      -- here is a config that makes the editor unusable rather than a missing
      -- feature.
      local notes = H.capture_notifications(function()
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
        vim.wait(500, function() return false end) -- let the async format settle
      end)
      for _, n in ipairs(notes) do
        assert.is_true((n.level or 0) < vim.log.levels.ERROR, "error notification: " .. tostring(n.msg))
      end
      assert.equals(1, vim.fn.filereadable(path))
    end)

    it("does not throw on write when the formatter is not installed", function()
      local path = H.write(H.tmpdir("missing") .. "/README.md", { "# hi" })
      -- markdown, not typescript: markdown maps to prettierd/prettier
      -- unconditionally and no language server in this config claims it, so
      -- the write exercises conform alone.
      local buf = H.edit(path)
      assert.equals("markdown", vim.bo[buf].filetype)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#  hi" })
      -- Simulate a machine where prettier was never installed. There is no way
      -- to ask conform to pretend, and mason has prettier here, so the seam is
      -- the executable lookup every formatter resolution ends at.
      H.stub(vim.fn, "executable", function() return 0 end)

      local notes = H.capture_notifications(function()
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
        vim.wait(500, function() return false end)
      end)
      -- conform may warn that formatters are unavailable; what it must not do
      -- is raise, because that turns every :w into a "Press ENTER" prompt.
      for _, n in ipairs(notes) do
        assert.is_true((n.level or 0) < vim.log.levels.ERROR, "error notification: " .. tostring(n.msg))
      end
      -- The write itself still happened: formatting is best-effort.
      assert.same({ "#  hi" }, vim.fn.readfile(path))
    end)
  end)
end)
