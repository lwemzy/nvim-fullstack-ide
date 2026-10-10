-- harper_ls's settings table in lua/plugins/lsp.lua.
--
-- Without an explicit (even empty) `settings` table, Neovim's client still
-- fires workspace/didChangeConfiguration on attach, and harper_ls's Rust
-- backend rejected whatever non-object payload that notification carried
-- with "Settings must be an object" — spammed to lsp.log on every config
-- push, one per buffer, harmless but constant noise. The fix was a one-line
-- `settings = { ["harper-ls"] = {} }`; this is the regression guard for it.

local H = require("helpers")

describe("harper_ls config", function()
  before_each(function()
    -- harper_ls's own cmd/filetypes/root_markers come from nvim-lspconfig's
    -- runtime/lsp/harper_ls.lua; vim.lsp.config.harper_ls only merges this
    -- config's override on top of it once that is on the runtimepath.
    H.load_plugin("nvim-lspconfig")
  end)

  it("sends a settings object, never nil", function()
    local settings = vim.lsp.config.harper_ls.settings
    assert.is_table(settings, "harper_ls.settings must not be nil — the client sends it verbatim on attach")
    assert.is_table(settings["harper-ls"])
  end)

  it("still extends the default filetypes rather than replacing them", function()
    -- The override adds javascriptreact; losing typescript/java/markdown/etc
    -- (nvim-lspconfig's own defaults) would mean harper_ls silently stops
    -- spell/grammar-checking every language it used to cover.
    local filetypes = vim.lsp.config.harper_ls.filetypes
    for _, ft in ipairs({ "java", "javascript", "typescript", "markdown", "lua" }) do
      assert.is_true(vim.tbl_contains(filetypes, ft), ft .. " missing from harper_ls filetypes")
    end
    assert.is_true(vim.tbl_contains(filetypes, "javascriptreact"), "javascriptreact was not added")
  end)
end)
