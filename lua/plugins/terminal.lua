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
        local spring = Terminal:new({
          cmd       = cmd,
          direction = "horizontal",
          close_on_exit = false,
        })
        spring:toggle()
      end
      vim.keymap.set("n", "<F3>", spring_boot_run, { desc = "Spring Boot: Run" })

      -- ── Gradle / npm helper terminals ─────────────────────────────────
      local function run_cmd_prompt()
        vim.ui.input({ prompt = "Run: " }, function(cmd)
          if cmd and cmd ~= "" then
            local t = Terminal:new({ cmd = cmd, direction = "horizontal", close_on_exit = false })
            t:toggle()
          end
        end)
      end
      vim.keymap.set("n", "<M-r>", run_cmd_prompt, { desc = "Run command in terminal" })
    end,
  },
}
