local map = vim.keymap.set

-- ── Drop core's gr-prefixed LSP defaults (nvim 0.11+) ─────────────────────
-- Neovim maps grn/gra/grr/gri/grt/grx (plus gra in visual mode) itself, in
-- runtime/lua/vim/_defaults.lua. Every one of them shares a prefix with this
-- config's own `gr` (references, bound per-buffer in plugins/lsp.lua's
-- on_attach), which makes `gr` an *ambiguous* prefix: nvim then has to wait the
-- full 'timeoutlen' (300ms here) on every press to learn whether a second key
-- is coming, so jumping to references stalls first, every time.
--
-- Nothing is lost — each default already has an equivalent bound here or in
-- plugins/lsp.lua: grn -> <leader>rn (and <F2>), gra -> <leader>ca (and
-- <F4>/<C-.>), grr -> gr, gri -> gi, grt -> <leader>lt, grx -> <leader>cl
-- (ftplugin/java.lua's own cursor-line code-lens runner; nothing in this config
-- renders lenses through vim.lsp.codelens, so its run() had nothing to run).
--
-- pcall, not a bare del: deleting a mapping that was never set raises E31, and
-- these are only there from 0.11 onwards.
for _, lhs in ipairs({ "grn", "gra", "grr", "gri", "grt", "grx" }) do
  pcall(vim.keymap.del, "n", lhs)
end
pcall(vim.keymap.del, "x", "gra")

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
map("n", "<C-Up>",    ":resize +2<CR>",          { silent = true, desc = "Resize split taller" })
map("n", "<C-Down>",  ":resize -2<CR>",          { silent = true, desc = "Resize split shorter" })
map("n", "<C-Left>",  ":vertical resize -2<CR>", { silent = true, desc = "Resize split narrower" })
map("n", "<C-Right>", ":vertical resize +2<CR>", { silent = true, desc = "Resize split wider" })
-- The four above are dead keys on this platform, and both obvious alternates are
-- taken: macOS claims plain Ctrl+arrow for Mission Control (switch Spaces /
-- Exposé) at the OS level, and Ghostty hard-binds Cmd+arrow to shell readline
-- (start/end-of-line) and scrollback prompt-jump — so neither ever reaches nvim.
-- Ctrl+Shift+arrow is unclaimed by both and is the one that actually arrives
-- (Ghostty's side verified against `ghostty +show-config --default`).
--
-- Ctrl+arrow is left in place rather than replaced: these mappings cost nothing
-- when the keys never fire, and keeping them means this file stays a superset of
-- main's rather than a divergence, so future merges only ever add.
map("n", "<C-S-Up>",    ":resize +2<CR>",          { silent = true, desc = "Resize split taller (macOS)" })
map("n", "<C-S-Down>",  ":resize -2<CR>",          { silent = true, desc = "Resize split shorter (macOS)" })
map("n", "<C-S-Left>",  ":vertical resize -2<CR>", { silent = true, desc = "Resize split narrower (macOS)" })
map("n", "<C-S-Right>", ":vertical resize +2<CR>", { silent = true, desc = "Resize split wider (macOS)" })

-- ── File explorer ──────────────────────────────────────────────────────────
-- overrides: C-e (scroll 1 line) — use C-d/C-u for scrolling instead
map("n", "<C-e>", ":NvimTreeToggle<CR>",   { silent = true, desc = "Toggle explorer" })
map("n", "<C-S-e>", ":NvimTreeFindFile<CR>", { silent = true, desc = "Reveal file in explorer" })
map("n", "<D-b>", ":NvimTreeToggle<CR>",   { silent = true, desc = "Toggle explorer (macOS)" })

-- ── Telescope / Search ─────────────────────────────────────────────────────
-- C-p     = find files  (like VS Code)       overrides: prev completion (Tab still works)
-- leader+/ = live grep  (like "Find in Files") — see note below on why not a Ctrl+Shift combo
-- C-b     = open buffers                      overrides: page-back      (C-u still scrolls)
-- C-t     = recent files                      overrides: tag-jump       (rarely used)
map("n", "<C-p>", "<cmd>Telescope find_files<CR>",  { desc = "Find files" })
-- leader+/ (not Ctrl+Shift+F): terminal emulators commonly claim Ctrl+Shift+F
-- as their own "find in terminal" shortcut, which swallows the keypress
-- before Neovim ever sees it. leader (Space) has no modifier key for a
-- terminal to intercept, so it always reaches Neovim.
map("n", "<leader>/", function() require("telescope.builtin").live_grep() end, { desc = "Live grep (search in files)" })
map("n", "<C-b>", "<cmd>Telescope buffers<CR>", { desc = "Switch buffer" })
map("n", "<C-t>", "<cmd>Telescope oldfiles<CR>",    { desc = "Recent files" })
map("n", "<D-p>", "<cmd>Telescope find_files<CR>",  { desc = "Find files (macOS)" })

-- ── Save / Quit ────────────────────────────────────────────────────────────
map({ "n", "i" }, "<C-s>", "<Esc>:w<CR>",  { silent = true, desc = "Save file" })
map({ "n", "i" }, "<D-s>", "<Esc>:w<CR>",  { silent = true, desc = "Save file (macOS)" })
-- C-q: overrides visual-block-2 (C-v still works for that)
map("n", "<C-q>", ":qa<CR>", { silent = true, desc = "Quit all" })

-- ── Format ─────────────────────────────────────────────────────────────────
-- Format-on-save handles this automatically (configured in editor.lua).
-- C-\ is reserved for toggleterm. Manual format via Alt+L (like IntelliJ Ctrl+Alt+L).
-- lsp_format = "fallback", not the old lsp_fallback = true: conform still
-- translates the old key (conform/init.lua's "For backwards compatibility"
-- block) but it is deprecated and undocumented now, so a future release
-- dropping it would silently turn every Java/XML format into a no-op — those
-- filetypes have no entry in formatters_by_ft and are formatted by their
-- language server through exactly this option.
map("n", "<M-l>", function()
  require("conform").format({ async = true, lsp_format = "fallback" })
end, { desc = "Format file" })

-- ── LSP actions ───────────────────────────────────────────────────────────
map("n", "<F2>",  vim.lsp.buf.rename,                   { desc = "Rename symbol" })
local function code_action()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    vim.notify("No LSP attached to this buffer", vim.log.levels.WARN)
    return
  end
  vim.lsp.buf.code_action()
end
map("n", "<F4>", code_action, { desc = "Code action" })
map("n", "<C-.>", code_action, { desc = "Code action (VS Code-style quick fix)" })
map("n", "<F12>", "<cmd>Telescope lsp_definitions<CR>", { desc = "Go to definition" })

-- ── Diagnostics ────────────────────────────────────────────────────────────
-- vim.diagnostic.goto_next/goto_prev are deprecated and slated for removal in
-- nvim 0.13; vim.diagnostic.jump is the replacement. (lsp.lua's on_attach binds
-- buffer-local [d/]d the same way — these globals are the fallback for buffers
-- with no LSP client attached.)
map("n", "]d", function() vim.diagnostic.jump({ count = 1,  float = true }) end, { desc = "Next diagnostic" })
map("n", "[d", function() vim.diagnostic.jump({ count = -1, float = true }) end, { desc = "Prev diagnostic" })
map("n", "<M-e>", vim.diagnostic.open_float,            { desc = "Show diagnostic detail" })
map("n", "<M-x>", "<cmd>Trouble diagnostics toggle<CR>",{ desc = "Diagnostics list" })

-- ── Debug (F5-F11) ─────────────────────────────────────────────────────────
-- Adapters configured in plugins/debug.lua
-- F5  = Continue/Start    F9  = Toggle breakpoint
-- F6  = Step over         F10 = Terminate
-- F7  = Step into         F11 = Toggle DAP UI
-- F8  = Step out
-- NOTE: Java ftplugin overrides F9/F10/F11 with test shortcuts (buffer-local)

-- ── Run / Debug the project (leader+r) ─────────────────────────────────────
-- The keyboard half of the toolbar in the statusline (lua/config/runner.lua,
-- spliced into lualine in plugins/ui.lua); :Run / :RunStop / … do the same. The
-- runner picks the target from the current buffer, so these work the same in a
-- Spring, plain-Java, Angular or node project — and in a monorepo containing
-- several, they act on the one the open file belongs to.
--
-- leader+r, not more F-keys or Ctrl+Shift combos: F5-F11 are already the DAP
-- stepping keys (above), and a Ctrl+Shift+F-key can be claimed by the terminal
-- emulator before Neovim sees it — the same reason leader+/ is the grep key.
-- No conflict with <leader>rn (lsp rename): that is buffer-local to an attached
-- LSP client, and which-key shows both.
local run = function(action) return function() require("config.runner").dispatch(action) end end
map("n", "<leader>rr", run("run"),     { desc = "Run project" })
map("n", "<leader>rR", run("restart"), { desc = "Restart project" })
map("n", "<leader>rs", run("stop"),    { desc = "Stop project" })
map("n", "<leader>rd", run("debug"),   { desc = "Debug project (attaches automatically)" })
map("n", "<leader>ra", run("attach"),  { desc = "Attach debugger to a running process" })

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
map("n", "<C-w>", function() require("bufdelete").bufdelete(0, false) end, { silent = true, desc = "Close buffer" })

-- ── Split windows ──────────────────────────────────────────────────────────
map("n", "<C-S-v>", ":vsplit<CR>",  { silent = true, desc = "Split vertical" })
map("n", "<C-S-x>", ":split<CR>",   { silent = true, desc = "Split horizontal" })
map("n", "<C-S-o>", "<C-w>o",       { silent = true, desc = "Close all other splits" })

-- ── AI (Claude CLI — no API key needed) ─────────────────────────────────────
local ai = function(fn) return function() require("claude_cli")[fn]() end end

map("n", "<C-g>",  ai("toggle_chat"),    { desc = "AI: Toggle Claude panel" })
map("n", "<C-a>",  ai("prompt"),         { desc = "AI: Ask Claude anything" })
-- Visual mode — select code first, then press the shortcut.
-- Mode "x" (visual), NOT "v". "v" means visual + SELECT mode, and select mode is
-- what LuaSnip puts you in when it selects a snippet placeholder: there, any
-- printable key is supposed to replace the selection. A "v" mapping hijacks that,
-- so typing over a placeholder ran these commands instead of editing the text.
map("x", "<C-1>",  ai("explain"),        { desc = "AI: Explain code" })
map("x", "<C-2>",  ai("refactor"),       { desc = "AI: Refactor code" })
map("x", "<C-3>",  ai("generate_tests"), { desc = "AI: Generate tests" })
map("x", "<C-4>",  ai("fix"),            { desc = "AI: Fix code" })
map("x", "<C-5>",  ai("generate_docs"),  { desc = "AI: Generate docs" })
map("x", "<C-6>",  ai("ask_about"),      { desc = "AI: Ask about selection" })

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
-- Move selected lines up/down in visual mode.
-- "x" not "v": with "v" these also bound SELECT mode, where J/K are ordinary
-- printable characters — so typing J or K over a LuaSnip placeholder moved lines
-- around instead of replacing the placeholder text.
map("x", "J", ":m '>+1<CR>gv=gv", { silent = true, desc = "Move selection down" })
map("x", "K", ":m '<-2<CR>gv=gv", { silent = true, desc = "Move selection up" })

-- Move current line up/down in normal mode (no selection needed)
map("n", "<M-j>", ":m .+1<CR>==", { silent = true, desc = "Move line down" })
map("n", "<M-k>", ":m .-2<CR>==", { silent = true, desc = "Move line up" })

-- Scroll and keep cursor centred
map("n", "<C-d>", "<C-d>zz", { desc = "Scroll down, cursor centred" })
map("n", "<C-u>", "<C-u>zz", { desc = "Scroll up, cursor centred" })
map("n", "n", "nzzzv", { desc = "Next search match, centred" })
map("n", "N", "Nzzzv", { desc = "Prev search match, centred" })

-- Paste over selection without losing yanked text
map("x", "<C-S-p>", '"_dP', { desc = "Paste without overwriting register" })

-- Copy to system clipboard
map({ "n", "x" }, "<C-y>", '"+y', { desc = "Copy to system clipboard" })
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
map("x", "<C-_>", comment_visual,  { desc = "Toggle comment" })
map("n", "<C-/>", comment_line,    { desc = "Toggle comment" })
map("x", "<C-/>", comment_visual,  { desc = "Toggle comment" })
-- Cmd+/ is what every editor on this platform uses for comment-toggle, and
-- Ghostty passes it through. Mode "x", not "v", for the same reason the Ctrl
-- variants above use it: "v" covers visual *and* select mode, and select mode is
-- where LuaSnip puts you on a snippet placeholder — there a printable key is
-- meant to replace the selection, so a "v" mapping made typing over a
-- placeholder toggle comments instead.
map("n", "<D-/>", comment_line,    { desc = "Toggle comment (macOS)" })
map("x", "<D-/>", comment_visual,  { desc = "Toggle comment (macOS)" })

-- Clear search highlight
map("n", "<Esc>", ":nohlsearch<CR>", { silent = true, desc = "Clear search highlight" })

-- ── Logs / Diagnostics ────────────────────────────────────────────────────
-- A log is a live-appended file this config's own autocmds would otherwise treat
-- as source code: auto-save writes any modified buffer with an empty buftype on
-- BufLeave, so one stray keystroke in a multi-megabyte log would be written back
-- over the file Neovim is still appending to. readonly + nomodifiable makes that
-- impossible (auto-save only writes `modified` buffers), and auto-reload's
-- checktime then keeps the view current as new lines arrive.
--
-- In a new tab because these are consulted *about* what you were doing: `:edit`
-- replaced the file you were working in, which is also why nvim-lspconfig's own
-- :LspLog used tabnew.
local function open_log(path)
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  vim.bo.readonly = true
  vim.bo.modifiable = false
end

-- LSP log: warnings/errors from language servers.
-- NOT `:LspLog`. nvim-lspconfig's plugin/lspconfig.lua returns early when `:lsp`
-- already exists, and Neovim 0.12 ships it — so lspconfig registers no Lsp*
-- command at all and <F1> raised E492. 0.12's own `:lsp` only takes
-- enable/disable/restart/stop, with no log subcommand, so open the file itself.
-- (`:checkhealth vim.lsp` is what replaced `:LspInfo`.)
map("n", "<F1>", function() open_log(vim.lsp.log.get_filename()) end, { desc = "Open LSP log" })
-- Notification history: browse past notifications in Telescope
map("n", "<C-S-n>", "<cmd>Telescope notify<CR>", { desc = "Notification history" })
-- Neovim runtime log
map("n", "<C-S-l>", function()
  open_log(vim.fn.stdpath("log") .. "/nvim.log")
end, { desc = "Open Neovim log" })
