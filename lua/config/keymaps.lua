local map = vim.keymap.set

-- ── Window navigation (Ctrl + h/j/k/l) ────────────────────────────────────
-- Normal mode
map("n", "<C-h>", "<C-w>h", { desc = "Window left" })
map("n", "<C-j>", "<C-w>j", { desc = "Window down" })
map("n", "<C-k>", "<C-w>k", { desc = "Window up" })
map("n", "<C-l>", "<C-w>l", { desc = "Window right" })
-- Terminal mode — exit terminal insert mode then move window
map("t", "<C-h>", "<C-\\><C-n><C-w>h", { desc = "Window left (from terminal)" })
map("t", "<C-j>", "<C-\\><C-n><C-w>j", { desc = "Window down (from terminal)" })
map("t", "<C-k>", "<C-\\><C-n><C-w>k", { desc = "Window up (from terminal)" })
map("t", "<C-l>", "<C-\\><C-n><C-w>l", { desc = "Window right (from terminal)" })

-- ── Resize splits (Ctrl + arrow keys) ─────────────────────────────────────
map("n", "<C-Up>",    ":resize +2<CR>",          { silent = true })
map("n", "<C-Down>",  ":resize -2<CR>",          { silent = true })
map("n", "<C-Left>",  ":vertical resize -2<CR>", { silent = true })
map("n", "<C-Right>", ":vertical resize +2<CR>", { silent = true })

-- ── File explorer ──────────────────────────────────────────────────────────
-- overrides: C-e (scroll 1 line) — use C-d/C-u for scrolling instead
map("n", "<C-e>", ":NvimTreeToggle<CR>",   { silent = true, desc = "Toggle explorer" })
map("n", "<C-S-e>", ":NvimTreeFindFile<CR>", { silent = true, desc = "Reveal file in explorer" })

-- ── Telescope / Search ─────────────────────────────────────────────────────
-- C-p = find files  (like VS Code)       overrides: prev completion (Tab still works)
-- C-f = live grep   (like "Find in Files") overrides: page-forward  (C-d still scrolls)
-- C-b = open buffers                      overrides: page-back      (C-u still scrolls)
-- C-t = recent files                      overrides: tag-jump       (rarely used)
map("n", "<C-p>", "<cmd>Telescope find_files<CR>",  { desc = "Find files" })
map("n", "<C-s-f>", function() require("telescope.builtin").live_grep() end, { desc = "Live grep (search in files)" })
map("n", "<C-b>", "<cmd>Telescope buffers<CR>", { desc = "Switch buffer" })
map("n", "<C-t>", "<cmd>Telescope oldfiles<CR>",    { desc = "Recent files" })

-- ── Save / Quit ────────────────────────────────────────────────────────────
map({ "n", "i" }, "<C-s>", "<Esc>:w<CR>",  { silent = true, desc = "Save file" })
-- C-q: overrides visual-block-2 (C-v still works for that)
map("n", "<C-q>", ":qa<CR>", { silent = true, desc = "Quit all" })

-- ── Format ─────────────────────────────────────────────────────────────────
-- Format-on-save handles this automatically (configured in editor.lua).
-- C-\ is reserved for toggleterm. Manual format via Alt+L (like IntelliJ Ctrl+Alt+L).
map("n", "<M-l>", function()
  require("conform").format({ async = true, lsp_fallback = true })
end, { desc = "Format file" })

-- ── LSP actions ───────────────────────────────────────────────────────────
map("n", "<F2>",  vim.lsp.buf.rename,                   { desc = "Rename symbol" })
map("n", "<F4>", function()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    vim.notify("No LSP attached to this buffer", vim.log.levels.WARN)
    return
  end
  vim.lsp.buf.code_action()
end, { desc = "Code action" })
map("n", "<F12>", "<cmd>Telescope lsp_definitions<CR>", { desc = "Go to definition" })

-- ── Diagnostics ────────────────────────────────────────────────────────────
map("n", "]d",   vim.diagnostic.goto_next,              { desc = "Next diagnostic" })
map("n", "[d",   vim.diagnostic.goto_prev,              { desc = "Prev diagnostic" })
map("n", "<M-e>", vim.diagnostic.open_float,            { desc = "Show diagnostic detail" })
map("n", "<M-x>", "<cmd>Trouble diagnostics toggle<CR>",{ desc = "Diagnostics list" })

-- ── Debug (F5-F11) ─────────────────────────────────────────────────────────
-- Adapters configured in plugins/debug.lua
-- F5  = Continue/Start    F9  = Toggle breakpoint
-- F6  = Step over         F10 = Terminate
-- F7  = Step into         F11 = Toggle DAP UI
-- F8  = Step out
-- NOTE: Java ftplugin overrides F9/F10/F11 with test shortcuts (buffer-local)

-- ── LSP navigation (standard vim keys — kept universal) ───────────────────
-- gd  = definition     (also F12 above)
-- gD  = declaration
-- gr  = references
-- gi  = implementations
-- K   = hover docs
-- C-k = signature help  (set in lsp.lua on_attach)
-- These are set per-buffer inside on_attach in lsp.lua

-- ── Buffer tabs ────────────────────────────────────────────────────────────
map("n", "<S-l>", ":bnext<CR>",     { silent = true, desc = "Next buffer" })
map("n", "<S-h>", ":bprevious<CR>", { silent = true, desc = "Prev buffer" })
map("n", "<C-w>", ":bdelete<CR>",   { silent = true, desc = "Close buffer" })

-- ── Split windows ──────────────────────────────────────────────────────────
map("n", "<C-S-v>", ":vsplit<CR>",  { silent = true, desc = "Split vertical" })
map("n", "<C-S-x>", ":split<CR>",   { silent = true, desc = "Split horizontal" })
map("n", "<C-S-o>", "<C-w>o",       { silent = true, desc = "Close all other splits" })

-- ── AI (Claude CLI — no API key needed) ─────────────────────────────────────
local ai = function(fn) return function() require("claude_cli")[fn]() end end

map("n", "<C-g>",  ai("toggle_chat"),    { desc = "AI: Toggle Claude panel" })
map("n", "<C-a>",  ai("prompt"),         { desc = "AI: Ask Claude anything" })
-- Visual mode — select code first, then press the shortcut
map("v", "<C-1>",  ai("explain"),        { desc = "AI: Explain code" })
map("v", "<C-2>",  ai("refactor"),       { desc = "AI: Refactor code" })
map("v", "<C-3>",  ai("generate_tests"), { desc = "AI: Generate tests" })
map("v", "<C-4>",  ai("fix"),            { desc = "AI: Fix code" })
map("v", "<C-5>",  ai("generate_docs"),  { desc = "AI: Generate docs" })
map("v", "<C-6>",  ai("ask_about"),      { desc = "AI: Ask about selection" })

-- ── Git ────────────────────────────────────────────────────────────────────
-- Alt+G = LazyGit (set in plugins/terminal.lua)
-- ]g / [g = next/prev hunk (set in gitsigns on_attach)
map("n", "<M-b>", "<cmd>Gitsigns blame_line<CR>",   { desc = "Git: Blame line" })
map("n", "<M-z>", "<cmd>Gitsigns preview_hunk<CR>", { desc = "Git: Preview hunk" })

-- ── Java (buffer-local, set in ftplugin/java.lua) ─────────────────────────
-- F9  → Organize imports        (overrides global F9 = breakpoint)
-- F10 → Run nearest test        (overrides global F10 = terminate)
-- F11 → Run all tests in class  (overrides global F11 = DAP UI)

-- ── Editing helpers ────────────────────────────────────────────────────────
-- Move selected lines up/down in visual mode
map("v", "J", ":m '>+1<CR>gv=gv", { silent = true, desc = "Move selection down" })
map("v", "K", ":m '<-2<CR>gv=gv", { silent = true, desc = "Move selection up" })

-- Scroll and keep cursor centred
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("n", "n", "nzzzv")
map("n", "N", "Nzzzv")

-- Paste over selection without losing yanked text
map("x", "<C-S-p>", '"_dP', { desc = "Paste without overwriting register" })

-- Copy to system clipboard
map({ "n", "v" }, "<C-y>", '"+y', { desc = "Copy to system clipboard" })
map("n", "<C-S-y>", '"+Y',        { desc = "Copy line to system clipboard" })

-- ── Comment (Ctrl+/) ───────────────────────────────────────────────────────
-- Terminals send Ctrl+/ as <C-_> (control underscore)
local comment_line = function()
  require("Comment.api").toggle.linewise.current()
end
local comment_visual = function()
  local esc = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
  require("Comment.api").toggle.linewise(vim.fn.visualmode())
end

map("n", "<C-_>", comment_line,    { desc = "Toggle comment" })
map("v", "<C-_>", comment_visual,  { desc = "Toggle comment" })
map("n", "<C-/>", comment_line,    { desc = "Toggle comment" })
map("v", "<C-/>", comment_visual,  { desc = "Toggle comment" })

-- Clear search highlight
map("n", "<Esc>", ":nohlsearch<CR>", { silent = true })

-- ── Logs / Diagnostics ────────────────────────────────────────────────────
-- LSP log: warnings/errors from language servers
map("n", "<F1>", "<cmd>LspLog<CR>", { desc = "Open LSP log" })
-- Notification history: browse past notifications in Telescope
map("n", "<C-S-n>", "<cmd>Telescope notify<CR>", { desc = "Notification history" })
-- Neovim runtime log
map("n", "<C-S-l>", function()
  vim.cmd("edit " .. vim.fn.stdpath("log") .. "/nvim.log")
end, { desc = "Open Neovim log" })
