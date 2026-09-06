-- The Run / Restart / Stop / Debug toolbar, end to end.
--
-- The unit spec (tests/unit/runner_spec.lua) covers which command a project gets.
-- What it cannot cover is the half that has to work at runtime: that the process
-- actually starts in the right *directory*, that Stop actually kills it, that
-- Restart leaves exactly one process behind rather than two or none, and that the
-- buttons really reach the statusline lualine renders.
--
-- These cases run real processes, deliberately — the running state is polled from
-- job exit state (vim.fn.jobwait), so a faked job would only test the fake. The
-- commands are trivial (`sleep`, `pwd`), and every terminal buffer created is
-- deleted in after_each, as in terminal_spec.lua.
--
-- The *target* is stubbed rather than detected: a real target's command is
-- `gradlew bootRun` or `ng serve`, which would make each case a multi-minute
-- network-dependent build. Detection is the unit spec's subject; the process
-- lifecycle is this one's.

local H = require("helpers")

describe("runner", function()
  local known, runner

  before_each(function()
    H.load_plugin("toggleterm.nvim", "lualine.nvim")
    H.disable_autosave()
    runner = require("config.runner")
    known = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do known[b] = true end
  end)

  after_each(function()
    -- A surviving terminal job keeps the whole headless session alive past the
    -- spec, so this runs before H.cleanup restores the stubs.
    --
    -- Stopped explicitly and *waited for*, rather than left to buffer deletion:
    -- deleting a terminal buffer signals its job but does not wait, so a `sleep 30`
    -- from one case could still poll as running in the next one — which showed up
    -- as the toolbar case seeing a Stop button it never started. jobwait with a
    -- timeout is the only synchronous point available.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not known[b] and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
        local id = vim.b[b].terminal_job_id
        if id then
          pcall(vim.fn.jobstop, id)
          vim.fn.jobwait({ id }, 2000)
        end
      end
    end
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

  local function new_terminals()
    return vim.tbl_filter(function(b)
      return not known[b]
        and vim.api.nvim_buf_is_valid(b)
        and vim.bo[b].buftype == "terminal"
    end, vim.api.nvim_list_bufs())
  end

  --- Pretend the current buffer is in a project whose run command is `cmd`.
  --- Returns the target, so a case can assert on the identity the registry uses.
  --- `kind`/`tool` default to node/npm, the pair with no special-casing anywhere.
  local function fake_target(cmd, dir, kind, tool)
    dir = dir or vim.fn.getcwd()
    kind = kind or "node"
    local target = {
      kind = kind,
      dir = dir,
      name = vim.fs.basename(dir),
      label = kind .. ":" .. vim.fs.basename(dir),
      id = dir .. "\0" .. kind,
      tool = tool or "npm",
      cmd = cmd,
      debug_cmd = cmd,
      port = 4200,
    }
    H.stub(runner, "target", function() return target end)
    H.stub(runner, "targets", function() return { target } end)
    return target
  end

  --- The job id of the most recently created run terminal.
  local function current_job()
    local terms = new_terminals()
    local last = terms[#terms]
    return last and vim.b[last].terminal_job_id or nil
  end

  describe("run", function()
    it("starts the command and reports it as running", function()
      local target = fake_target("sleep 30")
      runner.run()
      assert.equals(1, #new_terminals())
      assert.is_true(runner.is_running(target))
    end)

    it("runs in the project's directory, not the editor's cwd", function()
      -- The bug this whole module replaced: <F3> probed for mvnw/gradlew relative
      -- to the CWD, so a project opened from anywhere else ran the wrong wrapper
      -- or refused to run while plainly open. `dir` becomes termopen's cwd.
      local dir = H.fixture("java-plain")
      fake_target("pwd > " .. vim.fn.shellescape(dir .. "/where.txt"), dir)
      runner.run()
      H.wait_for("pwd written", function() return H.read(dir .. "/where.txt") ~= nil end)
      local where = vim.fs.normalize((H.read(dir .. "/where.txt") or { "" })[1])
      assert.equals(vim.fs.normalize(vim.uv.fs_realpath(dir) or dir), vim.fs.normalize(vim.uv.fs_realpath(where) or where))
    end)

    it("does not start a second copy of something already running", function()
      -- Two bootRuns fight over port 8080 and the second dies with an error about
      -- the first, which reads as "Run is broken".
      fake_target("sleep 30")
      runner.run()
      local first = current_job()
      local notes = H.capture_notifications(function() runner.run() end)
      assert.equals(1, #new_terminals())
      assert.equals(first, current_job())
      assert.is_true(notes[1].msg:find("already running", 1, true) ~= nil, notes[1].msg)
    end)
  end)

  describe("the JVM a build runs on", function()
    -- Reproduced against the real Spring demo: the toolbar ran the right wrapper
    -- in the right directory and Gradle still refused, with "Gradle requires JVM
    -- 17 or later to run. Your build is currently configured to use JVM 8" — the
    -- terminal inherited an old JAVA_HOME from the shell nvim was launched from,
    -- while jdtls indexed the same project on a Java 25 it had found for itself.
    -- Nothing in Gradle's message suggests the editor could fix it.
    --
    -- `echo "[$JAVA_HOME]"` is expanded by the terminal's own shell, so what lands
    -- in the file is the variable the process really received.
    local function java_home_after(tool, env_major)
      local dir = H.fixture("java-plain")
      local out = dir .. "/java_home.txt"
      local jdk = require("config.jdk")
      H.stub(jdk, "env_major", function() return env_major end)
      H.stub(jdk, "server_jdk", function() return { path = "/opt/test-jdk", major = 25 } end)
      local kind = tool == "npm" and "node" or "spring"
      fake_target('echo "[$JAVA_HOME]" > ' .. vim.fn.shellescape(out), dir, kind, tool)
      runner.run()
      H.wait_for("JAVA_HOME written", function() return H.read(out) ~= nil end)
      return vim.trim((H.read(out) or { "" })[1] or "")
    end

    it("corrects a JAVA_HOME too old for Gradle", function()
      assert.equals("[/opt/test-jdk]", java_home_after("gradle", 8))
    end)

    it("corrects it for Maven too", function()
      assert.equals("[/opt/test-jdk]", java_home_after("maven", 8))
    end)

    it("corrects a JAVA_HOME that points at nothing usable", function()
      -- A JAVA_HOME left behind by an uninstalled JDK: env_major cannot read a
      -- version, and inheriting it means `gradlew` dies on a missing bin/java.
      assert.equals("[/opt/test-jdk]", java_home_after("gradle", nil))
    end)

    it("leaves a JAVA_HOME the build can use alone", function()
      -- A deliberate JAVA_HOME — a project pinned to 17 while 25 is installed — is
      -- the user's decision, and overriding it would break exactly the setups that
      -- were already working.
      assert.is_not.equals("[/opt/test-jdk]", java_home_after("gradle", 21))
    end)

    it("does not touch a node project's environment", function()
      -- `ng serve` does not care, and rewriting the environment of a process that
      -- never asked is how a working setup breaks. A plain Java target is left
      -- alone by the same rule: its main class goes through jdtls, not a wrapper.
      assert.is_not.equals("[/opt/test-jdk]", java_home_after("npm", 8))
    end)
  end)

  describe("stop", function()
    it("kills the process and stops reporting it as running", function()
      local target = fake_target("sleep 30")
      runner.run()
      local job = current_job()
      runner.stop()
      -- Synchronously down: M.stop waits, because a Restart that spawned
      -- immediately would race the old process off the port it wants back.
      assert.is_true(vim.fn.jobwait({ job }, 0)[1] ~= -1, "the process outlived Stop")
      assert.is_false(runner.is_running(target))
    end)

    it("leaves the output on screen after the process is gone", function()
      -- close_on_exit = false is deliberate: a build that failed has to stay
      -- readable. It is also what made these terminals leak, hence the reaping.
      fake_target("sleep 30")
      runner.run()
      local buf = new_terminals()[1]
      runner.stop()
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
    end)

    it("says so instead of failing when nothing is running", function()
      fake_target("sleep 30")
      local notes = H.capture_notifications(function() runner.stop() end)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("not running", 1, true) ~= nil, notes[1].msg)
    end)
  end)

  describe("restart", function()
    it("replaces the process rather than adding to it", function()
      local target = fake_target("sleep 30")
      runner.run()
      local first = current_job()
      runner.restart()
      H.wait_for("a new process", function() return current_job() ~= first end)
      assert.is_true(vim.fn.jobwait({ first }, 0)[1] ~= -1, "the old process survived Restart")
      assert.is_true(runner.is_running(target))
      -- The finished one is reaped when the new run starts, so this stays at one
      -- instead of growing by one per Restart.
      assert.equals(1, #new_terminals())
    end)

    it("starts something even if nothing was running", function()
      -- Restart is on the toolbar only while a run is live, but :RunRestart and
      -- <leader>rR are not gated, and "did nothing" would be the worst answer.
      local target = fake_target("sleep 30")
      runner.restart()
      H.wait_for("started", function() return runner.is_running(target) end)
    end)
  end)

  describe("toolbar", function()
    it("reaches the rendered statusline", function()
      -- The point of the whole feature: the buttons are on screen without a
      -- keypress, which is more than runner.components() returning them — it needs
      -- the splice in lua/plugins/ui.lua to have landed in a real lualine section.
      --
      -- lualine's own renderer, not vim.o.statusline: with no UI attached lualine
      -- writes a *literal* computed string into the option at refresh time, so
      -- reading the option reports whatever the last refresh saw (a previous case's
      -- live process, complete with its Stop button) rather than the state here.
      fake_target("sleep 30")
      local columns = vim.o.columns
      -- Wide enough that lualine's %< truncation cannot decide the assertion.
      vim.o.columns = 240
      local rendered = vim.api.nvim_eval_statusline(require("lualine").statusline(true), { winid = 0 }).str
      vim.o.columns = columns
      assert.is_true(rendered:find("Run", 1, true) ~= nil, rendered)
      assert.is_true(rendered:find("Debug", 1, true) ~= nil, rendered)
      assert.is_nil(rendered:find("Stop", 1, true))
    end)

    it("grows Stop and Restart while a run is live, and drops them after", function()
      fake_target("sleep 30")
      runner.run()
      local running = runner.status()
      assert.is_true(running:find("Stop", 1, true) ~= nil, running)
      assert.is_true(running:find("Restart", 1, true) ~= nil, running)

      runner.stop()
      local stopped = runner.status()
      assert.is_nil(stopped:find("Stop", 1, true))
      assert.is_nil(stopped:find("Restart", 1, true))
    end)

    it("stops the run when the Stop button is clicked", function()
      -- mouse = "a" plus lualine's on_click is the whole click path; this exercises
      -- the handler the same way a click does.
      local target = fake_target("sleep 30")
      runner.run()
      local stop
      for _, component in ipairs(runner.components()) do
        if component[1]() == "■ Stop" then stop = component end
      end
      assert.is_not_nil(stop, "no Stop component while a run is live")
      stop.on_click()
      assert.is_false(runner.is_running(target))
    end)

    it("takes its buttons away by itself when the process ends on its own", function()
      -- A failed build has to update the toolbar with no keypress, which is what
      -- the on_exit hook is for.
      local target = fake_target("true")
      runner.run()
      H.wait_for("process finished", function() return not runner.is_running(target) end)
      assert.is_nil(runner.status():find("Stop", 1, true))
    end)
  end)

  describe("from inside the run's own terminal", function()
    it("still knows which project it is looking at", function()
      -- The one bug the headless specs missed until a real bootRun was run by
      -- hand: Run opens its terminal and moves focus there, that buffer has no
      -- name, and detection answered from the cwd — so Stop said "No run target
      -- here" with the build on screen and the toolbar was empty. A real terminal
      -- buffer is needed to reproduce it, which is why this case is here and not in
      -- the unit spec.
      local dir = H.fixture("spring-gradle")
      local cwd = vim.fn.getcwd()
      vim.cmd("silent lcd " .. vim.fn.fnameescape(dir))
      local ok, err = pcall(function()
        H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", nil)
        -- Move the cwd away *after* opening the file, so nothing below can be
        -- answered by the cwd fallback.
        vim.cmd("silent lcd " .. vim.fn.fnameescape(cwd))
        local term = require("toggleterm.terminal").Terminal:new({ cmd = "sleep 30" })
        term:toggle()
        assert.equals("terminal", vim.bo.buftype)

        local target = runner.target()
        assert.is_not_nil(target, "the toolbar went blank inside the run terminal")
        assert.equals("spring", target.kind)
        assert.is_true(runner.status():find("spring:", 1, true) ~= nil, runner.status())
        pcall(function() term:shutdown() end)
      end)
      vim.cmd("silent lcd " .. vim.fn.fnameescape(cwd))
      assert(ok, err)
    end)
  end)

  describe("wiring", function()
    it("registers :Run and friends", function()
      local commands = vim.api.nvim_get_commands({})
      for _, name in ipairs({ "Run", "RunRestart", "RunStop", "RunDebug", "RunAttach" }) do
        assert.is_not_nil(commands[name], name .. " is missing — init.lua did not call runner.setup()")
      end
    end)

    it("binds <leader>rr..<leader>ra and <F3> to the runner", function()
      for _, lhs in ipairs({ "<leader>rr", "<leader>rR", "<leader>rs", "<leader>rd", "<leader>ra" }) do
        assert.is_not_nil(H.keymap("n", lhs), lhs .. " is not mapped")
      end
      local f3 = H.keymap("n", "<F3>")
      assert.is_not_nil(f3, "<F3> is not mapped")
      -- It used to say "Spring Boot: Run" and only work for Spring.
      assert.is_true(f3.desc:find("Run project", 1, true) ~= nil, f3.desc)
    end)

    it("drops a buffer's cached detection when the buffer goes away", function()
      -- An entry keyed by bufnr outlives the buffer, and a long session opens a
      -- lot of them — the same leak the LSP and autocmd state had.
      local dir = H.fixture("java-plain")
      local buf = H.named_buf(dir .. "/src/main/java/com/example/App.java")
      assert.equals("java", runner.targets(buf)[1].kind)

      vim.api.nvim_buf_delete(buf, { force = true })
      -- The bufnr is now free for nvim to hand out again, and a stale entry would
      -- answer the next buffer's question with the dead one's project. Asking again
      -- must fall back to the cwd (this repository, which has no run target)
      -- instead of returning the fixture from the cache.
      local again = runner.targets(buf)
      assert.is_true(
        again[1] == nil or again[1].dir ~= vim.fs.normalize(vim.uv.fs_realpath(dir) or dir),
        "the deleted buffer's cache entry was kept"
      )
    end)

    it("re-detects after a build file is saved", function()
      -- Adding the Spring Boot plugin to build.gradle has to change the toolbar
      -- without restarting the editor.
      local dir = H.fixture("java-plain")
      local buf = H.edit(dir .. "/build.gradle")
      assert.equals("java", runner.targets(buf)[1].kind)

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plugins { id 'org.springframework.boot' }" })
      vim.cmd("silent write")
      assert.equals("spring", runner.targets(buf)[1].kind)
    end)
  end)
end)
