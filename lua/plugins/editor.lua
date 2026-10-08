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
      local bigfile = require("config.bigfile")
      require("illuminate").configure({
        providers = { "lsp", "treesitter", "regex" },
        delay = 200,
        filetypes_denylist = { "NvimTree", "toggleterm", "TelescopePrompt" },
        -- Illuminate re-resolves the symbol under the cursor on every CursorMoved,
        -- and its regex provider scans the whole buffer to do it. Its own cutoff
        -- is used rather than the switch-off in config.bigfile because this one
        -- needs no per-buffer call: above the cutoff illuminate disables itself.
        --
        -- On its own, deliberately, with no large_file_overrides beside it:
        -- config.get() returns the overrides table *instead of* the config rather
        -- than merged over it (illuminate/config.lua), and the absent key is not
        -- the no-op it looks like — large_file_overrides() falls back to
        -- `{ filetypes_allowlist = { '_none' } }`, which is what switches
        -- illuminate off entirely. Passing `{ providers = { "lsp" } }` here to keep
        -- the cheap provider measurably made big files *worse*: delay fell from
        -- 200ms to the 17ms floor and filetypes_denylist was emptied, so a 10k-line
        -- buffer got a documentHighlight request every 17ms of cursor movement
        -- where it had had none.
        --
        -- Byte-big files (a minified bundle: few lines, megabytes of them) are not
        -- covered by this, since illuminate only compares line('$') — config.bigfile
        -- stops those per buffer.
        large_file_cutoff = bigfile.MAX_LINES,
      })
      vim.keymap.set("n", "]]", function() require("illuminate").goto_next_reference() end, { desc = "Next reference" })
      vim.keymap.set("n", "[[", function() require("illuminate").goto_prev_reference() end, { desc = "Prev reference" })
    end,
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
    -- lua/config/keymaps.lua binds Ctrl+/ (and the <C-_> spelling terminals
    -- actually send) to functions that `require("Comment.api")` when pressed, and
    -- lazy's module loader loads the plugin — running `config` first — on that
    -- require. Those two need no keys entry here.
    --
    -- gco/gcO/gcA do, and they are not optional extras to list for completeness:
    -- they are created by setup() (config.lua's `extra` table, on by default) and
    -- keymaps.lua does not own them. Without them `gco` is not an unmapped key
    -- that beeps — Neovim 0.12 ships its own `gc` operator, so `gc` + `o` is
    -- consumed as operator + motion and comments a different range than asked
    -- for. A silent wrong edit is the one failure mode worth a trigger.
    -- Spelled out with descs rather than as bare strings so the which-key popup
    -- reads the same before the plugin has loaded as after: lazy's trigger
    -- mapping is a real mapping, and these are exactly the descs Comment.nvim's
    -- own `extra` mappings carry, so nothing changes on screen when it replaces
    -- them.
    keys = {
      { "gco", desc = "Comment insert below" },
      { "gcO", desc = "Comment insert above" },
      { "gcA", desc = "Comment insert end of line" },
    },
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
    -- BufReadPre, not VeryLazy. Not because a later load would lose the on_attach
    -- keys — gitsigns.setup() walks nvim_list_bufs() and attaches to every
    -- already-open named buffer (gitsigns.lua: "Attach to all open buffers"), so
    -- ]g/[g and the <leader>g* hunk keys would arrive either way. The reason is
    -- that the retro-attach is asynchronous and runs a git process per buffer, so
    -- a VeryLazy load means the file is on screen with no signs in the gutter and
    -- a visible shift when the sign column appears underneath it.
    event = { "BufReadPre", "BufNewFile" },
    -- cmd as well, because the event is not the only entry point: lua/config/
    -- keymaps.lua binds <M-b> and <M-z> to `:Gitsigns blame_line` /
    -- `:Gitsigns preview_hunk`, and a session that never reads a file — plain
    -- `nvim`, or `nvim <dir>`, neither of which fires BufReadPre — would have the
    -- keymaps present and the command missing, i.e. a guaranteed E492.
    cmd = "Gitsigns",
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
    -- BufWritePre is the earliest event that implies formatting is about to
    -- matter, and it still lands in time: `format_after_save` below registers a
    -- BufWritePost autocmd from inside setup(), so loading on the *pre* half of
    -- the very first write gets that autocmd installed before the *post* half
    -- fires. Alt+L goes through require("conform") in lua/config/keymaps.lua,
    -- which is a load trigger of its own.
    event = "BufWritePre",
    cmd = "ConformInfo",
    config = function()
      -- Projects with no prettier config of their own (no .prettierrc*, no
      -- prettier.config.*, no "prettier" key in package.json) get a project's
      -- explicit choice respected exactly (plain prettierd/prettier, no
      -- overrides) whenever one exists. Only affects JS/TS, where a project's
      -- own opinion can fight ESLint's style rules; CSS/JSON/YAML/MD keep
      -- unconditional Prettier since nothing there governs their style.
      --
      -- Absent a project opinion, fall back to the house JS/TS style rather
      -- than Prettier's stock config — see `prettier_house` below for the five
      -- flags and where each one comes from.
      local prettier_config_files = {
        ".prettierrc", ".prettierrc.json", ".prettierrc.yml", ".prettierrc.yaml",
        ".prettierrc.json5", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs",
        "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs",
      }
      -- Bounded: an unbounded upward search walks to /, so a single ~/.prettierrc
      -- (or a "prettier" key in ~/package.json) would silently mark every JS/TS
      -- project on the machine as having its own opinion and disable the house
      -- fallback everywhere. See lua/config/project.lua for the ceiling.
      local project = require("config.project")
      -- package.json is also the fallback root marker: with no .git/.hg/.svn it is
      -- the only thing that says where a JS project begins, and without it the
      -- search has no bound at all for a project outside $HOME.
      local ROOT_MARKERS = { "package.json" }
      local function has_prettier_config(bufnr)
        if project.find_upward(bufnr, prettier_config_files, { fallback_markers = ROOT_MARKERS })[1] then
          return true
        end
        -- Every package.json up to the root, not just the nearest: in a monorepo
        -- the workspace package usually has no "prettier" key and the repo root
        -- does, and stopping at the nearest one would hand the whole workspace the
        -- house fallback while its own prettier config (and its CI) says otherwise.
        for _, pkg in ipairs(project.find_upward(bufnr, "package.json",
          { fallback_markers = ROOT_MARKERS, limit = math.huge })) do
          local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(pkg), "\n"))
          if ok and type(decoded) == "table" and decoded.prettier ~= nil then return true end
        end
        return false
      end
      local function prettier_or_none(bufnr)
        if has_prettier_config(bufnr) then
          return { "prettierd", "prettier", stop_after_first = true }
        end
        return { "prettier_house", stop_after_first = true }
      end

      require("conform").setup({
        formatters_by_ft = {
          javascript      = prettier_or_none,
          javascriptreact = prettier_or_none,
          typescript      = prettier_or_none,
          typescriptreact = prettier_or_none,
          json            = { "prettierd", "prettier", stop_after_first = true },
          jsonc           = { "prettierd", "prettier", stop_after_first = true },
          css             = { "prettierd", "prettier", stop_after_first = true },
          scss            = { "prettierd", "prettier", stop_after_first = true },
          less            = { "prettierd", "prettier", stop_after_first = true },
          html            = { "prettierd", "prettier", stop_after_first = true },
          yaml            = { "prettierd", "prettier", stop_after_first = true },
          markdown        = { "prettierd", "prettier", stop_after_first = true },
        },
        -- format_after_save runs async so it never blocks editing
        --
        -- lsp_format = "fallback" is what formats the filetypes with no entry
        -- above — Java (jdtls, via the java-google-style.xml profile in
        -- ftplugin/java.lua), XML, Lua. It is spelled the current way, not the
        -- old `lsp_fallback = true`: conform still translates that key for
        -- backwards compatibility but no longer documents it, and a release
        -- dropping it would silently leave those filetypes unformatted on save
        -- with nothing in the logs to say so. This is now the *only* save-time
        -- formatting path for Java — ftplugin/java.lua's own BufWritePre copy
        -- was removed, since the two together cost three formatting round trips
        -- per write.
        -- On by default, and switchable with <leader>uf (lua/config/keymaps.lua).
        -- Returning nil is conform's own documented way to skip a save:
        -- `format_args, callback = format_args(args.buf)` followed by
        -- `if format_args then` (conform/init.lua), so the BufWritePost autocmd
        -- stays registered either way and a write with formatting off costs one
        -- table lookup.
        format_after_save = function(bufnr)
          if not require("config.format").enabled(bufnr) then return nil end
          return {
            timeout_ms  = 5000,
            lsp_format  = "fallback",
          }
        end,
        -- No per-formatter `env = { PATH = mason/bin .. vim.env.PATH }` here any
        -- more: lua/config/options.lua prepends that directory to the process
        -- PATH at startup, which both of these inherit. The per-formatter copies
        -- were not just redundant, they were the wrong lever — conform decides a
        -- formatter is available with vim.fn.executable() against the *process*
        -- PATH and never looks at `env` (conform/init.lua: get_formatter_info),
        -- so they made the spawned process resolve while leaving conform
        -- convinced prettier did not exist, and formatting was skipped silently.
        formatters = {
          -- The house JS/TS style, as five explicit flags on top of Prettier's
          -- stock defaults. Plain prettier, not prettierd — the daemon reads
          -- only project config files and silently drops ad-hoc CLI overrides,
          -- so every flag below would be thrown away. prepend_args only works
          -- when overriding an *existing* built-in formatter by name
          -- (conform.util.merge_formatter_configs); this is a new name, not a
          -- built-in override, so args must be wrapped directly.
          --
          -- The style is the one the work codebases actually enforce, read off
          -- commerce-api's eslint.config.mjs (confirmed with `eslint
          -- --print-config`, 128 rules resolved, rather than from the file) and
          -- matching the four legacy .eslintrc.yml copies in that repo. Only the
          -- rules Prettier can express are here; the flags map one-to-one:
          --
          --   quotes: [error, single]              --single-quote
          --   indent: [error, 2]                   --tab-width=2
          --   max-len: [error, 120]                --print-width=120
          --   comma-dangle: [error, never]         --trailing-comma=none
          --   arrow-parens: [error, as-needed]     --arrow-parens=avoid
          --
          -- Prettier's own defaults already satisfy `semi: always`,
          -- `object-curly-spacing: always`, `jsx-quotes: prefer-double`,
          -- `brace-style`, `eol-last` and the whitespace rules, so those are
          -- left unspelled rather than restated.
          --
          -- --tab-width=2 is Prettier's default and still passed explicitly,
          -- because this formatter previously read `--use-tabs --tab-width=4`
          -- to match the editor's global hard tabs. Silence about indent width
          -- is what let that drift go unnoticed; the editor side now agrees
          -- instead (js_ts_settings in lua/config/autocmds.lua).
          --
          -- One rule Prettier cannot reach: `space-before-function-paren: never`
          -- wants `async(item, ctx) =>` and Prettier always writes
          -- `async (item, ctx) =>`. There is no flag for it, and it only shows up
          -- on async arrows with two or more parameters (with one,
          -- --arrow-parens=avoid drops the parens and the question with them).
          -- `yarn eslint:fix` is what settles those, which is also the repo's
          -- real enforcement path — it has no prettier at all, only `eslint
          -- --fix` on pre-push and post-commit.
          prettier_house = (function()
            local base = require("conform.formatters.prettier")
            return vim.tbl_deep_extend("force", base, {
              args = function(self, ctx)
                local args = base.args(self, ctx)
                table.insert(args, "--single-quote")
                table.insert(args, "--tab-width=2")
                table.insert(args, "--print-width=120")
                table.insert(args, "--trailing-comma=none")
                table.insert(args, "--arrow-parens=avoid")
                return args
              end,
            })
          end)(),
        },
      })
    end,
  },

  -- Better diagnostics list
  {
    "folke/trouble.nvim",
    -- Alt+X in lua/config/keymaps.lua types :Trouble diagnostics toggle, so the
    -- command is the whole entry point.
    cmd = "Trouble",
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

  -- Undo history as a tree
  --
  -- Neovim's undo is already a tree, not a stack: `u` past a branch point and
  -- then typing creates a new branch, and the old one is still reachable — but
  -- only through `g-`/`g+` and `:undolist`, which show a flat list of sequence
  -- numbers with no indication of where the branches are. The usual outcome is
  -- that the work on the abandoned branch is treated as lost. options.lua already
  -- sets `undofile`, so that history survives across sessions too and this reads
  -- it.
  {
    "mbbill/undotree",
    cmd = { "UndotreeToggle", "UndotreeShow", "UndotreeFocus" },
    -- init, not config: this is a vimscript plugin, and plugin/undotree.vim reads
    -- every g:undotree_* at source time (its s:defineOption only fills in
    -- defaults for names that are already unset). lazy sources plugin/ files
    -- *before* calling config, so a config function would set these one step too
    -- late and they would be ignored.
    init = function()
      -- Layout 2: the tree on the left, the diff of the selected state underneath
      -- it, full height. The default (layout 1) puts the diff in a window split
      -- off the *editing* area, which rearranges the code you are comparing
      -- against while you read it.
      vim.g.undotree_WindowLayout = 2
      vim.g.undotree_SplitWidth = 34
      vim.g.undotree_DiffpanelHeight = 12
      -- The panel is read by moving through it, so starting outside it means every
      -- use begins with a window jump.
      vim.g.undotree_SetFocusWhenToggle = 1
      vim.g.undotree_ShortIndicators = 1
    end,
    keys = {
      -- Under the leader+u "ui toggles" group (leader+uf format-on-save,
      -- leader+uh inlay hints) rather than its own chord: this is a panel that
      -- toggles, which is exactly what that group is.
      { "<leader>uu", "<cmd>UndotreeToggle<CR>", desc = "Toggle undo tree" },
    },
  },

  -- Smooth scrolling
  {
    "karb94/neoscroll.nvim",
    -- VeryLazy keeps the existing precedence intact: neoscroll's own <C-u>/<C-d>
    -- mappings replace the plain `<C-d>zz` pair from lua/config/keymaps.lua, and
    -- they did that before too by virtue of loading after it. Earlier than
    -- VeryLazy would not change the outcome; later would leave a window where
    -- scrolling is not animated.
    event = "VeryLazy",
    config = function()
      require("neoscroll").setup({ mappings = { "<C-u>", "<C-d>" } })
    end,
  },
}
