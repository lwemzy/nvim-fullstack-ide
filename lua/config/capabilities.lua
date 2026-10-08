-- The LSP client capabilities every server in this config is started with.
--
-- A module because there are two places that start servers and they are not the
-- same code path: lua/plugins/lsp.lua hands this to vim.lsp.config("*"), which
-- covers every mason-installed server, while ftplugin/java.lua starts jdtls by
-- hand through nvim-jdtls — so the wildcard never reaches it. The two had
-- identical copies of this table, which is survivable for completion (a missing
-- capability there is immediately visible) and not for file operations: if only
-- the lsp.lua copy advertises workspace.fileOperations, Java package moves stop
-- rewriting imports and nothing anywhere reports it.

local M = {}

---Build a fresh capabilities table.
---
---Fresh, not a cached one: vim.lsp.config entries and nvim-jdtls both keep a
---reference to what they are given, and vim.lsp merges server-specific config
---over it, so handing the same table to two clients lets one client's
---resolution show up in the other's.
---@return lsp.ClientCapabilities
function M.make()
  local caps = vim.lsp.protocol.make_client_capabilities()

  -- Completion: advertise what nvim-cmp can actually render (snippets,
  -- additionalTextEdits for auto-import, resolve support).
  local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
  if cmp_ok then
    caps = vim.tbl_deep_extend("force", caps, cmp_lsp.default_capabilities())
  end

  -- File operations: asking is what makes a server offer them. jdtls gates its
  -- whole willRename implementation on this capability
  -- (InitHandler.isWorkspaceWillRenameFilesSupported), so without it
  -- server_capabilities.workspace.fileOperations comes back nil and
  -- nvim-lsp-file-operations' handler finds nothing to send to — a silent
  -- no-op, which is why :checkhealth nvim-ide reports this.
  --
  -- Requiring the plugin here is deliberately cheap and does NOT pull nvim-tree
  -- in: its spec (lua/plugins/ui.lua) has no `config`, and default_capabilities
  -- touches only the plugin's own config module. The nvim-tree subscription
  -- happens later, in lua/config/file_ops.lua, when the explorer loads.
  --
  -- No `operations` override anywhere, for the same reason: this runs before
  -- lsp-file-operations.setup() has, so default_capabilities() falls back to the
  -- plugin's defaults — and an override would advertise one set of operations
  -- while subscribing to another.
  local fileops_ok, fileops = pcall(require, "lsp-file-operations")
  if fileops_ok then
    caps = vim.tbl_deep_extend("force", caps, fileops.default_capabilities())
  end

  return caps
end

return M
