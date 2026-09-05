-- Claude CLI integration — uses `claude` (Claude Code) already on your system.
-- Chat opens as a persistent right-side panel that toggles open/closed.
--
-- File context is tracked silently via an MCP server (mcp/nvim_context_server.py).
-- Neovim writes the current file to a per-user context file; Claude calls the
-- get_current_file MCP tool to read it — nothing in the UI. That server is wired
-- up with --mcp-config on the panel's own `claude` invocation (see mcp_args), so
-- it needs no `claude mcp add` and no .mcp.json: pulling this config onto a new
-- machine is enough. It used to be registered NOWHERE, which made the tool
-- uncallable, made the system prompt below an instruction to call something that
-- did not exist, and made every BufEnter write a file nothing ever read.

local M = {}

--- Where the context file lives.
---
--- Not a fixed name in /tmp. That directory is world-writable and shared by every
--- user on the machine, so on a multi-user Linux box another account can create
--- the path first — as a symlink of its choosing — and this config's write then
--- lands wherever they pointed it, with the name of every file you open as the
--- payload. $XDG_RUNTIME_DIR is the per-user 0700 tmpfs on any systemd Linux;
--- stdpath("cache") is the fallback and is per-user on all three platforms.
local CTX_FILE = (function()
  local runtime = vim.env.XDG_RUNTIME_DIR
  if runtime and runtime ~= "" and vim.fn.isdirectory(runtime) == 1 then
    return runtime .. "/nvim-claude-ctx"
  end
  return vim.fn.stdpath("cache") .. "/nvim-claude-ctx"
end)()

--- How wide the chat panel opens.
---
--- Was a hardcoded `botright 80vsplit`, which on an 80-column terminal — a bare
--- ssh session, a split tmux pane — left the code window zero columns wide, so
--- opening the panel hid the file you wanted to ask about. 0.4 is the same
--- proportion lua/plugins/terminal.lua:8 uses for its vertical terminal, and the
--- 80 cap keeps it from ballooning to half an ultrawide screen.
local function panel_width()
  return math.min(80, math.floor(vim.o.columns * 0.4))
end

local state = {
  buf = nil,  -- the persistent terminal buffer
  win = nil,  -- the panel window (nil when hidden)
}

--- Has the panel been started this session? The MCP server is the only consumer
--- of the context file and is only launched with the panel, so before that first
--- toggle every BufEnter write is pure waste. (The floating-window commands carry
--- their context inline via file_prefix instead, so they do not need it either.)
local panel_started = false

-- ── Context file writer ──────────────────────────────────────────────────────

--- Last content written, so an unchanged buffer costs nothing.
local last_context = nil

--- One write at a time, newest content wins (see flush_context).
local writing = false
local queued  = nil

--- Where the half-written record lives before it is renamed into place.
---
--- Per-process, because $XDG_RUNTIME_DIR is shared by every nvim this user is
--- running and two of them writing the same temp file would interleave.
local TMP_FILE = string.format("%s.%d.tmp", CTX_FILE, vim.uv.os_getpid())

--- Write `queued` to CTX_FILE, then whatever arrived while that was happening.
---
--- Serialized rather than fired-and-forgotten. These are async renames, so
--- letting several run at once means they can COMPLETE out of order: stepping
--- through a telescope preview queued 80 writes and the file was left showing
--- neither the first nor the last buffer, just whichever rename happened to land
--- last. Measured before this: 80 switches ending on other.py left the context
--- reading Real.java. Holding one in flight and keeping only the newest pending
--- content makes the last buffer you entered the one that is recorded, and cuts
--- the syscalls under churn to a fraction.
local function flush_context()
  if writing or not queued then return end
  writing = true
  local content = queued
  queued = nil

  local function finish()
    writing = false
    flush_context()
  end

  -- 0600: the whole point of the per-user directory above is that nobody else
  -- gets to read which files you have open.
  vim.uv.fs_open(TMP_FILE, "w", tonumber("600", 8), function(err, fd)
    if err or not fd then return finish() end
    vim.uv.fs_write(fd, content, 0, function()
      vim.uv.fs_close(fd, function()
        -- rename(2) inside one directory is atomic, so the server never reads a
        -- partial record. Writing CTX_FILE directly could not give that: opening
        -- it "w" truncates, so a get_current_file landing between the truncate
        -- and the write saw an empty file and reported no context at all.
        vim.uv.fs_rename(TMP_FILE, CTX_FILE, function(rename_err)
          -- Do not leave debris in the runtime dir if the rename could not happen.
          if rename_err then vim.uv.fs_unlink(TMP_FILE, function() end) end
          finish()
        end)
      end)
    end)
  end)
end

--- Record the current buffer's identity where the MCP server can read it.
---
--- Asynchronous and deduplicated, because this runs on every BufEnter — every
--- :bnext, every window switch, every step through a telescope preview. Measured
--- on this machine: the io.open/write/close form this replaces cost 653us per
--- call, essentially all of it the synchronous write; vim.uv.fs_open returns in
--- 0.8us and does the write off the main loop. The dedupe removes even that for
--- the commonest case, re-entering a buffer you just left.
--- True when the current buffer is a real file the user is editing.
---
--- The unnamed check alone was not enough: a terminal, the file tree, a help page
--- and a quickfix list all have names, so entering any of them reported IT as
--- "the file you are working on" — ask "explain this file" after glancing at the
--- tree and Claude was told the tree was your file. 'buftype' is empty for
--- exactly the real-file case, and it also subsumes the chat panel itself
--- (terminal), which used to need its own special case at the BufEnter below.
local function editing_a_file()
  return vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= ""
end

local function write_context()
  if not editing_a_file() then return end
  local rel  = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~:.")
  local ft   = vim.bo.filetype
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local content = string.format(
    "File: %s\nLanguage: %s\nLine: %d",
    rel, ft ~= "" and ft or "unknown", line
  )
  if content == last_context then return end
  last_context = content
  queued = content
  flush_context()
end

-- Prefix for floating-window prompts (invisible — user sees only the response)
local function file_prefix()
  if not editing_a_file() then return "" end
  return string.format(
    "[File: %s | Language: %s | Line: %d]\n\n",
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~:."),
    vim.bo.filetype ~= "" and vim.bo.filetype or "unknown",
    vim.api.nvim_win_get_cursor(0)[1]
  )
end

-- ── Buffer-switch context sync (silent — writes to file, not terminal) ───────

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("claude_context_sync", { clear = true }),
  callback = function()
    if not panel_started then return end
    -- No state.buf check: write_context's buftype guard already declines the
    -- panel's own terminal buffer, along with every other non-file buffer.
    write_context()
  end,
})

-- ── Panel toggle ────────────────────────────────────────────────────────────

local function panel_is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local close_panel

--- The `claude` flags that register mcp/nvim_context_server.py for this session,
--- or nil when it cannot run here.
---
--- Registered per invocation rather than through `claude mcp add` or a .mcp.json:
--- both of those are machine state this repo cannot carry, so the integration
--- would silently be dead on every machine but the one it was set up on — which is
--- exactly the state it was found in. Passing the config inline means pulling the
--- repo is the whole install.
---
--- --allowedTools pre-approves the one tool, because a permission prompt for a
--- read of a file this config just wrote would defeat the point of doing it
--- silently. NOT --strict-mcp-config: that would also disable the user's own MCP
--- servers for the duration of the panel.
local function mcp_args()
  local script = vim.fn.stdpath("config") .. "/mcp/nvim_context_server.py"
  local python = vim.fn.exepath("python3")
  -- Degrade rather than break: without python3 the panel is still a perfectly
  -- good Claude session, it just cannot answer "which file am I in".
  if python == "" or vim.fn.filereadable(script) == 0 then return nil end
  return {
    "--mcp-config",
    vim.json.encode({
      mcpServers = {
        ["nvim-context"] = {
          command = python,
          args = { script },
          -- The server reads the path from here rather than hardcoding it, so
          -- there is one definition of where the context file lives.
          env = { NVIM_CLAUDE_CTX = CTX_FILE },
        },
      },
    }),
    "--allowedTools",
    "mcp__nvim-context__get_current_file",
  }
end

--- Is the CLI actually here? Both termopen and jobstart *throw* E475 ("... is not
--- executable") rather than reporting a failure, so without this check the very
--- first <C-g> on a machine that has not installed Claude Code was a stack trace
--- out of the keymap — and in the panel's case it left the scratch buffer it had
--- already created behind, since the error escaped before any cleanup.
local function claude_missing()
  if vim.fn.executable("claude") == 1 then return false end
  vim.notify(
    "claude CLI not found on $PATH. Install Claude Code to use the AI commands.",
    vim.log.levels.ERROR
  )
  return true
end

--- The panel's terminal buffer, or nil when `claude` could not be started.
local function create_terminal_buf()
  if claude_missing() then return nil end

  local buf = vim.api.nvim_create_buf(false, true)

  local cmd = { "claude" }
  local mcp = mcp_args()
  if mcp then
    vim.list_extend(cmd, mcp)
    -- Only claim the tool exists when it actually got registered. Telling Claude
    -- to call a tool that is not there wastes a turn and produces a confusing
    -- "tool not found" in what is supposed to be an invisible mechanism.
    vim.list_extend(cmd, {
      "--append-system-prompt",
      "You have access to an MCP tool called get_current_file. " ..
      "Call it automatically whenever the user refers to 'this file', " ..
      "'the current file', 'open file', or any file without naming it explicitly. " ..
      "Also call it at the start of the conversation to know what the user is working on.",
    })
  end

  -- pcall'd as well as pre-checked: `claude` can be on PATH and still fail to
  -- spawn (a dangling shim, a permissions bit, an exec-format error), and the
  -- scratch buffer above has to be cleaned up if it does.
  local spawned = pcall(vim.api.nvim_buf_call, buf, function()
    vim.fn.termopen(cmd, {
      env = { EDITOR = "nvim", VISUAL = "nvim" },
      on_exit = function()
        -- `claude` exiting — /exit, Ctrl-D, a crash, an auth timeout — used to
        -- nil these handles and nothing else. That left BOTH the
        -- "[Process exited]" terminal buffer (with its whole scrollback: Claude
        -- streams a lot, so this reached the 10 000-line cap routinely) and its
        -- window behind, while panel_is_open() started reporting false because
        -- it reads state.win. So the next <C-g> took the open_panel path and
        -- added a SECOND split with a SECOND terminal, on top of the stale one.
        -- The orphan is buflisted = false, so it did not even appear in :ls.
        --
        -- Read the handles out before clearing, then tear down for real.
        local buf, win = state.buf, state.win
        state.buf, state.win = nil, nil
        -- Scheduled: this runs from the job's own exit callback, where the
        -- terminal buffer is not yet in a state that can be deleted.
        vim.schedule(function()
          if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
          end
          if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end)
      end,
    })
  end)
  if not spawned then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify("Could not start the claude CLI.", vim.log.levels.ERROR)
    return nil
  end
  vim.bo[buf].buflisted = false

  vim.keymap.set("t", "<C-g>", function()
    close_panel()
  end, { buffer = buf, silent = true, desc = "AI: Close Claude panel" })

  return buf
end

close_panel = function()
  if panel_is_open() then
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
      -- Closing the only window is E444. That happens whenever the code window
      -- goes away while the panel is up (:q in it, <C-w>c, :only from the panel),
      -- and the throw escaped *before* state.win was cleared — so panel_is_open()
      -- kept returning true and every later <C-g> hit the same error. The panel
      -- was then unclosable for the rest of the session. Hand the window an empty
      -- buffer instead; the terminal buffer stays alive (bufhidden is "hide"), so
      -- the next toggle reattaches to the same Claude session rather than starting
      -- a new one.
      --
      -- The buffer is created explicitly rather than with :enew, which REUSES the
      -- current buffer when it is already empty and unnamed and so left the panel
      -- window showing the panel — measured: after :enew, nvim_win_get_buf still
      -- returned the same bufnr.
      local empty = vim.api.nvim_create_buf(true, false)
      if not pcall(vim.api.nvim_win_set_buf, state.win, empty) then
        pcall(vim.api.nvim_buf_delete, empty, { force = true })
      end
    else
      pcall(vim.api.nvim_win_close, state.win, false)
    end
  end
  state.win = nil
end

local function open_panel()
  -- Started before the split, while the current window is still the code window,
  -- so state below is created only if the terminal actually came up.
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = create_terminal_buf()
    if not state.buf then return end
  end

  -- The BufEnter sync is gated on this, and the panel is about to become the
  -- current window, so the write below is the one that records the file you were
  -- actually in when you asked. last_context is cleared first because that write
  -- must happen even if nothing changed — the file may not exist yet at all.
  panel_started = true
  last_context = nil
  write_context()

  vim.cmd("botright " .. panel_width() .. "vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  local wo = vim.wo[state.win]
  wo.number         = false
  wo.relativenumber = false
  wo.signcolumn     = "no"
  wo.wrap           = true

  -- No polling timer here. There used to be one running `checktime` every 2s for
  -- as long as the panel was open, to pick up files Claude wrote. It could not
  -- actually do that: it skipped whenever mode() == "t", which is precisely when
  -- you are sitting in the panel watching Claude work, and every moment it did
  -- fire was a moment config.autocmds' auto_reload group already covers —
  -- BufEnter, CursorHold at updatetime = 250ms, and TermLeave, which that module's
  -- comment names for this exact case.
  vim.cmd("startinsert")
end

function M.toggle_chat()
  if panel_is_open() then
    close_panel()
  else
    open_panel()
  end
end

function M.focus_chat()
  if panel_is_open() then
    vim.api.nvim_set_current_win(state.win)
    vim.cmd("startinsert")
  else
    open_panel()
  end
end

-- ── Floating result window for quick commands ────────────────────────────────

function M.ask(prompt, title)
  title = title or "Claude"
  -- Checked before the float is created, so a machine without the CLI gets one
  -- clear message instead of an empty window and a stack trace. The exit_code
  -- branch below that advises "check that claude is installed" was unreachable:
  -- jobstart throws for a missing executable, so there was never a job to exit.
  if claude_missing() then return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  -- nvim_create_buf's scratch flag gives bufhidden = "hide", not "wipe": closing
  -- the float left the buffer valid AND loaded, holding the entire response, for
  -- the rest of the session. One per <C-a>/<C-1>…<C-6> press, never reused — the
  -- bytes are small but the count is unbounded, and none of them are listed, so
  -- nothing ever showed they were there.
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  Asking Claude…" })

  local width  = math.floor(vim.o.columns * 0.75)
  local height = math.floor(vim.o.lines   * 0.65)
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    col       = math.floor((vim.o.columns - width)  / 2),
    row       = math.floor((vim.o.lines   - height) / 2),
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
  })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, silent = true })
  end

  -- ── Response rendering ─────────────────────────────────────────────────────
  -- `lines` is the answer so far; its last entry is still growing, because a
  -- delta can end mid-line. `drawn` is how many of them the buffer already shows.
  local lines     = { "" }
  local drawn     = 0
  local last_draw = 0
  local pending   = ""  -- an incomplete stdout line, see on_stdout

  --- Push the response into the buffer, at most every 50ms.
  ---
  --- Append-only. The old version re-sent the entire response on every chunk,
  --- which is quadratic in its length and made the float flicker its whole
  --- viewport as the answer grew. The throttle is a timestamp rather than a timer
  --- so there is no handle to leak if the float is dismissed mid-stream; on_exit
  --- forces a final draw, so nothing is left unrendered.
  local function draw(force)
    -- The CLI emits its session/init events a second or two before the first
    -- token. Drawing those would replace "Asking Claude…" with a blank float and
    -- leave it blank until the answer starts, which reads as a hang.
    if #lines == 1 and lines[1] == "" then return end
    local now = vim.uv.hrtime()
    if not force and now - last_draw < 50e6 then return end
    last_draw = now
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local from = math.max(drawn - 1, 0)
    vim.api.nvim_buf_set_lines(buf, from, -1, false, vim.list_slice(lines, from + 1))
    drawn = #lines
  end

  local function append(text)
    if text == "" then return end
    local parts = vim.split(text, "\n", { plain = true })
    lines[#lines] = lines[#lines] .. parts[1]
    for i = 2, #parts do
      lines[#lines + 1] = parts[i]
    end
  end

  local function handle_line(line)
    if line == "" then return end
    local ok, msg = pcall(vim.json.decode, line)
    -- Anything that is not one of our events — a CLI warning that went to
    -- stdout, a line truncated by the process dying — is ignored rather than
    -- shown as noise in what is meant to be a readable answer.
    if not ok or type(msg) ~= "table" then return end
    if msg.type ~= "stream_event" then return end
    local ev = msg.event or {}
    if ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
      append(ev.delta.text or "")
    end
  end

  local cmd = {
    "claude", "-p", prompt,
    -- Text mode buffers the entire answer and prints it when the process exits,
    -- so the float sat on "Asking Claude…" for the whole request — ten seconds
    -- and up for anything real — and then filled in at once. stream-json emits
    -- each token as it arrives. --verbose is what the CLI requires to stream
    -- under -p, and --include-partial-messages is what turns the per-token
    -- content_block_delta events on.
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    -- The user's own MCP servers have nothing to contribute to "explain this
    -- selection" and cost most of a second of startup on every keypress
    -- (measured on this machine: 3.15s with them, 2.32s without). The panel does
    -- the opposite on purpose — there you are having a conversation and may well
    -- want them. Note both flags are needed: --mcp-config alone *adds* to the
    -- user's servers, --strict-mcp-config is what replaces them.
    "--strict-mcp-config",
    "--mcp-config", '{"mcpServers":{}}',
  }

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      -- jobstart splits on \n and hands back the trailing fragment as the last
      -- element, so one JSON object can arrive across two callbacks.
      for i = 1, #data do
        pending = pending .. data[i]
        if i < #data then
          handle_line(pending)
          pending = ""
        end
      end
      vim.schedule(function() draw(false) end)
    end,
    on_exit = function(_, exit_code)
      handle_line(pending)  -- the final line may arrive with no trailing newline
      pending = ""
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        if table.concat(lines, "\n"):match("%S") then
          draw(true)
          return
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          exit_code ~= 0
            and ("  Claude exited with an error (code " .. exit_code .. ").")
            or  "  Claude returned no output.",
          "  Check that `claude` is installed and authenticated.",
        })
      end)
    end,
  })

  -- Dismissing the float early (q/<Esc>) left `claude -p` running to completion,
  -- still appending to `output` and still writing into a buffer nobody can see.
  -- Wiping the buffer is the one event that covers every way the float can go
  -- away, including :q, :bd and closing the tab.
  if job > 0 then
    vim.api.nvim_create_autocmd("BufWipeout", {
      -- clear = false: the group is shared by every concurrent M.ask float, so
      -- clearing it here would drop the other floats' jobstop handlers. Each
      -- entry removes itself anyway (`once`, plus the buffer it is bound to is
      -- the thing being wiped), so nothing accumulates.
      group = vim.api.nvim_create_augroup("claude_ask_jobs", { clear = false }),
      buffer = buf,
      once = true,
      callback = function() pcall(vim.fn.jobstop, job) end,
    })
  end
end

-- ── Visual selection helpers ─────────────────────────────────────────────────

--- The text selected right now, read from the live selection rather than the
--- '< and '> marks.
---
--- Those marks were the bug. The visual-mode maps in lua/config/keymaps.lua are
--- plain Lua callbacks with no :<C-u> prefix, so they run while visual mode is
--- STILL ACTIVE — and nvim only writes '< and '> when visual mode ends. Measured
--- on 0.12.4: getpos("'<") is {0,0,0,0} the first time in a buffer, so the first
--- visual AI command of every session reported "No text selected"; after that the
--- marks held the PREVIOUS selection, so every later one silently explained,
--- refactored or wrote tests for code you were no longer looking at. `v` and `.`
--- are the two live ends of the current selection and are correct on the first
--- use.
---
--- getregion also replaces string.sub slicing, which indexed by byte (cutting
--- multibyte characters in half), returned whole lines for a blockwise <C-v>
--- selection, and ignored 'selection' = exclusive.
local function get_visual_selection()
  local mode = vim.fn.mode()
  -- v, V or <C-v>. The maps are "x" mode, so select mode cannot reach here.
  if not mode:match("^[vV\22]") then return "" end
  local ok, region = pcall(
    vim.fn.getregion, vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode }
  )
  if not ok then return "" end
  return table.concat(region, "\n")
end

-- Visual-mode AI commands need a real selection; guards against a stray
-- keypress (or the marks not being where expected) firing an empty-code request.
local function get_selection_or_warn()
  local code = get_visual_selection()
  if code == "" then
    vim.notify("No text selected", vim.log.levels.WARN)
    return nil
  end
  return code
end

function M.explain()
  local code = get_selection_or_warn()
  if not code then return end
  M.ask(file_prefix() .. "Explain this code clearly and concisely:\n\n```\n" .. code .. "\n```", "Explain")
end

function M.refactor()
  local code = get_selection_or_warn()
  if not code then return end
  M.ask(file_prefix() .. "Refactor this code to be cleaner and more idiomatic. Show the improved version with a brief explanation:\n\n```\n" .. code .. "\n```", "Refactor")
end

function M.generate_tests()
  local code = get_selection_or_warn()
  if not code then return end
  local ft   = vim.bo.filetype
  local hint = ft == "java" and "Use JUnit 5 and Mockito."
            or ft == "typescript" and "Use Jest." or ""
  M.ask(file_prefix() .. "Write unit tests for this code. " .. hint .. "\n\n```\n" .. code .. "\n```", "Generate Tests")
end

function M.fix()
  local code = get_selection_or_warn()
  if not code then return end
  M.ask(file_prefix() .. "Find and fix bugs in this code. Show the corrected version and explain what was wrong:\n\n```\n" .. code .. "\n```", "Fix")
end

function M.generate_docs()
  local code = get_selection_or_warn()
  if not code then return end
  M.ask(file_prefix() .. "Write documentation/docstring for this code:\n\n```\n" .. code .. "\n```", "Generate Docs")
end

function M.ask_about()
  local code = get_selection_or_warn()
  if not code then return end
  vim.ui.input({ prompt = "Ask Claude: " }, function(q)
    if q and q ~= "" then
      M.ask(file_prefix() .. q .. "\n\n```\n" .. code .. "\n```", "Claude")
    end
  end)
end

function M.prompt()
  vim.ui.input({ prompt = "Ask Claude: " }, function(q)
    if q and q ~= "" then
      M.ask(file_prefix() .. q, "Claude")
    end
  end)
end

return M
