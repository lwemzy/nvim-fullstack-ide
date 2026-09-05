-- Init for INTEGRATION specs: boots the real config, exactly as a user's Neovim
-- does, then hands control to the spec.
--
-- Sourcing ../init.lua rather than re-implementing it is the point: lazy.nvim's
-- own merge/ordering rules, the plugin `config` functions, and the load order
-- between config/* and lazy.setup are all part of what these specs verify.
-- Anything reconstructed here by hand would be testing a copy of the config
-- instead of the config.

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

-- See minimal_init.lua: tests/helpers lives outside lua/, so require() needs
-- package.path rather than the runtimepath.
package.path = table.concat({
  config_dir .. "/tests/?.lua",
  config_dir .. "/tests/?/init.lua",
  package.path,
}, ";")

dofile(config_dir .. "/init.lua")

-- Real config, but never the user's files: options.lua turns undofile on, and a
-- spec that writes a scratch buffer would otherwise leave undo history behind.
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.more = false

_G.NVIM_IDE_TEST = { mode = "integration", config_dir = config_dir }
