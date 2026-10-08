-- lua/config/capabilities.lua — the client capabilities every server is started
-- with.
--
-- Unit tier, so neither cmp-nvim-lsp nor nvim-lsp-file-operations is on the
-- runtimepath: both contributions are stood in for through package.loaded. That
-- is the right seam for this module, whose job is composition and not the
-- contents of either table — what the real plugins return, and that jdtls
-- actually negotiates willRename from it, is asserted in
-- tests/integration/file_ops_spec.lua against a real client.

local H = require("helpers")

local MODULES = { "cmp_nvim_lsp", "lsp-file-operations" }

--- Make `module` require-able with a default_capabilities() returning `caps`.
local function provide(module, caps)
  package.loaded[module] = {
    default_capabilities = function() return vim.deepcopy(caps) end,
  }
end

local function make()
  package.loaded["config.capabilities"] = nil
  return require("config.capabilities").make()
end

describe("config.capabilities", function()
  before_each(function()
    provide("cmp_nvim_lsp", {
      textDocument = { completion = { completionItem = { snippetSupport = true } } },
    })
    provide("lsp-file-operations", {
      workspace = { fileOperations = { willRename = true, didRename = true } },
    })
  end)

  after_each(function()
    for _, module in ipairs(MODULES) do
      package.loaded[module] = nil
    end
    package.loaded["config.capabilities"] = nil
    H.cleanup()
  end)

  it("advertises file operations", function()
    -- The point of the whole feature: jdtls gates its willRename
    -- implementation on the client having asked for it
    -- (InitHandler.isWorkspaceWillRenameFilesSupported), so this table is the
    -- difference between a package move that fixes imports and one that breaks
    -- the build silently.
    local caps = make()
    assert.is_true(caps.workspace.fileOperations.willRename)
    assert.is_true(caps.workspace.fileOperations.didRename)
  end)

  it("keeps the completion capabilities cmp contributes", function()
    -- Merged, not replaced. These were here first and auto-import depends on
    -- them; a file-operations change that quietly dropped snippetSupport would
    -- show up as "completion got worse" with no connection to this file.
    local caps = make()
    assert.is_true(caps.textDocument.completion.completionItem.snippetSupport)
  end)

  it("keeps Neovim's own protocol defaults", function()
    -- The base is make_client_capabilities(), not an empty table: everything
    -- not mentioned by either plugin (hover, semantic tokens, workspace edit
    -- support) has to survive.
    local caps = make()
    assert.is_truthy(caps.textDocument.hover)
    assert.is_truthy(caps.workspace.workspaceEdit)
  end)

  it("returns independent tables across calls", function()
    -- Two clients are started from two call sites and both keep a reference;
    -- vim.lsp then merges server-specific config over what it was given. A
    -- shared table would let jdtls's resolution show up in ts_ls's
    -- capabilities, which is the kind of bug that only appears with both
    -- servers attached.
    local first, second = make(), make()
    assert.are_not.equal(first, second)
    assert.are_not.equal(first.workspace.fileOperations, second.workspace.fileOperations)
    first.workspace.fileOperations.willRename = false
    assert.is_true(second.workspace.fileOperations.willRename)
  end)

  for _, missing in ipairs(MODULES) do
    it("still returns usable capabilities without " .. missing, function()
      -- Both contributions are pcall-guarded because this runs at client-start
      -- time, before lazy has necessarily loaded either. Erroring here would
      -- take down the server start, i.e. trade "no auto-import on renames" for
      -- "no language server at all".
      package.loaded[missing] = nil
      package.preload[missing] = function() error(missing .. " not installed") end
      local ok, caps = pcall(make)
      package.preload[missing] = nil
      assert.is_true(ok, "make() should survive a missing " .. missing)
      assert.is_truthy(caps.textDocument.hover)
    end)
  end
end)
