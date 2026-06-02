return {
  -- ── Project-wide Find & Replace ─────────────────────────────────────────
  {
    "MagicDuck/grug-far.nvim",
    config = function()
      require("grug-far").setup({
        resultsSeparatorLineChar = "─",
        spinnerStates = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
      })
    end,
    keys = {
      { "<M-f>", function() require("grug-far").open() end,                                             desc = "Find & Replace (project)" },
      { "<M-f>", function() require("grug-far").open({ prefills = { search = vim.fn.expand("<cword>") } }) end, mode = "v", desc = "Find & Replace (word)" },
    },
  },

  -- ── Harpoon: pin & jump to frequent files ────────────────────────────────
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local harpoon = require("harpoon")
      harpoon:setup({
        settings = {
          save_on_toggle = true,
          sync_on_ui_close = true,
        },
      })

      vim.keymap.set("n", "<M-a>",  function() harpoon:list():add() end,          { desc = "Harpoon: Add file" })
      vim.keymap.set("n", "<M-h>",  function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = "Harpoon: Menu" })
      vim.keymap.set("n", "<M-F1>", function() harpoon:list():select(1) end,     { desc = "Harpoon: File 1" })
      vim.keymap.set("n", "<M-F2>", function() harpoon:list():select(2) end,     { desc = "Harpoon: File 2" })
      vim.keymap.set("n", "<M-F3>", function() harpoon:list():select(3) end,     { desc = "Harpoon: File 3" })
      vim.keymap.set("n", "<M-F4>", function() harpoon:list():select(4) end,     { desc = "Harpoon: File 4" })
    end,
  },

  -- ── HTTP Client (REST API testing from .http files) ──────────────────────
  {
    "mistweaverco/kulala.nvim",
    ft = { "http", "rest" },
    config = function()
      require("kulala").setup({
        default_view       = "body",
        view_headers       = false,
        show_icons         = "on_request",
        contenttypes = {
          ["application/json"] = { ft = "json", formatter = { "jq", "." } },
        },
      })
    end,
    keys = {
      { "<M-Return>", function() require("kulala").run() end,          ft = "http", desc = "HTTP: Run request" },
      { "<M-p>",      function() require("kulala").jump_prev() end,    ft = "http", desc = "HTTP: Prev request" },
      { "<M-n>",      function() require("kulala").jump_next() end,    ft = "http", desc = "HTTP: Next request" },
      { "<M-c>",      function() require("kulala").copy() end,         ft = "http", desc = "HTTP: Copy as curl" },
    },
  },

  -- ── Breadcrumbs (Class > method > line in winbar) ────────────────────────
  {
    "utilyre/barbecue.nvim",
    dependencies = {
      "SmiteshP/nvim-navic",
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("barbecue").setup({
        theme = "auto",
        show_modified = true,
        show_dirname  = false,
        show_basename = true,
        exclude_filetypes = { "NvimTree", "toggleterm", "terminal" },
        symbols = {
          separator = "",
        },
      })
    end,
  },

  -- ── Better Code Folding ──────────────────────────────────────────────────
  {
    "kevinhwang91/nvim-ufo",
    dependencies = { "kevinhwang91/promise-async" },
    config = function()
      vim.o.foldlevel     = 99
      vim.o.foldlevelstart = 99
      vim.o.foldenable    = true

      require("ufo").setup({
        provider_selector = function(_, filetype, _)
          local map = {
            java       = { "lsp", "indent" },
            typescript = { "lsp", "indent" },
            javascript = { "lsp", "indent" },
            lua        = { "treesitter", "indent" },
          }
          return map[filetype] or { "indent", "marker" }
        end,
      })

      vim.keymap.set("n", "zR", require("ufo").openAllFolds,  { desc = "Open all folds" })
      vim.keymap.set("n", "zM", require("ufo").closeAllFolds, { desc = "Close all folds" })
    end,
  },

  -- ── Markdown: inline rendering inside the buffer ────────────────────────
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
    ft = { "markdown" },
    config = function()
      require("render-markdown").setup({
        heading = { enabled = true },
        code    = { enabled = true, style = "full" },
        bullet  = { enabled = true },
        checkbox = { enabled = true },
        table   = { enabled = true },
        link    = { enabled = true },
      })
    end,
    keys = {
      { "<M-p>", "<cmd>RenderMarkdown toggle<CR>", ft = "markdown", desc = "Markdown: Toggle render" },
    },
  },

  -- ── Multi-cursor editing ─────────────────────────────────────────────────
  {
    "mg979/vim-visual-multi",
    init = function()
      -- Ctrl+N selects next occurrence (default — works in normal mode)
      vim.g.VM_maps = {
        ["Find Under"]         = "<C-n>",
        ["Find Subword Under"] = "<C-n>",
        ["Select All"]         = "<M-n>",
        ["Add Cursor Down"]    = "<M-Down>",
        ["Add Cursor Up"]      = "<M-Up>",
      }
    end,
  },

  -- ── .env file syntax support ─────────────────────────────────────────────
  {
    "ellisonleao/dotenv.nvim",
    config = function()
      require("dotenv").setup({
        enable_on_load = true,
        verbose        = false,
      })
    end,
  },
}
