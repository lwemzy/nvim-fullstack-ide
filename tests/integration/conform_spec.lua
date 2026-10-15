-- conform.nvim's formatter selection in lua/plugins/editor.lua.
--
-- The interesting part of that config is one function: `jsts_formatters`, which
-- decides per-buffer whether a JS/TS project has an opinion of its own about
-- formatting. If it says "yes" wrongly, this IDE silently overrides a project's
-- own config with the house style and every save produces a diff the project's
-- CI rejects. If it says "no" wrongly, the house fallback never applies and the
-- formatter's stock double quotes and 80-column wrap come back.
--
-- No LSP client is started anywhere in here, deliberately. formatters_by_ft
-- entries for JS/TS ARE that function, so `formatters_by_ft.typescript(bufnr)`
-- is the whole decision and can be called directly; and the function only reads
-- the buffer's *name*, so an unloaded buffer created with vim.fn.bufadd is
-- enough. Opening a real .ts buffer would set filetype=typescript and start
-- ts_ls/angularls, which is slow, machine-dependent, and tests nothing here.

local H = require("helpers")

--- The exact table jsts_formatters returns when a project ships a prettier
--- config. prettierd first (it is the daemon, so it is the fast path) with plain
--- prettier as the fallback, and stop_after_first so only one of them runs.
local PROJECT_PRETTIER = { "prettierd", "prettier", stop_after_first = true }
--- ...when it ships an oxfmt config: the built-in, which reads that config
--- itself. The house wrapper must not be used here — it passes an explicit -c.
local PROJECT_OXFMT = { "oxfmt", stop_after_first = true }
--- ...and when it has no opinion at all: the house-style wrapper defined in the
--- same config.
local HOUSE_FALLBACK = { "oxfmt_house", stop_after_first = true }

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
  --- attaches — and a name is all jsts_formatters looks at.
  local named_buffer = H.named_buf

  --- What the config would run for a typescript buffer in `fixture`.
  local function selection_in(fixture)
    local dir = H.fixture(fixture)
    return conform.formatters_by_ft.typescript(named_buffer(dir .. "/src/index.ts")), dir
  end

  describe("jsts_formatters", function()
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

    it("falls back to oxfmt_house when the project has no opinion", function()
      -- package.json present but with no "prettier" key: the decision must key
      -- off the key, not off the file's existence, or this branch is dead code.
      assert.same(HOUSE_FALLBACK, selection_in("prettier-none"))
    end)

    it("defers to a project that ships its own .oxfmtrc.json", function()
      -- The case the house fallback newly makes reachable: it passes
      -- `-c <this repo's .oxfmtrc.json> --disable-nested-config`, so a project
      -- that wrote its own oxfmt config would have it ignored on every save
      -- while the editor silently applied the house style instead. Same failure
      -- the prettier branch above exists to prevent.
      local dir = H.fixture("prettier-none")
      H.write(dir .. "/.oxfmtrc.json", { '{ "singleQuote": false }' })
      assert.same(PROJECT_OXFMT, conform.formatters_by_ft.typescript(named_buffer(dir .. "/src/index.ts")))
    end)

    it("prefers a project's prettier config over its oxfmt config", function()
      -- Both present is not a contradiction to resolve by guessing: prettier is
      -- what a project's CI and pre-commit hooks run, and an .oxfmtrc.json next
      -- to it is usually a local experiment. Formatting to the one CI does not
      -- check is how a green local save turns into a rejected pull request.
      local dir = H.fixture("prettier-configured")
      H.write(dir .. "/.prettierrc", { "{}" })
      H.write(dir .. "/.oxfmtrc.json", { '{ "singleQuote": false }' })
      assert.same(PROJECT_PRETTIER, conform.formatters_by_ft.typescript(named_buffer(dir .. "/src/index.ts")))
    end)

    it("ignores an oxfmt config above the project's VCS root", function()
      -- Same ceiling as the prettier search, for the same reason: an
      -- .oxfmtrc.json in $HOME (this config repo itself ships one, and people
      -- keep dotfiles there) must not make every project on the machine look
      -- like it has an opinion.
      local above = H.tmpdir("oxfmt-above")
      local dir = above .. "/repo"
      vim.fn.mkdir(dir .. "/.git", "p")
      H.write(dir .. "/package.json", { '{ "name": "repo" }' })
      H.write(above .. "/.oxfmtrc.json", { '{ "singleQuote": false }' })

      assert.same(HOUSE_FALLBACK, conform.formatters_by_ft.typescript(named_buffer(dir .. "/src/index.ts")))
      assert.equals(1, vim.fn.filereadable(above .. "/.oxfmtrc.json"))
    end)

    it("ignores a prettier config above the project's VCS root", function()
      -- The whole-machine failure the search bound exists for. `.prettierrc` and
      -- a package.json with a "prettier" key are dotfile-shaped things people
      -- keep in $HOME; an unbounded upward walk found them from any project and
      -- disabled the house fallback everywhere, with nothing on screen to say
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
      assert.same(HOUSE_FALLBACK, conform.formatters_by_ft.typescript(bufnr))
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

    it("never returns both prettier and the house wrapper", function()
      -- stop_after_first makes conform run one formatter, but the branches must
      -- also be mutually exclusive by name: oxfmt_house forces the house config
      -- with -c, so running it *after* a project's own prettier would re-quote a
      -- project that explicitly chose double quotes.
      for _, fixture in ipairs({ "prettier-configured", "prettier-pkgjson", "prettier-none" }) do
        local names = selection_in(fixture)
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        assert.is_true(set.oxfmt_house == nil or set.prettier == nil)
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

    it("shares one jsts_formatters across all four JS/TS filetypes", function()
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
      -- fight prettier, and oxfmt does not format them at all, so they must NOT
      -- go through the gate.
      for _, ft in ipairs({ "json", "jsonc", "css", "scss", "less", "html", "yaml", "markdown" }) do
        assert.same(PROJECT_PRETTIER, conform.formatters_by_ft[ft], ft .. " is not plain prettier")
      end
    end)
  end)

  describe("oxfmt_house", function()
    --- The path the formatter is told to read the house style from. Derived the
    --- same way the config derives it rather than hardcoded, so the assertions
    --- below are about the *file* being found, not about where this repo happens
    --- to be checked out.
    local HOUSE_RC = vim.fn.stdpath("config") .. "/.oxfmtrc.json"

    --- The formatter table conform itself would resolve, plus the ctx conform
    --- itself would build. Reusing conform's own resolution rather than reading
    --- require("conform").formatters directly is the point: oxfmt_house inherits
    --- from the built-in oxfmt config, and only get_formatter_config applies
    --- that inheritance.
    local function resolve(bufnr)
      local config = assert(conform.get_formatter_config("oxfmt_house", bufnr))
      return config, require("conform.runner").build_context(bufnr, config)
    end

    it("points oxfmt at the house config and nothing else", function()
      local dir = H.fixture("prettier-none")
      local buf = named_buffer(dir .. "/src/index.ts")
      local config = resolve(buf)

      -- oxfmt has no style flags on its command line at all, so -c is the only
      -- thing carrying the house style and --disable-nested-config is what stops
      -- a stray .oxfmtrc.json in a subdirectory from merging over the top of it.
      -- --stdin-filepath must survive too: oxfmt infers its parser from that
      -- path, and dropping it makes it fail on every buffer.
      assert.same({
        "-c", HOUSE_RC,
        "--disable-nested-config",
        "--stdin-filepath", "$FILENAME",
      }, config.args)
      -- The built-in it wraps carries none of this.
      local base = require("conform.formatters.oxfmt")
      assert.same({ "--stdin-filepath", "$FILENAME" }, base.args)
    end)

    it("does not inherit the built-in's config-file search for its cwd", function()
      local dir = H.fixture("prettier-none")
      local config = resolve(named_buffer(dir .. "/src/index.ts"))
      -- conform's built-in oxfmt resolves cwd by searching for the config files
      -- it would read — and it counts vite.config.ts, so a Vite project would
      -- run this formatter from a directory chosen for a config it is being told
      -- to ignore. nil means the buffer's own directory, as plain prettier does.
      -- tbl_deep_extend cannot express this: it drops nil values.
      assert.is_nil(config.cwd)
      assert.is_function(require("conform.formatters.oxfmt").cwd)
    end)

    it("ships the house style as a readable config file", function()
      -- The style used to be five CLI flags, which were at least visible in this
      -- spec. Now it is a file, and losing the file is silent: oxfmt still runs
      -- and still reports success, with its own defaults (double quotes, 80
      -- columns) on every save. :checkhealth nvim-ide warns about it too.
      assert.equals(1, vim.fn.filereadable(HOUSE_RC), HOUSE_RC .. " is missing")
      local decoded = vim.json.decode(table.concat(vim.fn.readfile(HOUSE_RC), "\n"))
      -- The five commerce-api ESLint rules a Prettier-style formatter can
      -- express: quotes/single, indent/2, max-len/120, comma-dangle/never,
      -- arrow-parens/as-needed.
      assert.is_true(decoded.singleQuote)
      assert.equals(2, decoded.tabWidth)
      assert.equals(120, decoded.printWidth)
      assert.equals("none", decoded.trailingComma)
      assert.equals("avoid", decoded.arrowParens)
    end)

    it("runs oxfmt, not a prettier", function()
      local dir = H.fixture("prettier-none")
      local buf = named_buffer(dir .. "/src/index.ts")
      local config, ctx = resolve(buf)
      local command = config.command
      if type(command) == "function" then command = command(config, ctx) end

      assert.is_truthy(command:match("oxfmt$"), "command is " .. tostring(command))
      -- mason installs oxfmt outside the system PATH. The fix is on the
      -- *process* PATH (lua/config/options.lua), not in this formatter's `env`:
      -- conform calls vim.fn.executable() against the process PATH and never
      -- reads `env`, so an env-only PATH left it "available = false" and the save
      -- silently unformatted.
      assert.is_truthy((":" .. vim.env.PATH .. ":"):find("/mason/bin:", 1, true),
        "mason bin not on the process PATH: " .. vim.env.PATH)
    end)

    it("is actually available on this machine", function()
      -- conform silently skips an unavailable formatter, so a fallback that
      -- resolves correctly but is not installed still leaves JS/TS unformatted.
      -- mason-tool-installer lists oxfmt for exactly this reason.
      local info = conform.get_formatter_info("oxfmt_house", named_buffer(H.tmpdir("oh") .. "/x.ts"))
      if not info.available then
        return H.skip("oxfmt not installed (" .. tostring(info.available_msg) .. ")")
      end
      assert.is_true(info.available)
    end)

    it("really produces the house style, not oxfmt's defaults", function()
      local info = conform.get_formatter_info("oxfmt_house")
      if not info.available then return H.skip("oxfmt not installed; cannot run end to end") end

      -- A buffer with a .ts name but no filetype: oxfmt picks its parser from
      -- --stdin-filepath, so the name is enough, and leaving filetype unset
      -- keeps ts_ls/angularls out of an assertion about formatting.
      --
      -- Observed on real output rather than on the argv, because the argv can be
      -- exactly right and still not reach the file: a -c path that does not
      -- exist, or a key oxfmt renames, is a hard exit that conform reports as
      -- "formatter failed" with the buffer untouched. These are also the five
      -- lines where oxfmt and the prettier flags it replaces were compared
      -- byte-for-byte.
      local path = H.tmpdir("oh-e2e") .. "/style.ts"
      local buf = H.scratch({ name = path, lines = {
        'const greeting = "hi"',
        "const obj = {",
        '        name: "a",',
        "        value: 1,",
        "}",
        "const fn = (x) => x + 1",
        -- 107 columns once formatted: over the stock 80, under 120, so it stays
        -- on one line only if printWidth actually arrived.
        "const longCall = someFunction('aaaaaaaaaa', 'bbbbbbbbbb', 'cccccccccc', 'dddddddddd', 'eeeeeeeeee', 12345)",
      } })
      conform.format({ bufnr = buf, formatters = { "oxfmt_house" }, async = false, timeout_ms = 15000 })

      assert.same({
        "const greeting = 'hi';", -- singleQuote (the default is double)
        "const obj = {",
        "  name: 'a',", -- tabWidth 2, and object-curly-spacing is already the default
        "  value: 1", -- trailingComma none (prettier 3 and oxfmt both default to "all")
        "};",
        "const fn = x => x + 1;", -- arrowParens avoid (the default is "always")
        "const longCall = someFunction('aaaaaaaaaa', 'bbbbbbbbbb', 'cccccccccc', 'dddddddddd', 'eeeeeeeeee', 12345);",
      }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("cannot satisfy space-before-function-paren, and that is known", function()
      local info = conform.get_formatter_info("oxfmt_house")
      if not info.available then return H.skip("oxfmt not installed; cannot run end to end") end

      -- The one house rule no Prettier-compatible formatter can reach, pinned so
      -- it stays a recorded limitation rather than turning into a bug report.
      -- Unchanged by the move off prettier: oxfmt writes the same space.
      -- `eslint --fix` closes the gap, and it is the work repo's only
      -- enforcement path anyway.
      local path = H.tmpdir("oh-gap") .. "/async.ts"
      local buf = H.scratch({ name = path, lines = { "const put = async (item, ctx) => item;" } })
      conform.format({ bufnr = buf, formatters = { "oxfmt_house" }, async = false, timeout_ms = 15000 })

      -- Two parameters, so arrowParens: avoid cannot drop the parens and the
      -- space in front of them survives. With one parameter it would read
      -- `async item => item;` and the rule would be satisfied by accident.
      assert.same({ "const put = async (item, ctx) => item;" },
        vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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

    it("stops formatting on save once the toggle is off", function()
      -- Asserted through conform.format rather than by checking the file's
      -- contents, because a file that was already well-formatted looks
      -- identical either way. Through H.stub so after_each's H.cleanup puts it
      -- back: leaving this set would turn format-on-save off for every spec
      -- that runs after this one.
      local path = H.write(H.tmpdir("gateoff") .. "/note.md", { "# hi" })
      local buf = H.scratch({ name = path, lines = { "# hi" } })
      local formats = H.spy(conform, "format")
      H.stub(vim.g, "autoformat", false)

      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, group = "Conform" })

      assert.equals(0, formats.count)
    end)

    it("lets one buffer opt out of a session that formats", function()
      -- vim.b beats vim.g, which is the case the precedence order in
      -- config.format exists for: a generated or vendored file you do not want
      -- rewritten, in a session where everything else formats on save.
      local path = H.write(H.tmpdir("gatebuf") .. "/note.md", { "# hi" })
      local buf = H.scratch({ name = path, lines = { "# hi" } })
      local formats = H.spy(conform, "format")
      vim.b[buf].autoformat = false

      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, group = "Conform" })

      assert.equals(0, formats.count)
      -- The opt-out must be exactly that, not a change to the session setting.
      assert.is_nil(vim.g.autoformat)
    end)

    it("passes timeout_ms=5000 and lsp_format=fallback on every write", function()
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
      -- This is what keeps filetypes with no CLI formatter (Java via jdtls, Lua
      -- via lua_ls) formatting on save at all — and for Java it is now the only
      -- save-time formatter, ftplugin/java.lua's own BufWritePre copy having
      -- been removed. Spelled lsp_format, not the deprecated lsp_fallback:
      -- conform still translates the old key silently, so a spec asserting on
      -- the old spelling would keep passing right up to the release that drops
      -- it and stops formatting Java altogether.
      assert.equals("fallback", opts.lsp_format)
      assert.is_nil(opts.lsp_fallback)
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
