-- claude_cli — the `claude` CLI integration (context file, one-shot prompts,
-- persistent terminal panel).
--
-- The one absolute rule here: nothing in this spec may spawn a process or touch
-- the real context file. vim.fn.jobstart and vim.fn.termopen are spied on every
-- path that would launch `claude`, and the assertions are made on the argv that
-- *would* have been passed — which is also the only part of the integration
-- that can silently rot (a renamed flag looks identical to a working panel
-- until you try to use it). io.open is intercepted for CTX_FILE for the same
-- reason: the path is a module-local constant with no override, so the only way
-- to observe write_context without writing /tmp/nvim-claude-ctx is to fake the
-- handle. That hardcoded path is the module's main testability gap.
--
-- Job callbacks are invoked by hand from the recorded opts table. That is the
-- point of spying rather than stubbing: on_stdout/on_exit are where the
-- has_output logic lives, and driving them directly makes "claude exited 1 with
-- no output" a one-line case instead of a fixture binary.

local H = require("helpers")

local CTX_FILE = "/tmp/nvim-claude-ctx"
local PLACEHOLDER = "  Asking Claude…"

--- Load a pristine copy of the module. Its state (terminal buffer, panel
--- window, reload timer) lives in a module-local table, so without this a
--- panel opened by one case would still look open to the next.
local function fresh_claude()
  package.loaded["claude_cli"] = nil
  local m = require("claude_cli")
  -- Requiring installs a BufEnter autocmd that writes the context file on
  -- every buffer switch; tracking it means H.cleanup removes it even if a case
  -- fails partway through.
  H.track_augroup("claude_context_sync")
  return m
end

--- Intercept io.open for CTX_FILE only. Returns the log of attempts:
--- { { path, mode, text }, ... }. Everything else (plenary's own output) is
--- passed through to whatever io.open was before, so nesting a second call
--- inside a case just gives that case its own log.
local function capture_ctx()
  local writes = {}
  local real_open = io.open
  H.stub(io, "open", function(path, mode, ...)
    if path ~= CTX_FILE then return real_open(path, mode, ...) end
    local entry = { path = path, mode = mode, text = "" }
    table.insert(writes, entry)
    return {
      write = function(_, s) entry.text = entry.text .. s end,
      close = function() end,
    }
  end)
  return writes
end

--- Put charwise visual-selection marks on `buf`.
--- nvim_buf_set_mark takes a 0-based column and getpos() reports it 1-based,
--- which is exactly the off-by-one get_visual_selection's string.sub arithmetic
--- relies on — so the marks are set the way a real `v` motion leaves them.
local function select_region(buf, sl, sc, el, ec)
  vim.api.nvim_buf_set_mark(buf, "<", sl, sc, {})
  vim.api.nvim_buf_set_mark(buf, ">", el, ec, {})
end

--- A file-backed buffer (buftype "") with a selection over all of `lines`.
local function selected_buf(lines, name)
  local buf = H.scratch({ name = name, lines = lines })
  select_region(buf, 1, 0, #lines, #lines[#lines])
  return buf
end

describe("claude_cli", function()
  local claude, jobs, known_bufs

  before_each(function()
    known_bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do known_bufs[b] = true end
    -- Spied unconditionally, including for cases that are not about M.ask: an
    -- accidental real jobstart would launch the user's `claude` from a test.
    jobs = H.spy(vim.fn, "jobstart", function() return 1 end)
    H.spy(vim.fn, "termopen", function() return 1 end)
    H.disable_autosave()
    -- Unconditionally, for every case: the BufEnter autocmd fires on each
    -- H.scratch/H.edit, so without this the real /tmp/nvim-claude-ctx gets
    -- overwritten with a temp-dir path by cases that are not about context at
    -- all — and the user's next MCP lookup would read it.
    capture_ctx()
    claude = fresh_claude()
  end)

  after_each(function()
    -- startinsert (panel) and the floating result window both outlive the case
    -- that created them; the float in particular would become the "current
    -- buffer" the next case's selection helpers read from.
    vim.cmd("stopinsert")
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do
      pcall(vim.api.nvim_win_close, wins[i], true)
    end
    H.cleanup()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not known_bufs[b] then
        pcall(vim.api.nvim_buf_delete, b, { force = true, unload = false })
      end
    end
  end)

  describe("context sync", function()
    it("creates the claude_context_sync augroup on BufEnter", function()
      assert.equals(1, H.count_autocmds("BufEnter", "claude_context_sync"))
    end)

    it("writes the current file, filetype and line to the context file", function()
      local writes = capture_ctx()
      local path = H.write(H.tmpdir("ctx") .. "/note.txt", { "one", "two", "three" })
      local buf = H.edit(path)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.bo[buf].filetype = "text"

      -- exec_autocmds with the group pinned: BufEnter has already fired for
      -- this buffer during :edit (before the cursor was placed), and the
      -- assertion is about the content, not about nvim's event ordering.
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })

      local last = writes[#writes]
      assert.is_not_nil(last)
      -- "w", not "a": the MCP tool reads the whole file, so appending would
      -- hand Claude a growing history with the stale entry first.
      assert.equals("w", last.mode)
      assert.equals(CTX_FILE, last.path)
      assert.equals(("File: %s\nLanguage: text\nLine: 2"):format(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")), last.text)
    end)

    it("reports an unset filetype as 'unknown' rather than an empty field", function()
      local writes = capture_ctx()
      local buf = H.scratch({ name = H.tmpdir("ctx") .. "/plain", lines = { "x" } })
      assert.equals("", vim.bo[buf].filetype)
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      -- "Language: \n" would read as a truncated field to the model; the
      -- explicit placeholder is what makes the record parseable.
      assert.is_true(writes[#writes].text:find("Language: unknown", 1, true) ~= nil)
    end)

    it("writes nothing for a buffer with no name", function()
      local writes = capture_ctx()
      local buf = H.scratch({ lines = { "scratch" } })
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      -- A `File: ` line pointing at nothing would make the MCP tool report a
      -- file the user is not in; skipping the write leaves the last real file
      -- in place, which is the useful answer.
      assert.equals(0, #writes)
    end)
  end)

  describe("file_prefix", function()
    it("prefixes the prompt with the buffer's path, filetype and line", function()
      local path = H.write(H.tmpdir("prefix") .. "/main.txt", { "local x = 1" })
      local buf = H.edit(path)
      vim.bo[buf].filetype = "text"
      select_region(buf, 1, 0, 1, 11)

      claude.explain()

      local prompt = jobs[1][1][3]
      -- The prefix is invisible to the user, so a wrong path here is silent:
      -- Claude answers about the wrong file and nothing looks broken.
      assert.equals(("[File: %s | Language: text | Line: 1]\n\n"):format(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")),
        prompt:sub(1, prompt:find("\n\n", 1, true) + 1))
    end)

    it("omits the prefix entirely for an unnamed buffer", function()
      selected_buf({ "local x = 1" })
      claude.explain()
      -- No "[File: ]" with an empty path: an unnamed buffer has no path worth
      -- claiming, and the fabricated header would be a lie to the model.
      assert.equals("Explain", jobs[1][1][3]:sub(1, 7))
    end)
  end)

  describe("ask", function()
    it("shells out to `claude -p <prompt>` and nothing else", function()
      claude.ask("what is 2+2", "Math")
      assert.equals(1, jobs.count)
      -- Exactly three argv entries: the prompt must stay a single argument, or
      -- a multi-word prompt turns into extra flags for the CLI.
      assert.same({ "claude", "-p", "what is 2+2" }, jobs[1][1])
      assert.is_false(jobs[1][2].stdout_buffered)
    end)

    it("opens a focused floating window with a placeholder", function()
      claude.ask("hi", "Title")
      local win = vim.api.nvim_get_current_win()
      local cfg = vim.api.nvim_win_get_config(win)
      assert.equals("editor", cfg.relative)
      -- The placeholder is the only feedback during the (slow) request; an
      -- empty window here reads as a broken command.
      assert.same({ PLACEHOLDER },
        vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false))
      assert.equals("markdown", vim.bo[vim.api.nvim_get_current_buf()].filetype)
    end)

    it("closes the window with q and with <Esc>", function()
      for _, key in ipairs({ "q", "<Esc>" }) do
        claude.ask("hi", "Title")
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        assert.is_not_nil(H.keymap("n", key, buf))
        H.run_keymap("n", key, buf)
        -- Buffer-local, so this must not be the only way out of a normal
        -- buffer either — but a result window you cannot dismiss is the worst
        -- failure mode of a modal UI.
        assert.is_false(vim.api.nvim_win_is_valid(win))
      end
    end)

    it("renders streamed stdout into the window", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      opts.on_stdout(1, { "first", "second" })
      opts.on_exit(1, 0)
      H.wait_for("stdout rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      assert.same({ "first", "second" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("shows an install/auth hint when claude fails with no output", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      -- jobstart fires on_stdout once with {""} when the stream closes even
      -- though the command printed nothing — the exact case #output alone
      -- cannot distinguish from one blank line of real output.
      opts.on_stdout(1, { "" })
      opts.on_exit(1, 1)
      H.wait_for("error rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[1]:find("code 1", 1, true) ~= nil)
      assert.is_true(lines[2]:find("installed and authenticated", 1, true) ~= nil)
    end)

    it("prefers real output over the error hint on a non-zero exit", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      opts.on_stdout(1, { "partial answer", "" })
      opts.on_exit(1, 1)
      H.wait_for("output rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      -- has_output is what makes this branch reachable: claude can print a
      -- usable answer and still exit non-zero, and replacing it with
      -- "check that claude is installed" would throw the answer away.
      assert.same({ "partial answer", "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)
  end)

  describe("visual selection", function()
    it("returns the text between the '< and '> marks", function()
      local buf = H.scratch({ lines = { "local x = 1", "local y = 2", "local z = 3" } })
      -- Mirrors `v` from column 7 of line 1 to column 11 of line 2: the first
      -- line is trimmed from the start column and the last to the end column,
      -- so a partial selection must not silently widen to whole lines.
      select_region(buf, 1, 6, 2, 10)
      claude.explain()
      assert.is_true(jobs[1][1][3]:find("x = 1\nlocal y = 2", 1, true) ~= nil)
    end)

    it("warns and sends nothing when there is no selection", function()
      H.scratch({ lines = { "untouched" } })
      local notes = H.capture_notifications(function() claude.explain() end)
      -- A fresh buffer has no '< / '> marks, which is what a stray keypress on
      -- a visual-mode mapping looks like. Sending an empty code fence would
      -- burn a request and answer about nothing.
      assert.equals(0, jobs.count)
      assert.equals(1, #notes)
      assert.equals("No text selected", notes[1].msg)
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)
  end)

  -- Every visual-mode command is the same shape — guard, prefix, prompt, ask —
  -- so they are table-driven: a new one that forgets the selection guard or
  -- reuses another command's instruction text fails here without anyone having
  -- to remember to write a case for it.
  local COMMANDS = {
    { name = "explain",        needs_selection = true,  contains = "Explain this code clearly and concisely" },
    { name = "refactor",       needs_selection = true,  contains = "Refactor this code to be cleaner and more idiomatic" },
    { name = "generate_tests", needs_selection = true,  contains = "Write unit tests for this code" },
    { name = "fix",            needs_selection = true,  contains = "Find and fix bugs in this code" },
    { name = "generate_docs",  needs_selection = true,  contains = "Write documentation/docstring for this code" },
    { name = "ask_about",      needs_selection = true,  contains = "why is this slow",  input = "why is this slow" },
    { name = "prompt",         needs_selection = false, contains = "how do I use vim.uv", input = "how do I use vim.uv" },
  }

  describe("commands", function()
    it("exposes every command as a function", function()
      for _, cmd in ipairs(COMMANDS) do
        assert.equals("function", type(claude[cmd.name]), cmd.name .. " is not a function")
      end
    end)

    for _, cmd in ipairs(COMMANDS) do
      it(cmd.name .. " builds a prompt with its own instruction", function()
        if cmd.input then
          -- vim.ui.input is stubbed rather than driven: without a UI the real
          -- one never calls back, so the command would appear to do nothing.
          H.stub(vim.ui, "input", function(_, on_confirm) on_confirm(cmd.input) end)
        end
        selected_buf({ "local x = 1" })
        claude[cmd.name]()
        assert.equals(1, jobs.count)
        local argv = jobs[1][1]
        assert.equals("claude", argv[1])
        assert.equals("-p", argv[2])
        assert.is_true(argv[3]:find(cmd.contains, 1, true) ~= nil,
          cmd.name .. " prompt was: " .. argv[3])
        if cmd.needs_selection then
          -- The code has to arrive inside a fence, or a snippet containing
          -- prose is read as instructions rather than as the subject.
          assert.is_true(argv[3]:find("```\nlocal x = 1\n```", 1, true) ~= nil)
        end
      end)

      if cmd.needs_selection then
        it(cmd.name .. " refuses to run without a selection", function()
          if cmd.input then
            H.stub(vim.ui, "input", function(_, on_confirm) on_confirm(cmd.input) end)
          end
          H.scratch({ lines = { "untouched" } })
          local notes = H.capture_notifications(function() claude[cmd.name]() end)
          assert.equals(0, jobs.count)
          assert.equals("No text selected", notes[1].msg)
        end)
      end
    end

    it("sends nothing when the input prompt is cancelled or empty", function()
      for _, answer in ipairs({ "", vim.NIL }) do
        H.stub(vim.ui, "input", function(_, on_confirm)
          on_confirm(answer ~= vim.NIL and answer or nil)
        end)
        selected_buf({ "local x = 1" })
        claude.ask_about()
        claude.prompt()
      end
      -- <Esc> at the "Ask Claude:" prompt must not fire a request built from
      -- nothing but the file header.
      assert.equals(0, jobs.count)
    end)

    it("adds no language-specific test hint for a neutral filetype", function()
      local buf = selected_buf({ "local x = 1" }, H.tmpdir("hint") .. "/main.txt")
      vim.bo[buf].filetype = "text"
      claude.generate_tests()
      local prompt = jobs[1][1][3]
      -- The JUnit/Jest branches are deliberately not exercised here: setting a
      -- buffer's filetype to java/typescript is what starts a real language
      -- server in integration mode, and this spec must stay unit-only.
      assert.is_false(prompt:find("JUnit", 1, true) ~= nil)
      assert.is_false(prompt:find("Jest", 1, true) ~= nil)
    end)
  end)

  describe("panel", function()
    local terms

    before_each(function()
      -- The real reload timer repeats every 2s and is only stopped by
      -- close_panel, so a case that leaves the panel open would leave a live
      -- libuv handle running :checktime for the rest of the process. Nothing
      -- under test uses vim.defer_fn, so faking new_timer is safe here.
      H.stub(vim.uv, "new_timer", function()
        return {
          start = function() end,
          stop = function() end,
          close = function() end,
        }
      end)
      terms = H.spy(vim.fn, "termopen", function() return 1 end)
      capture_ctx()
      claude = fresh_claude()
    end)

    it("spawns claude with the MCP system prompt", function()
      claude.toggle_chat()
      assert.equals(1, terms.count)
      local argv = terms[1][1]
      assert.same({ "claude", "--append-system-prompt" }, { argv[1], argv[2] })
      assert.equals(3, #argv)
      -- The system prompt is the entire mechanism by which the panel knows
      -- which file you are in — if the tool name drifts, the panel still opens
      -- and just never has context.
      assert.is_true(argv[3]:find("get_current_file", 1, true) ~= nil)
      -- $EDITOR inside the panel must be nvim, not whatever the parent shell
      -- exported, or `claude` opens a nested editor the user cannot see.
      assert.same({ EDITOR = "nvim", VISUAL = "nvim" }, terms[1][2].env)
    end)

    it("opens a window, and closes it on the second toggle", function()
      local before = #vim.api.nvim_list_wins()
      claude.toggle_chat()
      assert.equals(before + 1, #vim.api.nvim_list_wins())
      claude.toggle_chat()
      assert.equals(before, #vim.api.nvim_list_wins())
    end)

    it("reuses the terminal instead of spawning twice", function()
      claude.toggle_chat()
      claude.toggle_chat()
      claude.toggle_chat()
      -- The panel is persistent by design: a second spawn would silently
      -- throw away the conversation and start a new session.
      assert.equals(1, terms.count)
    end)

    it("unlists the terminal buffer and binds <C-g> to close it", function()
      claude.toggle_chat()
      local buf = vim.api.nvim_get_current_buf()
      assert.is_false(vim.bo[buf].buflisted)
      -- Terminal-mode mapping: without it there is no way out of the panel
      -- short of <C-\><C-n> then :q.
      assert.is_not_nil(H.keymap("t", "<C-g>", buf))
    end)

    it("focus_chat opens the panel when it is closed and focuses it when open", function()
      claude.focus_chat()
      assert.equals(1, terms.count)
      local panel_win = vim.api.nvim_get_current_win()
      local panel_buf = vim.api.nvim_get_current_buf()

      vim.api.nvim_set_current_win(vim.api.nvim_list_wins()[1])
      assert.is_true(vim.api.nvim_get_current_win() ~= panel_win)

      claude.focus_chat()
      -- Focus, not re-open: a second window on the same terminal buffer would
      -- split the screen again every time the keymap is pressed.
      assert.equals(1, terms.count)
      assert.equals(panel_win, vim.api.nvim_get_current_win())
      assert.equals(panel_buf, vim.api.nvim_get_current_buf())
    end)

    it("does not rewrite the context file while the panel itself is focused", function()
      claude.toggle_chat()
      local panel_buf = vim.api.nvim_get_current_buf()
      local writes = capture_ctx()
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = panel_buf })
      -- Entering the panel must not overwrite the record of the file you were
      -- editing — that record is the whole point of the panel.
      assert.equals(0, #writes)
    end)
  end)
end)
