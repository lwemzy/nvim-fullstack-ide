-- config.format — the one switch conform's format_after_save and eslint's
-- fix-on-save both read.
--
-- The precedence rule is the whole module, and the part worth pinning is that
-- `false` and "unset" are different: a truthiness check would make an explicit
-- per-buffer opt-out indistinguishable from no preference, so a buffer marked
-- `autoformat = false` would format anyway the moment the global was on.

local H = require("helpers")

local format = require("config.format")

describe("config.format", function()
  before_each(function() H.disable_autosave() end)
  after_each(function() H.cleanup() end)

  describe("enabled", function()
    it("is on when nothing has been set", function()
      -- The behaviour this config had before the toggle existed, and what an
      -- unconfigured buffer must keep getting.
      assert.is_nil(vim.g.autoformat)
      assert.is_true(format.enabled(H.scratch({ lines = { "x" } })))
    end)

    it("follows the session setting", function()
      local buf = H.scratch({ lines = { "x" } })
      H.stub(vim.g, "autoformat", false)
      assert.is_false(format.enabled(buf))
      H.stub(vim.g, "autoformat", true)
      assert.is_true(format.enabled(buf))
    end)

    it("lets a buffer opt out of a session that formats", function()
      local buf = H.scratch({ lines = { "x" } })
      H.stub(vim.g, "autoformat", true)
      vim.b[buf].autoformat = false
      assert.is_false(format.enabled(buf))
    end)

    it("lets a buffer opt in to a session that does not", function()
      local buf = H.scratch({ lines = { "x" } })
      H.stub(vim.g, "autoformat", false)
      vim.b[buf].autoformat = true
      assert.is_true(format.enabled(buf))
    end)

    it("answers for the buffer it is asked about, not the current one", function()
      -- format_after_save hands conform's event buffer in, which is not
      -- necessarily the buffer in the window: an async re-save can land after
      -- the user has moved on. Reading vim.b[0] here would consult the wrong
      -- buffer's opt-out.
      local other = H.scratch({ lines = { "x" } })
      local current = H.scratch({ lines = { "y" } })
      vim.api.nvim_set_current_buf(current)
      vim.b[other].autoformat = false

      assert.is_false(format.enabled(other))
      assert.is_true(format.enabled(current))
    end)

    it("defaults to the current buffer when given no argument", function()
      local buf = H.scratch({ lines = { "x" } })
      vim.api.nvim_set_current_buf(buf)
      vim.b[buf].autoformat = false
      assert.is_false(format.enabled())
    end)
  end)

  describe("toggle", function()
    it("turns an unset session off, then back on", function()
      H.stub(vim.g, "autoformat", nil)
      local notes = H.capture_notifications(function()
        assert.is_false(format.toggle())
      end)
      assert.is_false(vim.g.autoformat)
      assert.equals(1, #notes)
      assert.is_truthy(notes[1].msg:find("disabled", 1, true), notes[1].msg)

      -- Captured too, or the message lands in the test runner's own output.
      notes = H.capture_notifications(function()
        assert.is_true(format.toggle())
      end)
      assert.is_true(vim.g.autoformat)
      assert.is_truthy(notes[1].msg:find("enabled", 1, true), notes[1].msg)
    end)

    it("clears a buffer-local override so the message is not a lie", function()
      -- Without this, toggling in a buffer that had opted out announced
      -- "enabled" while that buffer's own `false` still won, and the next save
      -- did nothing.
      local buf = H.scratch({ lines = { "x" } })
      vim.api.nvim_set_current_buf(buf)
      vim.b[buf].autoformat = false
      H.stub(vim.g, "autoformat", nil)

      H.capture_notifications(function() assert.is_true(format.toggle()) end)

      assert.is_nil(vim.b[buf].autoformat)
      assert.is_true(format.enabled(buf))
    end)
  end)
end)
