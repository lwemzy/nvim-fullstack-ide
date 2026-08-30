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

          -- Matching brace/paren highlight (VS Code-style bracket-pair box)
          -- when the cursor sits on either one. Built-in matchparen, just
          -- restyled from a plain underline to ayu-mirage's selection color.
          MatchParen = { bg = "#274364", bold = true, underline = false },

          -- nvim-cmp's completion/documentation popups otherwise nearly
          -- vanish into the editor: Pmenu's stock bg (#23344B, ayu/init.lua)
          -- is close enough in luminance to Normal's bg (#1F2430) to barely
          -- read as a separate surface, and the documentation float defaults
          -- to NormalFloat, whose bg IS colors.bg — literally identical to
          -- the editor, zero contrast at all. Give the popup its own clearly
          -- lighter "elevated panel" tier, a distinctly richer blue for the
          -- selected item (reusing the same selection color as MatchParen
          -- above, for palette consistency), and a bright cyan border so the
          -- whole thing reads as an overlay instead of blending into the
          -- code behind it.
          Pmenu       = { fg = "#CCCAC2", bg = "#2E3648" },
          PmenuSel    = { fg = "#CCCAC2", bg = "#274364", bold = true },
          PmenuSbar   = { bg = "#2E3648" },
          PmenuThumb  = { bg = "#5CCFE6" },
          NormalFloat = { bg = "#2E3648" },
          FloatBorder = { fg = "#5CCFE6" },
        },
      })
      vim.cmd.colorscheme("ayu-mirage")
    end,
  },
}
