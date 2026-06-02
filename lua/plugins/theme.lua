return {
  {
    "Shatur/neovim-ayu",
    priority = 1000,
    lazy = false,
    config = function()
      require("ayu").setup({
        mirage = true,
        overrides = {},
      })
      vim.cmd.colorscheme("ayu-mirage")
    end,
  },
}
