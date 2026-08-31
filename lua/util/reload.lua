-- Shared throttle for :checktime, called from two independent, uncoordinated
-- pollers: claude_cli.lua's 2-second panel-open timer and autocmds.lua's
-- FocusGained/BufEnter/CursorHold/CursorHoldI/TermLeave autocmd. Each on its
-- own is fine — a :checktime with no real external change is a genuine
-- no-op (confirmed: it produces zero LSP traffic). The problem is what
-- happens when there IS a real change: Neovim's autoread reload sends
-- textDocument/didClose + textDocument/didOpen (never didChange — confirmed
-- by tracing real LSP traffic), which forces jdtls to fully discard and
-- rebuild that file's compilation unit from scratch. A real coding session
-- with the AI panel (lua/claude_cli.lua) typically involves several edits
-- over a few seconds, and with two independent pollers both free to fire
-- :checktime the moment each edit lands, those expensive full rebuilds can
-- stack up faster than jdtls can drain them — which is what actually broke
-- completion "while the AI is editing", not a single one-off race. This
-- throttle needs to be shared state, not a local copy per call site: two
-- independent timestamps wouldn't stop the two pollers firing close
-- together, which is exactly the failure mode this exists to prevent.

local M = {}

local MIN_INTERVAL_MS = 1500
local last_checktime_at = 0

function M.throttled_checktime()
  local now = vim.uv.now()
  if now - last_checktime_at < MIN_INTERVAL_MS then
    return
  end
  last_checktime_at = now
  vim.cmd("silent! checktime")
end

return M
