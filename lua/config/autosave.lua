-- Writing a buffer back to disk without clobbering anyone.
--
-- Extracted from the auto_save autocmd in lua/config/autocmds.lua, which is
-- still the main caller. The second one is lua/config/file_ops.lua: an LSP-aware
-- rename hands back edits for every file that referenced the renamed one, and
-- vim.lsp.util.apply_text_edits only puts those in buffers — so somebody has to
-- write them, under the same staleness guard, for buffers that are not the
-- current one.

local M = {}

---The on-disk identity of `name`, or nil if there is no file there.
---
---mtime seconds AND nanoseconds AND size, which is exactly what Neovim's own
---`buf_write` compares (`!=` on each, not `>`). A one-sided second-resolution
---check — what this used to be, `getftime(name) > known` — fails open in three
---ways that all end in silent data loss:
---
---  * `getftime` returns -1 for a missing file, so `-1 > known` is false and a
---    path that was deleted or renamed away gets RECREATED from the stale
---    buffer. Renaming Old.java to New.java in a terminal split left both on
---    disk, i.e. two classes of the same name and a build that stops compiling.
---  * an external write landing in the same wall-clock second compares equal,
---    so their content is clobbered.
---  * mtime moving BACKWARDS is `<`, not `>`, and `tar -x`, `unzip`, `cp -p`,
---    `rsync -a`, `git checkout` and `touch -r` all do that routinely.
---@param name string
---@return { sec: integer, nsec: integer, size: integer }?
function M.stat(name)
  if name == "" then return nil end
  local st = vim.uv.fs_stat(name)
  if not st then return nil end
  return { sec = st.mtime.sec, nsec = st.mtime.nsec, size = st.size }
end

---Record the on-disk identity we last synced with, so `M.write` can tell
---whether the file changed underneath us.
---
---Called from the auto_save_stamp augroup in lua/config/autocmds.lua on
---BufReadPost and BufWritePost. It lives here, next to the only consumer of the
---value, so the shape of `vim.b.autosave_mtime` is defined in one place.
---@param buf integer
function M.stamp(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" then vim.b[buf].autosave_mtime = M.stat(name) end
end

---Write `buf` if it is a modified, file-backed buffer and the file on disk has
---not moved under us since we last synced with it.
---
---The staleness guard is the whole reason this is a function rather than a
---`vim.cmd("write")`: `silent! write` does NOT suppress Neovim's "file has
---changed since reading it, really write (y/n)?" prompt, and a modified buffer
---is never auto-reloaded by checktime — so without the guard an external edit
---(git pull, Claude writing files) turns an automatic save into an invisible
---prompt that the user's next keystroke answers at random. Skipping and saying
---so lets them resolve it with an explicit :w.
---
---`vim.b.autosave_mtime` is stamped on BufReadPost/BufWritePost by the
---auto_save_stamp augroup in lua/config/autocmds.lua.
---@param buf integer? defaults to the current buffer
---@return boolean written
function M.write(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return false end

  local name = vim.api.nvim_buf_get_name(buf)
  if not (vim.bo[buf].modified and vim.bo[buf].buftype == "" and name ~= "") then
    return false
  end

  local known = vim.b[buf].autosave_mtime
  -- type(), not a bare truthiness test: this used to hold a bare getftime()
  -- number, and a buffer stamped before the config was reloaded (:source, a lazy
  -- re-config, or simply a long-lived session across an upgrade) still carries
  -- one. Indexing it raises inside a BufLeave callback, which aborts the write
  -- and loses the edit — the exact outcome the guard exists to prevent. An
  -- unrecognised stamp is treated as no stamp: M.stamp re-establishes it on the
  -- next read or write.
  if type(known) == "table" then
    local now = M.stat(name)
    local reason
    if not now then
      -- Deleted or renamed away while we held it modified. Writing here would
      -- resurrect the old path, which for a Java class means two files
      -- declaring the same type.
      reason = "no longer on disk"
    elseif now.sec ~= known.sec or now.nsec ~= known.nsec or now.size ~= known.size then
      reason = "changed on disk"
    end
    if reason then
      vim.notify(
        ("auto-save skipped: %s %s (:w to overwrite)")
          :format(vim.fn.fnamemodify(name, ":t"), reason),
        vim.log.levels.WARN
      )
      return false
    end
  end

  -- nvim_buf_call rather than a bare :write, because file_ops writes buffers
  -- that are not current (and usually not even displayed). For the auto_save
  -- caller, where buf IS current, this is a no-op wrapper.
  --
  -- Autocmds are deliberately left enabled: auto_save_stamp's BufWritePost
  -- re-stamp is what keeps the guard above honest on the next save, and
  -- format-on-save should behave here exactly as it does for a hand-typed :w.
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent! write") end)
  return true
end

return M
