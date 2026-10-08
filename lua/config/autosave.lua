-- Writing a buffer back to disk without clobbering anyone.
--
-- Extracted from the auto_save autocmd in lua/config/autocmds.lua, which is
-- still the main caller. The second one is lua/config/file_ops.lua: an LSP-aware
-- rename hands back edits for every file that referenced the renamed one, and
-- vim.lsp.util.apply_text_edits only puts those in buffers — so somebody has to
-- write them, under the same staleness guard, for buffers that are not the
-- current one.

local M = {}

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
  if known and vim.fn.getftime(name) > known then
    vim.notify(
      "auto-save skipped: " .. vim.fn.fnamemodify(name, ":t") .. " changed on disk (:w to overwrite)",
      vim.log.levels.WARN
    )
    return false
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
