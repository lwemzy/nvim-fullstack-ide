return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    -- BufReadPre, which is deliberately *before* filetype detection: the
    -- treesitter_highlight autocmd in lua/config/autocmds.lua calls
    -- vim.treesitter.start on FileType, and that needs this plugin's parser
    -- directory on the runtimepath to find a parser at all. BufReadPre is the
    -- last event that still precedes FileType, so highlighting is never missed
    -- on the first buffer. The ts_auto_install autocmd registered in config
    -- below gets installed in the same window, for the same reason.
    event = { "BufReadPre", "BufNewFile" },
    -- Exactly the commands this branch defines (TSInstall, TSInstallFromGrammar,
    -- TSLog, TSUninstall, TSUpdate — grep nvim_create_user_command in the plugin).
    -- A name that does not exist is worse than a missing one: lazy creates a stub
    -- for it, and invoking the stub loads the plugin, deletes the stub and then
    -- fails with E492. TSInstallSync was such a name — it belongs to the old
    -- master branch, not to `main`.
    cmd = { "TSUpdate", "TSInstall", "TSInstallFromGrammar", "TSUninstall", "TSLog" },
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
    -- Was lazy = false. BufReadPre and not BufReadPost: rainbow-delimiters
    -- attaches through a FileType autocmd of its own, so loading it after
    -- FileType has already fired would leave the *first* buffer of the session
    -- uncoloured until it was re-edited.
    event = { "BufReadPre", "BufNewFile" },
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
    -- VeryLazy preserves the existing precedence: emmet's Alt+E is set in config
    -- below and deliberately lands after lua/config/keymaps.lua's own Alt+E
    -- (diagnostic float), which is what happened when this was a start plugin.
    event = "VeryLazy",
    config = function()
      vim.keymap.set({ "n", "v" }, "<M-e>", require("nvim-emmet").wrap_with_abbreviation, { desc = "Emmet: Wrap with abbreviation" })
    end,
  },
}
