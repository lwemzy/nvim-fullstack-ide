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
        ensure_installed = { "prettierd", "prettier", "vscode-spring-boot-tools" },
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
        -- vim.diagnostic.goto_prev/goto_next are deprecated and slated for
        -- removal in nvim 0.13; vim.diagnostic.jump is the replacement.
        map("[d", function() vim.diagnostic.jump({ count = -1, float = true }) end, "Prev diagnostic")
        map("]d", function() vim.diagnostic.jump({ count = 1,  float = true }) end, "Next diagnostic")
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
          -- Insert mode too, because signature help is most useful *while* you
          -- are typing arguments. nvim 0.11+ ships insert-mode <C-S> as the
          -- default for this, but keymaps.lua binds <C-s> to save in insert mode
          -- (Ctrl+S is the same keycode regardless of case), which silently took
          -- it away. <M-k> rather than insert <C-k>: cmp already owns insert
          -- <C-k> for select_prev_item, and a buffer-local mapping here would
          -- shadow cmp's global one and break menu navigation.
          vim.keymap.set("i", "<M-k>", vim.lsp.buf.signature_help,
            { buffer = bufnr, desc = "Signature help" })
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

      -- ── Apply capabilities to EVERY server via wildcard ─────────────────
      -- NOTE: on_attach must NOT be passed here. vim.lsp.config resolution is
      --   tbl_deep_extend("force", configs["*"], <rtp lsp/*.lua>, configs[name])
      -- (see nvim runtime/lua/vim/lsp.lua), and "force" *overwrites* function
      -- values rather than chaining them. nvim-lspconfig ships its own
      -- on_attach in lsp/ts_ls.lua and lsp/eslint.lua, so the wildcard's
      -- on_attach was being silently discarded for exactly those two servers —
      -- no gr/gi/gD/rename/code-action/signature-help/inlay hints in any
      -- non-Angular TS/JS project. LspAttach is per-client and unconditional,
      -- so it cannot be clobbered, and it also reaches servers started outside
      -- the vim.lsp.enable() path (jdtls, via ftplugin/java.lua).
      vim.lsp.config("*", { capabilities = capabilities })

      -- ── Inlay hints: exactly ONE provider per buffer ────────────────────
      -- Works around a real crash in nvim 0.12's vim/lsp/inlay_hint.lua:
      --
      --   Decoration provider "win" (ns=nvim.lsp.inlayhint):
      --   .../lua/vim/lsp/inlay_hint.lua:362: Invalid 'col': out of range
      --
      -- Hints are stored PER CLIENT (`client_hints[client_id]`) but staleness is
      -- tracked with ONE PER-BUFFER `bufstate.version`, and every response sets
      -- `bufstate.version = ctx.version`. Nothing invalidates hints on a text
      -- change (nvim_buf_attach is registered with on_reload/on_detach only), so
      -- with two providers on one buffer:
      --
      --   client A answers for version V    -> stored, columns describe text(V)
      --   the buffer is edited              -> buf_versions = V+1, guard blocks
      --   client B answers for version V+1  -> stamps bufstate.version = V+1
      --
      -- the guard now passes and A's V-era columns are rendered against text(V+1).
      -- If a line got shorter, nvim_buf_set_extmark raises and every redraw of
      -- that window throws a "Press ENTER" prompt.
      --
      -- B does not even need hints of its own to do this: an EMPTY result takes the
      -- early-return at inlay_hint.lua:68-72, which still stamps
      -- `bufstate.version = ctx.version`. spring-boot and angularls answer .java /
      -- .ts with zero hints on every keystroke, so they are exactly the prolific
      -- stampers that resurrect the other server's stale columns.
      --
      -- Since every response REPLACES that client's whole hint set
      -- (`client_hints[client_id] = new_lnum_hints`, and requests always cover the
      -- whole buffer), one owner per buffer cannot desynchronise from its own
      -- columns — which is why restricting ownership is a sufficient fix.
      --
      -- Two providers per buffer is the normal case here, not an edge case:
      --   Java     spring-boot (static) + jdtls (registered DYNAMICALLY, so its
      --            server_capabilities.inlayHintProvider is false yet
      --            get_clients({method=...}) still returns it)
      --   Angular  angularls + ts_ls
      --
      -- Ranked so the server whose hints are actually worth having wins: jdtls
      -- gives Java parameter-name hints and ts_ls gives TS parameter/type hints,
      -- while spring-boot returns zero hints for .java and angularls adds nothing
      -- ts_ls does not already cover.
      local hint_rank = { jdtls = 3, ts_ls = 3 }
      local hint_owner = {} -- bufnr -> client_id allowed to supply hints

      -- Ownership goes to the first responder but stays REVISABLE by rank,
      -- because the server worth listening to is never the one that answers
      -- first: spring-boot and angularls both attach earlier than jdtls/ts_ls and
      -- both return zero hints, so "first responder keeps it" locked every Java
      -- and Angular buffer to a provider with nothing to say. A takeover needs a
      -- STRICTLY higher rank, so it can happen at most once per buffer and can
      -- never ping-pong.
      local function inlay_hint_owner_ok(bufnr, client_id)
        local owner = hint_owner[bufnr]
        if owner == client_id then return true end

        local mine = vim.lsp.get_client_by_id(client_id)
        if not mine then return false end
        if not owner then
          hint_owner[bufnr] = client_id
          return true
        end

        -- rank 0 for a departed owner, so anyone may take over from it
        local oc = vim.lsp.get_client_by_id(owner)
        local owner_rank = oc and (hint_rank[oc.name] or 1) or 0
        if (hint_rank[mine.name] or 1) <= owner_rank then return false end

        hint_owner[bufnr] = client_id
        -- The old owner's hints must go before the new owner's response can stamp
        -- a fresh version over them — that resurrection is the whole bug. Clear
        -- and re-request; the refreshed response arrives with this client already
        -- installed as owner, so it is accepted then.
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }) then
          vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
          vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
          return false
        end
        return true
      end

      local base_inlay_handler = vim.lsp.handlers["textDocument/inlayHint"]
      vim.lsp.handlers["textDocument/inlayHint"] = function(err, result, ctx, cfg)
        local bufnr = ctx.bufnr
        if bufnr and not inlay_hint_owner_ok(bufnr, ctx.client_id) then
          return
        end
        return base_inlay_handler(err, result, ctx, cfg)
      end

      -- Hints are only ever requested on didOpen / didChange / server refresh, and
      -- inlay hints are NOT part of the vim.lsp._capability framework that
      -- client/registerCapability re-attaches (handlers.lua:153-171 only re-runs
      -- on_attach for registered *capabilities*). jdtls registers
      -- textDocument/inlayHint dynamically — after its didOpen — so a freshly
      -- opened Java buffer was never asked at all, and hints appeared only after
      -- the first keystroke. Ask again the moment the registration lands.
      local base_register = vim.lsp.handlers["client/registerCapability"]
      vim.lsp.handlers["client/registerCapability"] = function(err, params, ctx, cfg)
        local res = base_register(err, params, ctx, cfg)

        local registers_hints = false
        for _, reg in ipairs(params and params.registrations or {}) do
          if reg.method == "textDocument/inlayHint" then registers_hints = true end
        end
        if registers_hints then
          local client = vim.lsp.get_client_by_id(ctx.client_id)
          for bufnr in pairs(client and client.attached_buffers or {}) do
            vim.schedule(function()
              -- enable(true) runs the internal _enable(), which drops the stored
              -- hints for the buffer and re-requests from every current provider —
              -- this client now among them.
              if
                vim.api.nvim_buf_is_loaded(bufnr)
                and vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
              then
                vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
              end
            end)
          end
        end
        return res
      end

      local hint_augroup = vim.api.nvim_create_augroup("user_inlay_hint_owner", { clear = true })

      -- bufnrs are recycled, so ownership must not outlive the buffer.
      vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = hint_augroup,
        callback = function(ev)
          hint_owner[ev.buf] = nil
        end,
      })

      -- Release ownership when the owner goes away (server crash, :LspRestart —
      -- which hands the same server a NEW client_id, so without this the buffer
      -- would never accept hints again). Its already-stored hints have to go with
      -- it: they are precisely the stale entries the next provider's response
      -- would re-validate. enable(false) clears every client's hints for the
      -- buffer and enable(true) re-requests them.
      vim.api.nvim_create_autocmd("LspDetach", {
        group = hint_augroup,
        callback = function(ev)
          if hint_owner[ev.buf] ~= ev.data.client_id then return end
          hint_owner[ev.buf] = nil
          if
            vim.api.nvim_buf_is_loaded(ev.buf)
            and vim.lsp.inlay_hint.is_enabled({ bufnr = ev.buf })
          then
            vim.lsp.inlay_hint.enable(false, { bufnr = ev.buf })
            vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
          end
        end,
      })

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("user_lsp_attach", { clear = true }),
        callback = function(ev)
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          if client then on_attach(client, ev.buf) end
        end,
      })

      -- ── Per-server overrides ────────────────────────────────────────────
      -- NOTE: there used to be a root_dir override here that disabled ts_ls
      -- entirely whenever angular.json was present, on the premise that
      -- "angularls supersedes ts_ls for .ts files". That premise is false, and
      -- the override cost every Angular project ALL of its TypeScript support.
      --
      -- The Angular language server hardcodes `const pluginConfig = {
      -- angularOnly: true }` (mason/packages/angular-language-server/
      -- node_modules/@angular/language-server/index.js — there is no CLI flag to
      -- change it), and the language-service bundle gates on exactly that:
      --   if (angularOnly || !isTypeScriptFile(fileName)) {
      --     return ngLS.getCompletionsAtPosition(...)   // Angular only
      --   } else { return tsLS.getCompletionsAtPosition(...) ?? ... }
      -- So angularls answers template questions only. Measured in an Angular
      -- fixture: `return this.` gave 0 completions from angularls and 2 from
      -- ts_ls, and a deliberate `const bad: number = 'nope'` produced ZERO
      -- diagnostics with angularls alone versus the correct TS2322 with ts_ls
      -- enabled — so the "duplicate diagnostics" this override was meant to
      -- prevent never existed either. Both servers are needed, and they
      -- complement rather than overlap: angularls does templates/DI, ts_ls does
      -- TypeScript.
      --
      -- The nvim-navic "Already attached to ts_ls" log line that motivated the
      -- override is cosmetic and is silenced with vim.g.navic_silence (set in
      -- plugins/ui.lua where barbecue/navic are configured) — a far better
      -- trade than losing TS intelligence.
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
        -- (single_file_support was removed here: it is a key of the deprecated
        -- lspconfig framework, not of vim.lsp.Config, so it was a silent no-op.
        -- Returning early from root_dir above is what actually prevents an
        -- attach outside an Angular project.)
      })

      -- lsp/eslint.lua defines its OWN on_attach, and that is the only thing that
      -- creates the buffer-local "LspEslintFixAll" command. vim.lsp.config merges
      -- with tbl_deep_extend("force", …), which OVERWRITES function values rather
      -- than chaining them — so setting on_attach here silently deleted the
      -- command, and the fix-on-save below then no-op'd forever inside its own
      -- pcall. Call the base handler first, exactly as lsp/eslint.lua documents.
      local eslint_base_on_attach = (vim.lsp.config.eslint or {}).on_attach

      vim.lsp.config("eslint", {
        on_attach = function(client, bufnr)
          if eslint_base_on_attach then
            eslint_base_on_attach(client, bufnr)
          end

          -- The command is "LspEslintFixAll", not "EslintFixAll" (the bare name
          -- only ever existed in the deprecated lspconfig framework). Needs a
          -- per-buffer augroup too: without one, every re-entry to the buffer
          -- stacked another BufWritePre, running eslint --fix N times per save.
          vim.api.nvim_create_autocmd("BufWritePre", {
            group = vim.api.nvim_create_augroup("eslint_fix_" .. bufnr, { clear = true }),
            buffer = bufnr,
            callback = function()
              pcall(vim.cmd, "LspEslintFixAll")
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
            -- schemastore.nvim already supplies ~1320 url -> fileMatch mappings
            -- (docker-compose, GitHub Actions, k8s, …) and they resolve fine
            -- with the built-in catalog disabled.
            --
            -- Two hand-written entries were REMOVED from here:
            --
            -- 1. ["http://json.schemastore.org/spring-boot-application"] mapped
            --    to application*.yml / bootstrap*.yml. That URL is dead — it
            --    301s twice and ends at a 404, and SchemaStore has no Spring
            --    Boot schema at all (zero catalog entries match "spring").
            --    Keeping it was strictly worse than nothing: because the
            --    fileMatch DID match, yamlls committed to that single schema for
            --    the buffer, failed to fetch it, and so had nothing to complete
            --    from — every application.yml got 0 completions plus a permanent
            --    false diagnostic ("Unable to load schema … No content."). Spring
            --    property completion in application.yml is the spring-boot LS's
            --    job (see lua/plugins/java.lua), not yamlls's.
            -- 2. ["https://www.schemastore.org/api/json/catalog.json"] = false.
            --    `false` is not a valid fileMatch (yamlls wants string|string[]),
            --    it matched no file, and it is not a "disable" idiom — the
            --    schemaStore.enable = false above is what disables the catalog.
            schemas = ss_ok and schemastore.yaml.schemas() or {},
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
      -- Emmet: EXTEND lspconfig's default filetype list, never replace it.
      -- The previous hardcoded list did two things wrong:
      --   1. It added plain "javascript"/"typescript". Emmet has no concept of
      --      JS scope, so it answered every completion request in ordinary .js/
      --      .ts files with HTML tag abbreviations — div, dir, dialog, section,
      --      script, select — which then competed with real ts_ls items at the
      --      same nvim_lsp source priority. (JSX/TSX is what you actually want,
      --      and javascriptreact/typescriptreact are already in the defaults.)
      --   2. It silently DROPPED astro, eruby, htmlangular, htmldjango, less,
      --      sass, svelte and vue, so emmet stopped working in all of those.
      vim.lsp.config("emmet_language_server", {
        filetypes = vim.list_extend(
          vim.deepcopy(vim.lsp.config.emmet_language_server.filetypes or {}),
          { "xml" }
        ),
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

      -- The wildcard `handlers` block that used to live here (wrapping
      -- textDocument/hover and textDocument/signatureHelp to add a rounded
      -- border) was dead code on two counts:
      --   1. vim.lsp.buf.hover/signature_help in 0.12 issue buf_request_all with
      --      inline callbacks and never consult client.handlers, so the wrappers
      --      were never invoked.
      --   2. vim.lsp.handlers.hover/.signature_help are themselves deprecated
      --      and slated for removal in 0.13.
      -- `vim.o.winborder = "rounded"` in lua/config/options.lua achieves the
      -- intended effect through the path 0.12 actually takes.
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
        -- ── Responsiveness ──────────────────────────────────────────────────
        -- Tuned down from cmp's defaults (debounce 60 / throttle 30 /
        -- fetching_timeout 500 / max_view_entries 200). max_view_entries is the
        -- big one: ts_ls alone returns ~1000 items for a bare cursor and cssls
        -- ~890 (measured), and cmp sorts + renders the whole set through 10
        -- comparators on every keystroke. Capping the *view* keeps matching
        -- intact while cutting the per-keystroke sort/render work by ~8x.
        performance = {
          debounce = 20,
          throttle = 10,
          fetching_timeout = 200,
          max_view_entries = 25,
        },
        snippet = {
          expand = function(args) luasnip.lsp_expand(args.body) end,
        },
        window = {
          -- bordered() with no argument resolves its border from vim.o.winborder
          -- and yields "none" when that is unset, so these popups were drawing
          -- borderless. winborder is now set in lua/config/options.lua; passing
          -- the border explicitly keeps it correct regardless.
          completion = cmp.config.window.bordered({ border = "rounded" }),
          documentation = cmp.config.window.bordered({ border = "rounded" }),
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-k>"]     = cmp.mapping.select_prev_item(),
          ["<C-j>"]     = cmp.mapping.select_next_item(),
          ["<C-b>"]     = cmp.mapping.scroll_docs(-4),
          ["<C-f>"]     = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"]     = cmp.mapping.abort(),
          -- Confirm ONLY an entry the user actually selected. cmp's confirm()
          -- does `if not e and option.select then e = get_first_entry()`
          -- (cmp/init.lua), and cmp runs with 'noselect', so nothing is ever
          -- preselected — `confirm({ select = true })` therefore accepted the
          -- top suggestion on <CR> and made it impossible to insert a newline
          -- while the menu was open. <Tab>/<C-j>/<C-n> select; <CR> commits.
          ["<CR>"] = cmp.mapping(function(fallback)
            if cmp.visible() and cmp.get_selected_entry() then
              cmp.confirm({ select = false })
            else
              fallback()
            end
          end, { "i", "s" }),
          -- expand_or_jumpable()/jumpable(-1) are NOT position-aware: they only
          -- ask whether a jump destination differs from the current node, with
          -- no in_snippet() check (luasnip/init.lua). Since region_check_events
          -- and delete_check_events are both unset, leaving a snippet early
          -- (Esc, arrows, editing elsewhere) never clears it — so Tab/S-Tab
          -- teleported the cursor back into a stale snippet from anywhere in the
          -- buffer instead of indenting. The locally_* variants add in_snippet().
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_next_item()
            elseif luasnip.expand_or_locally_jumpable() then luasnip.expand_or_jump()
            else fallback() end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_prev_item()
            elseif luasnip.locally_jumpable(-1) then luasnip.jump(-1)
            else fallback() end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp", priority = 1000 },
          -- lazydev registers itself as a cmp source (its own cmp integration
          -- calls cmp.register_source), but cmp only ever queries sources named
          -- in this list — so its whole purpose (completing vim.uv, plugin
          -- module names before the require path is typed) never reached the
          -- menu. Cheap: it only produces items in Lua buffers.
          { name = "lazydev",  priority = 900 },
          { name = "luasnip",  priority = 750 },
          -- keyword_length 3 stops single/double-char buffer words from
          -- crowding the menu on the first keystroke of every identifier.
          { name = "buffer",   priority = 500, keyword_length = 3 },
          { name = "path",     priority = 250 },
        }),
        formatting = {
          format = lspkind.cmp_format({
            -- `mode` and `show_labelDetails` were dropped: lspkind's cmp_format
            -- reads neither (mode is only honoured via lspkind.init(), which
            -- this config never calls, and show_labelDetails is read only inside
            -- an `if opts.menu` branch). nvim-cmp itself renders the icon from
            -- lspkind.symbol_map and populates the menu from labelDetails, so
            -- behaviour is unchanged — this just removes options that never did
            -- anything. `preset` IS honoured and stays.
            preset = "codicons",
            -- Was a bare `50`, which lspkind expands to { abbr = 50, menu = 50 }
            -- and applies to BOTH columns — so long TS/Java signatures in the
            -- detail column got chopped mid-type and read as a render glitch.
            maxwidth = { abbr = 50, menu = 80 },
            ellipsis_char = "…",
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
        -- cmp defaults disallow_symbol_nonprefix_matching = true, which blocks
        -- matching on any candidate whose first char is a symbol — cmp-cmdline
        -- documents turning it off as a requirement for completing things like
        -- `:e ~/…` or `:!cmd`.
        matching = { disallow_symbol_nonprefix_matching = false },
      })
    end,
  },
}
