return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").setup({
        ensure_installed = {
          "typescript", "javascript", "tsx", "java",
          "lua", "vim", "vimdoc", "query",
          "json", "jsonc", "yaml", "toml",
          "html", "css", "scss", "markdown", "markdown_inline",
          "bash", "xml", "regex", "angular",
        },
        auto_install = true,
      })
    end,
  },

  -- Rainbow delimiters — nested bracket/brace/paren colors via Treesitter
  {
    "HiPhish/rainbow-delimiters.nvim",
    lazy = false,
    config = function()
      vim.g.rainbow_delimiters = {
        strategy = {
          [""] = "rainbow-delimiters.strategy.global",
        },
        query = {
          [""] = "rainbow-delimiters",
          lua  = "rainbow-blocks",
        },
        highlight = {
          "RainbowDelimiterRed",
          "RainbowDelimiterYellow",
          "RainbowDelimiterBlue",
          "RainbowDelimiterOrange",
          "RainbowDelimiterGreen",
          "RainbowDelimiterViolet",
          "RainbowDelimiterCyan",
        },
      }
    end,
  },

  -- Auto-close and auto-rename HTML / JSX / TSX tags
  {
    "windwp/nvim-ts-autotag",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      require("nvim-ts-autotag").setup({
        opts = {
          enable_close        = true,  -- auto-close tags
          enable_rename       = true,  -- rename closing tag when opening tag is renamed
          enable_close_on_slash = true, -- auto-close on </
        },
        per_filetype = {
          ["html"]            = { enable_close = true },
          ["javascript"]      = { enable_close = true },
          ["typescript"]      = { enable_close = true },
          ["javascriptreact"] = { enable_close = true },
          ["typescriptreact"] = { enable_close = true },
          ["xml"]             = { enable_close = true },
          ["php"]             = { enable_close = true },
        },
      })
    end,
  },

  -- Emmet: expand abbreviations like `div.card>h2+p` → full HTML
  {
    "olrtg/nvim-emmet",
    config = function()
      vim.keymap.set({ "n", "v" }, "<M-e>", require("nvim-emmet").wrap_with_abbreviation, { desc = "Emmet: Wrap with abbreviation" })
    end,
  },
}
