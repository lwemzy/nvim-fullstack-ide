return {
  {
    "Shatur/neovim-ayu",
    priority = 1000,
    lazy = false,
    config = function()
      require("ayu").setup({
        mirage = true,
        -- Pulled from ayu-mirage's own syntax palette (lua/ayu/colors.lua,
        -- mirage branch) instead of arbitrary hex values, so bracket colors
        -- read as part of the theme rather than a generic rainbow overlay.
        overrides = {
          RainbowDelimiterRed    = { fg = "#f28779" }, -- markup
          RainbowDelimiterOrange = { fg = "#ffad66" }, -- keyword
          RainbowDelimiterYellow = { fg = "#ffd173" }, -- func
          RainbowDelimiterGreen  = { fg = "#d5ff80" }, -- string
          RainbowDelimiterCyan   = { fg = "#5ccfe6" }, -- tag
          RainbowDelimiterBlue   = { fg = "#73d0ff" }, -- entity
          RainbowDelimiterViolet = { fg = "#dfbfff" }, -- constant
        },
      })
      vim.cmd.colorscheme("ayu-mirage")
    end,
  },
}
