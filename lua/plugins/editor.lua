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
    -- Every key below is a default being overridden. Stock diffview renders a
    -- diff like a text buffer that happens to be in diff mode — linted,
    -- whitespace-marked, with unchanged text as bright as changed text — rather
    -- than like something built to be read. The gap filler and the line
    -- matching are deliberately NOT here but in lua/config/options.lua, since
    -- gitsigns' diffthis and :diffsplit need them too.
    opts = {
      -- Dims unchanged text and strengthens the changed-text highlight, so a
      -- one-word change inside a long line is findable. Off by default — and
      -- without it `inline:char` from diffopt has nothing visible to show,
      -- which is why the two settings only make sense together.
      enhanced_diff_hl = true,
      view = {
        -- Diagnostics in a diff are all false positives by construction:
        -- harper_ls grammar-checks the prose in comments, and every other
        -- server is reporting on a revision that is not the file on disk, so
        -- the squiggles land on lines nobody is editing. diffview already
        -- does this for the 3-way merge tool, just not for these two views.
        --
        -- `winbar_info = true` is deliberately NOT set, though it is the
        -- obvious thing to want here: it would label each pane with the
        -- revision it is showing. It cannot work in this config. barbecue
        -- (lua/plugins/tools.lua) owns the winbar of every window whose
        -- buffer has buftype "", and its only opt-outs are buftype and
        -- filetype (barbecue/ui.lua: M.update) — diffview's diff buffers are
        -- buftype "" with the file's real filetype, so excluding them would
        -- mean excluding every javascript/java/lua buffer everywhere. It
        -- re-renders on CursorMoved too, so writing the winbar from a hook
        -- loses the next time the cursor moves. The revision range is on the
        -- first line of the file panel instead.
        default      = { disable_diagnostics = true },
        file_history = { disable_diagnostics = true },
      },
      file_panel = {
        tree_options = {
          -- Each folder keeps its change status permanently instead of only
          -- while folded, so the tree answers "what changed under here"
          -- without having to be collapsed first.
          folder_statuses = "always",
        },
      },
      hooks = {
        -- `list` is on globally (lua/config/options.lua) and paints » and ·
        -- through the whole diff. Whitespace marks earn their place in a
        -- buffer being edited; these are not editable.
        diff_buf_read = function()
          vim.opt_local.list = false
        end,
      },
    },
  },

  -- Staging and committing: one buffer showing staged, unstaged and unpushed
  -- at once, which is the thing gitsigns and diffview together still do not
  -- give you. gitsigns stages the hunk under the cursor in the file you are
  -- editing, diffview reviews a revision range — neither answers "what is
  -- about to go into this commit, and what is not".
  {
    "NeogitOrg/neogit",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = "Neogit",
    keys = {
      { "<leader>gg", "<cmd>Neogit<CR>", desc = "Git: Neogit status" },
    },
    opts = {
      -- Both default to nil, which means auto-detect: neogit runs
      -- `pcall(require, name)` (its config.lua: check_integration) and takes
      -- the answer. That does work here even though both plugins are lazy —
      -- lazy.nvim hooks `require`, so the pcall loads them — which is why
      -- neither has to be a dependency. Pinned anyway, because auto-detect
      -- answers "whatever is installed" rather than "what this config
      -- chose": install fzf-lua or snacks for any unrelated reason and the
      -- branch picker silently stops being telescope (finder.lua checks the
      -- integrations in a fixed order), and add codediff and the diff stops
      -- being the diffview this file spends fifty lines configuring.
      integrations = {
        telescope = true,
        diffview  = true,
      },
      -- The other half of that: `diff_viewer` is the explicit version of the
      -- same choice, and the only one neogit checks before auto-detecting
      -- (config.lua: get_diff_viewer). So `d` on a file in the status buffer
      -- opens the hatched, dimmed, diagnostic-free diff configured above.
      diff_viewer = "diffview",
      -- The fold chevrons diffview uses (its config.lua: signs.fold_closed /
      -- fold_open) instead of neogit's `>`/`v`, so an expandable row looks
      -- the same in both git UIs. `hunk` is left alone: it defaults to two
      -- empty strings, and a chevron on every hunk header is noise rather
      -- than consistency — diffview has no hunk-level fold to match.
      signs = {
        item    = { "", "" },
        section = { "", "" },
      },
      -- Box-drawing characters for the commit graph rather than ASCII
      -- `|`/`/`/`\`. Pure rendering, no external tool: neogit draws the graph
      -- itself from `git log`. The terminal here is already running a Nerd
      -- Font for devicons, so the glyphs are safe.
      graph_style = "unicode",
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
      -- A project's explicit choice is respected exactly (plain
      -- prettierd/prettier, no overrides) whenever it has one. Only affects
      -- JS/TS, where a project's own opinion can fight ESLint's style rules;
      -- CSS/JSON/YAML/MD keep unconditional Prettier since nothing there
      -- governs their style.
      --
      -- Absent a project opinion, fall back to the house JS/TS style rather
      -- than a formatter's stock config — see `oxfmt_house` below.
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
      -- The same question for oxfmt, which the house fallback now runs. Needed
      -- because the fallback passes `-c <this repo's .oxfmtrc.json>`
      -- --disable-nested-config, so a project that has written its own oxfmt
      -- config would have it overridden — the exact failure the prettier gate
      -- above exists to prevent, newly reachable now that the fallback is oxfmt.
      --
      -- vite.config.ts/js are deliberately NOT in this list even though oxfmt
      -- reads a `fmt` section from them (and conform's built-in oxfmt treats
      -- them as config files): the overwhelming majority of Vite projects have
      -- no such section, so counting them would hand every Vite app oxfmt's
      -- stock defaults — double quotes, 80 columns — while reporting that the
      -- project asked for it.
      local oxfmt_config_files = { ".oxfmtrc.json", ".oxfmtrc.jsonc", "oxfmt.config.ts" }
      local function has_oxfmt_config(bufnr)
        return project.find_upward(bufnr, oxfmt_config_files, { fallback_markers = ROOT_MARKERS })[1] ~= nil
      end

      local function jsts_formatters(bufnr)
        if has_prettier_config(bufnr) then
          return { "prettierd", "prettier", stop_after_first = true }
        end
        if has_oxfmt_config(bufnr) then
          -- The built-in, not oxfmt_house: it finds and reads the project's
          -- config itself, which is the whole point of deferring here.
          return { "oxfmt", stop_after_first = true }
        end
        return { "oxfmt_house", stop_after_first = true }
      end

      require("conform").setup({
        formatters_by_ft = {
          javascript      = jsts_formatters,
          javascriptreact = jsts_formatters,
          typescript      = jsts_formatters,
          typescriptreact = jsts_formatters,
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
          -- The house JS/TS style, run by oxfmt (the Oxc project's formatter)
          -- against the .oxfmtrc.json at the root of this config repo.
          --
          -- oxfmt rather than prettier because it is Prettier-compatible by
          -- design and measurably cheaper: on 60 real commerce-api files put
          -- through both via stdin, the output was byte-identical in all 60
          -- (and in hand-written .tsx/.jsx cases), while five runs cost prettier
          -- 0.33s of CPU and oxfmt 0.03s. Formatting is async
          -- (format_after_save), so the win is machine load rather than
          -- latency — but it is the same style for a tenth of the work.
          --
          -- The style itself is unchanged, and is the one the work codebases
          -- actually enforce: read off commerce-api's eslint.config.mjs
          -- (confirmed with `eslint --print-config`, 128 rules resolved, rather
          -- than from the file) and matching the four legacy .eslintrc.yml
          -- copies in that repo. The five keys in .oxfmtrc.json map one-to-one
          -- onto the ESLint rules Prettier-style formatters can express:
          --
          --   quotes: [error, single]              singleQuote: true
          --   indent: [error, 2]                   tabWidth: 2
          --   max-len: [error, 120]                printWidth: 120
          --   comma-dangle: [error, never]         trailingComma: "none"
          --   arrow-parens: [error, as-needed]     arrowParens: "avoid"
          --
          -- `semi: always`, `object-curly-spacing: always`,
          -- `jsx-quotes: prefer-double`, `brace-style` and `eol-last` are
          -- already the default on both formatters, so they stay unspelled.
          --
          -- A config FILE, not flags, because oxfmt has no style CLI options at
          -- all — `oxfmt --help` lists only mode/output/ignore/runtime options.
          -- So the style has to live somewhere on disk, and it lives in this
          -- repo so that it travels with the config instead of having to be
          -- planted in every project that lacks one.
          --
          -- One rule neither formatter can reach: `space-before-function-paren:
          -- never` wants `async(item, ctx) =>` and both write
          -- `async (item, ctx) =>`. It only shows up on async arrows with two or
          -- more parameters (with one, arrowParens: avoid drops the parens and
          -- the question with them). `yarn eslint:fix` is what settles those,
          -- which is the work repo's only enforcement path anyway — it ships no
          -- prettier at all, just `eslint --fix` on pre-push and post-commit.
          oxfmt_house = (function()
            local base = require("conform.formatters.oxfmt")
            local house = vim.tbl_deep_extend("force", base, {
              -- A static list, not base.args plus insertions the way
              -- prettier_house built its argv: oxfmt's built-in args are exactly
              -- { "--stdin-filepath", "$FILENAME" }, so there is nothing to
              -- inherit, and spelling the whole argv out keeps the config path
              -- visible next to the flag that disables the search for any other.
              --
              -- --disable-nested-config is the load-bearing one. Without it
              -- oxfmt still looks for .oxfmtrc.json in subdirectories of the
              -- working directory and merges what it finds, so a project
              -- carrying its own would partially override the house style on
              -- some files and not others. A project that HAS one is routed to
              -- the plain built-in instead (see has_oxfmt_config above), which
              -- is the only place a project config should win.
              args = {
                "-c", vim.fn.stdpath("config") .. "/.oxfmtrc.json",
                "--disable-nested-config",
                "--stdin-filepath", "$FILENAME",
              },
            })
            -- The built-in resolves cwd by searching for the config files it
            -- would read, which is exactly what -c overrides — and it counts
            -- vite.config.ts, so a Vite project would run this formatter from a
            -- directory chosen for a config it is being told to ignore. Nil is
            -- what the prettier built-in does: run in the buffer's directory.
            -- Assigned after the extend because tbl_deep_extend drops nil.
            house.cwd = nil
            return house
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
