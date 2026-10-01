-- config.bigfile — the size thresholds every per-keystroke cost in this config
-- is gated on.
--
-- Asserted at the boundaries rather than with comfortably-over values, because
-- an off-by-one here is invisible in use: the file just feels slow, or the
-- highlighting just isn't there, and neither points at a comparison operator.
-- The plugin opt-outs are asserted through package.loaded rather than by loading
-- the plugins, which is also exactly the property under test.

local H = require("helpers")

local bigfile = require("config.bigfile")

--- A normal (buftype "") named buffer of `n` lines.
local function lines_buffer(n, tag)
  local lines = {}
  for i = 1, n do lines[i] = "line " .. i end
  return H.scratch({ scratch = false, name = H.tmpdir(tag) .. "/" .. tag .. ".txt", lines = lines })
end

describe("config.bigfile", function()
  before_each(function() H.disable_autosave() end)
  after_each(function() H.cleanup() end)

  describe("thresholds", function()
    it("keeps the LSP tier well above the decoration tier", function()
      -- The whole point of there being two numbers: a 10k-line Java class loses
      -- treesitter highlighting and keeps completion. Collapsing them would mean
      -- every large-but-ordinary source file silently loses its language server.
      assert.is_true(bigfile.LSP_MAX_LINES > bigfile.MAX_LINES)
      assert.is_true(bigfile.LSP_MAX_BYTES > bigfile.MAX_BYTES)
    end)
  end)

  describe("is_big", function()
    it("is false exactly at the line limit and true one line past it", function()
      assert.is_false(bigfile.is_big(lines_buffer(bigfile.MAX_LINES, "at")))
      assert.is_true(bigfile.is_big(lines_buffer(bigfile.MAX_LINES + 1, "over")))
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

  describe("is_too_big_for_lsp", function()
    it("leaves a merely large file to the language server", function()
      -- Over the decoration tier, under the LSP tier: the common real case, and
      -- the one where detaching would read as "autocomplete is broken".
      local buf = lines_buffer(bigfile.MAX_LINES + 1, "large")
      assert.is_true(bigfile.is_big(buf))
      assert.is_false(bigfile.is_too_big_for_lsp(buf))
    end)

    it("is true one line past its own limit", function()
      assert.is_false(bigfile.is_too_big_for_lsp(lines_buffer(bigfile.LSP_MAX_LINES, "lsp-at")))
      assert.is_true(bigfile.is_too_big_for_lsp(lines_buffer(bigfile.LSP_MAX_LINES + 1, "lsp-over")))
    end)
  end)

  describe("limit", function()
    it("bounds the regex engine and stops writing undo files", function()
      local buf = lines_buffer(3, "lim")
      bigfile.limit(buf)
      assert.equals(200, vim.bo[buf].synmaxcol)
      assert.is_false(vim.bo[buf].undofile)
    end)

    it("changes nothing globally", function()
      -- Every option it touches is buffer-scoped. A global synmaxcol of 200 would
      -- silently stop highlighting past column 200 in every file opened after.
      local before = vim.go.synmaxcol
      bigfile.limit(lines_buffer(3, "global"))
      assert.equals(before, vim.go.synmaxcol)
    end)

    it("does not load a plugin in order to switch it off", function()
      -- The trap this guards: require() is one of lazy.nvim's load triggers, so
      -- pcall(require, "ufo") here would pull ufo, ibl and colorizer into the
      -- session — on the one buffer where the entire goal is less work.
      for _, mod in ipairs({ "ufo", "ibl", "colorizer" }) do
        assert.is_nil(package.loaded[mod], mod .. " was already loaded; test is void")
      end
      bigfile.limit(lines_buffer(3, "noload"))
      for _, mod in ipairs({ "ufo", "ibl", "colorizer" }) do
        assert.is_nil(package.loaded[mod], "limit() loaded " .. mod)
      end
    end)

    it("detaches the decoration plugins that are loaded", function()
      local buf = lines_buffer(3, "detach")
      local calls = {}
      -- Stand-ins in package.loaded: the real plugins are not loaded in unit mode
      -- (and loading three of them to observe one call each is not worth it), and
      -- what matters is that each one is called with this buffer and by the name
      -- the installed version actually exports — verified against the plugins'
      -- own sources: ufo.detach, ibl.setup_buffer, colorizer.detach_from_buffer.
      package.loaded["ufo"] = { detach = function(b) calls.ufo = b end }
      package.loaded["ibl"] = { setup_buffer = function(b, cfg) calls.ibl = { b, cfg } end }
      package.loaded["colorizer"] = { detach_from_buffer = function(b) calls.colorizer = b end }

      local ok, err = pcall(bigfile.limit, buf)

      package.loaded["ufo"] = nil
      package.loaded["ibl"] = nil
      package.loaded["colorizer"] = nil

      assert.is_true(ok, tostring(err))
      assert.equals(buf, calls.ufo)
      assert.equals(buf, calls.colorizer)
      assert.same({ buf, { enabled = false } }, calls.ibl)
    end)

    it("survives a plugin that throws", function()
      -- pcall around each call, because this runs on FileType for every big
      -- buffer: one plugin erroring must not abort the remaining opt-outs or
      -- leave an error on screen every time such a file is opened.
      local buf = lines_buffer(3, "throws")
      package.loaded["ufo"] = { detach = function() error("boom") end }
      local reached = false
      package.loaded["colorizer"] = { detach_from_buffer = function() reached = true end }

      local ok = pcall(bigfile.limit, buf)

      package.loaded["ufo"] = nil
      package.loaded["colorizer"] = nil

      assert.is_true(ok)
      assert.is_true(reached)
    end)
  end)
end)
