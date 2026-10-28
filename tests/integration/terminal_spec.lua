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
    -- Drop every terminal's window handle first. Deleting the buffer below kills
    -- its shell, and toggleterm's exit callback then calls close() on whatever
    -- `term.window` still holds — which by then is the one window nvim keeps
    -- (it shows another buffer there rather than closing the last window), so
    -- the callback raised E444 into the test log. close_split checks
    -- nvim_win_is_valid first, so a nil handle makes it a no-op.
    for _, t in ipairs(require("toggleterm.terminal").get_all(true)) do
      t.window = nil
    end
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
    -- Let the killed jobs' exit callbacks run before the next case starts.
    -- toggleterm's __handle_exit reads `term.bufnr` when it fires rather than
    -- when the job died, so a callback still pending when the next case
    -- respawns the same Terminal (main_term is a singleton, created once at
    -- config time) deletes the NEW buffer and takes the new shell with it.
    -- Measured: without this every case after the first saw its terminal die a
    -- few hundred ms in, and the next send answered E900.
    vim.wait(200, function() return false end)
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

  describe("the main terminal's directory", function()
    --- toggleterm's registry rather than a captured reference: main_term is a
    --- local inside the plugin's config function. It is the only terminal in the
    --- session with no `cmd` — lazygit runs `lazygit`, and every <M-r>/<F3> run
    --- terminal is created with the command it runs.
    local function main_term()
      return require("toggleterm.terminal").find(function(t) return t.cmd == nil end)
    end

    --- Toggle on, and hand back the Terminal, with a file open in `dir`.
    local function open_in(dir)
      H.write(dir .. "/A.txt", { "x" })
      H.quiet_buffer(dir .. "/A.txt")
      H.run_keymap("n", "<C-\\>")
      local term = assert(main_term(), "the toggle did not create the main terminal")
      H.wait_for("shell spawned", function() return term.job_id ~= nil end)
      return term
    end

    --- Where the shell itself thinks it is. Asking it, rather than reading back
    --- `term.dir`, is the whole point: term.dir is our own bookkeeping and it was
    --- never the broken half.
    ---
    --- The question is asked up to three times, because bytes written to the pty
    --- before zsh has started its line editor are typeahead and zsh discards
    --- them. Readiness is not observable from the terminal buffer either —
    --- libvterm paints blank rows as soon as the window opens, so waiting for a
    --- non-empty line proved nothing and was flaky — and an answer is the only
    --- reliable signal. The re-send is between waits rather than inside the wait
    --- predicate: send() switches windows and runs autocmds, and doing that from
    --- a vim.wait callback wedged the whole spec file at 100% CPU.
    ---
    --- Nothing in the production path races this; a keypress lands many ms after
    --- the spawn either way.
    local function shell_cwd(term, dir)
      local out = dir .. "/pwd.txt"
      local function answered()
        local lines = H.read(out)
        return lines ~= nil and lines[1] ~= nil and lines[1] ~= ""
      end
      for _ = 1, 3 do
        term:send("pwd > " .. vim.fn.shellescape(out))
        if vim.wait(3000, answered, 50) then break end
      end
      assert(answered(), "the shell never answered pwd")
      return vim.uv.fs_realpath(H.read(out)[1])
    end

    it("cd's the live shell into a directory whose name contains a space", function()
      -- toggleterm's own change_dir is `self:send(fmt("cd %s", dir))` with no
      -- quoting (terminal.lua:346), and `dir` comes straight from
      -- expand("%:p:h"). So for any ordinary path with a space in it the shell
      -- answered "cd: too many arguments" and stayed where it was — every later
      -- `git commit` or `mvn test` typed in that terminal ran against the
      -- previous project, with nothing on screen to say so.
      local a, b = H.tmpdir("main term a"), H.tmpdir("main term b")
      assert.is_truthy(a:find(" "), "the fixture path has no space in it")
      local term = open_in(a)
      -- The spawn's own cwd, and the barrier that proves the shell is answering
      -- before the cd under test is sent to it.
      assert.equals(vim.uv.fs_realpath(a), shell_cwd(term, a))

      -- Off, then back on from a file in the other directory: the realistic
      -- route into the cd branch, and the only one the guard at the top of
      -- toggle_main_term (buftype ~= "terminal") lets through.
      H.run_keymap("n", "<C-\\>")
      H.write(b .. "/B.txt", { "x" })
      H.quiet_buffer(b .. "/B.txt")
      H.run_keymap("n", "<C-\\>")

      assert.equals(vim.uv.fs_realpath(b), shell_cwd(term, b))
    end)

    it("sends nothing when the file is already in the terminal's directory", function()
      -- The early-out that change_dir does and that the hand-rolled version has
      -- to reproduce. Without it every toggle dropped a `cd` and a `clear` into
      -- the shell, wiping the output of whatever had just been run there.
      local dir = H.tmpdir("main term same")
      local term = open_in(dir)

      H.run_keymap("n", "<C-\\>")
      H.write(dir .. "/B.txt", { "x" })
      H.quiet_buffer(dir .. "/B.txt") -- same directory, different file
      local sent = H.spy(term, "send")
      H.run_keymap("n", "<C-\\>")
      assert.equals(0, sent.count, "re-sent cd for the directory it was already in")
    end)

    it("comes back after the shell has exited instead of writing to a dead channel", function()
      -- toggleterm never clears job_id, and close_on_exit (on, from setup) means
      -- typing `exit` deletes the terminal buffer and with it the channel. So a
      -- `job_id ~= nil` test said "running" and the cd was sent into nothing:
      -- E900, thrown out of the keymap callback before toggle() ran. <C-\> then
      -- opened no terminal at all for the rest of the session, from any
      -- directory but the dead shell's.
      local a, b = H.tmpdir("main term gone a"), H.tmpdir("main term gone b")
      local term = open_in(a)
      local dead_job = term.job_id

      term:send("exit")
      H.wait_for("the shell exited and took its buffer with it", function()
        return not (term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr))
      end)
      assert.equals(dead_job, term.job_id, "toggleterm cleared job_id after all")

      H.write(b .. "/B.txt", { "x" })
      H.quiet_buffer(b .. "/B.txt")
      H.run_keymap("n", "<C-\\>") -- threw E900 before the fix

      local fresh = assert(main_term(), "the terminal never came back")
      H.wait_for("respawned", function()
        return fresh.job_id ~= nil and fresh.job_id ~= dead_job
      end)
      -- And in the right place: the else branch has to set dir for the respawn,
      -- because there is no live shell left to cd.
      assert.equals(vim.uv.fs_realpath(b), shell_cwd(fresh, b))
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
