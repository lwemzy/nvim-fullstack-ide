return {
  {
    "akinsho/toggleterm.nvim",
    config = function()
      require("toggleterm").setup({
        size = function(term)
          if term.direction == "horizontal" then return 15
          elseif term.direction == "vertical" then return math.floor(vim.o.columns * 0.4)
          end
        end,
        direction     = "horizontal",
        close_on_exit = true,
        shell         = vim.o.shell,
        float_opts    = { border = "rounded" },
      })

      local Terminal = require("toggleterm.terminal").Terminal

      -- ── Main terminal: opens/cd's to the current file's directory ──────
      -- Hidden (not close_on_exit-managed away) so the shell process and
      -- its history/state persist across toggles — only the window hides.
      local main_term = Terminal:new({ hidden = true, direction = "horizontal" })

      local function toggle_main_term()
        if vim.bo.buftype ~= "terminal" then
          local dir = vim.fn.expand("%:p:h")
          if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
            if main_term.job_id then
              -- Already running: actually `cd` the live shell.
              main_term:change_dir(dir)
            else
              -- Not spawned yet: this becomes termopen()'s initial cwd.
              main_term.dir = dir
            end
          end
        end
        main_term:toggle()
      end
      vim.keymap.set({ "n", "t" }, "<C-\\>", toggle_main_term, { desc = "Toggle terminal (cwd = current file's directory)" })

      -- ── LazyGit ──────────────────────────────────────────────────────
      local lazygit = Terminal:new({
        cmd       = "lazygit",
        hidden    = true,
        direction = "float",
        float_opts = {
          border = "rounded",
          width  = function() return math.floor(vim.o.columns * 0.95) end,
          height = function() return math.floor(vim.o.lines * 0.9) end,
        },
        on_open = function(term)
          vim.keymap.set("t", "<M-g>", function() term:toggle() end, { buffer = term.bufnr })
        end,
      })
      vim.keymap.set("n", "<M-g>", function() lazygit:toggle() end, { desc = "LazyGit" })

      -- ── Ad-hoc run terminals (<F3>, <M-r>) ────────────────────────────
      -- Unlike main_term and lazygit above, these are created per keypress,
      -- because each run is a distinct one-shot process. That makes their
      -- lifetime ours to manage, and it was leaking badly:
      --
      -- `close_on_exit = false` is deliberate — a build that fails has to stay
      -- on screen to be read — but it means toggleterm's __handle_exit does
      -- nothing at all, while its own TermClose autocmd still drops the terminal
      -- from toggleterm's registry. So the buffer survived with its full
      -- scrollback AND became unreachable: not in `get_all()`, and the local
      -- holding it went out of scope. Every <F3> orphaned ~21MB (10 000-line
      -- default 'scrollback', and libvterm keeps its cell grid per row — a
      -- bootRun or an npm build saturates that cap easily), permanently.
      --
      -- So: track them, and reap the ones whose process has exited whenever a new
      -- run starts. Live runs are left alone, so `npm run watch` alongside a
      -- gradle build still works; the output of a finished run stays readable
      -- until the next run, which is the point at which nobody wants it anymore.
      local run_terms = {}

      local function reap_finished_runs()
        local live = {}
        for _, t in ipairs(run_terms) do
          -- jobwait with a 0 timeout polls: -1 means still running, anything
          -- else (exit code, or -3 for an invalid id) means there is nothing to
          -- keep the buffer alive for.
          local running = t.job_id and vim.fn.jobwait({ t.job_id }, 0)[1] == -1
          if running then
            table.insert(live, t)
          else
            -- shutdown(), not close(): close() only hides the window, which is
            -- what left the buffer behind in the first place. shutdown() closes
            -- the window, deletes the buffer and drops the registry entry.
            pcall(function() t:shutdown() end)
          end
        end
        run_terms = live
      end

      --- Open `cmd` in a fresh horizontal terminal that outlives its process.
      local function run_in_terminal(cmd)
        reap_finished_runs()
        local t = Terminal:new({ cmd = cmd, direction = "horizontal", close_on_exit = false })
        table.insert(run_terms, t)
        t:toggle()
      end

      -- ── Spring Boot run ───────────────────────────────────────────────
      local function spring_boot_run()
        local cmd
        if vim.fn.filereadable("mvnw") == 1 then
          cmd = "./mvnw spring-boot:run"
        elseif vim.fn.filereadable("gradlew") == 1 then
          cmd = "./gradlew bootRun"
        else
          vim.notify("No mvnw or gradlew found in current directory", vim.log.levels.WARN)
          return
        end
        run_in_terminal(cmd)
      end
      vim.keymap.set("n", "<F3>", spring_boot_run, { desc = "Spring Boot: Run" })

      -- ── Gradle / npm helper terminals ─────────────────────────────────
      local function run_cmd_prompt()
        vim.ui.input({ prompt = "Run: " }, function(cmd)
          if cmd and cmd ~= "" then run_in_terminal(cmd) end
        end)
      end
      vim.keymap.set("n", "<M-r>", run_cmd_prompt, { desc = "Run command in terminal" })
    end,
  },
}
