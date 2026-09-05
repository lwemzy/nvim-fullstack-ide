-- lua/plugins/terminal.lua — the toggleterm setup.
--
-- The subject is terminal LIFETIME, which was the worst memory bug in the config:
-- <F3> and <M-r> build a new Terminal per keypress with close_on_exit = false, so
-- toggleterm's __handle_exit does nothing while its own TermClose autocmd still
-- drops the terminal from the registry — leaving the buffer alive with its whole
-- scrollback (~21MB at the 10 000-line default) and unreachable from any Lua
-- reference. Ten <F3> presses over a few days was ~200MB of buffers nothing could
-- find, and because they are `buflisted = false` in effect nothing showed them.
--
-- These cases run real processes, deliberately: the reaping is driven off job exit
-- state (vim.fn.jobwait), so a faked job would test the fake. They are kept
-- trivial (`true`, `sleep`) and every terminal buffer the case creates is deleted
-- in after_each.

local H = require("helpers")

describe("terminal", function()
  local known

  before_each(function()
    H.load_plugin("toggleterm.nvim")
    H.disable_autosave()
    known = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do known[b] = true end
  end)

  after_each(function()
    -- Terminal buffers hold live jobs; leaving one running would keep the whole
    -- headless session alive past the spec.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not known[b] and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do pcall(vim.api.nvim_win_close, wins[i], true) end
    vim.cmd("stopinsert")
    H.cleanup()
  end)

  --- Every terminal buffer that did not exist when the case started.
  local function new_terminals()
    return vim.tbl_filter(function(b)
      return not known[b]
        and vim.api.nvim_buf_is_valid(b)
        and vim.bo[b].buftype == "terminal"
    end, vim.api.nvim_list_bufs())
  end

  --- Press <M-r> and answer its prompt with `cmd`.
  local function run_cmd(cmd)
    H.stub(vim.ui, "input", function(_, on_confirm) on_confirm(cmd) end)
    H.run_keymap("n", "<M-r>")
  end

  describe("<M-r> run terminals", function()
    it("reaps a finished run terminal when the next run starts", function()
      run_cmd("true")
      local first = new_terminals()
      assert.equals(1, #first, "the first run did not open a terminal")

      -- close_on_exit = false is deliberate — a failed build has to stay readable
      -- — so the buffer must still be here after the process is gone. That is
      -- also exactly what made it leak.
      H.wait_for("first run's process exited", function()
        local job = vim.b[first[1]].terminal_job_id
        return job == nil or vim.fn.jobwait({ job }, 0)[1] ~= -1
      end)
      assert.is_true(vim.api.nvim_buf_is_valid(first[1]))

      run_cmd("true")
      -- The whole fix: starting a run reclaims the previous, finished one, so the
      -- count stays at one instead of growing by one per keypress.
      H.wait_for("previous run terminal reclaimed", function()
        return not vim.api.nvim_buf_is_valid(first[1])
      end)
      assert.equals(1, #new_terminals())
    end)

    it("does not grow without bound across many runs", function()
      -- The failure mode was unbounded accumulation, so the regression test has
      -- to be about the count over several presses rather than one transition.
      for _ = 1, 4 do
        run_cmd("true")
        H.wait_for("run finished", function()
          local terms = new_terminals()
          if #terms == 0 then return false end
          local job = vim.b[terms[#terms]].terminal_job_id
          return job == nil or vim.fn.jobwait({ job }, 0)[1] ~= -1
        end)
      end
      -- At most the one still on screen. Before the fix this was 4.
      assert.is_true(#new_terminals() <= 1,
        "run terminals accumulated: " .. #new_terminals())
    end)

    it("leaves a still-running command alone", function()
      -- Reaping must be by exit state, not by age: `npm run watch` in one
      -- terminal and a gradle build in another is an ordinary thing to want, and
      -- killing the long-running one would be a far worse bug than the leak.
      run_cmd("sleep 30")
      local long = new_terminals()
      assert.equals(1, #long)

      run_cmd("true")
      -- Both alive: the sleeper untouched, plus the new one.
      assert.is_true(vim.api.nvim_buf_is_valid(long[1]))
      assert.equals(2, #new_terminals())
    end)
  end)

  describe("persistent terminals", function()
    it("does not respawn the main terminal or lazygit per keypress", function()
      -- These two are created once at config time and reused, which is the
      -- pattern the run terminals were missing. Toggling twice must leave one
      -- buffer, not two.
      for _, lhs in ipairs({ "<C-\\>", "<M-g>" }) do
        local before = #new_terminals()
        H.run_keymap("n", lhs)
        H.run_keymap("n", lhs)
        H.run_keymap("n", lhs)
        local after = #new_terminals()
        assert.is_true(after - before <= 1,
          lhs .. " created " .. (after - before) .. " terminals across three toggles")
      end
    end)
  end)
end)
