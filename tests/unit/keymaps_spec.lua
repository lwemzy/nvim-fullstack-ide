-- config.keymaps — the global mapping table.
--
-- The centre of this file is one table listing every mapping the config defines
-- and one test that walks it. That table is cross-checked against the *text* of
-- lua/config/keymaps.lua in both directions, so it cannot rot: adding a mapping
-- to the config without adding it here fails, and deleting one from the config
-- fails too. Without that, a table-driven test slowly becomes a list of the
-- mappings that happened to exist when it was written.
--
-- Nothing here invokes a mapping that quits, writes, opens a terminal, or calls
-- a plugin: unit mode loads no plugins at all, so <C-e> (NvimTree), <C-p>
-- (Telescope), <C-g> (claude_cli) and the comment mappings can only be checked
-- structurally.

local H = require("helpers")

local keymaps_path = _G.NVIM_IDE_TEST.config_dir .. "/lua/config/keymaps.lua"

-- config.keymaps is a script whose whole effect is its vim.keymap.set calls, so
-- the require cache has to be dropped for a spec to observe a real execution.
local function load_keymaps()
  package.loaded["config.keymaps"] = nil
  require("config.keymaps")
end

--- Every (mode, lhs) pair the file's `map(...)` calls define, read from the
--- source text rather than from maparg.
---
--- Parsing the text (not counting maparg hits) is deliberate: maparg cannot tell
--- a mapping this file defined from one the test init or another module defined,
--- and — the case that matters for the duplicate check below — two `map` calls
--- for the same mode+lhs leave exactly one maparg entry, so a shadowed mapping
--- is invisible from the runtime side by construction.
local function parsed_mappings()
  local out = {}
  for _, line in ipairs(vim.fn.readfile(keymaps_path)) do
    local modes, lhs = line:match('^map%(%s*(%b{})%s*,%s*"([^"]*)"')
    if not modes then
      local single
      single, lhs = line:match('^map%(%s*"([^"]*)"%s*,%s*"([^"]*)"')
      if single then modes = '"' .. single .. '"' end
    end
    if modes and lhs then
      for mode in modes:gmatch('"([^"]+)"') do
        table.insert(out, { mode = mode, lhs = lhs, line = line })
      end
    end
  end
  return out
end

local function key(mode, lhs)
  return mode .. " " .. lhs
end

-- Every mapping in lua/config/keymaps.lua, in file order.
--
-- Third field is a substring the mapping's `desc` must contain, or `false` for
-- the mappings the config deliberately leaves undescribed. `false` is spelled
-- out rather than omitted so that a mapping losing its desc is a failure and not
-- a silent gap. There are currently none: the nine that used to be undescribed
-- (split resize, centred scroll/search, <Esc>) have been given descs, since
-- which-key is the only place a user discovers them.
local MAPPINGS = {
  -- Window navigation. The terminal-mode copies exist so the same keys work
  -- from inside a toggleterm buffer; dropping them traps the cursor there.
  { "n", "<C-h>", "Window left" },
  { "n", "<C-j>", "Window down" },
  { "n", "<C-k>", "Window up" },
  { "n", "<C-l>", "Window right" },
  { "t", "<C-h>", "Window left (from terminal)" },
  { "t", "<C-j>", "Window down (from terminal)" },
  { "t", "<C-k>", "Window up (from terminal)" },
  { "t", "<C-l>", "Window right (from terminal)" },

  -- Split resize.
  { "n", "<C-Up>", "Resize split taller" },
  { "n", "<C-Down>", "Resize split shorter" },
  { "n", "<C-Left>", "Resize split narrower" },
  { "n", "<C-Right>", "Resize split wider" },

  -- File explorer.
  { "n", "<C-e>", "Toggle explorer" },
  { "n", "<C-S-e>", "Reveal file in explorer" },

  -- Telescope.
  { "n", "<C-p>", "Find files" },
  { "n", "<leader>/", "Live grep" },
  { "n", "<C-b>", "Switch buffer" },
  { "n", "<C-t>", "Recent files" },

  -- Save / quit.
  { "n", "<C-s>", "Save file" },
  { "i", "<C-s>", "Save file" },
  { "n", "<C-q>", "Quit all" },

  -- Format.
  { "n", "<M-l>", "Format file" },

  -- LSP actions.
  { "n", "<F2>", "Rename symbol" },
  { "n", "<F4>", "Code action" },
  { "n", "<C-.>", "Code action" },
  { "n", "<F12>", "Go to definition" },

  -- Diagnostics.
  { "n", "]d", "Next diagnostic" },
  { "n", "[d", "Prev diagnostic" },
  { "n", "<M-e>", "Show diagnostic detail" },
  { "n", "<M-x>", "Diagnostics list" },

  -- Buffer tabs.
  { "n", "<S-l>", "Next buffer" },
  { "n", "<S-h>", "Prev buffer" },
  { "n", "<C-w>", "Close buffer" },

  -- Splits.
  { "n", "<C-S-v>", "Split vertical" },
  { "n", "<C-S-x>", "Split horizontal" },
  { "n", "<C-S-o>", "Close all other splits" },

  -- AI.
  { "n", "<C-g>", "AI: Toggle Claude panel" },
  { "n", "<C-a>", "AI: Ask Claude anything" },
  { "x", "<C-1>", "AI: Explain code" },
  { "x", "<C-2>", "AI: Refactor code" },
  { "x", "<C-3>", "AI: Generate tests" },
  { "x", "<C-4>", "AI: Fix code" },
  { "x", "<C-5>", "AI: Generate docs" },
  { "x", "<C-6>", "AI: Ask about selection" },

  -- Git.
  { "n", "<M-b>", "Git: Blame line" },
  { "n", "<M-z>", "Git: Preview hunk" },

  -- Editing helpers.
  { "x", "J", "Move selection down" },
  { "x", "K", "Move selection up" },
  { "n", "<M-j>", "Move line down" },
  { "n", "<M-k>", "Move line up" },
  { "n", "<C-d>", "Scroll down, cursor centred" },
  { "n", "<C-u>", "Scroll up, cursor centred" },
  { "n", "n", "Next search match, centred" },
  { "n", "N", "Prev search match, centred" },
  { "x", "<C-S-p>", "Paste without overwriting register" },
  { "n", "<C-y>", "Copy to system clipboard" },
  { "x", "<C-y>", "Copy to system clipboard" },
  { "n", "<C-S-y>", "Copy line to system clipboard" },

  -- Comment toggling.
  { "n", "<C-_>", "Toggle comment" },
  { "x", "<C-_>", "Toggle comment" },
  { "n", "<C-/>", "Toggle comment" },
  { "x", "<C-/>", "Toggle comment" },

  -- Search highlight.
  { "n", "<Esc>", "Clear search highlight" },

  -- Logs.
  { "n", "<F1>", "Open LSP log" },
  { "n", "<C-S-n>", "Notification history" },
  { "n", "<C-S-l>", "Open Neovim log" },
}

describe("config.keymaps", function()
  before_each(function()
    load_keymaps()
  end)

  after_each(function()
    package.loaded["config.keymaps"] = nil
    H.cleanup()
  end)

  describe("coverage", function()
    it("defines every mapping in MAPPINGS, in the right mode", function()
      -- The single test that catches the most likely regression: a mapping
      -- deleted in a refactor, or moved from "x" to "v" / from "n" to "i".
      local missing = {}
      for _, m in ipairs(MAPPINGS) do
        if not H.has_keymap(m[1], m[2]) then
          table.insert(missing, key(m[1], m[2]))
        end
      end
      assert.same({}, missing)
    end)

    it("gives every described mapping a non-empty desc", function()
      -- desc is not decoration: which-key and Telescope keymaps show it, so an
      -- empty one produces an unlabelled entry in the only place a user
      -- discovers these bindings.
      local wrong = {}
      for _, m in ipairs(MAPPINGS) do
        local d = H.keymap(m[1], m[2])
        local desc = d and d.desc or ""
        if m[3] then
          if desc == "" or not desc:find(m[3], 1, true) then
            table.insert(wrong, ("%s desc=%q want=%q"):format(key(m[1], m[2]), desc, m[3]))
          end
        elseif desc ~= "" then
          -- A desc appearing where MAPPINGS says there is none means the config
          -- gained one and this table is now the stale copy.
          table.insert(wrong, ("%s gained desc=%q"):format(key(m[1], m[2]), desc))
        end
      end
      assert.same({}, wrong)
    end)

    it("MAPPINGS matches the map() calls in the source, both ways", function()
      -- Keeps the table honest. Without this, MAPPINGS is only a snapshot and a
      -- newly added mapping would never be tested at all.
      local in_table, in_source = {}, {}
      for _, m in ipairs(MAPPINGS) do in_table[key(m[1], m[2])] = true end
      for _, m in ipairs(parsed_mappings()) do in_source[key(m.mode, m.lhs)] = true end

      local untested, stale = {}, {}
      for k in pairs(in_source) do
        if not in_table[k] then table.insert(untested, k) end
      end
      for k in pairs(in_table) do
        if not in_source[k] then table.insert(stale, k) end
      end
      table.sort(untested)
      table.sort(stale)
      assert.same({}, untested)
      assert.same({}, stale)
    end)
  end)

  describe("no duplicate definitions", function()
    it("maps each mode+lhs exactly once", function()
      -- A second map() for the same mode and lhs overwrites the first with no
      -- warning, no error and no trace in maparg — the reader of the file sees
      -- two behaviours and gets the later one. This is why the check is done
      -- against the parsed source and not against the runtime map table.
      local seen, dupes = {}, {}
      for _, m in ipairs(parsed_mappings()) do
        local k = key(m.mode, m.lhs)
        if seen[k] then table.insert(dupes, k) end
        seen[k] = true
      end
      assert.same({}, dupes)
    end)
  end)

  describe("platform rule", function()
    it("uses no <D-...> (Cmd) mappings", function()
      -- Standing project rule: this branch keeps Windows/Linux Ctrl-based
      -- shortcuts and Mac Cmd bindings live on a separate branch. A <D- lhs
      -- landing here is how the two branches quietly converge, and it is also
      -- dead weight for every non-Mac GUI, where <D- is never produced.
      local offenders = {}
      for i, line in ipairs(vim.fn.readfile(keymaps_path)) do
        if line:find("<D%-") then
          table.insert(offenders, ("line %d: %s"):format(i, line))
        end
      end
      assert.same({}, offenders)
    end)
  end)

  describe("window resize", function()
    it("binds <C-arrow> in normal mode to resize commands", function()
      -- The direction pairing is the easy thing to get wrong: vertical (height)
      -- for Up/Down, `vertical resize` (width) for Left/Right. A swap here
      -- resizes the wrong axis and looks like the mapping is broken.
      assert.equals(":resize +2<CR>", H.keymap("n", "<C-Up>").rhs)
      assert.equals(":resize -2<CR>", H.keymap("n", "<C-Down>").rhs)
      assert.equals(":vertical resize -2<CR>", H.keymap("n", "<C-Left>").rhs)
      assert.equals(":vertical resize +2<CR>", H.keymap("n", "<C-Right>").rhs)
    end)
  end)

  describe("<Esc> clears search highlight", function()
    it("resets v:hlsearch", function()
      H.scratch({ lines = { "alpha", "beta", "alpha" } })
      -- The config sets hlsearch=false, so v:hlsearch would already be 0 and the
      -- assertion would pass for the wrong reason; turning it on locally is what
      -- makes the mapping's effect observable.
      local hls = vim.o.hlsearch
      vim.o.hlsearch = true
      vim.cmd("silent! normal! gg")
      vim.cmd("silent! /alpha")
      assert.equals(1, vim.v.hlsearch)

      H.run_keymap("n", "<Esc>")
      assert.equals(0, vim.v.hlsearch)
      vim.o.hlsearch = hls
    end)
  end)

  describe("visual-mode line moves", function()
    it("binds J and K in mode x, never in select mode", function()
      -- "x" not "v" on purpose: "v" covers visual *and* select mode, and select
      -- mode is where LuaSnip puts the cursor over a placeholder. There, J and K
      -- must stay ordinary printable characters — a "v" mapping made typing over
      -- a placeholder move lines instead of replacing text.
      assert.is_true(H.has_keymap("x", "J"))
      assert.is_true(H.has_keymap("x", "K"))
      -- mode_bits 2 is VISUAL only; select mode would add 4.
      assert.equals(2, H.keymap("x", "J").mode_bits)
      assert.equals(2, H.keymap("x", "K").mode_bits)
      -- gv=gv at the end: the moved lines stay selected and get re-indented, so
      -- the mapping can be repeated.
      assert.equals(":m '>+1<CR>gv=gv", H.keymap("x", "J").rhs)
      assert.equals(":m '<-2<CR>gv=gv", H.keymap("x", "K").rhs)
    end)

    it("also restricts the visual AI and paste mappings to mode x", function()
      -- Same reasoning, same failure mode: these were the mappings that broke
      -- snippet placeholders in the first place.
      for _, lhs in ipairs({ "<C-1>", "<C-2>", "<C-3>", "<C-4>", "<C-5>", "<C-6>", "<C-S-p>", "<C-y>" }) do
        assert.equals(2, H.keymap("x", lhs).mode_bits, lhs .. " is not visual-only")
      end
    end)
  end)

  describe("AI mappings", function()
    it("binds <C-1>..<C-6> in visual mode with distinct callbacks", function()
      -- Six wrappers built by the same closure factory; a copy-paste slip would
      -- give two of them the same claude_cli function, which no other assertion
      -- would notice.
      local seen = {}
      for i = 1, 6 do
        local d = H.keymap("x", ("<C-%d>"):format(i))
        assert.is_not_nil(d)
        assert.is_not_nil(d.callback)
        assert.is_nil(seen[d.callback])
        seen[d.callback] = true
      end
    end)
  end)

  describe("comment toggling", function()
    it("binds both <C-_> and <C-/> to the same callbacks", function()
      -- Terminals disagree about Ctrl+/: some send <C-_> (control-underscore),
      -- newer ones send <C-/>. Both have to be mapped, and to the *same*
      -- function, or the shortcut works in one terminal and not another.
      assert.equals(H.keymap("n", "<C-_>").callback, H.keymap("n", "<C-/>").callback)
      assert.equals(H.keymap("x", "<C-_>").callback, H.keymap("x", "<C-/>").callback)
      -- Normal and visual use different implementations (the visual one leaves
      -- visual mode first and passes visualmode() to Comment.api).
      assert.is_not.equals(H.keymap("n", "<C-_>").callback, H.keymap("x", "<C-_>").callback)
    end)

    it("does not invoke Comment.api in unit mode", function()
      -- Comment.nvim is a plugin, and unit mode loads none: proving the callback
      -- runs belongs in an integration spec. Guarded rather than deleted so the
      -- gap is visible.
      if not pcall(require, "Comment.api") then
        return H.skip("Comment.nvim not loaded in unit mode")
      end
      H.scratch({ lines = { "local x = 1" }, ft = "lua" })
      H.run_keymap("n", "<C-_>")
    end)
  end)

  describe("code action guard", function()
    it("warns instead of calling vim.lsp.buf.code_action with no client", function()
      -- The one piece of real logic in this file. Calling code_action with no
      -- attached client shows an empty picker; the guard turns that into a
      -- message that says why.
      H.scratch()
      local calls = H.spy(vim.lsp.buf, "code_action")
      local notes = H.capture_notifications(function() H.run_keymap("n", "<F4>") end)
      assert.equals(0, calls.count)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("No LSP attached", 1, true) ~= nil)
      -- WARN, not INFO: this is a keypress that did nothing.
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)

    it("shares one implementation between <F4> and <C-.>", function()
      -- <C-.> is the VS Code-style alias. If it were bound to
      -- vim.lsp.buf.code_action directly it would skip the guard above.
      assert.equals(H.keymap("n", "<F4>").callback, H.keymap("n", "<C-.>").callback)
    end)
  end)

  describe("diagnostic navigation", function()
    it("uses vim.diagnostic.jump, not the removed goto_next/goto_prev", function()
      -- goto_next/goto_prev are deprecated and scheduled for removal in 0.13;
      -- the count sign is what distinguishes next from prev.
      --
      -- Comment lines are stripped before the scan: the file *explains* why it
      -- avoids goto_next, so a naive text search over the whole source finds the
      -- prose and reports a violation that is not there.
      local code = {}
      for _, line in ipairs(vim.fn.readfile(keymaps_path)) do
        if not line:match("^%s*%-%-") then table.insert(code, line) end
      end
      code = table.concat(code, "\n")
      assert.is_nil(code:find("diagnostic.goto_next", 1, true))
      assert.is_nil(code:find("diagnostic.goto_prev", 1, true))
      assert.is_not_nil(code:find("vim.diagnostic.jump({ count = 1", 1, true))
      assert.is_not_nil(code:find("vim.diagnostic.jump({ count = -1", 1, true))
    end)

    it("runs ]d, [d and <M-e> without error on a buffer with no diagnostics", function()
      -- Safe to actually invoke: no plugin involved, and the empty case is the
      -- one users hit constantly.
      H.scratch({ lines = { "x" } })
      H.run_keymap("n", "]d")
      H.run_keymap("n", "[d")
      H.run_keymap("n", "<M-e>")
    end)
  end)

  describe("rename", function()
    it("binds <F2> straight to vim.lsp.buf.rename", function()
      -- Asserted by identity rather than invoked: rename opens a prompt, which
      -- would block a headless run.
      assert.equals(vim.lsp.buf.rename, H.keymap("n", "<F2>").callback)
    end)
  end)

  describe("centred scrolling", function()
    it("appends zz to <C-d>/<C-u> and zzzv to n/N", function()
      -- The recentring is the whole point of these four; losing the suffix
      -- leaves the mapping working but pointless, which no existence check
      -- would catch.
      assert.equals("<C-d>zz", H.keymap("n", "<C-d>").rhs)
      assert.equals("<C-u>zz", H.keymap("n", "<C-u>").rhs)
      -- zzzv, not zz: zv reopens a fold the match landed inside.
      assert.equals("nzzzv", H.keymap("n", "n").rhs)
      assert.equals("Nzzzv", H.keymap("n", "N").rhs)
    end)

    it("runs <C-d> and <C-u> without error", function()
      H.scratch({ lines = vim.fn["repeat"]({ "line" }, 200) })
      H.run_keymap("n", "<C-d>")
      H.run_keymap("n", "<C-u>")
    end)
  end)

  describe("clipboard mappings", function()
    it("yanks to the + register in both normal and visual mode", function()
      -- Explicit "+ mappings exist alongside clipboard=unnamedplus so the
      -- shortcut still works if that option is ever narrowed.
      assert.equals('"+y', H.keymap("n", "<C-y>").rhs)
      assert.equals('"+y', H.keymap("x", "<C-y>").rhs)
      assert.equals('"+Y', H.keymap("n", "<C-S-y>").rhs)
    end)
  end)

  describe("log buffers", function()
    --- Press `lhs` and return the buffer it opened, asserting it landed in a new
    --- tab. Tracked so cleanup wipes it, which closes the tab with it.
    local function open(lhs)
      local tabs = #vim.api.nvim_list_tabpages()
      H.run_keymap("n", lhs)
      assert.equals(tabs + 1, #vim.api.nvim_list_tabpages())
      return H.track_buf(vim.api.nvim_get_current_buf())
    end

    --- The buffer's file, with both sides symlink-resolved (macOS's temp dir
    --- lives behind /var -> /private/var).
    local function opened_file(buf)
      return vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf))
    end

    it("opens the LSP log in a new tab, read-only and unmodifiable", function()
      -- readonly + nomodifiable is protection, not politeness: a log is a
      -- live-appended file that auto_save (autocmds.lua) would treat as source
      -- code, writing the whole buffer back on BufLeave over what the server is
      -- still appending to. auto_save only writes `modified` buffers, and an
      -- unmodifiable one can never become modified. The new tab matters too — a
      -- log is consulted *about* what you were doing, so :edit would replace it.
      local path = H.write(H.tmpdir("logs") .. "/lsp.log", { "[START][info] hello" })
      H.stub(vim.lsp.log, "get_filename", function() return path end)

      local buf = open("<F1>")
      -- The path comes from vim.lsp.log.get_filename() and not from :LspLog:
      -- nvim 0.12 ships its own :lsp, so nvim-lspconfig registers no Lsp*
      -- command at all and the old <F1> raised E492 on every press.
      assert.equals(vim.uv.fs_realpath(path), opened_file(buf))
      assert.same({ "[START][info] hello" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_true(vim.bo[buf].readonly)
      assert.is_false(vim.bo[buf].modifiable)
      assert.is_false(vim.bo[buf].modified)
    end)

    it("opens the Neovim runtime log the same way", function()
      local dir = H.tmpdir("logs")
      local path = H.write(dir .. "/nvim.log", { "runtime log" })
      local stdpath = vim.fn.stdpath
      H.stub(vim.fn, "stdpath", function(what)
        return what == "log" and dir or stdpath(what)
      end)

      local buf = open("<C-S-l>")
      assert.equals(vim.uv.fs_realpath(path), opened_file(buf))
      assert.is_true(vim.bo[buf].readonly)
      assert.is_false(vim.bo[buf].modifiable)
    end)
  end)

  describe("module", function()
    it("can be loaded twice without error and keeps the same mappings", function()
      -- vim.keymap.set is idempotent, but a future guard clause or a
      -- module-local that assumes a single load would break here first.
      local before = {}
      for _, m in ipairs(MAPPINGS) do
        local d = H.keymap(m[1], m[2])
        before[key(m[1], m[2])] = (d.rhs or "") .. "|" .. (d.desc or "")
      end

      load_keymaps()

      local after = {}
      for _, m in ipairs(MAPPINGS) do
        local d = H.keymap(m[1], m[2])
        after[key(m[1], m[2])] = (d.rhs or "") .. "|" .. (d.desc or "")
      end
      assert.same(before, after)
    end)
  end)
end)
