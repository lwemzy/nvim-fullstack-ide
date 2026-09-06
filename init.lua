-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("config.options")
require("config.keymaps")
require("config.autocmds")

require("lazy").setup("plugins", {
  change_detection = { notify = false },
  ui = { border = "rounded" },
})

-- :Run / :RunStop / … and the statusline toolbar's cache invalidation. After
-- lazy.setup because the commands it registers are meant to be available in the
-- same session as the plugins they eventually drive (toggleterm, dap, jdtls) —
-- each of which it requires lazily, inside the action that needs it.
require("config.runner").setup()
