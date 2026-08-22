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
        -- build.gradle (groovy) / build.gradle.kts (kotlin) syntax highlighting
        "groovy", "kotlin",
        "dockerfile",
        "sql",
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

  -- Semantic text objects/motions (function/class/argument) from the same
  -- Treesitter parsers already installed above — af/if, ac/ic, aa/ia to
  -- select, ]m/[m (+ ]M/[M) and ]c/[c to jump between function/class starts.
  {
    "nvim-treesitter/nvim-treesitter-textobjects",
    branch = "main",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require("nvim-treesitter-textobjects").setup({
        select = {
          lookahead = true,
          selection_modes = {
            ["@parameter.outer"] = "v",
            ["@function.outer"] = "V",
            ["@class.outer"] = "V",
          },
        },
        move = { set_jumps = true },
      })

      local select = require("nvim-treesitter-textobjects.select")
      local move = require("nvim-treesitter-textobjects.move")

      local function selector(query)
        return function() select.select_textobject(query, "textobjects") end
      end

      vim.keymap.set({ "x", "o" }, "af", selector("@function.outer"),  { desc = "Select: function (outer)" })
      vim.keymap.set({ "x", "o" }, "if", selector("@function.inner"),  { desc = "Select: function (inner)" })
      vim.keymap.set({ "x", "o" }, "ac", selector("@class.outer"),     { desc = "Select: class (outer)" })
      vim.keymap.set({ "x", "o" }, "ic", selector("@class.inner"),     { desc = "Select: class (inner)" })
      vim.keymap.set({ "x", "o" }, "aa", selector("@parameter.outer"), { desc = "Select: argument (outer)" })
      vim.keymap.set({ "x", "o" }, "ia", selector("@parameter.inner"), { desc = "Select: argument (inner)" })

      vim.keymap.set({ "n", "x", "o" }, "]m", function() move.goto_next_start("@function.outer", "textobjects") end,     { desc = "Next function start" })
      vim.keymap.set({ "n", "x", "o" }, "]M", function() move.goto_next_end("@function.outer", "textobjects") end,       { desc = "Next function end" })
      vim.keymap.set({ "n", "x", "o" }, "[m", function() move.goto_previous_start("@function.outer", "textobjects") end, { desc = "Prev function start" })
      vim.keymap.set({ "n", "x", "o" }, "[M", function() move.goto_previous_end("@function.outer", "textobjects") end,   { desc = "Prev function end" })
      vim.keymap.set({ "n", "x", "o" }, "]c", function() move.goto_next_start("@class.outer", "textobjects") end,       { desc = "Next class start" })
      vim.keymap.set({ "n", "x", "o" }, "[c", function() move.goto_previous_start("@class.outer", "textobjects") end,   { desc = "Prev class start" })
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
