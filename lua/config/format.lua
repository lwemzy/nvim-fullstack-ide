-- Whether saving a file should reformat it, and the one switch that changes it.
--
-- A module rather than a bare `vim.g.autoformat` read at each call site, because
-- there are three of them — conform's format_after_save (lua/plugins/editor.lua),
-- eslint's fix-on-save (lua/plugins/lsp.lua) and the toggle keymap
-- (lua/config/keymaps.lua) — and they have to agree on the precedence rule
-- below. Spelling it out in three places is how two of them end up disagreeing
-- about what an unset buffer variable means.

local M = {}

---Is format-on-save active for `buf`?
---
---Precedence, deliberately in this order:
---  * `vim.b.autoformat`, if set, so one buffer can opt out of a session that
---    formats (a generated file, a vendored bundle) or opt in to one that does
---    not. `false` has to be distinguished from "unset" here, which is why this
---    tests `~= nil` rather than truthiness.
---  * `vim.g.autoformat`, the session-wide setting the toggle below flips.
---  * on, matching the behaviour this config had before the toggle existed.
---@param buf integer? defaults to the current buffer
---@return boolean
function M.enabled(buf)
  local local_pref = vim.b[buf or 0].autoformat
  if local_pref ~= nil then return local_pref end
  if vim.g.autoformat ~= nil then return vim.g.autoformat end
  return true
end

---Flip format-on-save for the session and say which way it went.
---
---Writes the global and clears the buffer-local override, so the toggle always
---reports the truth: leaving `vim.b.autoformat` set would mean pressing the key
---announced "enabled" while this buffer carried an opt-out that still won.
---@return boolean enabled the state after the flip
function M.toggle()
  local now = not M.enabled()
  vim.g.autoformat = now
  vim.b.autoformat = nil
  vim.notify("Format on save " .. (now and "enabled" or "disabled"),
    vim.log.levels.INFO, { title = "conform" })
  return now
end

return M
