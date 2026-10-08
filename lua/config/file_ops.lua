-- LSP-aware file operations from the file explorer.
--
-- Renaming or moving a file in nvim-tree is, on its own, just a rename on disk:
-- rename Foo.java to Bar.java and the class inside it is still `Foo`, so a
-- project that compiled before the rename does not compile after it, with
-- nothing on screen to say so. The LSP has an answer for this
-- (workspace/willRenameFiles, which returns the refactoring as a
-- WorkspaceEdit) and jdtls implements it: FileEventHandler.computeFileRenameEdit
-- for a file, computePackageRenameEdit for a folder. nvim-lsp-file-operations is
-- the wiring between nvim-tree's events and that request.
--
-- What jdtls 1.60.0 actually fixes, measured end-to-end against a real gradle
-- project rather than taken from its README:
--
--   * Renaming a .java file in place — the type is renamed and every reference
--     to it is rewritten.
--   * Renaming a package DIRECTORY — the `package` declarations inside it and
--     the importers' `import` lines both follow.
--   * Moving a single .java file into a different directory — NOT fixed. jdtls
--     returns no package edit for it, so the file keeps its old `package`
--     declaration and importers keep the old fully-qualified name. That is a
--     server-side gap, not something this config can wire around; the workaround
--     is to move the file with an LSP code action, or to rename the package
--     directory when that is what was meant.
--
-- What this module adds on top of the plugin is the last step: getting the
-- result onto disk. See M.setup.

local M = {}

---Buffers that were already modified when the current rename started, so the
---write below can tell "this buffer was dirty anyway" from "the refactor
---changed it". Lives across the two handlers, nil between renames.
---@type table<integer, true>?
local dirty_before

local function modified_bufs()
  local set = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified then set[buf] = true end
  end
  return set
end

---Write everything the refactor touched, and nothing else.
---
---Only buffers that became modified during the rename: a buffer the user had
---already left dirty is their business, and a rename is no reason to write
---unrelated work in progress.
---
---The renamed file's own buffer needs no special case. nvim-tree force-writes
---and reloads it in utils.rename_loaded_buffers (`silent! write!` then `edit`,
---to avoid an overwrite error under the new name), which runs after the edits
---were applied and before NodeRenamed — so by the time this is called it is
---already on disk and no longer modified.
local function save_touched()
  local before = dirty_before or {}
  dirty_before = nil
  local autosave = require("config.autosave")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified and not before[buf] then
      autosave.write(buf)
    end
  end
end

---Subscribe to nvim-tree's file events and forward them to attached servers.
---
---Called from the tail of nvim-tree's own config (lua/plugins/ui.lua) rather
---than from the plugin's spec, because nvim-lsp-file-operations' setup()
---subscribes through nvim-tree's api and so has to run after nvim-tree.setup().
function M.setup()
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then return end
  local Event = api.events.Event

  -- Before the plugin's own handler, and that ordering is load-bearing: this one
  -- records the pre-rename state, so it has to see the buffers as they were.
  -- nvim-tree/events.lua keeps handlers in a table.insert list and dispatches
  -- with pairs(), which walks a sequence in insertion order — subscribing first
  -- is therefore the mechanism. If that ever changes, this snapshot silently
  -- becomes a post-image and every refactored file looks "dirty anyway".
  api.events.subscribe(Event.WillRenameNode, function()
    dirty_before = modified_bufs()
  end)

  require("lsp-file-operations").setup({
    -- The request is synchronous (client.request_sync), so this is how long the
    -- editor can sit frozen on a rename. The plugin's default is 10000, which on
    -- a cold jdtls still building its index is a ten-second hang with no
    -- feedback; too low and the refactor is skipped silently, which is worse
    -- than slow. 5000 is the same number, for the same reason, as conform's
    -- format timeout in lua/plugins/editor.lua.
    timeout_ms = 5000,

    -- auto_save stays off — deliberately, because it is the plugin's own answer
    -- to the problem the NodeRenamed handler below solves, and it solves it in a
    -- way this config cannot accept:
    --
    --   * It replaces vim.lsp.util.apply_workspace_edit globally and for the rest
    --     of the session, so EVERY workspace edit auto-writes to disk — rename
    --     symbol, organize-imports, "move to another file", any multi-file code
    --     action. That is a much larger behavioural change than "renames in the
    --     explorer write what they changed", and none of it is visible from here.
    --   * Its write is `vim.cmd.update` inside a pcall, with no equivalent of the
    --     vim.b.autosave_mtime check in lua/config/autosave.lua. That guard is in
    --     this config precisely because a silent write does NOT suppress the
    --     "changed since reading it" prompt — so a file something else had just
    --     rewritten (git pull, an agent) is either a hidden prompt or a swallowed
    --     failure. Going through config.autosave keeps one write path, one guard
    --     and one warning for both callers.
  })

  -- vim.lsp.util.apply_text_edits loads each referencing file into a buffer and
  -- edits it in memory — it never writes. Those buffers are hidden and never
  -- entered, so the auto_save autocmd (FocusLost/BufLeave) never fires for them
  -- either: without this, the import fixes exist only inside nvim while :Run and
  -- gradle compile the stale files on disk, and the feature looks broken while
  -- technically having worked.
  api.events.subscribe(Event.NodeRenamed, save_touched)
end

return M
