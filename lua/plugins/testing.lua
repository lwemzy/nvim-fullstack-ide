return {
  {
    "nvim-neotest/neotest",
    dependencies = {
      "nvim-neotest/nvim-nio",
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
      "rcasia/neotest-java",
      "haydenmeade/neotest-jest",
    },
    config = function()
      require("neotest").setup({
        adapters = {
          require("neotest-java")({
            ignore_wrapper = false,
          }),
          require("neotest-jest")({
            jestCommand      = "npx jest --no-coverage",
            jestConfigFile   = function()
              -- Auto-detect jest config
              for _, name in ipairs({ "jest.config.ts", "jest.config.js", "jest.config.json" }) do
                if vim.fn.filereadable(name) == 1 then return name end
              end
            end,
            env = { CI = "true" },
            cwd = function() return vim.fn.getcwd() end,
          }),
        },
        output        = { open_on_run = true, enter = true },
        summary       = { animated = true, follow = true },
        quickfix      = { open = false },
        status        = { signs = true, virtual_text = false },
        icons = {
          passed    = "✓",
          failed    = "✗",
          running   = "↻",
          skipped   = "○",
          unknown   = "?",
        },
      })
    end,
    keys = {
      { "<M-t>", function() require("neotest").run.run() end,                              desc = "Test: Run nearest" },
      { "<M-T>", function() require("neotest").run.run(vim.fn.expand("%")) end,            desc = "Test: Run file" },
      { "<M-s>", function() require("neotest").summary.toggle() end,                       desc = "Test: Toggle summary" },
      { "<M-o>", function() require("neotest").output_panel.toggle() end,                  desc = "Test: Toggle output" },
      { "<M-d>", function() require("neotest").run.run({ strategy = "dap" }) end,          desc = "Test: Debug nearest" },
    },
  },
}
