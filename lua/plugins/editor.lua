return {
  -- Fast jump-to-any-location motions
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      { "s", mode = { "n", "x", "o" }, function() require("flash").jump() end,        desc = "Flash jump" },
      { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end,  desc = "Flash treesitter" },
      { "r", mode = "o",               function() require("flash").remote() end,      desc = "Remote flash" },
      { "R", mode = { "o", "x" },      function() require("flash").treesitter_search() end, desc = "Treesitter search" },
    },
  },

  -- Highlight other references to the symbol under the cursor
  {
    "RRethy/vim-illuminate",
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require("illuminate").configure({
        providers = { "lsp", "treesitter", "regex" },
        delay = 200,
        filetypes_denylist = { "NvimTree", "toggleterm", "TelescopePrompt" },
      })
      vim.keymap.set("n", "]]", function() require("illuminate").goto_next_reference() end, { desc = "Next reference" })
      vim.keymap.set("n", "[[", function() require("illuminate").goto_prev_reference() end, { desc = "Prev reference" })
    end,
  },

  -- Gutter sign that lights up when a code action is available at the
  -- cursor — tells you when Ctrl+./F4 is worth pressing instead of guessing.
  {
    "kosayoda/nvim-lightbulb",
    event = "LspAttach",
    opts = {
      autocmd = { enabled = true },
      sign = { enabled = true, text = "💡" },
    },
  },

  -- Auto bracket/quote pairs
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      local autopairs = require("nvim-autopairs")
      autopairs.setup({ check_ts = true })
      -- Integrate with nvim-cmp
      local cmp_autopairs = require("nvim-autopairs.completion.cmp")
      local ok, cmp = pcall(require, "cmp")
      if ok then
        cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
      end
    end,
  },

  -- Commenting
  {
    "numToStr/Comment.nvim",
    config = true,
  },

  -- Surround text objects
  {
    "kylechui/nvim-surround",
    event = "VeryLazy",
    config = true,
  },

  -- Git signs in gutter
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup({
        signs = {
          add = { text = "▎" },
          change = { text = "▎" },
          delete = { text = "" },
          topdelete = { text = "" },
          changedelete = { text = "▎" },
          untracked = { text = "▎" },
        },
        -- Inline blame as virtual text once the cursor sits still on a line
        -- for a bit — leader+gb (blame_line below) stays as the on-demand
        -- popup with the full commit body, this is just the passive at-a-
        -- glance version.
        current_line_blame = true,
        current_line_blame_opts = {
          delay = 500,
        },
        current_line_blame_formatter = "   <author>, <author_time:%R>",
        on_attach = function(bufnr)
          local gs = package.loaded.gitsigns
          local map = function(mode, l, r, desc)
            vim.keymap.set(mode, l, r, { buffer = bufnr, desc = desc })
          end
          map("n", "]g", gs.next_hunk, "Next hunk")
          map("n", "[g", gs.prev_hunk, "Prev hunk")
          map("n", "<leader>gb", gs.blame_line, "Blame line")
          map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
          map("n", "<leader>gs", gs.stage_hunk, "Stage hunk")
          map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
          map("n", "<leader>gS", gs.stage_buffer, "Stage buffer")
          map("n", "<leader>gR", gs.reset_buffer, "Reset buffer")
          map("n", "<leader>gd", gs.diffthis, "Diff this")
        end,
      })
    end,
  },

  -- Full side-by-side diff view + file history (beyond gitsigns' hunk preview)
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<CR>",         desc = "Git: Diff view" },
      { "<leader>gh", "<cmd>DiffviewFileHistory<CR>",  desc = "Git: File history" },
    },
  },

  -- Formatter
  {
    "stevearc/conform.nvim",
    config = function()
      -- Projects with no prettier config of their own (no .prettierrc*, no
      -- prettier.config.*, no "prettier" key in package.json) get a project's
      -- explicit choice respected exactly (plain prettierd/prettier, no
      -- overrides) whenever one exists. Only affects JS/TS, where a project's
      -- own opinion can fight ESLint's style rules; CSS/JSON/YAML/MD keep
      -- unconditional Prettier since nothing there governs their style.
      --
      -- Absent a project opinion, fall back to Google's JS/TS style guide
      -- (google.github.io/styleguide/{js,ts}guide.html) as this IDE's own
      -- default rather than Prettier's stock config. In practice this is a
      -- single real difference: Prettier defaults to double quotes; both
      -- guides explicitly mandate single quotes. Everything else Prettier
      -- already does by default — 2-space indent, 80-col wrap, semicolons,
      -- trailing commas, K&R braces — either matches what's written or the
      -- guide is silent (the TS guide explicitly doesn't specify indent
      -- width or a trailing-comma policy). Naming/language-feature rules
      -- (no var, interfaces over type aliases, etc.) are ESLint's domain,
      -- not Prettier's — those need Google's own eslint-config-google/gts
      -- installed per-project; there's no editor-global equivalent the way
      -- jdtls's formatter profile works for Java.
      local prettier_config_files = {
        ".prettierrc", ".prettierrc.json", ".prettierrc.yml", ".prettierrc.yaml",
        ".prettierrc.json5", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs",
        "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs",
      }
      local function has_prettier_config(bufnr)
        local dirname = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
        if vim.fs.find(prettier_config_files, { path = dirname, upward = true })[1] then
          return true
        end
        local pkg = vim.fs.find("package.json", { path = dirname, upward = true })[1]
        if not pkg then return false end
        local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(pkg), "\n"))
        return ok and decoded.prettier ~= nil
      end
      local function prettier_or_none(bufnr)
        if has_prettier_config(bufnr) then
          return { "prettierd", "prettier", stop_after_first = true }
        end
        return { "prettier_google", stop_after_first = true }
      end

      require("conform").setup({
        formatters_by_ft = {
          javascript      = prettier_or_none,
          javascriptreact = prettier_or_none,
          typescript      = prettier_or_none,
          typescriptreact = prettier_or_none,
          -- palantir-java-format, not jdtls/Eclipse: Eclipse's JDT formatter
          -- (previously the sole Java formatter, via lsp_fallback below)
          -- uses its own ad-hoc alignment/wrapping algorithm for chained
          -- method calls — not a real pretty-printer — and produces an
          -- ever-deepening "staircase" on fluent/builder-style chains
          -- (assertions, Mockito, builders) that no XML profile setting
          -- fixes. palantir-java-format is a google-java-format fork built
          -- specifically to fix method-chain/lambda/stream formatting.
          -- Fixed 120-col width (neither it nor google-java-format allows a
          -- custom width — deliberate in both tools), so this is no longer
          -- 100-col "Google Style Guide" output — see autocmds.lua's
          -- colorcolumn for the matching guide.
          java            = { "palantir-java-format" },
          json            = { "prettierd", "prettier", stop_after_first = true },
          jsonc           = { "prettierd", "prettier", stop_after_first = true },
          css             = { "prettierd", "prettier", stop_after_first = true },
          scss            = { "prettierd", "prettier", stop_after_first = true },
          less            = { "prettierd", "prettier", stop_after_first = true },
          html            = { "prettierd", "prettier", stop_after_first = true },
          yaml            = { "prettierd", "prettier", stop_after_first = true },
          markdown        = { "prettierd", "prettier", stop_after_first = true },
        },
        -- format_after_save (async) is the *safe* auto-format path: confirmed
        -- in conform's own source (lua/conform/lsp_format.lua) that it checks
        -- the buffer's changedtick before applying an LSP-formatter's result
        -- and discards it on any mismatch, for every filetype (its autocmd is
        -- unscoped — pattern = "*", not filtered by formatters_by_ft) — so
        -- this also covers Java via lsp_fallback below, going through jdtls
        -- the safe way. This replaces jdtls's own BufWritePre formatting
        -- (ftplugin/java.lua), which called Neovim's synchronous
        -- vim.lsp.buf.format() directly — confirmed in Neovim's own runtime
        -- (lua/vim/lsp/buf.lua) to apply results with NO staleness check —
        -- and was observed dropping real content on save.
        format_after_save = function(bufnr)
          return {
            timeout_ms   = 5000,
            lsp_fallback = true,
          }
        end,
        formatters = {
          prettierd = {
            env = {
              -- Ensure mason's prettierd is found even if not in system PATH
              PATH = vim.fn.stdpath("data") .. "/mason/bin:" .. vim.env.PATH,
            },
          },
          ["palantir-java-format"] = {
            env = {
              -- Ensure mason's palantir-java-format is found even if not in system PATH
              PATH = vim.fn.stdpath("data") .. "/mason/bin:" .. vim.env.PATH,
            },
          },
          -- Plain prettier (not prettierd — the daemon doesn't accept ad-hoc
          -- CLI overrides) with Google's one confirmed formatting difference
          -- from Prettier's stock defaults applied explicitly. prepend_args
          -- only works when overriding an *existing* built-in formatter by
          -- name (conform.util.merge_formatter_configs) — since this is a
          -- new name, not a built-in override, args must be wrapped directly.
          prettier_google = (function()
            local base = require("conform.formatters.prettier")
            return vim.tbl_deep_extend("force", base, {
              args = function(self, ctx)
                local args = base.args(self, ctx)
                table.insert(args, "--single-quote")
                return args
              end,
              env = {
                PATH = vim.fn.stdpath("data") .. "/mason/bin:" .. vim.env.PATH,
              },
            })
          end)(),
        },
      })
    end,
  },

  -- Better diagnostics list
  {
    "folke/trouble.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = true,
  },

  -- Highlight TODO/FIXME/NOTE comments
  {
    "folke/todo-comments.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = true,
    keys = {
      { "<leader>ft", "<cmd>TodoTelescope<CR>", desc = "Find TODOs" },
    },
  },

  -- Smooth scrolling
  {
    "karb94/neoscroll.nvim",
    config = function()
      require("neoscroll").setup({ mappings = { "<C-u>", "<C-d>" } })
    end,
  },
}
