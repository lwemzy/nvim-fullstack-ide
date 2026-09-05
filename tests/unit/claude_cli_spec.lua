-- claude_cli — the `claude` CLI integration (context file, one-shot prompts,
-- persistent terminal panel).
--
-- The one absolute rule here: nothing in this spec may spawn a process or touch
-- the real context file. vim.fn.jobstart and vim.fn.termopen are spied on every
-- path that would launch `claude`, and the assertions are made on the argv that
-- *would* have been passed — which is also the only part of the integration
-- that can silently rot (a renamed flag looks identical to a working panel
-- until you try to use it, and the MCP registration spent its whole life
-- missing for exactly that reason). vim.uv's fs_open/fs_write/fs_close/fs_rename
-- are intercepted for the context path for the same reason: the path is a
-- module-local with no override, so faking the descriptor is the only way to
-- observe write_context without clobbering the file the user's own panel reads.
--
-- Job callbacks are invoked by hand from the recorded opts table. That is the
-- point of spying rather than stubbing: on_stdout/on_exit are where the
-- stream-json parsing and the has-output logic live, and driving them directly
-- makes "claude exited 1 with no output" a one-line case instead of a fixture
-- binary.
--
-- The visual-mode commands are the exception: those are driven through a real
-- x-mode mapping with real keys, because the module reads the LIVE selection and
-- an earlier version of this spec set the '< / '> marks by hand instead — which
-- is precisely how the bug it now pins survived. See `visually`.

local H = require("helpers")

--- Derived the same way the module derives it, rather than hardcoded: the point
--- of the change that moved it here is that there is no one fixed path, and a
--- literal in this spec would pass on the machine it was written on and silently
--- intercept nothing anywhere else.
local CTX_FILE = (function()
  local runtime = vim.env.XDG_RUNTIME_DIR
  if runtime and runtime ~= "" and vim.fn.isdirectory(runtime) == 1 then
    return runtime .. "/nvim-claude-ctx"
  end
  return vim.fn.stdpath("cache") .. "/nvim-claude-ctx"
end)()

local PLACEHOLDER = "  Asking Claude…"

--- Key the visual-mode cases press. Any unused key would do; <F17> is one no
--- terminal sends by accident, so it cannot collide with a mapping the config
--- being tested installs.
local RUN_KEY = "<F17>"

--- Load a pristine copy of the module. Its state (terminal buffer, panel window,
--- whether the context sync has been armed) lives in module-locals, so without
--- this a panel opened by one case would still look open to the next.
local function fresh_claude()
  package.loaded["claude_cli"] = nil
  local m = require("claude_cli")
  -- Requiring installs a BufEnter autocmd that writes the context file on
  -- every buffer switch; tracking it means H.cleanup removes it even if a case
  -- fails partway through.
  H.track_augroup("claude_context_sync")
  return m
end

--- Intercept the libuv file calls for the context path. Returns the log of
--- writes: { { tmp, path, flags, mode, text, offset, closed }, ... } where `tmp`
--- is where the bytes were written and `path` is where they were renamed to.
--- Anything outside the context path is passed through to whatever the function
--- was before, so nesting a second call inside a case just gives that case its
--- own log.
---
--- With opts.manual the callbacks are queued instead of run, and `writes.drain()`
--- releases them. That is the only way to observe the module's write
--- serialization: with callbacks running synchronously every write completes
--- before the next buffer switch, which is exactly the interleaving that cannot
--- happen in the spec but does happen in libuv.
local FAKE_FD = -424242
local function capture_ctx(opts)
  opts = opts or {}
  local writes = {}
  local queue = {}
  local real = {
    open   = vim.uv.fs_open,
    write  = vim.uv.fs_write,
    close  = vim.uv.fs_close,
    rename = vim.uv.fs_rename,
    unlink = vim.uv.fs_unlink,
  }

  --- Matches CTX_FILE and the sibling temp file it is renamed from.
  local function ours(path)
    return type(path) == "string" and vim.startswith(path, CTX_FILE)
  end

  local function later(cb, ...)
    if not cb then return end
    if not opts.manual then return cb(...) end
    -- select("#") and the global unpack, not table.pack/table.unpack: nvim's
    -- LuaJIT has neither (measured — both are nil), and calling one here threw
    -- from inside the fs_open stub, which the BufEnter callback swallowed. The
    -- explicit n is what keeps a trailing nil argument countable.
    local args = { n = select("#", ...), ... }
    table.insert(queue, function() cb(unpack(args, 1, args.n)) end)
  end

  H.stub(vim.uv, "fs_open", function(path, flags, mode, cb)
    if not ours(path) then return real.open(path, flags, mode, cb) end
    table.insert(writes, { tmp = path, flags = flags, mode = mode })
    later(cb, nil, FAKE_FD)
    return FAKE_FD
  end)
  H.stub(vim.uv, "fs_write", function(fd, data, offset, cb)
    if fd ~= FAKE_FD then return real.write(fd, data, offset, cb) end
    local entry = writes[#writes]
    entry.text, entry.offset = data, offset
    later(cb, nil, #data)
    return #data
  end)
  H.stub(vim.uv, "fs_close", function(fd, cb)
    if fd ~= FAKE_FD then return real.close(fd, cb) end
    writes[#writes].closed = true
    later(cb, nil, true)
    return true
  end)
  H.stub(vim.uv, "fs_rename", function(from, to, cb)
    if not ours(from) then return real.rename(from, to, cb) end
    writes[#writes].path = to
    later(cb, nil, true)
    return true
  end)
  H.stub(vim.uv, "fs_unlink", function(path, cb)
    if not ours(path) then return real.unlink(path, cb) end
    writes[#writes].unlinked = true
    later(cb, nil, true)
    return true
  end)

  writes.drain = function()
    -- Each step of the chain queues the next, and finishing one write releases
    -- the one held behind it, so this runs until the module is genuinely idle.
    local guard = 0
    while #queue > 0 do
      guard = guard + 1
      assert(guard < 500, "context writes did not settle")
      table.remove(queue, 1)()
    end
  end
  writes.in_flight = function() return #queue end

  return writes
end

--- One line of `claude --output-format stream-json --include-partial-messages`
--- output carrying a token, shaped the way the CLI really emits it (verified
--- against claude 2.1.252):
---   {"type":"stream_event","event":{"type":"content_block_delta",
---    "delta":{"type":"text_delta","text":"..."}}}
local function delta(text)
  return vim.json.encode({
    type  = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = text } },
  })
end

--- A line the CLI emits before any token: session setup, tool lists, the final
--- result envelope. Everything the renderer must ignore.
local function noise()
  return vim.json.encode({ type = "system", subtype = "init", model = "claude-opus-5" })
end

--- Index of `flag` in an argv, or nil.
---
--- Used instead of positional indices, which shift every time a flag is added,
--- and instead of a pairwise flag->value walk, because not every flag this module
--- passes takes an argument.
local function flag_at(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then return i end
  end
end

local function flag_value(argv, flag)
  local i = flag_at(argv, flag)
  return i and argv[i + 1] or nil
end

describe("claude_cli", function()
  local claude, jobs, known_bufs, saved_columns

  before_each(function()
    known_bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do known_bufs[b] = true end
    saved_columns = vim.o.columns
    -- Spied unconditionally, including for cases that are not about M.ask: an
    -- accidental real jobstart would launch the user's `claude` from a test.
    jobs = H.spy(vim.fn, "jobstart", function() return 1 end)
    H.spy(vim.fn, "termopen", function() return 1 end)
    -- The module now refuses to start anything when the CLI is absent, which is
    -- correct — both jobstart and termopen *throw* E475 for a missing binary — but
    -- it means every case here would otherwise pass or fail based on whether the
    -- machine running the suite happens to have `claude` on $PATH. The cases that
    -- are about the missing-CLI path stub this the other way round.
    local real_executable = vim.fn.executable
    H.stub(vim.fn, "executable", function(name)
      if name == "claude" then return 1 end
      return real_executable(name)
    end)
    H.disable_autosave()
    -- Unconditionally, for every case: the BufEnter autocmd fires on each
    -- H.scratch/H.edit, so without this the real context file gets overwritten
    -- with a temp-dir path by cases that are not about context at all — and the
    -- user's next MCP lookup would read it.
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
    vim.o.columns = saved_columns
    H.cleanup()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not known_bufs[b] then
        pcall(vim.api.nvim_buf_delete, b, { force = true, unload = false })
      end
    end
  end)

  --- Run `fn` from a real x-mode mapping, with `keys` having made the selection.
  ---
  --- H.run_keymap cannot be used for the visual commands: it invokes the callback
  --- directly, from normal mode. That is what let the bug this pins live — the
  --- module reads the live selection (getpos("v") / getpos(".")), which only
  --- exists while visual mode is actually active, and for a Lua callback that
  --- means being reached by real keys through a real mapping, exactly the way
  --- lua/config/keymaps.lua reaches it.
  local function visually(keys, fn)
    vim.keymap.set("x", RUN_KEY, fn)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys .. RUN_KEY, true, true, true), "mx", false)
    vim.cmd("normal! \27")
    pcall(vim.keymap.del, "x", RUN_KEY)
  end

  --- Select all of the current buffer charwise and run `fn`.
  local function whole_buffer(fn)
    visually("gg0vG$", fn)
  end

  --- Close the result float so a second visual command in the same case selects
  --- from the buffer rather than from the previous answer.
  local function dismiss_float()
    local buf = vim.api.nvim_get_current_buf()
    if H.keymap("n", "q", buf) then H.run_keymap("n", "q", buf) end
  end

  --- The code fence contents of the prompt the nth request would have sent.
  local function sent_code(n)
    local prompt = jobs[n or 1][1][3]
    return prompt:match("```\n(.*)\n```")
  end

  --- Open and dismiss the panel, which is what arms the BufEnter context sync.
  --- The MCP server is the only reader of the context file and only exists once
  --- the panel does, so the module deliberately writes nothing before that first
  --- toggle — a case about the *content* has to get past that gate. termopen is
  --- already spied, so no process is launched.
  local function arm_context_sync()
    claude.toggle_chat()
    claude.toggle_chat()
    vim.cmd("stopinsert")
  end

  describe("context sync", function()
    it("creates the claude_context_sync augroup on BufEnter", function()
      assert.equals(1, H.count_autocmds("BufEnter", "claude_context_sync"))
    end)

    it("writes nothing at all until the panel has been opened", function()
      -- The measured cost of this write was 653us synchronous, on every BufEnter:
      -- every :bnext, every window switch, every step through a telescope
      -- preview. Nothing reads it before the panel exists, so an editing session
      -- that never opens Claude must pay none of it.
      local writes = capture_ctx()
      local buf = H.edit(H.write(H.tmpdir("ctx") .. "/untouched.txt", { "one" }))
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      assert.equals(0, #writes)
    end)

    it("writes the current file, filetype and line to the context file", function()
      arm_context_sync()
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
      -- "w" and offset 0: the MCP tool reads the whole file, so appending — or
      -- writing at a non-zero offset over a longer previous record — would hand
      -- Claude a stale path with the fresh one spliced into it.
      assert.equals("w", last.flags)
      assert.equals(0, last.offset)
      assert.equals(("File: %s\nLanguage: text\nLine: 2"):format(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")), last.text)
      -- An unclosed descriptor per buffer switch is a file-descriptor leak with
      -- exactly the shape of the buffer leaks this module already had.
      assert.is_true(last.closed)
    end)

    it("renames the record into place instead of truncating the file readers use", function()
      -- The MCP server is a separate process and can read at any moment. Opening
      -- the context file "w" truncates it, so a get_current_file landing in the
      -- window between the truncate and the write saw an empty file and reported
      -- no context at all.
      arm_context_sync()
      local writes = capture_ctx()
      local buf = H.edit(H.write(H.tmpdir("ctx") .. "/atomic.txt", { "x" }))
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })

      local last = writes[#writes]
      assert.is_not_nil(last)
      -- Written somewhere else...
      assert.is_true(last.tmp ~= CTX_FILE, "wrote straight to the path the server reads")
      -- ...then renamed onto the path the server reads.
      assert.equals(CTX_FILE, last.path)
      -- rename(2) is atomic within one directory and not across them, so the temp
      -- file has to be a sibling. It also has to be per-process: $XDG_RUNTIME_DIR
      -- is shared by every nvim this user is running.
      assert.equals(vim.fn.fnamemodify(CTX_FILE, ":h"), vim.fn.fnamemodify(last.tmp, ":h"))
      assert.is_true(last.tmp:find(tostring(vim.uv.os_getpid()), 1, true) ~= nil,
        "temp file is not per-process: " .. last.tmp)
    end)

    it("keeps one write in flight so the buffer you ended on is the one recorded", function()
      -- These are async renames. Letting several run at once means they can
      -- COMPLETE out of order, and they did: measured before this was serialized,
      -- 80 rapid switches ending on b.txt left the context file reading a.txt.
      -- Stepping through a telescope preview is exactly that pattern.
      arm_context_sync()
      local writes = capture_ctx({ manual = true })
      local dir = H.tmpdir("ctx")
      H.edit(H.write(dir .. "/a.txt", { "a" }))
      H.edit(H.write(dir .. "/b.txt", { "b" }))
      H.edit(H.write(dir .. "/c.txt", { "c" }))

      -- Three switches, one write started: the rest are held rather than racing.
      assert.equals(1, #writes)
      assert.is_true(writes.in_flight() > 0, "nothing was pending")

      writes.drain()
      -- Two writes for three switches: b was superseded before it ever started,
      -- which is the other half of what serializing buys — the churn does not
      -- turn into one syscall chain per keypress.
      assert.equals(2, #writes)
      assert.is_true(writes[1].text:find("a.txt", 1, true) ~= nil,
        "first write was not the first buffer: " .. writes[1].text)
      -- And what finally lands is the buffer we ended on, not whichever rename won.
      assert.is_true(writes[2].text:find("c.txt", 1, true) ~= nil,
        "context ended up on the wrong buffer: " .. writes[2].text)
      assert.equals(CTX_FILE, writes[2].path)
    end)

    it("writes the context file 0600, and not into shared /tmp", function()
      -- /tmp/nvim-claude-ctx was a fixed name in a world-writable directory
      -- shared by every account on the machine: another user can create that
      -- path first, as a symlink of their choosing, and this write then lands
      -- wherever they pointed it with the name of every file you open as the
      -- payload. Linux is where that matters, so it is the reference case.
      arm_context_sync()
      local writes = capture_ctx()
      local buf = H.edit(H.write(H.tmpdir("ctx") .. "/perm.txt", { "x" }))
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })

      local last = writes[#writes]
      assert.is_not_nil(last)
      assert.is_false(vim.startswith(last.path, "/tmp/"))
      assert.is_false(vim.startswith(last.tmp, "/tmp/"))
      assert.equals(tonumber("600", 8), last.mode)
    end)

    it("does not rewrite the file when nothing about the buffer changed", function()
      -- BufEnter fires again for a buffer you already recorded every time you
      -- come back to it, which is the commonest switch there is.
      arm_context_sync()
      local writes = capture_ctx()
      local buf = H.edit(H.write(H.tmpdir("ctx") .. "/same.txt", { "one", "two" }))
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      local after_first = #writes
      assert.is_true(after_first > 0)

      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      assert.equals(after_first, #writes)

      -- ...but a real change still gets through, or the dedupe would be a bug
      -- rather than an optimisation.
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      assert.equals(after_first + 1, #writes)
      assert.is_true(writes[#writes].text:find("Line: 2", 1, true) ~= nil)
    end)

    it("reports an unset filetype as 'unknown' rather than an empty field", function()
      arm_context_sync()
      local writes = capture_ctx()
      local buf = H.scratch({ name = H.tmpdir("ctx") .. "/plain", lines = { "x" } })
      assert.equals("", vim.bo[buf].filetype)
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      -- "Language: \n" would read as a truncated field to the model; the
      -- explicit placeholder is what makes the record parseable.
      assert.is_true(writes[#writes].text:find("Language: unknown", 1, true) ~= nil)
    end)

    it("writes nothing for a buffer with no name", function()
      arm_context_sync()
      local writes = capture_ctx()
      local buf = H.scratch({ lines = { "scratch" } })
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = buf })
      -- A `File: ` line pointing at nothing would make the MCP tool report a
      -- file the user is not in; skipping the write leaves the last real file
      -- in place, which is the useful answer.
      assert.equals(0, #writes)
    end)

    it("writes nothing for a named buffer that is not a file", function()
      -- The unnamed check alone was not enough. The file tree, a terminal, a help
      -- page and a quickfix list all have names, so entering any of them reported
      -- IT as the file you were working on: glance at the tree, ask "explain this
      -- file", and Claude was told the tree was your file. 'buftype' is what
      -- distinguishes them, and it covers the chat panel's own terminal too.
      arm_context_sync()
      local writes = capture_ctx()
      local real = H.edit(H.write(H.tmpdir("ctx") .. "/real.txt", { "x" }))
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = real })
      local after_real = #writes
      assert.is_true(after_real > 0)

      local tree = H.scratch({ name = "NvimTree_1", lines = { "  src/" }, scratch = true })
      assert.equals("nofile", vim.bo[tree].buftype)
      assert.is_true(vim.api.nvim_buf_get_name(tree) ~= "", "premise: the tree buffer has a name")
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = tree })
      assert.equals(after_real, #writes)
    end)
  end)

  describe("file_prefix", function()
    it("prefixes the prompt with the buffer's path, filetype and line", function()
      local path = H.write(H.tmpdir("prefix") .. "/main.txt", { "local x = 1" })
      local buf = H.edit(path)
      vim.bo[buf].filetype = "text"

      whole_buffer(function() claude.explain() end)

      local prompt = jobs[1][1][3]
      -- The prefix is invisible to the user, so a wrong path here is silent:
      -- Claude answers about the wrong file and nothing looks broken.
      assert.equals(("[File: %s | Language: text | Line: 1]\n\n"):format(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")),
        prompt:sub(1, prompt:find("\n\n", 1, true) + 1))
    end)

    it("omits the prefix entirely for an unnamed buffer", function()
      H.scratch({ lines = { "local x = 1" } })
      whole_buffer(function() claude.explain() end)
      -- No "[File: ]" with an empty path: an unnamed buffer has no path worth
      -- claiming, and the fabricated header would be a lie to the model.
      assert.equals("Explain", jobs[1][1][3]:sub(1, 7))
    end)

    it("omits the prefix for a named buffer that is not a file", function()
      -- Same guard as the context file, and for the same reason: a name is not
      -- evidence of a file. Selecting a line out of the file tree and pressing
      -- explain should not tell Claude the tree is the file under discussion.
      H.scratch({ name = "NvimTree_1", lines = { "  src/" }, scratch = true })
      whole_buffer(function() claude.explain() end)
      assert.equals("Explain", jobs[1][1][3]:sub(1, 7))
    end)
  end)

  describe("ask", function()
    it("passes the prompt as one argument and asks for streamed output", function()
      claude.ask("what is 2+2", "Math")
      assert.equals(1, jobs.count)
      local argv = jobs[1][1]
      assert.equals("claude", argv[1])
      assert.equals("-p", argv[2])
      -- The prompt must stay a single argv entry, or a multi-word prompt turns
      -- into extra flags for the CLI. It also has to come before the flags:
      -- --allowedTools and --mcp-config are variadic, and a prompt after them is
      -- swallowed as one of their values ("Input must be provided either through
      -- stdin or as a prompt argument").
      assert.equals("what is 2+2", argv[3])
      -- Text mode buffers the whole answer and prints it on exit, which is what
      -- made the float sit on the placeholder for the length of the request.
      assert.equals("stream-json", flag_value(argv, "--output-format"))
      assert.is_not_nil(flag_at(argv, "--include-partial-messages"))
      -- Required by the CLI to stream under -p; without it stream-json errors out
      -- and the float shows nothing at all.
      assert.is_not_nil(flag_at(argv, "--verbose"))
      assert.is_false(jobs[1][2].stdout_buffered)
    end)

    it("starts no MCP servers for a one-shot prompt", function()
      -- The user's own MCP servers have nothing to contribute to "explain this
      -- selection" and cost most of a second of startup on every keypress
      -- (measured on this machine: 3.15s with them, 2.32s without). Both flags
      -- are needed — --mcp-config alone ADDS to the user's servers, and
      -- --strict-mcp-config is what replaces them.
      claude.ask("hi", "Title")
      local argv = jobs[1][1]
      assert.is_not_nil(flag_at(argv, "--strict-mcp-config"))
      local ok, cfg = pcall(vim.json.decode, flag_value(argv, "--mcp-config") or "")
      assert.is_true(ok, "--mcp-config is not valid JSON")
      assert.same({}, cfg.mcpServers or {})
    end)

    it("warns and starts nothing when the claude CLI is not installed", function()
      -- jobstart *throws* E475 for a missing executable, so the exit-code branch
      -- advising "check that claude is installed" was unreachable: there was never
      -- a job to exit. What the user actually got was a stack trace out of the
      -- keymap and an empty float.
      H.stub(vim.fn, "executable", function() return 0 end)
      local wins = #vim.api.nvim_list_wins()
      local notes = H.capture_notifications(function() claude.ask("hi", "Title") end)
      assert.equals(0, jobs.count)
      assert.equals(wins, #vim.api.nvim_list_wins())
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("claude CLI not found", 1, true) ~= nil)
      assert.equals(vim.log.levels.ERROR, notes[1].level)
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

    it("wipes the result buffer with the window instead of hiding it", function()
      -- nvim_create_buf's scratch flag gives bufhidden = "hide", so dismissing
      -- the float used to leave the buffer valid AND loaded, holding the whole
      -- response, for the rest of the session — one per <C-a>/<C-1>…<C-6> press,
      -- never reused. Unlisted too, so nothing ever showed they were piling up.
      claude.ask("hi", "Title")
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_get_current_buf()
      assert.equals("wipe", vim.bo[buf].bufhidden)

      H.run_keymap("n", "q", buf)
      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end)

    it("stops the claude process when the result window is dismissed early", function()
      -- Dismissing the float left `claude -p` running to completion, still
      -- accumulating output and still writing into a buffer nobody can see.
      local stops = H.spy(vim.fn, "jobstop")
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()

      H.run_keymap("n", "q", buf)
      assert.equals(1, stops.count)
      -- The id jobstart handed back, not a guess: stopping the wrong job would
      -- be worse than stopping none.
      assert.equals(1, stops[1][1])
    end)

    it("does not try to stop a job that never started", function()
      -- jobstart returns 0 for an invalid argument and -1 when the binary is
      -- missing; jobstop on either is an error.
      H.stub(vim.fn, "jobstart", function() return -1 end)
      local stops = H.spy(vim.fn, "jobstop")
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()

      H.run_keymap("n", "q", buf)
      assert.equals(0, stops.count)
    end)

    it("renders tokens as they arrive, before the process has exited", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]

      opts.on_stdout(1, { delta("Hello "), "" })
      H.wait_for("first token rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      -- The whole point of the change: this is true with the job still running.
      -- Before it, text mode meant nothing appeared until on_exit.
      assert.same({ "Hello " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

      vim.wait(80)  -- past the 50ms draw throttle
      opts.on_stdout(1, { delta("world"), "" })
      H.wait_for("second token rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "Hello world"
      end, 2000)
      opts.on_exit(1, 0)
    end)

    it("keeps the placeholder until the first token arrives", function()
      -- The CLI emits its session/init events a second or two before any text.
      -- Drawing those would blank the float and leave it blank until the answer
      -- started, which reads as a hang rather than as progress.
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      jobs[1][2].on_stdout(1, { noise(), noise(), "" })
      vim.wait(120)
      assert.same({ PLACEHOLDER }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("reassembles an event split across two stdout callbacks", function()
      -- jobstart splits on \n and hands back the trailing fragment as the last
      -- element, so one JSON object routinely arrives across two callbacks. A
      -- parser that treated every element as a whole line would drop that token.
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      local line = delta("reassembled")
      local half = math.floor(#line / 2)

      opts.on_stdout(1, { line:sub(1, half) })
      opts.on_stdout(1, { line:sub(half + 1), "" })
      H.wait_for("rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      assert.same({ "reassembled" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("renders a final token that arrives with no trailing newline", function()
      -- The last line of the stream has no \n after it, so it sits in the pending
      -- buffer until on_exit flushes it. Without that flush the last token — often
      -- the end of the answer — is silently lost.
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      opts.on_stdout(1, { delta("no newline after me") })
      opts.on_exit(1, 0)
      H.wait_for("flushed on exit", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      assert.same({ "no newline after me" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("splits a multi-line token into lines", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      -- Tokens do not align with lines: one delta can carry several newlines and
      -- the next can continue the line the previous one left open. The trailing ""
      -- is jobstart's own convention — the last element of every chunk is the
      -- fragment after the final newline, so a complete line arrives as
      -- { line, "" } and omitting it means "this event is not finished yet".
      opts.on_stdout(1, { delta("one\ntw"), "" })
      opts.on_stdout(1, { delta("o\nthree"), "" })
      opts.on_exit(1, 0)
      H.wait_for("rendered", function()
        return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 3
      end, 2000)
      assert.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("appends the changed tail instead of rewriting the whole response", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      opts.on_stdout(1, { delta("l1\nl2\nl3\nl4"), "" })
      H.wait_for("first draw", function()
        return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 4
      end, 2000)

      -- Recorded only from here, so the placeholder's own full replacement (which
      -- legitimately starts at 0) is not what is being measured.
      local real_set = vim.api.nvim_buf_set_lines
      local sets = H.spy(vim.api, "nvim_buf_set_lines", function(...) return real_set(...) end)
      vim.wait(80)
      opts.on_stdout(1, { delta("\nl5"), "" })
      H.wait_for("second draw", function()
        return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 5
      end, 2000)

      assert.is_true(sets.count > 0, "no redraw happened at all")
      -- Re-sending the whole response on every chunk is quadratic in its length,
      -- and made the float flicker its entire viewport as the answer grew.
      assert.is_true(sets[sets.count][2] > 0,
        "redraw started at line 0: the whole response was re-sent")
    end)

    it("ignores output that is not a stream event", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
      -- A CLI warning on stdout, or a line truncated by the process dying, must
      -- not appear in the answer as noise.
      opts.on_stdout(1, { "Warning: something on stdout", "{not json", noise(), "" })
      opts.on_exit(1, 0)
      H.wait_for("resolved", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[1]:find("no output", 1, true) ~= nil, "showed: " .. lines[1])
    end)

    it("shows an install/auth hint when claude fails with no output", function()
      claude.ask("hi", "Title")
      local buf = vim.api.nvim_get_current_buf()
      local opts = jobs[1][2]
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
      -- claude can print a usable answer and still exit non-zero; replacing it
      -- with "check that claude is installed" would throw the answer away.
      opts.on_stdout(1, { delta("partial answer"), "" })
      opts.on_exit(1, 1)
      H.wait_for("output rendered", function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= PLACEHOLDER
      end, 2000)
      assert.same({ "partial answer" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)
  end)

  describe("visual selection", function()
    it("sends the selection on the very first visual command", function()
      -- The bug this pins: the maps in lua/config/keymaps.lua are plain Lua
      -- callbacks with no :<C-u> prefix, so they run while visual mode is STILL
      -- ACTIVE — and nvim only writes '< / '> when visual mode ends. getpos("'<")
      -- was {0,0,0,0} here, so the first visual AI command of every session
      -- reported "No text selected" and sent nothing at all.
      H.scratch({ lines = { "local x = 1", "local y = 2", "local z = 3" } })
      local notes = H.capture_notifications(function()
        visually("gg0llllllvjllll", function() claude.explain() end)
      end)
      assert.equals(0, #notes, "warned instead of sending: " .. vim.inspect(notes))
      assert.equals(1, jobs.count)
      -- From column 7 of line 1 to column 11 of line 2: the first line is trimmed
      -- from the start column and the last to the end column, so a partial
      -- selection must not silently widen to whole lines.
      assert.equals("x = 1\nlocal y = 2", sent_code())
    end)

    it("sends the live selection, not the previous one", function()
      -- After the first use the marks held the PREVIOUS selection, so every later
      -- visual command silently explained, refactored or wrote tests for code the
      -- user was no longer looking at — with no warning, and a plausible-looking
      -- answer about the wrong lines.
      H.scratch({ lines = { "AAAA", "BBBB", "CCCC" } })
      visually("gg0v$", function() claude.explain() end)
      assert.equals("AAAA", sent_code(1))
      dismiss_float()

      visually("3G0v$", function() claude.explain() end)
      assert.equals(2, jobs.count)
      assert.equals("CCCC", sent_code(2))
    end)

    it("ignores stale '< and '> marks left by an earlier selection", function()
      -- The marks are what the module used to read, so pointing them somewhere
      -- else is the direct test: a module reading them fails this, and one reading
      -- the live selection cannot notice they exist.
      local buf = H.scratch({ lines = { "WRONG LINE", "RIGHT LINE" } })
      vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
      vim.api.nvim_buf_set_mark(buf, ">", 1, 9, {})

      visually("2G0v$", function() claude.explain() end)
      assert.equals("RIGHT LINE", sent_code())
    end)

    it("selects whole lines for a linewise selection", function()
      H.scratch({ lines = { "first", "second", "third" } })
      visually("gg0lllVj", function() claude.explain() end)
      -- V from mid-line must still take both lines entire; the old byte slicing
      -- trimmed the first line at the cursor column even in linewise mode.
      assert.equals("first\nsecond", sent_code())
    end)

    it("selects a column range for a blockwise selection", function()
      H.scratch({ lines = { "xxDELTAxx", "xxECHOxx", "xxFOXxx" } })
      visually("gg0ll<C-v>jjl", function() claude.explain() end)
      -- The old helper returned whole lines here, so a <C-v> selection sent three
      -- times as much code as was highlighted.
      assert.equals("DE\nEC\nFO", sent_code())
    end)

    it("does not cut a multibyte character in half", function()
      H.scratch({ lines = { "naïve café ünïcode" } })
      visually("gg0vll", function() claude.explain() end)
      -- string.sub indexes by byte: the old helper could end a selection halfway
      -- through the two bytes of "ï" and hand Claude invalid UTF-8.
      assert.equals("naï", sent_code())
    end)

    it("warns and sends nothing when invoked outside visual mode", function()
      H.scratch({ lines = { "untouched" } })
      local notes = H.capture_notifications(function() claude.explain() end)
      -- What a stray keypress looks like. Sending an empty code fence would burn
      -- a request and answer about nothing.
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
        H.scratch({ lines = { "local x = 1" } })
        if cmd.needs_selection then
          whole_buffer(function() claude[cmd.name]() end)
        else
          claude[cmd.name]()
        end

        assert.equals(1, jobs.count)
        local argv = jobs[1][1]
        assert.equals("claude", argv[1])
        assert.equals("-p", argv[2])
        assert.is_true(argv[3]:find(cmd.contains, 1, true) ~= nil,
          cmd.name .. " prompt was: " .. argv[3])
        if cmd.needs_selection then
          -- The code has to arrive inside a fence, or a snippet containing
          -- prose is read as instructions rather than as the subject.
          assert.equals("local x = 1", sent_code())
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
        H.scratch({ lines = { "local x = 1" } })
        whole_buffer(function() claude.ask_about() end)
        dismiss_float()
        claude.prompt()
      end
      -- <Esc> at the "Ask Claude:" prompt must not fire a request built from
      -- nothing but the file header.
      assert.equals(0, jobs.count)
    end)

    it("adds no language-specific test hint for a neutral filetype", function()
      local buf = H.scratch({ name = H.tmpdir("hint") .. "/main.txt", lines = { "local x = 1" } })
      vim.bo[buf].filetype = "text"
      whole_buffer(function() claude.generate_tests() end)
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
      terms = H.spy(vim.fn, "termopen", function() return 1 end)
      capture_ctx()
      claude = fresh_claude()
    end)

    it("registers the context MCP server on the panel's own invocation", function()
      -- The headline defect this replaces: mcp/nvim_context_server.py was
      -- registered NOWHERE — no .mcp.json in the repo or $HOME, and no
      -- `claude mcp add` entry — so get_current_file was not callable, the system
      -- prompt was an instruction to call a tool that did not exist, and every
      -- BufEnter wrote a file nothing ever read. Registering it inline is what
      -- makes pulling this repo the whole install.
      claude.toggle_chat()
      assert.equals(1, terms.count)
      local argv = terms[1][1]
      assert.equals("claude", argv[1])

      local ok, cfg = pcall(vim.json.decode, flag_value(argv, "--mcp-config") or "")
      assert.is_true(ok, "--mcp-config is not valid JSON: " .. tostring(flag_value(argv, "--mcp-config")))
      local server = assert(cfg.mcpServers["nvim-context"], "no nvim-context server registered")
      assert.equals(1, #server.args)
      assert.equals(1, vim.fn.filereadable(server.args[1]),
        "registered a script that is not there: " .. server.args[1])
      assert.equals(1, vim.fn.executable(server.command))
      -- The server takes the path from the environment so there is exactly one
      -- definition of it; a hardcoded copy on the Python side is how the two
      -- halves drift apart without either looking wrong.
      assert.equals(CTX_FILE, server.env.NVIM_CLAUDE_CTX)

      -- Pre-approved, or the "silent" context lookup opens a permission prompt on
      -- the first message of every session.
      assert.equals("mcp__nvim-context__get_current_file", flag_value(argv, "--allowedTools"))
      -- NOT --strict-mcp-config here, the opposite of the one-shot prompts: this
      -- is a conversation, and disabling the user's own MCP servers for as long as
      -- the panel is open would be a surprise.
      assert.is_nil(flag_at(argv, "--strict-mcp-config"))
    end)

    it("spawns claude with the MCP system prompt", function()
      claude.toggle_chat()
      local argv = terms[1][1]
      -- The system prompt is the entire mechanism by which the panel knows which
      -- file you are in — if the tool name drifts, the panel still opens and just
      -- never has context.
      assert.is_true((flag_value(argv, "--append-system-prompt") or "")
        :find("get_current_file", 1, true) ~= nil)
      -- $EDITOR inside the panel must be nvim, not whatever the parent shell
      -- exported, or `claude` opens a nested editor the user cannot see.
      assert.same({ EDITOR = "nvim", VISUAL = "nvim" }, terms[1][2].env)
    end)

    it("still opens a working panel on a machine with no python3", function()
      -- Degrading, not breaking: the MCP server is a convenience, and a machine
      -- without python3 should lose "which file am I in", not the chat. Passing
      -- --mcp-config for a server that cannot start would make `claude` complain
      -- on every open.
      local real_exepath = vim.fn.exepath
      H.stub(vim.fn, "exepath", function(name)
        return name == "python3" and "" or real_exepath(name)
      end)
      claude = fresh_claude()
      claude.toggle_chat()

      local argv = terms[1][1]
      assert.same({ "claude" }, argv)
      assert.is_nil(flag_at(argv, "--mcp-config"))
      -- And no system prompt telling Claude to call a tool that is not there:
      -- that costs a turn and surfaces as a confusing error in a mechanism the
      -- user is not supposed to see at all.
      assert.is_nil(flag_at(argv, "--append-system-prompt"))
    end)

    it("does not open a panel or leak a buffer when the claude CLI is missing", function()
      -- termopen throws E475 for a missing binary, and the scratch buffer is
      -- created before it, so the throw used to leave one behind on every attempt
      -- — unlisted, so nothing showed they were piling up.
      H.stub(vim.fn, "executable", function() return 0 end)
      claude = fresh_claude()
      local wins = #vim.api.nvim_list_wins()
      local bufs = #vim.api.nvim_list_bufs()

      local notes = H.capture_notifications(function() claude.toggle_chat() end)
      assert.equals(0, terms.count)
      assert.equals(wins, #vim.api.nvim_list_wins())
      assert.equals(bufs, #vim.api.nvim_list_bufs())
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("claude CLI not found", 1, true) ~= nil)
    end)

    it("does not poll the editor on a timer while the panel is open", function()
      -- There used to be a 2s repeating checktime timer, live for as long as the
      -- panel was, to pick up files Claude wrote. It could not do that: it
      -- returned early whenever mode() == "t", which is exactly when you are
      -- watching Claude work. Every moment it *did* fire, config.autocmds'
      -- auto_reload group already covered — CursorHold at updatetime = 250ms,
      -- BufEnter, and TermLeave, which that module names for this case.
      local timers = H.spy(vim.uv, "new_timer")
      claude.toggle_chat()
      assert.equals(0, timers.count)
    end)

    it("sizes the panel from the terminal width instead of a fixed 80 columns", function()
      -- `botright 80vsplit` left the code window zero columns wide on an
      -- 80-column terminal — a bare ssh session, a split tmux pane — so opening
      -- the panel hid the file you wanted to ask about.
      vim.o.columns = 80
      claude.toggle_chat()
      local panel = vim.api.nvim_get_current_win()
      assert.is_true(vim.api.nvim_win_get_width(panel) < 80)
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= panel then
          assert.is_true(vim.api.nvim_win_get_width(w) > 20,
            "code window collapsed to " .. vim.api.nvim_win_get_width(w) .. " columns")
        end
      end
    end)

    it("caps the panel width on a very wide terminal", function()
      -- 40% of an ultrawide screen is half the editor given to a chat log.
      vim.o.columns = 400
      claude.toggle_chat()
      assert.equals(80, vim.api.nvim_win_get_width(vim.api.nvim_get_current_win()))
    end)

    it("opens a window, and closes it on the second toggle", function()
      local before = #vim.api.nvim_list_wins()
      claude.toggle_chat()
      assert.equals(before + 1, #vim.api.nvim_list_wins())
      claude.toggle_chat()
      assert.equals(before, #vim.api.nvim_list_wins())
    end)

    it("closes a panel that is the only window left, and stays usable after", function()
      -- Closing the last window is E444, and the throw escaped from close_panel
      -- *before* state.win was cleared — so panel_is_open() kept reporting true
      -- and every later <C-g> hit the same error. The panel became permanently
      -- unclosable for the rest of the session. Reached by :q or <C-w>c in the
      -- code window, or :only from the panel.
      claude.toggle_chat()
      local panel_buf = vim.api.nvim_get_current_buf()
      local panel_win = vim.api.nvim_get_current_win()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= panel_win then pcall(vim.api.nvim_win_close, w, true) end
      end
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

      claude.toggle_chat()
      assert.is_true(vim.api.nvim_win_get_buf(0) ~= panel_buf, "panel did not go away")

      -- ...and the next toggle opens rather than throwing again, on the SAME
      -- terminal buffer: the conversation has to survive being closed this way.
      claude.toggle_chat()
      assert.equals(panel_buf, vim.api.nvim_get_current_buf())
      assert.equals(1, terms.count)
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

    it("tears the panel down when claude itself exits", function()
      -- `claude` exiting (/exit, Ctrl-D, a crash, an auth timeout) used to nil
      -- the handles and nothing else. That left the "[Process exited]" terminal
      -- buffer AND its window on screen, while panel_is_open() started reporting
      -- false because it reads state.win — so the next toggle opened a SECOND
      -- split with a SECOND terminal on top of the stale one.
      claude.toggle_chat()
      local buf = vim.api.nvim_get_current_buf()
      local win = vim.api.nvim_get_current_win()
      local before = #vim.api.nvim_list_wins()

      -- The on_exit termopen was handed, invoked the way the job would.
      terms[1][2].on_exit(1, 0, "exit")
      vim.wait(200, function() return not vim.api.nvim_buf_is_valid(buf) end)

      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
      assert.equals(before - 1, #vim.api.nvim_list_wins())
    end)

    it("starts a single fresh panel after claude exited", function()
      -- The observable consequence of the bug above. Absolute counts, not counts
      -- relative to "after the exit": a relative assertion passes even with the
      -- stale window still on screen, which is the exact bug being pinned.
      local baseline = #vim.api.nvim_list_wins()
      claude.toggle_chat()
      terms[1][2].on_exit(1, 0, "exit")
      vim.wait(200, function() return #vim.api.nvim_list_wins() == baseline end)
      assert.equals(baseline, #vim.api.nvim_list_wins())

      claude.toggle_chat()
      assert.equals(baseline + 1, #vim.api.nvim_list_wins())
      -- A fresh spawn is correct here (the old session is gone), but exactly one.
      assert.equals(2, terms.count)
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
      -- termopen is spied, so this buffer is not a real terminal: 'buftype' is
      -- "nofile" rather than "terminal", non-empty either way, which is what makes
      -- the guard right for the real thing too ('buftype' cannot be set to
      -- "terminal" by hand — E474 — so a spec cannot fake one more closely).
      -- Being unnamed as well, it would also be declined by the older
      -- name-only check, so what pins the buftype guard itself is the named
      -- non-file buffer above, not this case.
      assert.is_true(vim.bo[panel_buf].buftype ~= "")

      -- Positive control. Without it this case passes on a module that never
      -- writes at all — which is how it used to pass: the spied panel buffer was
      -- also unnamed, so the old "is it unnamed" check was what declined it and
      -- the guard being tested was never reached.
      vim.cmd("wincmd p")
      local file = H.edit(H.write(H.tmpdir("panelctx") .. "/real.txt", { "x" }))
      vim.api.nvim_exec_autocmds("BufEnter", { group = "claude_context_sync", buffer = file })
      assert.equals(1, #writes)
    end)
  end)
end)
