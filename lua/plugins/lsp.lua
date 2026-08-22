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
          "emmet_language_server", "angularls",
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
        -- plain prettier (not just prettierd): the daemon doesn't accept
        -- ad-hoc CLI overrides, needed for the Google-style fallback in
        -- plugins/editor.lua's conform.nvim config.
        ensure_installed = { "prettierd", "prettier", "vscode-spring-boot-tools", "stylelint" },
        run_on_start = true,
      })
    end,
  },

  -- Schema store for JSON / YAML validation
  { "b0o/schemastore.nvim" },

  -- Standalone linter runner — fills the one real gap left by the LSPs
  -- above: eslint covers JS/TS style rules, but cssls only validates CSS
  -- syntax, not style. stylelint (via Mason, see ensure_installed above)
  -- covers CSS/SCSS/LESS the same way eslint covers JS/TS.
  {
    "mfussenegger/nvim-lint",
    event = { "BufWritePost", "BufReadPost", "InsertLeave" },
    config = function()
      require("lint").linters_by_ft = {
        css  = { "stylelint" },
        scss = { "stylelint" },
        less = { "stylelint" },
      }

      -- Without a project stylelint config, stylelint itself throws
      -- ConfigurationError ("No configuration provided") instead of just
      -- no-opping — unlike eslint's LSP, which silently attaches nothing.
      -- Left unguarded that shows up as a permanent fake "lint error" on
      -- every CSS/SCSS/LESS buffer in projects that never opted into
      -- stylelint. Mirrors has_prettier_config's project-opt-in check
      -- in plugins/editor.lua: only lint where a project asked for it.
      local stylelint_config_files = {
        ".stylelintrc", ".stylelintrc.json", ".stylelintrc.yaml", ".stylelintrc.yml",
        ".stylelintrc.js", ".stylelintrc.cjs", ".stylelintrc.mjs",
        "stylelint.config.js", "stylelint.config.cjs", "stylelint.config.mjs",
      }
      local function has_stylelint_config(bufnr)
        local dirname = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
        if vim.fs.find(stylelint_config_files, { path = dirname, upward = true })[1] then
          return true
        end
        local pkg = vim.fs.find("package.json", { path = dirname, upward = true })[1]
        if not pkg then return false end
        local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(pkg), "\n"))
        return ok and decoded.stylelint ~= nil
      end

      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
        group = vim.api.nvim_create_augroup("nvim_lint", { clear = true }),
        callback = function(ev)
          if has_stylelint_config(ev.buf) then
            require("lint").try_lint()
          end
        end,
      })
    end,
  },

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
        if caps.documentSymbolProvider then
          map("<leader>ls", "<cmd>Telescope lsp_document_symbols<CR>", "Document symbols")
        end
        if caps.workspaceSymbolProvider then
          map("<leader>lw", "<cmd>Telescope lsp_dynamic_workspace_symbols<CR>", "Workspace symbols")
        end
        if caps.inlayHintProvider then
          vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
          map("<leader>uh", function()
            vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }), { bufnr = bufnr })
          end, "Toggle inlay hints")
        end
        if caps.callHierarchyProvider then
          -- Call hierarchy (who calls this / what does this call), quickfix-based
          -- since Telescope has no built-in call-hierarchy picker to route through.
          map("<leader>lc", vim.lsp.buf.incoming_calls, "Incoming calls (callers)")
          map("<leader>lC", vim.lsp.buf.outgoing_calls, "Outgoing calls (callees)")
        end
      end

      -- ── Apply capabilities + on_attach to EVERY server via wildcard ─────
      vim.lsp.config("*", { capabilities = capabilities, on_attach = on_attach })

      -- ── Per-server overrides ────────────────────────────────────────────
      -- In Angular projects, angularls supersedes ts_ls for .ts files (it
      -- provides equivalent TS intelligence plus template/DI awareness).
      -- Running both attached to the same buffer causes duplicate diagnostics
      -- and breaks single-client consumers like nvim-navic ("Failed to attach
      -- to angularls for current buffer. Already attached to ts_ls"). Skip
      -- ts_ls entirely when angular.json is present so angularls is the sole
      -- TS server there.
      local ts_ls_default_root_dir = vim.lsp.config.ts_ls.root_dir
      vim.lsp.config("ts_ls", {
        root_dir = function(bufnr, on_dir)
          if vim.fs.root(bufnr, { "angular.json" }) then
            return
          end
          ts_ls_default_root_dir(bufnr, on_dir)
        end,
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

      -- angularls's own root_markers (angular.json/nx.json, from lspconfig's
      -- runtime/lsp/angularls.lua) only govern the *cmd* it builds — nothing
      -- stops it attaching outside an Angular project, since the framework
      -- falls back to cwd as a "single file" root when no marker is found.
      -- That meant angularls attached to *every* TypeScript file, Angular or
      -- not, duplicating ts_ls's diagnostics/navic attach exactly the same
      -- way the ts_ls override above exists to prevent — just backwards.
      -- Mirror that override: only start angularls when angular.json/nx.json
      -- actually exists upward from the buffer.
      vim.lsp.config("angularls", {
        root_dir = function(bufnr, on_dir)
          local root = vim.fs.root(bufnr, { "angular.json", "nx.json" })
          if root then on_dir(root) end
        end,
        single_file_support = false,
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

      vim.lsp.enable({ "ts_ls", "lua_ls", "jsonls", "yamlls", "html", "cssls", "eslint", "emmet_language_server", "angularls" })

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

      -- SQL buffers (opened via vim-dadbod-ui below): bean/table/column
      -- completion from the active DB connection, ahead of plain buffer words.
      cmp.setup.filetype({ "sql", "mysql", "plsql" }, {
        sources = cmp.config.sources({
          { name = "vim-dadbod-completion", priority = 1000 },
          { name = "buffer", priority = 500 },
        }),
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
