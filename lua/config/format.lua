-- Whether saving a file should reformat it, and the one switch that changes it.
--
-- A module rather than a bare `vim.g.autoformat` read at each call site, because
-- there are three of them — conform's format_after_save (lua/plugins/editor.lua),
-- eslint's fix-on-save (lua/plugins/lsp.lua) and the toggle keymaps
-- (lua/config/keymaps.lua) — and they have to agree on the precedence rule
-- below. Spelling it out in three places is how two of them end up disagreeing
-- about what an unset buffer variable means.
--
-- Two switches, not one: format-on-save (M.enabled) and eslint's fix-on-save
-- (M.lint_fix_enabled), the second defaulting to the first. See
-- M.lint_fix_enabled for why they had to come apart.

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

---Is eslint's fix-on-save active for `buf`?
---
---Separate from M.enabled because the two do different jobs on the same save and
---only one of them is a formatter. eslint --fix sorts imports, drops unused
---variables and applies every other autofixable rule in the project's eslint
---config; prettier reprints the file. They also run at different times —
---LspEslintFixAll on BufWritePre (lua/plugins/lsp.lua), conform on BufWritePost
---(lua/plugins/editor.lua) — so prettier runs LAST and wins any disagreement.
---That is mostly invisible, but not always: commerce-api's
---`space-before-function-paren: never` wants `async(item, ctx)` and no
---Prettier-compatible formatter will write that, so eslint fixes it and prettier
---puts the space straight back on every save. Turning just this half off is the
---way out of that loop without losing format-on-save.
---
---Precedence mirrors M.enabled, with one addition at the end: unset falls
---through to format-on-save rather than to `true`. So <leader>uf still switches
---BOTH off (the behaviour before this flag existed — otherwise turning
---format-on-save off would leave JS/TS files still rewriting themselves on save,
---the one place the setting would look broken), while <leader>ul switches off
---only the lint autofix.
---@param buf integer? defaults to the current buffer
---@return boolean
function M.lint_fix_enabled(buf)
  local local_pref = vim.b[buf or 0].autolintfix
  if local_pref ~= nil then return local_pref end
  if vim.g.autolintfix ~= nil then return vim.g.autolintfix and M.enabled(buf) end
  return M.enabled(buf)
end

---Flip eslint's fix-on-save for the session and say which way it went.
---@return boolean enabled the state after the flip
function M.toggle_lint_fix()
  local now = not M.lint_fix_enabled()
  vim.g.autolintfix = now
  vim.b.autolintfix = nil
  -- "and format-on-save is off" rather than a bare "enabled": with
  -- vim.g.autolintfix true but format-on-save off, lint_fix_enabled is still
  -- false, and reporting "enabled" there would be a lie.
  local effective = M.lint_fix_enabled()
  vim.notify(
    "eslint fix on save " .. (effective and "enabled" or "disabled")
      .. ((now and not effective) and " (format on save is off)" or ""),
    vim.log.levels.INFO, { title = "eslint" }
  )
  return effective
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
