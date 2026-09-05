-- Init for UNIT specs: this config's own Lua modules plus plenary, and nothing
-- else. lazy.nvim is never set up here, so no plugin is loaded and no language
-- server is started — a unit spec that passes here cannot be passing because
-- some plugin happened to be present.
--
-- Deliberately does NOT source ../init.lua. Integration specs use full_init.lua
-- for that; keeping the two apart is what makes "does this module work on its
-- own" a meaningful question.

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local data_dir = vim.fn.stdpath("data")

vim.opt.rtp:prepend(config_dir)
vim.opt.rtp:prepend(data_dir .. "/lazy/plenary.nvim")

-- tests/helpers is not under a `lua/` directory, so rtp would not find it;
-- package.path is what makes require("helpers") / require("helpers.fake_lsp")
-- work from a spec without shipping test code inside lua/.
package.path = table.concat({
  config_dir .. "/tests/?.lua",
  config_dir .. "/tests/?/init.lua",
  package.path,
}, ";")

-- init.lua sets these before requiring config.keymaps, and <leader> is baked
-- into a mapping's lhs at definition time — so a spec that asserts on
-- "<leader>d" would look at "\\d" without this.
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Test runs must not litter the real editing environment.
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false
vim.opt.more = false

-- Specs assert on notifications; keep the real vim.notify (nvim-notify is not
-- loaded here anyway) so helpers.capture_notifications can wrap it.

_G.NVIM_IDE_TEST = { mode = "unit", config_dir = config_dir }
