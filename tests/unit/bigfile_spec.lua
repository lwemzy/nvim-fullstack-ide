-- config.bigfile — the size thresholds every per-keystroke cost in this config
-- is gated on.
--
-- Asserted at the boundaries rather than with comfortably-over values, because
-- an off-by-one here is invisible in use: the file just feels slow, or the
-- highlighting just isn't there, and neither points at a comparison operator.
-- The plugin opt-outs are asserted through package.loaded rather than by loading
-- the plugins, which is also exactly the property under test.
--
-- Note the ordering requirement in limit(): the plugin opt-outs are deferred with
-- vim.schedule (so they land after every FileType handler, including the ones
-- that attach colorizer and rainbow-delimiters), so a test that asserts on them
-- has to let the scheduler run first — hence H.drain() rather than a bare call.

local H = require("helpers")

local bigfile = require("config.bigfile")

--- Run queued vim.schedule callbacks and return.
---
--- vim.wait(0) is not enough: it processes nothing. A predicate that is satisfied
--- by a scheduled flag is the only form that both runs the queue and returns as
--- soon as it has.
local function drain()
  local done = false
  vim.schedule(function() done = true end)
  vim.wait(200, function() return done end)
end

describe("config.bigfile", function()
  before_each(function() H.disable_autosave() end)
  after_each(function() H.cleanup() end)

  describe("thresholds", function()
    it("keeps the LSP tier well above the decoration tier", function()
      -- The whole point of there being two numbers: a 10k-line Java class loses
      -- treesitter highlighting and keeps completion. Collapsing them would mean
      -- every large-but-ordinary source file silently loses its inlay hints and
      -- reference highlighting too.
      assert.is_true(bigfile.LSP_MAX_LINES > bigfile.MAX_LINES)
      assert.is_true(bigfile.LSP_MAX_BYTES > bigfile.MAX_BYTES)
    end)
  end)

  describe("is_big", function()
    it("is false exactly at the line limit and true one line past it", function()
      assert.is_false(bigfile.is_big(H.lines_buffer(bigfile.MAX_LINES, "at")))
      assert.is_true(bigfile.is_big(H.lines_buffer(bigfile.MAX_LINES + 1, "over")))
    end)

    it("catches a file that is huge on disk but short in the buffer", function()
      -- The minified-bundle shape: one enormous line. The line count says 1, so
      -- only the byte check can see it, and the two have to be independent.
      local path = H.write(H.tmpdir("wide") .. "/bundle.js",
        { string.rep("x", bigfile.MAX_BYTES + 1024) })
      local buf = H.scratch({ scratch = false, name = path, lines = { "x" } })
      assert.is_true(bigfile.is_big(buf))
    end)

    it("judges an unwritten buffer on its lines alone", function()
      -- getfsize returns -1 for a file that isn't there yet, which compares below
      -- every threshold — so a new buffer must not be called big, and a new
      -- buffer someone pasted 20k lines into must.
      assert.is_false(bigfile.is_big(H.scratch({ scratch = false, lines = { "a" } })))
      local lines = {}
      for i = 1, bigfile.MAX_LINES + 1 do lines[i] = "x" end
      assert.is_true(bigfile.is_big(H.scratch({ scratch = false, lines = lines })))
    end)
  end)

  describe("file_over", function()
    -- The BufReadPre half of detection: at that point the incoming file is not in
    -- the buffer, so the path is all there is to go on. Tested separately from
    -- is_big precisely because it must NOT look at any buffer — reading the
    -- current buffer's line count there is the bug it exists to avoid (a 3-line
    -- file reloaded after 20k lines were pasted into it was being marked big).
    it("judges the file on disk and ignores every buffer", function()
      local path = H.write(H.tmpdir("fo") .. "/b.js", { string.rep("x", bigfile.MAX_BYTES + 1) })
      local small = H.write(H.tmpdir("fo2") .. "/s.js", { "x" })
      -- A 20k-line buffer is current for both calls; neither answer may change.
      local lines = {}
      for i = 1, 20000 do lines[i] = "x" end
      H.scratch({ scratch = false, lines = lines })
      assert.is_true(bigfile.file_over(path, bigfile.MAX_BYTES))
      assert.is_false(bigfile.file_over(small, bigfile.MAX_BYTES))
    end)

    it("is false for a path that does not exist", function()
      -- getfsize returns -1 here, and -1 > max_bytes must stay false: an unwritten
      -- buffer is not a big file.
      assert.is_false(bigfile.file_over(H.tmpdir("gone") .. "/nope.js", bigfile.MAX_BYTES))
      assert.is_false(bigfile.file_over("", bigfile.MAX_BYTES))
    end)
  end)

  describe("is_heavy_for_lsp", function()
    it("leaves a merely large file every LSP feature", function()
      -- Over the decoration tier, under the LSP tier: the common real case, and
      -- the one where dropping LSP features would read as "the LSP is broken".
      local buf = H.lines_buffer(bigfile.MAX_LINES + 1, "large")
      assert.is_true(bigfile.is_big(buf))
      assert.is_false(bigfile.is_heavy_for_lsp(buf))
    end)

    it("is true one line past its own limit", function()
      assert.is_false(bigfile.is_heavy_for_lsp(H.lines_buffer(bigfile.LSP_MAX_LINES, "lsp-at")))
      assert.is_true(bigfile.is_heavy_for_lsp(H.lines_buffer(bigfile.LSP_MAX_LINES + 1, "lsp-over")))
    end)
  end)

  describe("limit", function()
    it("bounds the regex engine and stops writing undo files", function()
      local buf = H.lines_buffer(3, "lim")
      -- Set deliberately against the expected outcome first. undofile's default is
      -- false *and* tests/minimal_init.lua turns it off, so asserting false on a
      -- fresh buffer passes whether or not limit() does anything at all — this is
      -- the difference between testing the code and testing the harness.
      vim.bo[buf].undofile = true
      vim.bo[buf].synmaxcol = 3000

      bigfile.limit(buf)

      assert.equals(200, vim.bo[buf].synmaxcol)
      assert.is_false(vim.bo[buf].undofile)
    end)

    it("changes nothing globally", function()
      -- Every option it touches is buffer-scoped. A global synmaxcol of 200 would
      -- silently stop highlighting past column 200 in every file opened after.
      --
      -- Against sentinels set here rather than against whatever the globals happen
      -- to hold: an earlier test in this block has already called limit(), so
      -- reading the current global as the baseline would compare 200 with 200 and
      -- pass for the buffer-scoped and global versions alike.
      local before_syn, before_undo = vim.go.synmaxcol, vim.go.undofile
      vim.go.synmaxcol = 1234
      vim.go.undofile = true

      bigfile.limit(H.lines_buffer(3, "global"))

      local syn, undo = vim.go.synmaxcol, vim.go.undofile
      vim.go.synmaxcol, vim.go.undofile = before_syn, before_undo
      assert.equals(1234, syn)
      assert.is_true(undo)
    end)

    it("stops treesitter and gives the buffer its regex syntax back", function()
      -- The case that made this necessary: Neovim's own ftplugins for lua,
      -- markdown, help and query call vim.treesitter.start() themselves, so on
      -- those filetypes treesitter ends up highlighting a file this size and not
      -- calling start() ourselves achieves nothing.
      --
      -- The second assertion is the half that is easy to get wrong: start() clears
      -- 'syntax' and stop() does not put it back, so stopping alone would leave a
      -- big Lua file with no highlighting at all.
      local buf = H.lines_buffer(3, "ts")
      vim.bo[buf].filetype = "lua"
      if not pcall(vim.treesitter.start, buf, "lua") then
        H.skip("no lua parser available")
        return
      end
      assert.is_not_nil(vim.treesitter.highlighter.active[buf])
      assert.equals("", vim.bo[buf].syntax)

      bigfile.limit(buf)
      drain()

      assert.is_nil(vim.treesitter.highlighter.active[buf])
      assert.equals("lua", vim.bo[buf].syntax)
    end)

    it("stops treesitter even when the parser starts after limit() returns", function()
      -- Not a hypothetical: Neovim's `filetypeplugin` autocmd group is created
      -- while the runtime is sourced, which is *after* init.lua requires
      -- config.autocmds — so its lua/markdown/help/query ftplugins run after our
      -- FileType handler, and an inline stop runs before there is anything to
      -- stop. Measured in a real session: a 20002-line .lua file came out of the
      -- guard with ts_hl=true and 'syntax' empty, i.e. no highlighting of either
      -- kind, which is worse than doing nothing at all.
      local buf = H.lines_buffer(3, "ts-late")
      vim.bo[buf].filetype = "lua"
      bigfile.limit(buf)
      if not pcall(vim.treesitter.start, buf, "lua") then
        H.skip("no lua parser available")
        return
      end

      drain()

      assert.is_nil(vim.treesitter.highlighter.active[buf])
      assert.equals("lua", vim.bo[buf].syntax)
    end)

    it("leaves syntax alone when treesitter was never highlighting", function()
      -- The ordinary path: no parser started, so there is nothing to restore and
      -- 'syntax' must not be rewritten from the filetype behind the user's back.
      local buf = H.lines_buffer(3, "nots")
      vim.bo[buf].filetype = "text"
      vim.bo[buf].syntax = "off"
      bigfile.limit(buf)
      drain()
      assert.equals("off", vim.bo[buf].syntax)
    end)

    it("does not load a plugin in order to switch it off", function()
      -- The trap this guards: require() is one of lazy.nvim's load triggers, so
      -- pcall(require, "ufo") here would pull ufo, ibl, colorizer and the rest
      -- into the session — on the one buffer where the entire goal is less work.
      local mods = { "ufo", "ibl", "colorizer", "rainbow-delimiters", "rainbow-delimiters.lib", "illuminate" }
      for _, mod in ipairs(mods) do
        assert.is_nil(package.loaded[mod], mod .. " was already loaded; test is void")
      end
      bigfile.limit(H.lines_buffer(3, "noload"))
      drain()
      for _, mod in ipairs(mods) do
        assert.is_nil(package.loaded[mod], "limit() loaded " .. mod)
      end
    end)

    it("detaches the decoration plugins that are loaded", function()
      local buf = H.lines_buffer(3, "detach")
      local calls = {}
      -- Stand-ins in package.loaded: the real plugins are not loaded in unit mode
      -- (and loading five of them to observe one call each is not worth it), and
      -- what matters is that each one is called with this buffer and by the name
      -- the installed version actually exports — verified against the plugins' own
      -- sources: ufo.detach, ibl.setup_buffer, colorizer.detach_from_buffer,
      -- rainbow-delimiters' disable, and illuminate.engine's stop_buf (the
      -- top-level illuminate.stop_buf drops the bufnr).
      --
      -- rainbow-delimiters needs both keys, and that pairing is the test: the
      -- *gate* is "rainbow-delimiters.lib", because that is what the plugin's own
      -- FileType autocmd loads, while the *call* goes through the top-level
      -- module. Stubbing only the module it is called through is what let this
      -- opt-out silently never run in a real session.
      H.stub(package.loaded, "ufo", { detach = function(b) calls.ufo = b end })
      H.stub(package.loaded, "ibl", { setup_buffer = function(b, cfg) calls.ibl = { b, cfg } end })
      H.stub(package.loaded, "colorizer", { detach_from_buffer = function(b) calls.colorizer = b end })
      H.stub(package.loaded, "rainbow-delimiters.lib", {})
      H.stub(package.loaded, "rainbow-delimiters", { disable = function(b) calls.rainbow = b end })
      H.stub(package.loaded, "illuminate", {})
      H.stub(package.loaded, "illuminate.engine", { stop_buf = function(b) calls.illuminate = b end })

      bigfile.limit(buf)
      drain()

      assert.equals(buf, calls.ufo)
      assert.equals(buf, calls.colorizer)
      assert.equals(buf, calls.rainbow)
      assert.equals(buf, calls.illuminate)
      assert.same({ buf, { enabled = false } }, calls.ibl)
    end)

    it("defers the plugin opt-outs instead of running them inline", function()
      -- Load-bearing, not an implementation detail: limit() runs from a FileType
      -- autocmd registered in init.lua before lazy.setup, so it runs *ahead* of
      -- every plugin's FileType handler. colorizer and rainbow-delimiters both
      -- attach from one, so an inline detach detaches nothing and they attach to
      -- the big buffer immediately afterwards (measured: colorizer stayed attached
      -- to a 12000-line CSS file).
      local when = {}
      H.stub(package.loaded, "colorizer", { detach_from_buffer = function() when.detached = true end })

      bigfile.limit(H.lines_buffer(3, "deferred"))
      assert.is_nil(when.detached, "detach ran inline; a plugin attaching later wins")

      drain()
      assert.is_true(when.detached)
    end)

    it("skips the opt-outs if the buffer is gone by the time they run", function()
      -- A :bwipeout between the FileType event and the next tick is ordinary (a
      -- directory buffer being replaced, a quickfix window opening and closing),
      -- and the detach APIs take a bufnr that nvim_buf_is_valid would reject.
      local buf = H.lines_buffer(3, "wiped")
      local called = false
      H.stub(package.loaded, "colorizer", { detach_from_buffer = function() called = true end })

      bigfile.limit(buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      drain()

      assert.is_false(called)
    end)

    it("survives a plugin that throws", function()
      -- pcall around each call, because this runs for every big buffer: one plugin
      -- erroring must not abort the remaining opt-outs or leave an error on screen
      -- every time such a file is opened.
      local reached = false
      H.stub(package.loaded, "ufo", { detach = function() error("boom") end })
      H.stub(package.loaded, "colorizer", { detach_from_buffer = function() reached = true end })

      local ok = pcall(bigfile.limit, H.lines_buffer(3, "throws"))
      drain()

      assert.is_true(ok)
      assert.is_true(reached)
    end)

    it("survives a module that is loaded but not a table", function()
      -- The require itself has to be inside the pcall, not just the call: a
      -- half-initialised module in package.loaded would otherwise throw straight
      -- past the guard and abort the rest of the opt-outs.
      H.stub(package.loaded, "ufo", true)
      local reached = false
      H.stub(package.loaded, "colorizer", { detach_from_buffer = function() reached = true end })

      local ok = pcall(bigfile.limit, H.lines_buffer(3, "weird"))
      drain()

      assert.is_true(ok)
      assert.is_true(reached)
    end)
  end)

  describe("limit_lsp", function()
    -- The client stays attached, deliberately. lua/config/lsp_reap.lua derives
    -- idleness from client.attached_buffers, so detaching the only buffer of a
    -- jdtls client made the reaper stop the JVM five minutes later — a second
    -- notification about a file still on screen, and a ~30s re-import to get it
    -- back. These tests pin the three features that do get turned off.
    local function fake_client(caps)
      return { id = 1, name = "fake", server_capabilities = caps or {} }
    end

    it("turns off inlay hints for just this buffer", function()
      local buf = H.lines_buffer(3, "hints")
      local calls = H.spy(vim.lsp.inlay_hint, "enable")

      bigfile.limit_lsp(buf, fake_client())

      assert.equals(1, calls.count)
      assert.is_false(calls[1][1])
      assert.same({ bufnr = buf }, calls[1][2])
    end)

    it("stops semantic tokens only when the server offers them", function()
      local buf = H.lines_buffer(3, "semtok")
      local calls = H.spy(vim.lsp.semantic_tokens, "stop")

      bigfile.limit_lsp(buf, fake_client({}))
      assert.equals(0, calls.count, "stopped tokens on a server that has none")

      bigfile.limit_lsp(buf, fake_client({ semanticTokensProvider = { full = true } }))
      assert.equals(1, calls.count)
      assert.same({ buf, 1 }, calls[1])
    end)

    it("stops illuminate, which is what issues documentHighlight", function()
      local buf = H.lines_buffer(3, "dochl")
      local stopped
      H.stub(package.loaded, "illuminate", {})
      H.stub(package.loaded, "illuminate.engine", { stop_buf = function(b) stopped = b end })

      bigfile.limit_lsp(buf, fake_client())

      assert.equals(buf, stopped)
    end)

    it("does not detach the client", function()
      -- The assertion that keeps the lsp_reap interaction from coming back: a
      -- regression to buf_detach_client would empty attached_buffers and hand the
      -- buffer's own language server to the idle reaper.
      local calls = H.spy(vim.lsp, "buf_detach_client")
      bigfile.limit_lsp(H.lines_buffer(3, "nodetach"), fake_client())
      assert.equals(0, calls.count)
    end)
  end)
end)
