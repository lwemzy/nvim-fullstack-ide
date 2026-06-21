return {
  -- Neovim Lua dev support
  {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {
      library = {
        { path = "luvit-meta/library", words = { "vim%.uv" } },
      },
    },
  },

  -- LSP installer UI
  {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup({
        ui = {
          border = "rounded",
          icons = { package_installed = "✓", package_pending = "➜", package_uninstalled = "✗" },
        },
      })
    end,
  },

  -- Ensures LSP servers are installed; automatic_enable hands off to vim.lsp.enable
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim" },
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = {
          "ts_ls", "jdtls", "lua_ls",
          "jsonls", "yamlls", "html", "cssls", "eslint",
          "emmet_language_server",
        },
        automatic_installation = true,
        -- jdtls is started manually in ftplugin/java.lua with Lombok javaagent.
        -- Exclude it here so mason-lspconfig doesn't launch a second bare instance.
        automatic_enable = { exclude = { "jdtls" } },
      })
    end,
  },

  -- Formatters
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    dependencies = { "williamboman/mason.nvim" },
    config = function()
      require("mason-tool-installer").setup({
        ensure_installed = { "prettierd" },
        run_on_start = true,
      })
    end,
  },

  -- Schema store for JSON / YAML validation
  { "b0o/schemastore.nvim" },

  -- nvim-lspconfig: kept only for its runtime/lsp/ server definitions.
  -- We do NOT call require('lspconfig').X.setup() — that API is deprecated in
  -- nvim 0.11. We use vim.lsp.config / vim.lsp.enable instead.
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
      "b0o/schemastore.nvim",
      "folke/lazydev.nvim",
    },
    config = function()
      -- ── Capabilities (advertise nvim-cmp completion to LSP servers) ────
      local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
      local capabilities = vim.tbl_deep_extend(
        "force",
        vim.lsp.protocol.make_client_capabilities(),
        cmp_ok and cmp_lsp.default_capabilities() or {}
      )

      -- ── Shared on_attach keymaps ────────────────────────────────────────
      local function on_attach(client, bufnr)
        local map = function(keys, func, desc)
          vim.keymap.set("n", keys, func, { buffer = bufnr, desc = desc })
        end
        local caps = client.server_capabilities

        map("gd",         "<cmd>Telescope lsp_definitions<CR>",    "Go to definition")
        map("K",          vim.lsp.buf.hover,                       "Hover docs")
        map("[d",         vim.diagnostic.goto_prev,                "Prev diagnostic")
        map("]d",         vim.diagnostic.goto_next,                "Next diagnostic")
        map("<leader>d",  vim.diagnostic.open_float,               "Show diagnostic")

        if caps.declarationProvider then
          map("gD", vim.lsp.buf.declaration, "Go to declaration")
        end
        if caps.referencesProvider then
          map("gr", "<cmd>Telescope lsp_references<CR>", "Find references")
        end
        if caps.implementationProvider then
          map("gi", "<cmd>Telescope lsp_implementations<CR>", "Find implementations")
        end
        if caps.typeDefinitionProvider then
          map("<leader>lt", "<cmd>Telescope lsp_type_definitions<CR>", "Type definition")
        end
        if caps.signatureHelpProvider then
          map("<C-k>", vim.lsp.buf.signature_help, "Signature help")
        end
        if caps.renameProvider then
          map("<leader>rn", vim.lsp.buf.rename, "Rename symbol")
        end
        if caps.codeActionProvider then
          map("<leader>ca", vim.lsp.buf.code_action, "Code action")
        end
      end

      -- ── Apply capabilities + on_attach to EVERY server via wildcard ─────
      vim.lsp.config("*", { capabilities = capabilities, on_attach = on_attach })

      -- ── Per-server overrides ────────────────────────────────────────────
      vim.lsp.config("ts_ls", {
        settings = {
          typescript = {
            inlayHints = {
              includeInlayParameterNameHints = "all",
              includeInlayFunctionParameterTypeHints = true,
              includeInlayVariableTypeHints = true,
              includeInlayPropertyDeclarationTypeHints = true,
              includeInlayFunctionLikeReturnTypeHints = true,
              includeInlayEnumMemberValueHints = true,
            },
          },
          javascript = {
            inlayHints = {
              includeInlayParameterNameHints = "all",
              includeInlayFunctionLikeReturnTypeHints = true,
            },
          },
        },
      })

      vim.lsp.config("eslint", {
        on_attach = function(client, bufnr)
          on_attach(client, bufnr)
          vim.api.nvim_create_autocmd("BufWritePre", {
            buffer = bufnr,
            callback = function()
              pcall(vim.cmd, "EslintFixAll")
            end,
          })
        end,
      })

      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
            diagnostics = { globals = { "vim" } },
          },
        },
      })

      local ss_ok, schemastore = pcall(require, "schemastore")
      vim.lsp.config("jsonls", {
        settings = {
          json = {
            schemas = ss_ok and schemastore.json.schemas() or {},
            validate = { enable = true },
          },
        },
      })

      vim.lsp.config("yamlls", {
        settings = {
          yaml = {
            schemaStore = { enable = false, url = "" },
            schemas = vim.tbl_extend("force",
              ss_ok and schemastore.yaml.schemas() or {},
              {
                -- Spring Boot application.yml / application-{profile}.yml
                ["https://www.schemastore.org/api/json/catalog.json"] = false,
                ["http://json.schemastore.org/spring-boot-application"] = {
                  "application.yml",
                  "application.yaml",
                  "application-*.yml",
                  "application-*.yaml",
                  "bootstrap.yml",
                  "bootstrap-*.yml",
                },
              }
            ),
            validate = true,
            completion = true,
            hover = true,
          },
        },
      })

      -- Disable inline CSS validation in HTML files — the CSS language service
      -- inside html-lsp crashes on null config when validating inline styles
      vim.lsp.config("html", {
        settings = {
          html = {
            validate = { scripts = true, styles = false },
          },
        },
      })

      -- ── Enable servers (jdtls is handled separately by ftplugin/java.lua) ─
      -- Emmet language server config
      vim.lsp.config("emmet_language_server", {
        filetypes = {
          "html", "css", "scss", "javascript", "typescript",
          "javascriptreact", "typescriptreact", "xml",
        },
      })

      vim.lsp.enable({ "ts_ls", "lua_ls", "jsonls", "yamlls", "html", "cssls", "eslint", "emmet_language_server" })

      -- ── LSP logging (warn + above written to ~/.local/state/nvim/lsp.log) ─
      vim.lsp.log.set_level(vim.log.levels.WARN)

      -- ── Diagnostic display ──────────────────────────────────────────────
      vim.diagnostic.config({
        virtual_text = { prefix = "●" },
        signs = true,
        underline = true,
        update_in_insert = false,
        severity_sort = true,
        float = { border = "rounded", source = "always" },
      })

      vim.lsp.config("*", {
        handlers = {
          ["textDocument/hover"] = function(err, result, ctx, config)
            vim.lsp.handlers.hover(err, result, ctx, vim.tbl_extend("force", config or {}, { border = "rounded" }))
          end,
          ["textDocument/signatureHelp"] = function(err, result, ctx, config)
            vim.lsp.handlers.signature_help(err, result, ctx, vim.tbl_extend("force", config or {}, { border = "rounded" }))
          end,
        },
      })
    end,
  },

  -- ── Completion engine ───────────────────────────────────────────────────
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "hrsh7th/cmp-cmdline",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
      "rafamadriz/friendly-snippets",
      "onsails/lspkind.nvim",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      local lspkind = require("lspkind")
      require("luasnip.loaders.from_vscode").lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args) luasnip.lsp_expand(args.body) end,
        },
        window = {
          completion = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-k>"]     = cmp.mapping.select_prev_item(),
          ["<C-j>"]     = cmp.mapping.select_next_item(),
          ["<C-b>"]     = cmp.mapping.scroll_docs(-4),
          ["<C-f>"]     = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"]     = cmp.mapping.abort(),
          ["<CR>"]      = cmp.mapping.confirm({ select = true }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then luasnip.expand_or_jump()
            else fallback() end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then luasnip.jump(-1)
            else fallback() end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp", priority = 1000 },
          { name = "luasnip",  priority = 750 },
          { name = "buffer",   priority = 500 },
          { name = "path",     priority = 250 },
        }),
        formatting = {
          format = lspkind.cmp_format({
            mode = "symbol_text",
            preset = "codicons",
            maxwidth = 50,
            ellipsis_char = "…",
            show_labelDetails = true,
          }),
        },
      })

      cmp.setup.cmdline({ "/", "?" }, {
        mapping = cmp.mapping.preset.cmdline(),
        sources = { { name = "buffer" } },
      })
      cmp.setup.cmdline(":", {
        mapping = cmp.mapping.preset.cmdline(),
        sources = cmp.config.sources({ { name = "path" } }, { { name = "cmdline" } }),
      })
    end,
  },
}
