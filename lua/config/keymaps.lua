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
-- VS Code's sidebar toggle. <C-e> is kept as well rather than replaced: it is
-- what this config has always used, and a second lhs on the same command costs
-- nothing. Ctrl+B was free to take because the buffer list it used to open has
-- moved to <leader>bb — see the Telescope section below.
map("n", "<C-b>", ":NvimTreeToggle<CR>",   { silent = true, desc = "Toggle explorer (sidebar)" })
-- Cmd+B is both VS Code's sidebar chord on macOS and one of the handful of Cmd
-- keys Ghostty leaves alone, so the Mac alias and the VS Code chord are the
-- same key here. Both of the above stay: this is an alias, not a replacement.
map("n", "<D-b>", ":NvimTreeToggle<CR>",   { silent = true, desc = "Toggle explorer (macOS)" })

-- ── Telescope / Search ─────────────────────────────────────────────────────
-- The VS Code chords, in the order their names appear in its Command Palette:
-- C-p   = Go to File              overrides: prev completion (Tab still works)
-- C-S-p = Command Palette
-- C-f   = Find (in this file)     overrides: page-forward    (C-d/C-u scroll)
-- C-S-f = Find in Files           (leader+/ does the same — see below)
--
-- The buffer list and the recent-files list used to be on C-b and C-t, which
-- VS Code spends on the sidebar and on Go to Symbol in Workspace. They moved to
-- <leader>bb and <leader>fr, under the "buffer" and "find / format" which-key
-- groups that lua/plugins/ui.lua already declares.
map("n", "<C-p>", "<cmd>Telescope find_files<CR>",  { desc = "Find files" })
-- leader+/ stays the primary "find in files" key and C-S-f is the alias, not the
-- other way round. Measured, not assumed: `ghostty +list-keybinds --default` on
-- this machine binds ctrl+shift+f to nothing (only super+shift+f=end_search), so
-- the chord does reach Neovim here — but Ctrl+Shift+F is the stock "find" binding
-- in GNOME Terminal, Konsole and xfce4-terminal, which is where this branch is
-- aimed. leader (Space) carries no modifier for a terminal to claim, so it is the
-- one that always works.
map("n", "<leader>/", function() require("telescope.builtin").live_grep() end, { desc = "Live grep (search in files)" })
map("n", "<C-S-f>", function() require("telescope.builtin").live_grep() end, { desc = "Find in files" })
-- `/` rather than a fuzzy picker: VS Code's find box highlights every match and
-- steps through them with Enter, which is what incsearch + hlsearch + n/N already
-- do here — and n/N are centred (see the editing helpers below). A
-- current_buffer_fuzzy_find would be a different feature wearing this key's name.
map("n", "<C-f>", "/", { desc = "Find in this file" })
-- Telescope's `commands` picker is the closest thing to the Command Palette: it
-- lists every user command with its description and runs the chosen one.
map("n", "<C-S-p>", "<cmd>Telescope commands<CR>", { desc = "Command palette" })
map("n", "<leader>bb", "<cmd>Telescope buffers<CR>", { desc = "Switch buffer" })
map("n", "<leader>fr", "<cmd>Telescope oldfiles<CR>", { desc = "Recent files" })
map("n", "<D-p>", "<cmd>Telescope find_files<CR>",  { desc = "Find files (macOS)" })

-- ── Save / Quit ────────────────────────────────────────────────────────────
map({ "n", "i" }, "<C-s>", "<Esc>:w<CR>",  { silent = true, desc = "Save file" })
map({ "n", "i" }, "<D-s>", "<Esc>:w<CR>",  { silent = true, desc = "Save file (macOS)" })
-- C-q: overrides visual-block-2 (C-v still works for that)
map("n", "<C-q>", ":qa<CR>", { silent = true, desc = "Quit all" })

-- ── Select all / go to line ────────────────────────────────────────────────
-- Both were free to take because the AI panel and prompt that held them have
-- moved under the <leader>a group (see the AI section below).
--
-- overrides: C-a (increment the number under the cursor). The increment pair is
-- C-a/C-x and only C-a is taken here, so g C-a in visual mode — which is the one
-- that actually gets used, for renumbering a block — is untouched.
map("n", "<C-a>", "ggVG", { desc = "Select all" })
-- overrides: C-g (show the current file's name and position), which is a
-- statusline away.
--
-- A prompt rather than `:`, because the point of the VS Code chord is that you
-- type a bare number: `:` would need the number *and* Enter with nothing
-- validating it, and a typo there runs an Ex command. tonumber rejects anything
-- that is not a line number, and an empty answer (Esc) cancels.
map("n", "<C-g>", function()
  vim.ui.input({ prompt = "Go to line: " }, function(answer)
    local line = tonumber(answer)
    if not line then return end
    -- Clamp rather than error: VS Code's Go to Line takes you to the end of the
    -- file when the number is past it, and `:normal! 9999G` would beep instead.
    line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(0)))
    vim.cmd("normal! " .. line .. "Gzz")
  end)
end, { desc = "Go to line" })

-- ── Format ─────────────────────────────────────────────────────────────────
-- Format-on-save handles this automatically (configured in editor.lua) and is
-- on by default; leader+uf turns it off and on for the session. Alt+L formats
-- on demand and works either way. C-\ is reserved for toggleterm, and Alt+L
-- matches IntelliJ's Ctrl+Alt+L.
--
-- lsp_format = "fallback", not the old lsp_fallback = true: conform still
-- translates the old key (conform/init.lua's "For backwards compatibility"
-- block) but it is deprecated and undocumented now, so a future release
-- dropping it would silently turn every Java/XML format into a no-op — those
-- filetypes have no entry in formatters_by_ft and are formatted by their
-- language server through exactly this option.
local function format_buffer()
  require("conform").format({ async = true, lsp_format = "fallback" })
end
map("n", "<M-l>", format_buffer, { desc = "Format file" })
-- Shift+Alt+F is VS Code's "Format Document" on Windows/Linux, and Alt+L stays
-- because it is what this config has used and what IntelliJ trains. Shift+Alt+F
-- normalises to <M-F>, which is a different lhs from grug-far's <M-f> — the
-- <M-t>/<M-T> pair in lua/plugins/testing.lua relies on the same distinction.
map("n", "<M-F>", format_buffer, { desc = "Format file (VS Code Shift+Alt+F)" })
-- Under the existing leader+u "ui toggles" group (see plugins/ui.lua's which-key
-- spec), alongside leader+uh for inlay hints, rather than another Alt chord.
map("n", "<leader>uf", function()
  require("config.format").toggle()
end, { desc = "Toggle format on save" })
-- The other half of save-time rewriting, for JS/TS only: eslint --fix runs on
-- BufWritePre and prettier on BufWritePost, so prettier wins wherever they
-- disagree and the pair can churn the same character on every save. This turns
-- off the lint autofix (import sorting, unused vars) and keeps formatting;
-- leader+uf still turns off both.
map("n", "<leader>ul", function()
  require("config.format").toggle_lint_fix()
end, { desc = "Toggle eslint fix on save" })

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
-- VS Code's Problems panel. Same window as Alt+X, which stays: this is the
-- chord VS Code trains and that one is the chord this config trained.
map("n", "<C-S-m>", "<cmd>Trouble diagnostics toggle<CR>", { desc = "Problems panel" })
-- Build problems, which are a different list from diagnostics above and arrive
-- from a different place: diagnostics come from the language server's view of the
-- open file, this is what the *build* said (lua/config/problems.lua parses the
-- run terminal's output into quickfix on exit). The two disagree often enough to
-- matter — jdtls compiles with its own classpath, so an annotation processor or a
-- Gradle sourceSet it does not model produces errors that only the build sees.
--
-- Through Trouble rather than :copen for the same reason <M-x> is: the same
-- window, the same keys, and a preview. `]q`/`[q` walk the list without opening
-- anything and are Neovim 0.11 defaults, so there is nothing to bind for those.
map("n", "<M-q>", "<cmd>Trouble qflist toggle<CR>",     { desc = "Build problems (quickfix)" })

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
-- Everything the project can build that is not "start the app": test, lint,
-- clean, dependency:tree, any npm script. Same group because it is the same
-- detection — lua/config/tasks.lua is a picker over config.runner's target, not a
-- second guess at which project this is.
map("n", "<leader>rt", function() require("config.tasks").pick() end,
  { desc = "Run a build task (test, lint, clean, …)" })

-- ── Counterpart file (class ↔ test, component ↔ template) ─────────────────
-- lua/config/alternate.lua works out the path from the project layout; this is
-- just the trigger, and it requires the module lazily so nothing is parsed at
-- startup for a key that may not be pressed.
--
-- Under the existing leader+f "find / format" group rather than on an Alt chord,
-- and the reason is worth recording because it cost a debug run to find: this was
-- <M-o> ("other file") first, and every Alt letter that reads as "alternate",
-- "other" or "test" is already taken by neotest's lazy `keys` spec
-- (lua/plugins/testing.lua binds <M-t>, <M-T> and <M-o>). A lazy keys entry
-- creates its stub mapping when lazy.setup runs, i.e. *after* init.lua has
-- sourced this file — so the collision silently replaced the mapping here and
-- <M-o> opened neotest's output panel instead. tests/unit/plugin_specs_spec.lua
-- now fails on that class of collision rather than leaving it to be noticed.
--
-- IntelliJ's own Ctrl+Shift+T was rejected up front for a different reason:
-- Ghostty and most other terminal emulators bind it to "new tab" and never
-- forward it, so the mapping would register in Neovim and still do nothing.
--
-- :A as well, after a.vim's command, because it is what the muscle memory of
-- anyone who has used that plugin reaches for.
local alternate = function() require("config.alternate").toggle() end
map("n", "<leader>fa", alternate, { desc = "Open counterpart file (test / template)" })
vim.api.nvim_create_user_command("A", alternate, {
  desc = "Open the counterpart of this file (class <-> test, component <-> template)",
})

-- ── LSP navigation (standard vim keys — kept universal) ───────────────────
-- gd  = definition     (also F12 above)
-- gD  = declaration
-- gr  = references
-- gi  = implementations
-- K   = hover docs
-- <leader>lk / insert <M-k> = signature help. NOT <C-k>, which is window-up
-- above: a buffer-local mapping beats a global one, so an LSP <C-k> killed
-- window-up in exactly the buffers it is used in. See lsp.lua's gate call.
-- These are set per-buffer inside on_attach in lsp.lua

-- ── Buffer tabs ────────────────────────────────────────────────────────────
map("n", "<S-l>", ":bnext<CR>",     { silent = true, desc = "Next buffer" })
map("n", "<S-h>", ":bprevious<CR>", { silent = true, desc = "Prev buffer" })
map("n", "<C-w>", function() require("bufdelete").bufdelete(0, false) end, { silent = true, desc = "Close buffer" })

-- ── Split windows ──────────────────────────────────────────────────────────
map("n", "<C-S-v>", ":vsplit<CR>",  { silent = true, desc = "Split vertical" })
map("n", "<C-S-x>", ":split<CR>",   { silent = true, desc = "Split horizontal" })
-- Was <C-S-o>, which VS Code spends on Go to Symbol in File — that is now bound
-- per-buffer in lua/plugins/lsp.lua, where the document-symbol capability can be
-- checked first. <leader>s is the "split" which-key group lua/plugins/ui.lua
-- already declares and had no members until now.
--
-- Ctrl+Shift+V and Ctrl+Shift+X are deliberately NOT given up, even though VS
-- Code uses them for Markdown Preview and the Extensions view: splitting is a
-- keystroke that gets pressed all day here, and `:Lazy` is not. VS Code's own
-- split key, Ctrl+\, belongs to toggleterm (lua/plugins/terminal.lua).
map("n", "<leader>so", "<C-w>o",    { silent = true, desc = "Close all other splits" })

-- ── AI (Claude CLI — no API key needed) ─────────────────────────────────────
-- Under the <leader>a group ("AI (Claude)" in lua/plugins/ui.lua's which-key
-- spec, which was declared for this and had no members). The panel and the
-- prompt were on C-g and C-a, which VS Code spends on Go to Line and Select All;
-- these are the two the rest of this file's VS Code alignment needed back.
local ai = function(fn) return function() require("claude_cli")[fn]() end end

map("n", "<leader>aa", ai("toggle_chat"), { desc = "AI: Toggle Claude panel" })
map("n", "<leader>ap", ai("prompt"),      { desc = "AI: Ask Claude anything" })
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
-- VS Code puts these on Alt+Up/Down. Alt+j/k stays as the home-row version, so
-- both habits work; the arrows are what a VS Code user reaches for first.
map("n", "<M-Down>", ":m .+1<CR>==", { silent = true, desc = "Move line down" })
map("n", "<M-Up>",   ":m .-2<CR>==", { silent = true, desc = "Move line up" })
-- And the visual-mode halves, so a selection moves with the same chord it moves
-- with in VS Code. Same rhs as J/K above, "x" for the same select-mode reason.
map("x", "<M-Down>", ":m '>+1<CR>gv=gv", { silent = true, desc = "Move selection down" })
map("x", "<M-Up>",   ":m '<-2<CR>gv=gv", { silent = true, desc = "Move selection up" })

-- Duplicate the current line up/down — VS Code's Shift+Alt+Up/Down.
-- `:t .` copies the line to just after itself, so the cursor ends on the
-- original and `:t .-1` would leave it on the copy; the explicit motion after
-- each keeps the cursor on the *new* line both ways, which is what VS Code does.
-- Shift+Alt+Up normalises to <M-S-Up> (verified with nvim_get_keymap), so that is
-- the spelling used here — writing <S-M-Up> would store the same mapping under a
-- name the tests' text scan would not match.
map("n", "<M-S-Down>", ":t .<CR>",       { silent = true, desc = "Copy line down" })
map("n", "<M-S-Up>",   ":t .-1<CR>k",    { silent = true, desc = "Copy line up" })

-- Delete the whole line — VS Code's Ctrl+Shift+K. In visual mode it takes the
-- selected lines, which is what VS Code does with a selection active.
map("n", "<C-S-k>", "dd", { silent = true, desc = "Delete line" })
map("x", "<C-S-k>", "d",  { silent = true, desc = "Delete selected lines" })

-- Insert a blank line below/above without splitting the current one and without
-- leaving insert mode — VS Code's Ctrl+Enter and Ctrl+Shift+Enter.
--
-- These need a terminal that encodes modified Enter (the kitty keyboard
-- protocol, or anything else sending CSI-u); Ghostty does, and binds neither
-- chord itself. In a terminal that does not, the keypress arrives as a plain
-- <CR> and these never fire — nothing breaks, the shortcut is just absent, which
-- is why `o`/`O` are not being replaced.
-- All four land in insert mode on the new line, which is where VS Code leaves
-- you: there it is the only mode, so "insert line below" always means "and keep
-- typing there". `o`/`O` from normal mode rather than `o<Esc>` for that reason.
map("n", "<C-CR>",   "o", { silent = true, desc = "Insert line below" })
map("n", "<C-S-CR>", "O", { silent = true, desc = "Insert line above" })
map("i", "<C-CR>",   "<Esc>o", { silent = true, desc = "Insert line below" })
map("i", "<C-S-CR>", "<Esc>O", { silent = true, desc = "Insert line above" })

-- Scroll and keep cursor centred
map("n", "<C-d>", "<C-d>zz", { desc = "Scroll down, cursor centred" })
map("n", "<C-u>", "<C-u>zz", { desc = "Scroll up, cursor centred" })
map("n", "n", "nzzzv", { desc = "Next search match, centred" })
map("n", "N", "Nzzzv", { desc = "Prev search match, centred" })

-- Paste over selection without losing yanked text.
-- Was <C-S-p>, which is now the Command Palette (see the Telescope section). It
-- had to move rather than coexist: the palette is a normal-mode mapping and this
-- is a visual-mode one, so nothing would have errored — the same chord would just
-- have done two unrelated things depending on the mode, which is the kind of
-- keymap that is impossible to remember.
map("x", "<leader>p", '"_dP', { desc = "Paste without overwriting register" })

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

-- Block comment — VS Code's Shift+Alt+A. The linewise toggles above comment each
-- line with `//`; this wraps the region in `/* */` instead, which is the
-- distinction VS Code draws between Ctrl+/ and Shift+Alt+A. Comment.nvim exposes
-- it as a separate api namespace (toggle.blockwise), so this is its own pair of
-- callbacks rather than a flag on the ones above.
local block_comment_line = function()
  require("Comment.api").toggle.blockwise.current()
end
local block_comment_visual = function()
  local esc = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
  require("Comment.api").toggle.blockwise(vim.fn.visualmode())
end
map("n", "<M-A>", block_comment_line,   { desc = "Toggle block comment" })
map("x", "<M-A>", block_comment_visual, { desc = "Toggle block comment" })

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
