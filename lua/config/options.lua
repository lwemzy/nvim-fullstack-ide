local opt = vim.opt

opt.number = true
opt.relativenumber = false
opt.tabstop = 2
opt.shiftwidth = 2
opt.expandtab = true
opt.smartindent = true
opt.wrap = false
opt.swapfile = false
opt.backup = false
opt.undofile = true
opt.undodir = vim.fn.stdpath("data") .. "/undo"
opt.hlsearch = false
opt.incsearch = true
opt.termguicolors = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.signcolumn = "yes"
opt.updatetime = 250
opt.timeoutlen = 300
opt.splitright = true
opt.splitbelow = true
opt.cursorline = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"
-- Only affects Neovim's *native* completion (i_CTRL-X). nvim-cmp drives its own
-- popup off cmp's `completion.completeopt`, not this option.
opt.completeopt = "menuone,noinsert,noselect"
opt.pumheight = 10
-- Default border for every floating window. Set here (before lazy.setup, so it
-- is in place when plugin configs run) because three separate things read it:
--   1. vim.lsp.util.open_floating_preview -> hover + signature help
--      (runtime/lua/vim/lsp/util.lua: `opts.border or vim.o.winborder`)
--   2. cmp.config.window.bordered() -> falls back to `winborder`, and returns
--      "none" when it is empty, which is why the completion/docs popups had no
--      border at all despite calling bordered()
--   3. nvim_open_win's `border` default
-- One setting instead of repeating border="rounded" at every call site.
opt.winborder = "rounded"
opt.showmode = false
opt.laststatus = 3
opt.fileencoding = "utf-8"
opt.ignorecase = true
opt.smartcase = true
opt.list = true
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
opt.autoread = true
