-- Claude CLI integration — uses `claude` (Claude Code) already on your system.
-- Chat opens as a persistent right-side panel that toggles open/closed.
-- The terminal session stays alive when hidden.

local M = {}

local state = {
  buf = nil,  -- the persistent terminal buffer
  win = nil,  -- the panel window (nil when hidden)
}

-- ── Panel toggle ────────────────────────────────────────────────────────────

local function panel_is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

-- Forward declaration so create_terminal_buf can reference it
local close_panel

local function create_terminal_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_call(buf, function()
    vim.fn.termopen("claude", {
      env = { EDITOR = "nvim", VISUAL = "nvim" },
      on_exit = function()
        state.buf = nil
        state.win = nil
      end,
    })
  end)
  vim.bo[buf].buflisted = false

  -- Ctrl+G inside the terminal (even while typing) closes the panel
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
end

local function open_panel()
  -- Create the terminal buffer once; reuse it on subsequent opens
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = create_terminal_buf()
  end

  -- Open a vertical split on the far right
  vim.cmd("botright 80vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  -- Window-local options
  local wo = vim.wo[state.win]
  wo.number         = false
  wo.relativenumber = false
  wo.signcolumn     = "no"
  wo.wrap           = true

  vim.cmd("startinsert")
end

function M.toggle_chat()
  if panel_is_open() then
    close_panel()
  else
    open_panel()
  end
end

-- Focus the panel if open, or open it
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

  -- Close float with q or Escape
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
  M.ask("Explain this code clearly and concisely:\n\n```\n" .. code .. "\n```", "Explain")
end

function M.refactor()
  local code = get_visual_selection()
  M.ask("Refactor this code to be cleaner and more idiomatic. Show the improved version with a brief explanation:\n\n```\n" .. code .. "\n```", "Refactor")
end

function M.generate_tests()
  local code = get_visual_selection()
  local ft   = vim.bo.filetype
  local hint = ft == "java" and "Use JUnit 5 and Mockito."
            or ft == "typescript" and "Use Jest." or ""
  M.ask("Write unit tests for this code. " .. hint .. "\n\n```\n" .. code .. "\n```", "Generate Tests")
end

function M.fix()
  local code = get_visual_selection()
  M.ask("Find and fix bugs in this code. Show the corrected version and explain what was wrong:\n\n```\n" .. code .. "\n```", "Fix")
end

function M.generate_docs()
  local code = get_visual_selection()
  M.ask("Write documentation/docstring for this code:\n\n```\n" .. code .. "\n```", "Generate Docs")
end

function M.ask_about()
  local code = get_visual_selection()
  vim.ui.input({ prompt = "Ask Claude: " }, function(q)
    if q and q ~= "" then
      M.ask(q .. "\n\n```\n" .. code .. "\n```", "Claude")
    end
  end)
end

function M.prompt()
  vim.ui.input({ prompt = "Ask Claude: " }, function(q)
    if q and q ~= "" then M.ask(q, "Claude") end
  end)
end

return M
