return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    config = function()
      local ts = require("nvim-treesitter")
      -- jsonc isn't a separate parser — Neovim core already maps the
      -- jsonc filetype onto the json parser (vim.treesitter.language.get_lang).
      local ensure_installed = {
        "typescript", "javascript", "tsx", "java",
        "lua", "vim", "vimdoc", "query",
        "json", "yaml", "toml",
        "html", "css", "scss", "markdown", "markdown_inline",
        "bash", "xml", "regex", "angular",
      }
      -- main-branch nvim-treesitter dropped the old `ensure_installed` /
      -- `auto_install` setup() options (setup() only takes `install_dir`
      -- now) — they were silently no-ops here. install() is idempotent
      -- (skips already-installed parsers), so this replicates ensure_installed.
      ts.install(ensure_installed)

      -- Replicate auto_install: install a parser on demand the first time
      -- its filetype is opened, if one isn't already present.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("ts_auto_install", { clear = true }),
        callback = function(ev)
          local lang = vim.treesitter.language.get_lang(ev.match) or ev.match
          if vim.tbl_contains(ts.get_available(), lang) and not vim.tbl_contains(ts.get_installed(), lang) then
            ts.install(lang)
          end
        end,
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

  -- Sticky enclosing function/class signature at the top of the window
  {
    "nvim-treesitter/nvim-treesitter-context",
    event = { "BufReadPost", "BufNewFile" },
    opts = { max_lines = 3 },
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
