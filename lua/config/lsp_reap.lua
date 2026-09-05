-- Reclaim idle JVM language servers.
--
-- Neovim never stops a client by itself. Client:_on_detach only clears
-- attached_buffers[bufnr] (runtime lsp/client.lua:1365-1398), and the only
-- internal client:stop() calls are `vim.lsp.enable(name, false)` and VimLeavePre
-- (runtime lsp.lua:662, 1187). A client therefore outlives every buffer it ever
-- served, for the rest of the session.
--
-- For the node servers that is tens of MB and not worth touching. For the JVMs it
-- is not: ftplugin/java.lua gives every project root its own workspace and calls
-- jdtls.start_or_attach per root, and spring-boot.nvim starts boot-ls per
-- vim.fs.root — so visiting N Java projects in one session ends with N jdtls JVMs
-- plus N boot-ls JVMs resident long after the last buffer from those projects is
-- closed. Each instance's heap is already capped (ftplugin/java.lua sizes -Xmx
-- from the machine; boot-ls is pinned to 1G by the plugin) but nothing capped the
-- instance COUNT, and a per-instance cap is no help when the count is what grows.
-- On Linux this is the shape that ends at the OOM killer, which picks the largest
-- RSS — jdtls — so it surfaces as Java completion dying mid-session with nothing
-- in nvim to explain it.
--
-- A module rather than a block inside lua/plugins/lsp.lua's config function so the
-- grace period is testable: sweep() takes the clock as an argument.

local M = {}

--- Servers worth reclaiming. Only the JVMs — a node server's footprint does not
--- justify the risk of an unwanted restart.
M.servers = { jdtls = true, ["spring-boot"] = true }

--- Deliberately not eager. A jdtls start is a ~30s project import, so reclaiming a
--- server the user is about to return to costs far more than the RAM it frees.
--- Five minutes with not one live buffer means the project was genuinely left
--- behind, not navigated away from.
M.idle_timeout_ms = 5 * 60 * 1000

--- Idleness is measured per client, so the sweep has to be periodic rather than a
--- single timer armed by the first detach: with one shared timer, a server that
--- fell idle 4:59 into the window would be stopped one second later instead of
--- five minutes later. This interval is the resolution, so the real grace period
--- is one interval wider than idle_timeout_ms.
M.sweep_interval_ms = 60 * 1000

--- client id -> clock reading when it was first seen with no live buffer.
local idle_since = {}
local scheduled = false

--- Does this client still have a buffer worth staying alive for?
---
--- attached_buffers is what nvim's own deprecation notice for
--- get_buffers_by_client_id() points at, so it is the supported read.
---
--- The validity/loaded check is belt-and-braces, not load-bearing: measured, nvim
--- clears the entry itself for all three ways a buffer can be retired (:bwipeout,
--- :bdelete and :bunload all route through nvim_buf_attach's on_detach, which ends
--- in attached_buffers[bufnr] = nil). It stays because being wrong in either
--- direction here is expensive — a phantom entry means a JVM is never reclaimed,
--- and a missed one means a ~30s import the user did not ask for — and the check
--- costs a table lookup on a table that is almost always size one.
local function has_live_buffer(client)
  for bufnr in pairs(client.attached_buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      return true
    end
  end
  return false
end

--- Stop JVM servers whose buffers have all been gone for the grace period.
---
--- Re-derives idleness from attached_buffers on every pass instead of bookkeeping
--- from events, because the events are not trustworthy enough to bookkeep from:
--- LspDetach is fired inside _on_detach behind an `nvim_buf_is_valid` guard
--- (runtime lsp/client.lua:1366), so :bwipeout can retire a buffer without it ever
--- arriving. Deriving the state makes this correct whichever event woke it, and
--- self-healing when none did.
---
---@param now integer? clock reading in ms; defaults to vim.uv.now()
---@return string[] stopped names of the clients this pass stopped
---@return boolean live whether any tracked server is still running
function M.sweep(now)
  now = now or vim.uv.now()
  local stopped, live = {}, false

  for _, client in ipairs(vim.lsp.get_clients()) do
    if M.servers[client.name] and not client:is_stopped() then
      if has_live_buffer(client) then
        idle_since[client.id] = nil
        live = true
      elseif not idle_since[client.id] then
        idle_since[client.id] = now
        live = true
      elseif now - idle_since[client.id] >= M.idle_timeout_ms then
        idle_since[client.id] = nil
        table.insert(stopped, client.name)
        client:stop()
      else
        live = true
      end
    end
  end

  -- Clients that went away on their own (crash, :LspRestart, our own stop) would
  -- otherwise leave their id here for the rest of the session.
  for id in pairs(idle_since) do
    local c = vim.lsp.get_client_by_id(id)
    if not c or c:is_stopped() then idle_since[id] = nil end
  end

  return stopped, live
end

--- Arm the next sweep, unless one is already pending.
function M.schedule()
  if scheduled then return end
  scheduled = true
  vim.defer_fn(function()
    scheduled = false
    local stopped, live = M.sweep()
    for _, name in ipairs(stopped) do
      -- Announced, because the cost is deferred and otherwise inexplicable: the
      -- next visit to that project pays a fresh import, and a silent 30s stall
      -- reads like a hang.
      vim.notify(
        ("Stopped idle %s (no open buffers for %d min) — reopening the project will restart it")
          :format(name, M.idle_timeout_ms / 60000),
        vim.log.levels.INFO
      )
    end
    -- Only keep ticking while there is something left to reap, so an editing
    -- session with no JVM server running never pays for this at all.
    if live then M.schedule() end
  end, M.sweep_interval_ms)
end

function M.setup()
  -- LspAttach as well as the teardown events, so the sweep is already running
  -- before there is anything to reap; it stops itself once nothing is left.
  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach", "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("user_lsp_reap_idle", { clear = true }),
    callback = function() M.schedule() end,
  })
end

--- Drop all idle bookkeeping. For tests: sweep() is stateful across calls, and a
--- spec that left an entry behind would decide a later one's outcome.
function M.reset()
  idle_since = {}
  scheduled = false
end

return M
