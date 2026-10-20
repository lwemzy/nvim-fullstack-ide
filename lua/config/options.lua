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
-- Prepended, not appended, to match the mason default this replaces (PATH =
-- "prepend") so resolution order is exactly what it was while mason.setup() did
-- it. mason.setup() is now passed PATH = "skip" (lua/plugins/lsp.lua), because
-- mason's own prepend is unconditional and would add the same directory again
-- on every load. The guard here is belt-and-braces for that setting being
-- changed back, and for this file being sourced twice (`:luafile`, a spec
-- re-requiring it). Separator is ":" like the rest of the config
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
-- Only the `diff` item is overridden here; every fillchars item left out keeps
-- its Neovim default. The one being replaced is `diff:-`, which fills the empty
-- side of an unbalanced hunk with a band of dashes — the loudest thing on
-- screen in a side-by-side diff, drawn exactly where a GUI client (IntelliJ,
-- VS Code) leaves a quiet shaded gap. U+2571 reads as texture rather than as
-- content, which is the whole job of a filler line.
opt.fillchars = { diff = "╱" }
-- How every diff in this config is computed and drawn. Set globally rather
-- than in diffview's spec (lua/plugins/editor.lua) because three separate
-- things render diffs and only one of them is diffview: `<leader>gd` is
-- gitsigns' diffthis, `:diffsplit` is built in, and all three read this option.
--
--   * internal, filler, closeoff, indent-heuristic and inline:char are
--     Neovim 0.12's own defaults. Repeated rather than appended to so this
--     list is the whole truth, instead of a delta against a default that has
--     changed twice in two releases.
--   * algorithm:histogram groups changed lines the way `git diff --histogram`
--     does. The default (myers) splits a moved or re-indented block into
--     unrelated add/delete pairs more often, which is what produces a diff
--     where nothing lines up.
--   * linematch:60 raises the default of 40. linematch is what pairs a changed
--     line with its counterpart so inline:char can highlight just the words
--     that differ; past the limit it gives up and the two sides stop aligning
--     at all. The JS/TS hunks in the repos this config is used on routinely
--     pass 40 lines. It is O(n*m) per hunk, hence a cap rather than no cap.
--   * vertical makes :diffsplit and gitsigns' diffthis open left/right, the
--     way diffview already does, instead of stacking the two versions.
opt.diffopt = {
  "internal", "filler", "closeoff", "indent-heuristic", "inline:char",
  "algorithm:histogram", "linematch:60", "vertical",
}
opt.autoread = true
