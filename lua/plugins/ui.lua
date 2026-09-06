return {
  -- Icons (required by many plugins)
  { "nvim-tree/nvim-web-devicons", lazy = true },

  -- Statusline
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("lualine").setup({
        options = {
          theme = "ayu_mirage",
          component_separators = { left = "", right = "" },
          section_separators = { left = "", right = "" },
          globalstatus = true,
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = { { "filename", path = 1 } },
          -- The Run / Restart / Stop / Debug toolbar (lua/config/runner.lua).
          -- Here rather than in a bar of its own: laststatus = 3 +
          -- globalstatus already make this line a single persistent one for the
          -- whole editor, and mouse = "a" makes lualine's per-component on_click
          -- really clickable — so the toolbar costs no screen line at all.
          --
          -- lualine_x rather than lualine_c because lualine_c's width moves with
          -- the file path, and a button that slides sideways when you switch
          -- files is a button that gets misclicked.
          lualine_x = vim.list_extend(
            require("config.runner").components(),
            { "encoding", "fileformat", "filetype" }
          ),
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },

  -- Buffer tabs
  -- Closes a buffer without disturbing window layout — switches affected
  -- windows to a sensible sibling buffer first, instead of leaving Neovim
  -- to improvise (which is what let other splits expand into the gap).
  { "famiu/bufdelete.nvim", lazy = true },

  {
    "akinsho/bufferline.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("bufferline").setup({
        options = {
          mode = "buffers",
          separator_style = "slant",
          show_buffer_close_icons = true,
          show_close_icon = false,
          diagnostics = "nvim_lsp",
          diagnostics_indicator = function(_, _, diag)
            local icons = { error = " ", warning = " " }
            local ret = (diag.error and icons.error .. diag.error .. " " or "")
              .. (diag.warning and icons.warning .. diag.warning or "")
            return vim.trim(ret)
          end,
          -- Default close_command is a plain "bdelete! %d", which doesn't
          -- pick a sibling buffer before closing (see bufdelete.nvim above).
          close_command = function(bufnum) require("bufdelete").bufdelete(bufnum, false) end,
          right_mouse_command = function(bufnum) require("bufdelete").bufdelete(bufnum, false) end,
          offsets = {
            {
              filetype = "NvimTree",
              text = "File Explorer",
              highlight = "Directory",
              separator = true,
            },
          },
        },
      })
    end,
  },

  -- File explorer
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup({
        view = {
          width = 35,
          side = "left",
        },
        renderer = {
          group_empty = true,
          highlight_git = true,
          icons = {
            show = { git = true, file = true, folder = true },
          },
        },
        filters = { dotfiles = false, custom = { "^.git$" } },
        git = { enable = true, ignore = false },
        -- Auto-reveal the current file's path in the tree on every buffer
        -- switch. Expands what's needed to show it, doesn't force-collapse
        -- other folders you have open — same as Ctrl+Shift+e's manual reveal.
        update_focused_file = { enable = true },
        actions = {
          open_file = {
            quit_on_open = false,
            -- Always open in the nearest non-tree, non-terminal window
            window_picker = {
              enable = true,
              picker = "default",
              chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
              exclude = {
                filetype = { "notify", "packer", "qf", "diff", "fugitive", "fugitiveblame" },
                buftype  = { "nofile", "terminal", "help" },
              },
            },
          },
        },
      })
    end,
  },

  -- Fuzzy finder
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
      "nvim-telescope/telescope-ui-select.nvim",
    },
    config = function()
      local telescope = require("telescope")
      local actions = require("telescope.actions")
      telescope.setup({
        defaults = {
          file_ignore_patterns = { "node_modules", "%.git/", "target/", "build/" },
          layout_strategy = "horizontal",
          -- preview_width nested under horizontal (not flat/global): the
          -- "center" strategy (used by telescope-ui-select's dropdown below)
          -- strictly rejects any top-level layout_config key it doesn't
          -- recognize, and preview_width is horizontal/vertical/flex-only.
          layout_config = { horizontal = { preview_width = 0.55 }, height = 0.8 },
          mappings = {
            i = {
              ["<C-k>"] = actions.move_selection_previous,
              ["<C-j>"] = actions.move_selection_next,
              ["<C-q>"] = actions.send_selected_to_qflist + actions.open_qflist,
            },
          },
        },
        extensions = {
          -- Routes vim.ui.select() through a Telescope dropdown instead of
          -- the plain numbered command-line list — used by code actions
          -- (Ctrl+./F4), jdtls's Generate/Override menus, and anywhere else
          -- vim.ui.select shows up.
          ["ui-select"] = {
            require("telescope.themes").get_dropdown({}),
          },
        },
      })
      telescope.load_extension("fzf")
      telescope.load_extension("ui-select")
    end,
  },

  -- Indent guides
  {
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    config = function()
      require("ibl").setup({
        indent = { char = "│" },
        scope = { enabled = false },
      })
    end,
  },

  -- Key hints popup
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    config = function()
      local wk = require("which-key")
      wk.setup({ delay = 500 })
      wk.add({
        { "<leader>a", group = "AI (Claude)" },
        { "<leader>b", group = "buffer" },
        { "<leader>f", group = "find / format" },
        { "<leader>g", group = "git" },
        { "<leader>j", group = "java" },
        { "<leader>l", group = "lsp" },
        { "<leader>r", group = "run / debug" },
        { "<leader>s", group = "split" },
        { "<leader>u", group = "ui toggles" },
        { "<leader>uq", group = "session" },
        { "<leader>x", group = "diagnostics" },
      })
    end,
  },

  -- Inline hex/rgb/hsl color swatches
  {
    "catgoose/nvim-colorizer.lua",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      filetypes = { "css", "scss", "html", "typescript", "typescriptreact", "javascript", "lua" },
      user_default_options = {
        RGB = true,
        RRGGBB = true,
        RRGGBBAA = true,
        css = true,
        css_fn = true,
        tailwind = true,
      },
    },
  },

  -- LSP progress/status messages (e.g. "jdtls: Building workspace 63%")
  {
    "j-hui/fidget.nvim",
    event = "LspAttach",
    opts = {},
  },

  -- Notifications + history
  {
    "rcarriga/nvim-notify",
    config = function()
      require("notify").setup({
        background_colour = "#1f2430",
        timeout = 3000,
        stages = "fade_in_slide_out",
      })
      vim.notify = require("notify")

      -- Load telescope extension so we can browse notification history
      local ok, telescope = pcall(require, "telescope")
      if ok then telescope.load_extension("notify") end
    end,
  },
}
