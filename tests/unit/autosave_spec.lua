-- lua/config/autosave.lua — the guarded buffer write.
--
-- Extracted from the auto_save autocmd so lua/config/file_ops.lua can reuse it,
-- which means it now has a caller that autocmds.lua never had: a buffer that is
-- not current and not displayed in any window. That is the case this file is
-- really about. The autocmd's own behaviour stays covered by the auto_save group
-- in autocmds_spec.lua, deliberately unchanged — those cases are the regression
-- check on the extraction, so nothing here duplicates them.

local H = require("helpers")

local function write(buf)
  return require("config.autosave").write(buf)
end

describe("config.autosave", function()
  local dir

  before_each(function()
    H.disable_autosave()
    dir = H.tmpdir("autosave-mod")
  end)

  after_each(H.cleanup)

  --- A loaded, named, modified buffer that is NOT current — the shape
  --- apply_text_edits leaves behind for every file a rename touched.
  local function hidden(path, lines)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    -- The stamp BufReadPost would have set. bufadd/bufload is used rather than
    -- H.edit because entering the buffer is exactly what must not happen here.
    vim.b[buf].autosave_mtime = vim.fn.getftime(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    H.track_buf(buf)
    return buf
  end

  it("writes a buffer that is neither current nor displayed", function()
    -- The whole reason this module exists separately. vim.lsp.util's text edits
    -- land in buffers like this one and nothing else in the config ever writes
    -- them: auto_save is BufLeave/FocusLost, and you cannot leave a buffer you
    -- were never in. Without this the imports an LSP rename fixed would exist
    -- only inside nvim while gradle compiled the stale file.
    local path = H.write(dir .. "/Hidden.java", { "class Hidden {}" })
    local buf = hidden(path, { "class Renamed {}" })
    local current = vim.api.nvim_get_current_buf()

    assert.is_true(write(buf))

    assert.same({ "class Renamed {}" }, vim.fn.readfile(path))
    assert.is_false(vim.bo[buf].modified)
    -- A `:write` without nvim_buf_call would have written the current buffer
    -- instead, which is both the wrong file and a silent data change.
    assert.equals(current, vim.api.nvim_get_current_buf())
  end)

  it("defaults to the current buffer", function()
    -- autocmds.lua passes the bufnr explicitly, but the default is what makes
    -- this callable from a keymap or :lua line without one.
    local path = H.write(dir .. "/cur.txt", { "before" })
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "after" })
    assert.is_true(write())
    assert.same({ "after" }, vim.fn.readfile(path))
  end)

  it("reports false without writing when the buffer is unmodified", function()
    local path = H.write(dir .. "/clean.txt", { "untouched" })
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    H.track_buf(buf)
    -- The return value is not decoration: file_ops writes whatever became
    -- modified during a rename, so "nothing to do" has to be distinguishable
    -- from "wrote it" or a no-op rename would look like a successful one.
    assert.is_false(write(buf))
  end)

  it("refuses a buffer with no name", function()
    -- :write with no file name is an E32 in the message area, and in the
    -- file_ops path it would fire for any scratch buffer the user left dirty.
    local buf = vim.api.nvim_create_buf(true, false) -- listed, buftype ""
    H.track_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "scratch work" })
    assert.is_false(write(buf))
  end)

  for _, buftype in ipairs({ "nofile", "help", "acwrite" }) do
    it("refuses a " .. buftype .. " buffer", function()
      local path = H.write(dir .. "/" .. buftype .. ".txt", { "original" })
      local buf = hidden(path, { "edited" })
      vim.bo[buf].buftype = buftype
      assert.is_false(write(buf))
      -- acwrite is the pointed one: :write there routes into a plugin's
      -- BufWriteCmd, so writing it behind the user's back runs arbitrary
      -- plugin code.
      assert.same({ "original" }, vim.fn.readfile(path))
    end)
  end

  it("refuses an invalid buffer instead of erroring", function()
    -- A rename can wipe a buffer out (nvim-tree reloads buffers for the
    -- renamed path), and this runs afterwards over a snapshot taken before —
    -- so a stale bufnr is expected input, not a bug to propagate.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_false(write(buf))
  end)

  it("skips and warns when the file changed on disk after the stamp", function()
    local path = H.write(dir .. "/raced.txt", { "theirs" })
    local buf = hidden(path, { "ours" })
    -- Backdating the stamp stands in for an external rewrite without
    -- depending on getftime's one-second resolution.
    vim.b[buf].autosave_mtime = vim.fn.getftime(path) - 10

    local notes = H.capture_notifications(function()
      assert.is_false(write(buf))
    end)

    -- `silent! write` does not suppress the "changed since reading it, really
    -- write?" prompt — it makes it invisible, and the next keystroke answers
    -- it. So losing this guard loses whatever the other writer (git pull, an
    -- agent) had just put on disk.
    assert.same({ "theirs" }, vim.fn.readfile(path))
    assert.is_true(vim.bo[buf].modified)
    assert.equals(1, #notes)
    assert.equals(vim.log.levels.WARN, notes[1].level)
    assert.is_true(notes[1].msg:find("raced.txt", 1, true) ~= nil)
    -- The message has to name the way out: nothing else will write this buffer.
    assert.is_true(notes[1].msg:find(":w to overwrite", 1, true) ~= nil)
  end)

  it("writes a buffer that was never stamped", function()
    -- No autosave_mtime means the buffer was not read from disk by this
    -- editor — a brand new file, or one bufload'd by apply_text_edits before
    -- BufReadPost's stamp applies. Refusing those would make an LSP rename
    -- silently skip exactly the files it created.
    local path = dir .. "/New.java"
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    H.track_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "class New {}" })
    assert.is_true(write(buf))
    assert.same({ "class New {}" }, vim.fn.readfile(path))
  end)

  it("leaves autocmds on, so the next save is still guarded", function()
    -- Writing with `noautocmd` would be the obvious way to keep a background
    -- write quiet, and it would break the guard above: auto_save_stamp's
    -- BufWritePost re-stamp is what stops the file this write just changed
    -- from looking externally modified on the following save.
    local path = H.write(dir .. "/stamped.txt", { "one" })
    local buf = hidden(path, { "two" })
    local fired = false
    local group = vim.api.nvim_create_augroup("autosave_spec_post", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      buffer = buf,
      callback = function() fired = true end,
    })

    assert.is_true(write(buf))
    assert.is_true(fired)
    vim.api.nvim_del_augroup_by_id(group)
  end)
end)
