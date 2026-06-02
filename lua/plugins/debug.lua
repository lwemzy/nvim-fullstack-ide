return {
  -- Core DAP
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      -- UI
      { "rcarriga/nvim-dap-ui", dependencies = { "nvim-neotest/nvim-nio" } },
      -- Inline variable values while debugging
      "theHamsta/nvim-dap-virtual-text",
      -- Mason bridge (auto-installs DAP adapters)
      "jay-babu/mason-nvim-dap.nvim",
    },
    config = function()
      local dap    = require("dap")
      local dapui  = require("dapui")

      -- ── Mason: auto-install DAP adapters ─────────────────────────────
      require("mason-nvim-dap").setup({
        ensure_installed = { "java-debug-adapter", "java-test", "js-debug-adapter" },
        automatic_installation = true,
        handlers = {},
      })

      -- ── DAP UI ───────────────────────────────────────────────────────
      dapui.setup({
        icons = { expanded = "", collapsed = "", current_frame = "" },
        layouts = {
          {
            elements = {
              { id = "scopes",      size = 0.4 },
              { id = "breakpoints", size = 0.2 },
              { id = "stacks",      size = 0.2 },
              { id = "watches",     size = 0.2 },
            },
            size = 40,
            position = "left",
          },
          {
            elements = { { id = "console", size = 0.6 }, { id = "repl", size = 0.4 } },
            size = 12,
            position = "bottom",
          },
        },
      })

      -- Auto open/close UI with session
      dap.listeners.after.event_initialized["dapui"]  = function() dapui.open() end
      dap.listeners.before.event_terminated["dapui"]  = function() dapui.close() end
      dap.listeners.before.event_exited["dapui"]      = function() dapui.close() end

      -- ── Inline variable values ────────────────────────────────────────
      require("nvim-dap-virtual-text").setup({
        commented = true,
      })

      -- ── TypeScript / JavaScript ───────────────────────────────────────
      local js_adapter = vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter"
      if vim.fn.isdirectory(js_adapter) == 1 then
        require("dap").adapters["pwa-node"] = {
          type = "server",
          host = "localhost",
          port = "${port}",
          executable = {
            command = "node",
            args = { js_adapter .. "/js-debug/src/dapDebugServer.js", "${port}" },
          },
        }

        for _, lang in ipairs({ "typescript", "javascript", "typescriptreact", "javascriptreact" }) do
          dap.configurations[lang] = {
            {
              type    = "pwa-node",
              request = "launch",
              name    = "Launch file",
              program = "${file}",
              cwd     = "${workspaceFolder}",
              sourceMaps = true,
              outFiles = { "${workspaceFolder}/dist/**/*.js" },
            },
            {
              type      = "pwa-node",
              request   = "attach",
              name      = "Attach to process",
              processId = require("dap.utils").pick_process,
              cwd       = "${workspaceFolder}",
            },
          }
        end
      end

      -- ── Signs ─────────────────────────────────────────────────────────
      vim.fn.sign_define("DapBreakpoint",          { text = "●", texthl = "DiagnosticError" })
      vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DiagnosticWarn" })
      vim.fn.sign_define("DapStopped",             { text = "▶", texthl = "DiagnosticOk", linehl = "CursorLine" })
    end,
    keys = {
      { "<F5>",  function() require("dap").continue() end,          desc = "Debug: Continue" },
      { "<F6>",  function() require("dap").step_over() end,         desc = "Debug: Step over" },
      { "<F7>",  function() require("dap").step_into() end,         desc = "Debug: Step into" },
      { "<F8>",  function() require("dap").step_out() end,          desc = "Debug: Step out" },
      { "<F9>",  function() require("dap").toggle_breakpoint() end, desc = "Debug: Toggle breakpoint" },
      { "<F10>", function() require("dap").terminate() end,         desc = "Debug: Terminate" },
      { "<F11>", function() require("dapui").toggle() end,          desc = "Debug: Toggle UI" },
    },
  },
}
