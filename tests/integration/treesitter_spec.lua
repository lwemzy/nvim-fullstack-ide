-- The treesitter setup in lua/plugins/treesitter.lua, plus the large-buffer
-- opt-out in lua/config/autocmds.lua (augroup treesitter_highlight).
--
-- Two things make this worth an integration spec rather than a structural one:
--
-- 1. nvim-treesitter's `main` branch dropped setup({ ensure_installed = ...,
--    highlight = ... }). Those options are now silently ignored, so "the config
--    asks for these parsers and highlighting is on" cannot be read off a table
--    of options any more — it has to be observed from the loaded plugin and
--    from a real buffer.
-- 2. The size guard's whole purpose is to NOT do something. The only way to see
--    it work is to open a genuinely oversized file and find no highlighter
--    attached.
--
-- Everything runs on files under H.tmpdir(); the config auto-saves on BufLeave.

local H = require("helpers")
local highlighter = require("vim.treesitter.highlighter")

-- Thresholds copied from lua/config/autocmds.lua. Duplicated deliberately: the
-- values are local to that module, and a spec that read them from the source
-- would pass no matter what they were changed to.
local TS_MAX_LINES = 10000
local TS_MAX_BYTES = 512 * 1024

--- Whether treesitter highlighting is attached to `buf`.
---
--- highlighter.active is the table vim.treesitter.start() populates and the
--- decoration provider reads, so it is the same state that decides whether the
--- buffer is highlighted by treesitter or by the regex syntax engine.
local function highlighted(buf)
  return highlighter.active[buf] ~= nil
end

--- The plugin spec lazy.nvim resolved for nvim-treesitter.
local function plugin_spec()
  return require("lazy.core.config").plugins["nvim-treesitter"]
end

--- The language list the config hands to nvim-treesitter's install().
---
--- Re-runs the real config() function with install() recorded. There is nowhere
--- else to read this from: main-branch nvim-treesitter keeps no
--- `ensure_installed` state, so the list exists only as the argument to
--- install(), and the alternative — copying the list into this spec — would
--- assert that the spec agrees with itself.
---
--- Re-running config() is safe: install() is suppressed by the spy, and the
--- ts_auto_install augroup it recreates is declared with clear = true.
local function ensure_installed()
  local ts = require("nvim-treesitter")
  local calls = H.spy(ts, "install")
  local plugin = plugin_spec()
  plugin.config(plugin, {})
  assert.is_true(calls.count >= 1, "config() did not call nvim-treesitter.install()")
  local langs = calls[1][1]
  assert.is_table(langs)
  return langs
end

describe("treesitter setup", function()
  before_each(function()
    H.load_plugin("nvim-treesitter")
    H.disable_autosave()
  end)

  after_each(function()
    H.cleanup()
  end)

  it("is pinned to the branch whose API the config calls", function()
    local plugin = plugin_spec()
    -- config() calls ts.install()/get_installed()/get_available(), which exist
    -- only on `main`. On `master` the config function would throw at startup and
    -- take every plugin after it in the same file down with it.
    assert.equals("main", plugin.branch)
    local ts = require("nvim-treesitter")
    for _, fn in ipairs({ "install", "get_installed", "get_available", "setup" }) do
      assert.equals("function", type(ts[fn]), "nvim-treesitter." .. fn .. " is missing")
    end
    -- Parsers are compiled by :TSUpdate on install; without the build step the
    -- listed languages install but never get a usable parser.
    assert.equals(":TSUpdate", plugin.build)
  end)

  it("asks for a parser for every language this config edits", function()
    local langs = ensure_installed()
    local set = {}
    for _, lang in ipairs(langs) do
      assert.is_nil(set[lang], "duplicate language in ensure_installed: " .. lang)
      set[lang] = true
    end

    -- The stack this IDE config exists for (Java/Spring + Angular/TypeScript)
    -- plus the languages its own files are written in. A missing entry is
    -- invisible until you open such a file and find it unhighlighted.
    for _, lang in ipairs({
      "java", "typescript", "javascript", "tsx", "angular", "html", "css", "scss",
      "json", "yaml", "toml", "xml",
      "lua", "vim", "vimdoc", "query", "markdown", "markdown_inline", "bash", "regex",
    }) do
      assert.is_true(set[lang] == true, "ensure_installed is missing " .. lang)
    end

    -- markdown_inline is not optional once markdown is present: without it the
    -- markdown parser has no injected language for inline spans and code spans
    -- render unhighlighted.
    assert.is_true(set.markdown_inline == true)
  end)

  it("uses only language names treesitter recognises", function()
    local ts = require("nvim-treesitter")
    local available = ts.get_available()
    for _, lang in ipairs(ensure_installed()) do
      -- install() ignores a name it does not know. A typo ("typescipt") is
      -- therefore completely silent: no error, no parser, no highlighting.
      assert.is_true(
        vim.tbl_contains(available, lang),
        lang .. " is not a language nvim-treesitter can install"
      )
    end
  end)

  it("leaves jsonc to the json parser instead of listing it", function()
    -- The comment at the top of the config claims jsonc is not a separate
    -- parser. If that ever stopped being true, jsonc files would quietly lose
    -- highlighting because nothing installs a parser for them.
    assert.equals("json", vim.treesitter.language.get_lang("jsonc"))
    assert.is_false(vim.tbl_contains(ensure_installed(), "jsonc"))
  end)

  it("installs a parser on demand for a filetype it did not list", function()
    -- Replaces main-branch's removed `auto_install`. Exactly one autocmd, in a
    -- cleared group: ensure_installed() above re-runs config(), so a group
    -- declared without clear = true would stack a duplicate installer per call
    -- and re-install on every FileType.
    ensure_installed()
    assert.equals(1, H.count_autocmds("FileType", "ts_auto_install"))

    local ts = require("nvim-treesitter")
    local installs = H.spy(ts, "install")
    -- A filetype with a parser that nothing in ensure_installed covers.
    vim.api.nvim_exec_autocmds("FileType", { group = "ts_auto_install", pattern = "ruby" })
    local requested = vim.tbl_contains(ts.get_installed(), "ruby")
    if requested then
      -- Already installed on this machine, so the guard must have skipped it.
      assert.equals(0, installs.count)
    else
      assert.equals(1, installs.count)
      assert.equals("ruby", installs[1][1])
    end

    -- And it must not try to install something that is not a language at all:
    -- get_available() is the gate, so an unknown filetype is a no-op.
    vim.api.nvim_exec_autocmds("FileType", { group = "ts_auto_install", pattern = "no-such-language" })
    assert.equals(requested and 0 or 1, installs.count)
  end)

  it("has the parsers this config's stack needs already installed", function()
    -- install() is asynchronous and network-bound, so this is a report on the
    -- machine rather than a property of the config: it says which of the
    -- requested parsers a spec can actually exercise below.
    local installed = require("nvim-treesitter").get_installed()
    local missing = {}
    for _, lang in ipairs(ensure_installed()) do
      if not vim.tbl_contains(installed, lang) then
        table.insert(missing, lang)
      end
    end
    if #missing > 0 then
      -- Not a failure: a fresh clone has installed nothing yet, and :TSUpdate
      -- runs in the background.
      return H.skip("parsers not installed on this machine: " .. table.concat(missing, ", "))
    end
    assert.same({}, missing)
  end)
end)

describe("treesitter highlighting on real buffers", function()
  local dir

  -- A filetype used for the size-guard cases. It must satisfy three things at
  -- once, which is why it is not typescript or lua:
  --   * a parser is installed, so highlighting *can* start;
  --   * nvim's own runtime ftplugin does not call vim.treesitter.start()
  --     unconditionally (ftplugin/lua.lua, markdown.lua, help.lua and query.lua
  --     all do — the config's size guard cannot opt those out at all, see the
  --     report);
  --   * no language server in lua/plugins/lsp.lua is enabled for it, so opening
  --     one does not spawn a real server mid-spec.
  local CANDIDATES = {
    {
      lang = "toml",
      ext = "toml",
      -- A comment line of exactly `width` bytes, so the byte-threshold cases
      -- can hit the boundary rather than "somewhere near it".
      line = function(width) return "# " .. string.rep("x", width - 2) end,
    },
    {
      lang = "xml",
      ext = "xml",
      line = function(width) return "<!-- " .. string.rep("x", width - 9) .. " -->" end,
    },
  }

  local function pick_language()
    local installed = require("nvim-treesitter").get_installed()
    for _, candidate in ipairs(CANDIDATES) do
      if vim.tbl_contains(installed, candidate.lang) then return candidate end
    end
    return nil
  end

  local lang

  --- A real on-disk file of `count` lines, each exactly `width` bytes.
  --- One writefile of a prebuilt table: appending line by line to a 10k-line
  --- buffer is slow enough to dominate the runtime of the whole suite.
  local function open_file(name, count, width)
    local lines = {}
    local text = lang.line(width)
    for i = 1, count do
      lines[i] = text
    end
    local path = H.write(("%s/%s.%s"):format(dir, name, lang.ext), lines)
    local buf = H.edit(path)
    assert.equals(lang.lang, vim.bo[buf].filetype)
    return buf, path
  end

  before_each(function()
    H.load_plugin("nvim-treesitter")
    H.disable_autosave()
    dir = H.tmpdir("ts-buffers")
    lang = pick_language()
  end)

  after_each(function()
    H.cleanup()
  end)

  it("attaches a parser that spans the whole buffer", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    local buf = open_file("parsed", 40, 20)

    local ok, parser = pcall(vim.treesitter.get_parser, buf)
    assert.is_true(ok, "no parser for " .. lang.lang .. ": " .. tostring(parser))
    local tree = parser:parse()[1]
    local root = tree:root()

    -- A tree that exists but covers nothing is the shape a broken/missing query
    -- or an empty parse produces, and it highlights exactly nothing. The root
    -- has to reach the last line of the buffer.
    assert.is_false(root:has_error())
    local last_row = select(1, root:end_())
    assert.is_true(last_row >= vim.api.nvim_buf_line_count(buf) - 1)
    assert.is_true(root:child_count() > 0)
  end)

  it("starts highlighting for an ordinary file", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    local buf = open_file("small", 20, 20)

    -- Load-bearing: main-branch nvim-treesitter does not start highlighting,
    -- so this only happens because of the FileType autocmd in
    -- lua/config/autocmds.lua. If that autocmd disappeared, every buffer would
    -- silently drop back to regex syntax and nobody would see an error.
    assert.is_true(highlighted(buf))
    assert.is_true(vim.b[buf].ts_highlight)
  end)

  it("does not put treesitter's indentexpr on the buffer", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    local buf = open_file("indent", 10, 20)
    -- main-branch treesitter indentation is opt-in
    -- ('indentexpr=v:lua.require"nvim-treesitter".indentexpr()') and this config
    -- does not opt in; indentation comes from the built-in indent scripts and
    -- LSP formatting. Recorded so that turning it on is a deliberate change
    -- rather than something a plugin update does to the config's behaviour.
    assert.is_nil((vim.bo[buf].indentexpr):find("nvim%-treesitter"))
  end)

  it("skips buffers that are not files", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    local buf = H.scratch({ lines = { lang.line(10) } })
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = lang.lang

    -- Pickers and preview windows set their filetype to get highlighting from
    -- the syntax engine; attaching a parser to them pays the parse cost for
    -- content that is thrown away a keystroke later.
    assert.is_false(highlighted(buf))
  end)

  it("opts out of a buffer over the line limit", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    local buf = open_file("too-many-lines", TS_MAX_LINES + 1, 8)
    assert.equals(TS_MAX_LINES + 1, vim.api.nvim_buf_line_count(buf))
    -- Under the byte limit, so only the line count can explain the opt-out.
    assert.is_true(vim.fn.getfsize(vim.api.nvim_buf_get_name(buf)) < TS_MAX_BYTES)

    -- Incremental reparse is paid on every keystroke before completion even
    -- debounces, which is what makes a large file feel like a broken editor.
    assert.is_false(highlighted(buf))
    assert.is_not_true(vim.b[buf].ts_highlight)
    -- …and the buffer is not left with no highlighting at all: 'syntax' is
    -- still set, so the regex engine takes over.
    assert.equals(lang.lang, vim.bo[buf].syntax)
  end)

  it("keeps highlighting a buffer exactly at the line limit", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    -- The comparison is `> TS_MAX_LINES`, so the limit itself is inclusive:
    -- 10000 lines is highlighted, 10001 is not. Pinned because an off-by-one
    -- here is invisible either way — you would just never know which side of
    -- 10000 lost its colours.
    local buf = open_file("at-line-limit", TS_MAX_LINES, 8)
    assert.equals(TS_MAX_LINES, vim.api.nvim_buf_line_count(buf))
    assert.is_true(highlighted(buf))
  end)

  it("opts out of a buffer over the byte limit that is under the line limit", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    -- 100 lines of 6000 bytes: a minified bundle or a one-line JSON blob. A
    -- guard that only counted lines would sail straight past this and hang on
    -- exactly the files that hurt most, which is why the byte check is a
    -- separate condition and this a separate case.
    local buf, path = open_file("too-many-bytes", 100, 6000)
    assert.is_true(vim.api.nvim_buf_line_count(buf) < TS_MAX_LINES)
    assert.is_true(vim.fn.getfsize(path) > TS_MAX_BYTES)

    assert.is_false(highlighted(buf))
    assert.equals(lang.lang, vim.bo[buf].syntax)
  end)

  it("keeps highlighting a buffer exactly at the byte limit", function()
    if not lang then
      return H.skip("no parser installed for any of the candidate languages")
    end
    -- getfsize() counts the trailing newline of each line, so 128 lines of 4095
    -- bytes is 128 * 4096 = exactly 524288. The comparison is `> TS_MAX_BYTES`,
    -- so the limit itself is inclusive on this side too.
    local buf, path = open_file("at-byte-limit", 128, 4095)
    assert.equals(TS_MAX_BYTES, vim.fn.getfsize(path))
    assert.is_true(highlighted(buf))
  end)
end)

describe("treesitter-adjacent plugins in lua/plugins/treesitter.lua", function()
  after_each(function()
    H.cleanup()
  end)

  it("configures rainbow-delimiters globally", function()
    H.load_plugin("rainbow-delimiters.nvim")
    local cfg = vim.g.rainbow_delimiters
    -- rainbow-delimiters reads vim.g at attach time, so this global *is* its
    -- configuration — a wrong key name is silently ignored and brackets simply
    -- stay one colour.
    assert.is_table(cfg)
    assert.equals("rainbow-delimiters.strategy.global", cfg.strategy[""])
    assert.equals("rainbow-delimiters", cfg.query[""])
    -- Lua gets rainbow-blocks (do/end, if/end) rather than only delimiters,
    -- which is the reason for a per-language override at all.
    assert.equals("rainbow-blocks", cfg.query.lua)
    assert.is_true(#cfg.highlight > 1)
  end)
end)
