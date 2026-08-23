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
    -- `keys` alone as the lazy-load trigger means neotest never initializes
    -- (never runs setup(), never starts the discovery autocmds that place
    -- its sign-column icons) until one of those keys is pressed for the
    -- first time — so the "icon marks every test before you ever run it"
    -- effect (the whole point of status.signs below) silently never showed
    -- up on a freshly opened test file. `ft` loads it on open instead, for
    -- exactly the filetypes the two adapters below actually handle.
    ft = { "java", "javascript", "javascriptreact", "typescript", "typescriptreact" },
    config = function()
      require("neotest").setup({
        adapters = {
          require("neotest-java")({
            ignore_wrapper = false,
            -- Default patterns only match filenames ending in Test/Tests/
            -- IT/Spec — real classes here (BeerControllerMvc, Beer
            -- ControllerTestAI) don't fit that convention, so they were
            -- silently invisible to discovery (no icons, no :Test: Run
            -- nearest) despite containing real @Test methods. Directory
            -- placement (anything under a non-main source root) is already
            -- a sufficient, correct signal on its own — see file_checker.lua's
            -- separate `relative_path:contains("main")` exclusion.
            test_classname_patterns = { ".*" },
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

      -- NOTE on sign timing: neotest's own position-discovery autocmds
      -- (BufAdd/BufWritePost/DirChanged) aren't registered until its
      -- internal client actually starts, which itself only happens lazily
      -- on the first call that needs it (running a test, opening the
      -- summary, etc.) — confirmed by tracing neotest's source, and true
      -- even in LazyVim's own reference neotest config, which does nothing
      -- special here either. So status-sign icons won't appear on a file
      -- opened cold in a fresh session until you interact with neotest once;
      -- after that, discovery is live for the rest of the session. `ft`
      -- above at least gets the plugin loaded on file open rather than
      -- waiting for a keypress, which is as far as this can go without
      -- depending on undocumented internals.
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
