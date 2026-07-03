return {
  {
    "Shatur/neovim-ayu",
    priority = 1000,
    lazy = false,
    config = function()
      require("ayu").setup({
        mirage = true,
        overrides = {
          RainbowDelimiterRed    = { fg = "#ff3333" },
          RainbowDelimiterYellow = { fg = "#ffd580" },
          RainbowDelimiterBlue   = { fg = "#73d0ff" },
          RainbowDelimiterOrange = { fg = "#ffa759" },
          RainbowDelimiterGreen  = { fg = "#bae67e" },
          RainbowDelimiterViolet = { fg = "#dfbfff" },
          RainbowDelimiterCyan   = { fg = "#5ccfe6" },
        },
      })
      vim.cmd.colorscheme("ayu-mirage")
    end,
  },
}
