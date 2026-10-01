local opt = vim.opt

-- mason's bin dir on PATH, here rather than as a side effect of mason.setup().
-- mason is lazy-loaded (lua/plugins/lsp.lua) and its setup is what used to
-- prepend this, so without it nothing mason installed is findable until the
-- installer UI happens to load. That matters because conform decides whether a
-- formatter exists with a bare `vim.fn.executable(command)` against the *process*
-- PATH (conform/init.lua: get_formatter_info) and ignores the formatter's own
-- `env.PATH` — so prettier/prettierd carrying mason's bin dir in `env` makes the
-- spawned process resolve, but cannot make conform consider it available. An
-- unavailable formatter is skipped silently, which is JS/TS/JSON/CSS/YAML/MD
-- quietly not formatting on save.
--
-- Prepended, not appended, to match mason's own default (PATH = "prepend") so
-- resolution order is exactly what it was while mason.setup() did this. Guarded
-- against double-prepending because mason.setup() still runs this when the
-- installer does load. Separator is ":" like the rest of the config
-- (lua/plugins/editor.lua); this config targets Linux/macOS.
local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
if not (":" .. (vim.env.PATH or "") .. ":"):find(":" .. mason_bin .. ":", 1, true) then
  vim.env.PATH = mason_bin .. ":" .. (vim.env.PATH or "")
end

opt.number = true
opt.relativenumber = false
-- Hard tabs, 4 columns wide (VS Code-style: Tab inserts a tab character, and
-- >> / << shift by one tab). softtabstop = -1 makes Backspace follow shiftwidth.
opt.tabstop = 4
opt.shiftwidth = 4
opt.softtabstop = -1
opt.expandtab = false
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
