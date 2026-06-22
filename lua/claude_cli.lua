-- Claude CLI integration — uses `claude` (Claude Code) already on your system.
-- Chat opens as a persistent right-side panel that toggles open/closed.
--
-- File context is tracked silently via an MCP server (nvim_context_server.py).
-- On every BufEnter, Neovim writes the current file to /tmp/nvim-claude-ctx.
-- Claude calls the get_current_file MCP tool to read it — nothing in the UI.

local M = {}

local CTX_FILE = "/tmp/nvim-claude-ctx"

local state = {
  buf   = nil,  -- the persistent terminal buffer
  win   = nil,  -- the panel window (nil when hidden)
  timer = nil,  -- reload timer active while panel is open
}

local function start_reload_timer()
  if state.timer then return end
  state.timer = vim.uv.new_timer()
  state.timer:start(2000, 2000, vim.schedule_wrap(function()
    -- Skip while terminal is actively rendering (Claude streaming output)
    -- to avoid cursor corruption. Fires normally when in any other mode.
    if vim.fn.mode() == "t" then return end
    vim.cmd("silent! checktime")
  end))
end

local function stop_reload_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- ── Context file writer ──────────────────────────────────────────────────────

local function write_context()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then return end
  local rel  = vim.fn.fnamemodify(path, ":~:.")
  local ft   = vim.bo.filetype
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local content = string.format(
    "File: %s\nLanguage: %s\nLine: %d",
    rel, ft ~= "" and ft or "unknown", line
  )
  local f = io.open(CTX_FILE, "w")
  if f then f:write(content) f:close() end
end

-- Prefix for floating-window prompts (invisible — user sees only the response)
local function file_prefix()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then return "" end
  return string.format(
    "[File: %s | Language: %s | Line: %d]\n\n",
    vim.fn.fnamemodify(path, ":~:."),
    vim.bo.filetype ~= "" and vim.bo.filetype or "unknown",
    vim.api.nvim_win_get_cursor(0)[1]
  )
end

-- ── Buffer-switch context sync (silent — writes to file, not terminal) ───────

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("claude_context_sync", { clear = true }),
  callback = function()
    if state.buf and state.buf == vim.api.nvim_get_current_buf() then return end
    write_context()
  end,
})

-- ── Panel toggle ────────────────────────────────────────────────────────────

local function panel_is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local close_panel

local function create_terminal_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  -- System prompt instructs Claude to use the MCP tool automatically
  local system_prompt =
    "You have access to an MCP tool called get_current_file. " ..
    "Call it automatically whenever the user refers to 'this file', " ..
    "'the current file', 'open file', or any file without naming it explicitly. " ..
    "Also call it at the start of the conversation to know what the user is working on."

  vim.api.nvim_buf_call(buf, function()
    vim.fn.termopen({ "claude", "--append-system-prompt", system_prompt }, {
      env = { EDITOR = "nvim", VISUAL = "nvim" },
      on_exit = function()
        state.buf = nil
        state.win = nil
        stop_reload_timer()
      end,
    })
  end)
  vim.bo[buf].buflisted = false

  vim.keymap.set("t", "<C-g>", function()
    close_panel()
  end, { buffer = buf, silent = true, desc = "AI: Close Claude panel" })

  return buf
end

close_panel = function()
  if panel_is_open() then
    vim.api.nvim_win_close(state.win, false)
  end
  state.win = nil
  stop_reload_timer()
end

local function open_panel()
  -- Write context before opening so it's ready when Claude starts
  write_context()

  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = create_terminal_buf()
  end

  vim.cmd("botright 80vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  local wo = vim.wo[state.win]
  wo.number         = false
  wo.relativenumber = false
  wo.signcolumn     = "no"
  wo.wrap           = true

  vim.cmd("startinsert")
  start_reload_timer()
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
  local output = {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
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

  vim.fn.jobstart({ "claude", "-p", prompt }, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        table.insert(output, line)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.schedule(function()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
        end)
      end
    end,
    on_exit = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
        end
      end)
    end,
  })
end

-- ── Visual selection helpers ─────────────────────────────────────────────────

local function get_visual_selection()
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  local lines = vim.fn.getline(s[2], e[2])
  if #lines == 0 then return "" end
  lines[#lines] = string.sub(lines[#lines], 1, e[3])
  lines[1]      = string.sub(lines[1], s[3])
  return table.concat(lines, "\n")
end

function M.explain()
  local code = get_visual_selection()
  M.ask(file_prefix() .. "Explain this code clearly and concisely:\n\n```\n" .. code .. "\n```", "Explain")
end

function M.refactor()
  local code = get_visual_selection()
  M.ask(file_prefix() .. "Refactor this code to be cleaner and more idiomatic. Show the improved version with a brief explanation:\n\n```\n" .. code .. "\n```", "Refactor")
end

function M.generate_tests()
  local code = get_visual_selection()
  local ft   = vim.bo.filetype
  local hint = ft == "java" and "Use JUnit 5 and Mockito."
            or ft == "typescript" and "Use Jest." or ""
  M.ask(file_prefix() .. "Write unit tests for this code. " .. hint .. "\n\n```\n" .. code .. "\n```", "Generate Tests")
end

function M.fix()
  local code = get_visual_selection()
  M.ask(file_prefix() .. "Find and fix bugs in this code. Show the corrected version and explain what was wrong:\n\n```\n" .. code .. "\n```", "Fix")
end

function M.generate_docs()
  local code = get_visual_selection()
  M.ask(file_prefix() .. "Write documentation/docstring for this code:\n\n```\n" .. code .. "\n```", "Generate Docs")
end

function M.ask_about()
  local code = get_visual_selection()
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
