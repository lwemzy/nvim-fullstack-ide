-- Run / Restart / Stop / Debug for the project the cursor is in — the model
-- behind the toolbar in the statusline (see M.components, wired up in
-- lua/plugins/ui.lua) and behind <leader>r* / :Run.
--
-- Why a module and not four keymaps: "run this project" is one question with a
-- per-project answer (bootRun vs spring-boot:run vs ng serve vs a main class),
-- and Restart/Stop/Debug are only answerable if something remembers what Run
-- started. <F3> used to be that logic inline in lua/plugins/terminal.lua, and it
-- was wrong in two ways that mattered: it decided between mvnw and gradlew with
-- vim.fn.filereadable("mvnw") — a CWD-relative test, so opening nvim above or
-- beside the project ran the wrong thing or nothing — and there was no handle on
-- the process afterwards, so stopping a bootRun meant finding its terminal and
-- pressing Ctrl-C in it.
--
-- The three deliberate design choices:
--
--   * Terminals for build-tool runs (Spring, Angular), DAP for main classes.
--     A bootRun/ng serve is a long-lived process whose *output* is the point
--     (Spring's banner, the compile errors, ng's rebuild log) and which the user
--     may want to interact with; DAP's console panel is not that. A `main`
--     method with no build-tool entry point is the opposite: jdtls already knows
--     the classpath, so asking it is the only thing that works without editing
--     the build script.
--   * Detection is cached per buffer and invalidated on build-file writes.
--     The statusline asks for a target on every redraw, and answering it means
--     reading pom.xml/build.gradle/package.json from disk. Uncached, that is
--     file I/O per redraw of a component the user is not even looking at.
--   * Nothing here requires a plugin at require time. toggleterm, dap and jdtls
--     are all looked up inside the action that needs them, so this module loads
--     (and is testable) in a session with no plugins at all.

local M = {}

local project = require("config.project")

-- The JDWP port for the Spring debug launches below, and the port the attach
-- prompt defaults to. 5005 rather than a random free port: it is what every
-- Spring/Gradle/Maven debug guide and IDE uses, so a JVM someone else started
-- with -agentlib:jdwp is already listening there.
local JDWP_PORT = 5005
-- `ng serve`'s default. Read from nothing: angular.json can override it, but only
-- via a `serve` target option this would have to parse out of a schema that moves
-- between Angular versions — and a wrong guess here only costs the Chrome debug
-- launch, which says which URL it tried.
local NG_PORT = 4200
-- Gradle 8/9 refuse to run below JVM 17 ("Gradle requires JVM 17 or later to
-- run"), and Maven 3.9 needs the same in practice. See build_env.
local MIN_BUILD_JDK = 17

-- ── Ad-hoc run terminals ────────────────────────────────────────────────────
-- Moved here from lua/plugins/terminal.lua, which still owns <M-r> and the
-- persistent shell/lazygit terminals but now shares this registry: a run started
-- from the toolbar and a run started from the <M-r> prompt are the same kind of
-- object and must be reaped by the same rule.
--
-- `close_on_exit = false` is deliberate — a build that fails has to stay on
-- screen to be read — but it means toggleterm's __handle_exit does nothing at all,
-- while its own TermClose autocmd still drops the terminal from toggleterm's
-- registry. So the buffer survived with its full scrollback AND became
-- unreachable: not in `get_all()`, and the local holding it went out of scope.
-- Every run orphaned ~21MB (10 000-line default 'scrollback', and libvterm keeps
-- its cell grid per row — a bootRun or an npm build saturates that cap easily),
-- permanently.
--
-- So: track them, and reap the ones whose process has exited whenever a new run
-- starts. Live runs are left alone, so `npm run watch` alongside a gradle build
-- still works; the output of a finished run stays readable until the next run,
-- which is the point at which nobody wants it anymore.
local run_terms = {}

--- Is this terminal's process still running? Nil-safe, because a reaped or
--- never-spawned Terminal has no job_id.
local function term_live(term)
  if not (term and term.job_id) then return false end
  -- jobwait with a 0 timeout polls: -1 means still running, anything else (exit
  -- code, or -3 for an invalid id) means there is nothing to keep it alive for.
  return vim.fn.jobwait({ term.job_id }, 0)[1] == -1
end

local function reap_finished_runs()
  local live = {}
  for _, t in ipairs(run_terms) do
    if term_live(t) then
      table.insert(live, t)
    else
      -- shutdown(), not close(): close() only hides the window, which is what
      -- left the buffer behind in the first place. shutdown() closes the window,
      -- deletes the buffer and drops the registry entry.
      pcall(function() t:shutdown() end)
    end
  end
  run_terms = live
end

--- Open `cmd` in a fresh horizontal terminal that outlives its process.
---
--- opts.dir runs it there (the project root, not the cwd nvim happens to have);
--- opts.env adds environment variables (see build_env); opts.on_exit is called
--- when the process ends. Returns the Terminal, or nil when toggleterm is not
--- available.
function M.run_in_terminal(cmd, opts)
  opts = opts or {}
  local ok, terminal = pcall(require, "toggleterm.terminal")
  if not ok then
    vim.notify("toggleterm is not loaded — cannot run: " .. cmd, vim.log.levels.ERROR)
    return nil
  end
  reap_finished_runs()
  local t = terminal.Terminal:new({
    cmd = cmd,
    dir = opts.dir,
    env = opts.env,
    direction = "horizontal",
    close_on_exit = false,
    on_exit = function()
      -- The toolbar's Stop/Restart buttons appear and disappear with this, and a
      -- build that fails on its own has to take them away without a keypress.
      vim.schedule(M.refresh)
      if opts.on_exit then opts.on_exit() end
    end,
  })
  table.insert(run_terms, t)
  t:toggle()
  return t
end

-- ── Target detection ────────────────────────────────────────────────────────

--- The npm scripts that mean "start this application", in preference order.
local NODE_SCRIPTS = { "start", "dev", "serve" }

--- lockfile -> the package manager that wrote it. Checked because `npm run` in a
--- pnpm workspace resolves a different (or no) node_modules layout, so running
--- the wrong one fails with an error about a missing binary that says nothing
--- about the real cause.
local PACKAGE_MANAGERS = {
  { lock = "pnpm-lock.yaml", cmd = "pnpm" },
  { lock = "yarn.lock", cmd = "yarn" },
  { lock = "bun.lockb", cmd = "bun" },
}

--- How deep a path is, for "nearest marker wins" below.
local function depth(path)
  local _, n = path:gsub("/", "")
  return n
end

--- An executable wrapper script (mvnw/gradlew) at or above `dir`, absolute and
--- shell-quoted, or nil.
---
--- Absolute rather than "./gradlew": the command runs with cwd = the module
--- directory (so Gradle and Maven resolve the right subproject), and in a
--- multi-module build the wrapper lives at the repository root, several levels
--- up. Quoted because a project path with a space in it is otherwise two
--- arguments.
local function wrapper(dir, name)
  local found = project.find_upward(dir, name)[1]
  if found and vim.fn.executable(found) == 1 then return vim.fn.shellescape(found) end
  return nil
end

--- The package manager to use in `dir`.
local function package_manager(dir)
  for _, pm in ipairs(PACKAGE_MANAGERS) do
    if vim.fn.filereadable(dir .. "/" .. pm.lock) == 1 and vim.fn.executable(pm.cmd) == 1 then
      return pm.cmd
    end
  end
  return "npm"
end

--- The first of NODE_SCRIPTS that `dir`'s package.json defines, or nil.
local function node_script(dir)
  local path = dir .. "/package.json"
  local ok, text = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local decoded, json = pcall(vim.json.decode, table.concat(text, "\n"))
  if not decoded or type(json) ~= "table" or type(json.scripts) ~= "table" then return nil end
  for _, name in ipairs(NODE_SCRIPTS) do
    if type(json.scripts[name]) == "string" then return name end
  end
  return nil
end

--- `pm run <script>`, except for the two scripts npm/yarn/pnpm expose directly.
local function node_cmd(pm, script)
  if script == "start" and pm == "npm" then return "npm start" end
  if pm == "npm" then return "npm run " .. script end
  return pm .. " " .. script
end

--- The Java/Spring target rooted at the nearest build file, or nil.
local function java_target(source, build_files)
  local nearest = build_files[1]
  local dir, tool
  if nearest then
    dir = vim.fs.dirname(nearest)
    tool = vim.fs.basename(nearest) == "pom.xml" and "maven" or "gradle"
  else
    -- A loose .java file with no build script at all. jdtls still resolves a
    -- classpath for it, so a main class can still be launched — this is the case
    -- <leader>dR has always covered, and dropping it would make the toolbar less
    -- capable than the keymap it replaces.
    local name = type(source) == "number" and vim.api.nvim_buf_get_name(source) or ""
    if not name:match("%.java$") then return nil end
    dir, tool = vim.fs.dirname(name), "jdtls"
  end

  local spring = tool ~= "jdtls" and project.declares_spring_boot(source)
  local target = {
    kind = spring and "spring" or "java",
    dir = dir,
    tool = tool,
    port = JDWP_PORT,
  }

  if spring and tool == "maven" then
    local mvn = wrapper(dir, "mvnw") or "mvn"
    target.cmd = mvn .. " spring-boot:run"
    -- suspend=n: the app starts and serves immediately, and the debugger attaches
    -- as soon as the port opens. suspend=y would hold a web app before its first
    -- line of code on the chance that a breakpoint is set that early, which for a
    -- Spring service is almost never where the interesting one is.
    target.debug_cmd = mvn
      .. ' spring-boot:run "-Dspring-boot.run.jvmArguments=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:'
      .. JDWP_PORT
      .. '"'
  elseif spring then
    local gradle = wrapper(dir, "gradlew") or "gradle"
    target.cmd = gradle .. " bootRun"
    -- Gradle's own flag, and the only way to get JVM args into bootRun without
    -- editing build.gradle. It implies suspend=y (JavaExec's debugOptions default,
    -- with no CLI switch to change it), which is exactly why the attach below is
    -- automatic: the app is sitting on the listening socket waiting for it.
    target.debug_cmd = gradle .. " bootRun --debug-jvm"
  end

  return target
end

--- The Angular/node target nearest `source`, or nil.
local function web_target(source)
  local ng = project.find_upward(source, { "angular.json", "nx.json" })[1]
  local pkg = project.find_upward(source, "package.json")[1]
  if not (ng or pkg) then return nil end

  -- angular.json decides the *kind* (it is what makes the Chrome debug launch
  -- meaningful), package.json decides the *command*. In an Nx or Angular
  -- workspace they are usually the same directory; when they are not, the scripts
  -- live with package.json.
  local dir = vim.fs.dirname(ng or pkg)
  local script_dir = pkg and vim.fs.dirname(pkg) or dir
  local script = node_script(script_dir)
  local pm = package_manager(script_dir)

  local cmd
  if script then
    cmd = node_cmd(pm, script)
  elseif ng then
    -- An Angular workspace whose package.json has no start script (or none at
    -- all): the CLI is still there via npx, which is how `ng` is meant to be run
    -- without a global install.
    cmd = "npx ng serve"
  else
    return nil -- a package.json that starts nothing is not a run target
  end

  return {
    kind = ng and "angular" or "node",
    dir = script_dir,
    tool = script and pm or "npx",
    cmd = cmd,
    debug_cmd = cmd,
    port = NG_PORT,
  }
end

-- bufnr -> targets, for a buffer with a file name: its directory cannot change,
-- so this entry is good until a build file is written.
local cache = {}
-- directory -> targets, for every question asked about a path rather than a
-- buffer. Nameless buffers go through here rather than through `cache` because
-- their answer depends on nameless_dir(), which changes as you navigate — caching
-- it per terminal buffer would pin the dashboard to whatever project happened to
-- be open the first time it was drawn. Keyed by directory, the redraw cost is
-- still paid once.
local dir_cache = {}

--- The directory to answer a nameless buffer's question from.
---
--- A terminal, the Claude panel and the dashboard have no directory of their own,
--- and the toolbar has to keep working while one of them is focused. That is not a
--- corner: Run opens its terminal and moves focus there, so the run's own terminal
--- is the window the user is looking at when they press Stop. Measured before this
--- existed — against a real `gradlew bootRun` — Stop answered "No run target here"
--- with the build plainly on screen, and the toolbar was empty.
---
--- The alternate file first, then any file visible in another window, then the cwd.
--- Each is a better guess than the next about which project this is: the alternate
--- is the file you were in a keystroke ago, a visible buffer is at least on screen,
--- and the cwd is only right if nvim was started in the project — which is exactly
--- the assumption the old <F3> made and got wrong.
--- Does `bufnr` name a file on disk, so its own directory can be asked?
---
--- buftype is the load-bearing half. A terminal buffer HAS a name — nvim calls it
--- `term://<cwd>//<pid>:<cmd>` — and taking its dirname sends the upward search
--- into a path that does not exist, under whatever cwd nvim was started in. That is
--- precisely how the toolbar went blank inside its own run terminal, and a name-only
--- check does not catch it. Help buffers, quickfix and the panels are excluded for
--- the same reason.
local function file_buffer(bufnr)
  return bufnr > 0
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function nameless_dir()
  -- bufnr("#") is -1 when there is no alternate file.
  local candidates = { vim.fn.bufnr("#") }
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    table.insert(candidates, vim.api.nvim_win_get_buf(win))
  end
  for _, buf in ipairs(candidates) do
    if file_buffer(buf) then return vim.fs.dirname(vim.api.nvim_buf_get_name(buf)) end
  end
  return vim.fn.getcwd()
end

local function detect(source)
  local targets = {}
  local java = java_target(source, project.java_build_files(source))
  if java then table.insert(targets, java) end
  local web = web_target(source)
  if web then table.insert(targets, web) end

  -- Nearest first, which is what makes a monorepo (a Spring backend/ beside an
  -- Angular frontend/) offer the target the open file actually belongs to. A tie
  -- — both markers in one directory, e.g. a Spring app that also builds its own
  -- frontend — keeps the Java target first, since that is the deployable.
  table.sort(targets, function(a, b) return depth(a.dir) > depth(b.dir) end)

  for _, t in ipairs(targets) do
    t.name = vim.fs.basename(t.dir)
    t.label = t.kind .. ":" .. t.name
    -- The job registry key. Two kinds in one directory are two independently
    -- runnable things, so the kind is part of the identity.
    t.id = t.dir .. "\0" .. t.kind
  end
  return targets
end

--- Every run target visible from `source` (a buffer number, default the current
--- buffer; a directory path is also accepted), nearest first.
---
--- Cached per buffer, because the statusline asks on every redraw and answering
--- means reading build files off disk. See M.invalidate for when it is dropped.
function M.targets(source)
  local function for_dir(dir)
    local hit = dir_cache[dir]
    if hit then return hit end
    local found = detect(dir)
    dir_cache[dir] = found
    return found
  end

  if type(source) == "string" then return for_dir(source) end

  local bufnr = (source == nil or source == 0) and vim.api.nvim_get_current_buf() or source
  -- A buffer that is not a file has no directory of its own; see nameless_dir.
  if not file_buffer(bufnr) then return for_dir(nameless_dir()) end

  local hit = cache[bufnr]
  if hit then return hit end
  local targets = detect(bufnr)
  cache[bufnr] = targets
  return targets
end

--- The target to act on: `kind` if given and present, otherwise the nearest one.
function M.target(kind, source)
  local targets = M.targets(source)
  if not kind then return targets[1] end
  for _, t in ipairs(targets) do
    if t.kind == kind then return t end
  end
  return nil
end

--- Forget cached detection. `bufnr` forgets one buffer, no argument forgets all.
function M.invalidate(bufnr)
  if bufnr then
    cache[bufnr] = nil
  else
    cache, dir_cache = {}, {}
  end
end

-- ── Job registry ────────────────────────────────────────────────────────────

-- id -> { target, term?, dap?, mode }. One entry per (directory, kind), so the
-- Spring app and the Angular app of a monorepo can run at the same time and each
-- keep its own Stop button.
local jobs = {}

local function dap_session()
  local ok, dap = pcall(require, "dap")
  return ok and dap.session() or nil
end

--- Is `target` running right now?
---
--- Asked on every statusline redraw, so it must be a poll and not a search: a
--- terminal job is one non-blocking jobwait, and a DAP launch is one table read
--- inside nvim-dap.
function M.is_running(target)
  if not target then return false end
  local job = jobs[target.id]
  if not job then return false end
  if job.term then return term_live(job.term) end
  if job.dap then return dap_session() ~= nil end
  return false
end

--- Ask lualine to redraw now instead of at its next tick. Guarded: this module
--- works without lualine, and the toolbar is only one of its two front ends.
function M.refresh()
  pcall(function() require("lualine").refresh({ place = { "statusline" } }) end)
end

-- ── Actions ─────────────────────────────────────────────────────────────────

local function no_target()
  vim.notify(
    "No run target here.\n"
      .. "Looked for pom.xml / build.gradle(.kts) above this file (Java, Spring Boot),\n"
      .. "angular.json / nx.json (Angular), and a package.json with a "
      .. table.concat(NODE_SCRIPTS, "/")
      .. " script.",
    vim.log.levels.WARN
  )
end

--- Call cb(true) as soon as something is listening on 127.0.0.1:`port`, or
--- cb(false) once `timeout_ms` has passed or the run has stopped.
---
--- A JVM started with -agentlib:jdwp opens its listening socket seconds after the
--- build tool does — Gradle has to configure the project and compile first — so
--- attaching straight after spawning the terminal always failed with a connection
--- refused and no session, and the user had to time the attach by hand. Polling
--- is what makes it automatic.
local function wait_for_port(port, timeout_ms, still_wanted, cb)
  local deadline = vim.uv.now() + timeout_ms
  local function probe()
    if not still_wanted() then return cb(false) end
    local sock = vim.uv.new_tcp()
    if not sock then return cb(false) end
    local ok = pcall(function()
      sock:connect("127.0.0.1", port, function(err)
        sock:close()
        vim.schedule(function()
          if not err then return cb(true) end
          if vim.uv.now() >= deadline then return cb(false) end
          vim.defer_fn(probe, 250)
        end)
      end)
    end)
    if not ok then
      pcall(function() sock:close() end)
      cb(false)
    end
  end
  probe()
end

--- Attach the Java debug adapter to a JVM already listening on `port`.
local function attach_jvm(port, label)
  local ok, dap = pcall(require, "dap")
  if not ok then
    return vim.notify("nvim-dap is not loaded", vim.log.levels.ERROR)
  end
  if not dap.adapters.java then
    -- jdtls registers this adapter (jdtls.setup_dap in ftplugin/java.lua), and it
    -- is the *server* jdtls exposes rather than a standalone binary — so there is
    -- nothing to attach with until a Java buffer has started one.
    return vim.notify(
      "No Java debug adapter yet — open a .java file in this project first "
        .. "(jdtls registers it), and check :checkhealth nvim-ide for java-debug-adapter.",
      vim.log.levels.WARN
    )
  end
  dap.run({
    type = "java",
    request = "attach",
    name = label or ("Attach to JVM :" .. port),
    hostName = "127.0.0.1",
    port = port,
  })
end

--- Run or debug a main class through jdtls's DAP integration.
---
--- This is the implementation <leader>dR has always had; it lives here so the
--- toolbar and the keymap cannot drift apart. console = "internalConsole" routes
--- the program's stdout into dap-ui's console panel instead of a terminal split
--- that dapui's own layout then evicts (see ftplugin/java.lua).
local function java_main(target, mode)
  local ok, jdtls_dap = pcall(require, "jdtls.dap")
  if not ok then
    return vim.notify("nvim-jdtls is not loaded — open a .java file first", vim.log.levels.WARN)
  end
  local overrides = { console = "internalConsole" }
  if mode == "run" then overrides.noDebug = true end

  local function launch(config)
    jobs[target.id] = { target = target, dap = true, mode = mode }
    require("dap").run(config)
    -- dapui is opened explicitly rather than left to the global
    -- event_initialized listener: a noDebug launch does not reliably fire that
    -- event the way a real debug session does, so the panel showing the
    -- internalConsole output could otherwise never appear even though the program
    -- genuinely ran (confirmed in jdtls's log: LaunchWithoutDebuggingDelegate
    -- fires fine — nothing was broken except visibility).
    pcall(function() require("dapui").open() end)
    M.refresh()
  end

  jdtls_dap.fetch_main_configs({ config_overrides = overrides }, function(configs)
    vim.schedule(function()
      if #configs == 0 then
        vim.notify("No runnable main classes found in this project", vim.log.levels.WARN)
      elseif #configs == 1 then
        launch(configs[1])
      else
        vim.ui.select(configs, {
          prompt = mode == "run" and "Run (no debug):" or "Debug:",
          format_item = function(c) return c.name end,
        }, function(choice)
          if choice then launch(choice) end
        end)
      end
    end)
  end)
end

--- Run or debug a main class in the current project, whatever kind of project
--- this is. `<leader>dR` in ftplugin/java.lua is this: "run this class, no
--- debugger", which stays meaningful in a Spring project where the toolbar's Run
--- means bootRun — a Spring app has main classes and plain ones too.
function M.main_class(mode, source)
  local target = M.target("java", source) or M.target("spring", source)
  if not target then return no_target() end
  if target.kind == "java" then return java_main(target, mode) end
  -- In a Spring project this launch is a *different* process from bootRun, so it
  -- gets its own registry id: sharing one would have it take over (and then lose)
  -- bootRun's Stop button. Terminate it with <leader>dt, as with any DAP session.
  java_main(
    vim.tbl_extend("force", target, {
      id = target.dir .. "\0main",
      label = target.name .. " (main class)",
    }),
    mode
  )
end

--- Environment additions for a build launched from inside nvim, or nil to inherit
--- nvim's environment unchanged.
---
--- A terminal inherits nvim's environment, so a JAVA_HOME still pointing at an old
--- JRE — the default on plenty of machines, and what a version manager set up only
--- for interactive shells leaves behind when nvim is launched from a desktop entry
--- — fails the build before it has read the project at all: "Gradle requires JVM
--- 17 or later to run. Your build is currently configured to use JVM 8". Nothing
--- in that message says the editor could have fixed it, and it reads as a broken
--- Run button. This was reproduced against the real Spring demo, where jdtls was
--- happily indexing the same project on a Java 25 it found for itself.
---
--- Only corrected when the inherited JVM cannot work, so a deliberate `JAVA_HOME`
--- (a project pinned to 17 while 25 is installed) is left alone.
--- Keyed on the build tool rather than the kind: what needs a JVM is the *command*,
--- and a plain Java target has none — its main class is launched through jdtls,
--- which resolves its own runtime. Anything npm-shaped is left alone entirely.
local function build_env(target)
  if target.tool ~= "gradle" and target.tool ~= "maven" then return nil end
  local jdk = require("config.jdk")
  local current = jdk.env_major()
  if current and current >= MIN_BUILD_JDK then return nil end
  -- The same JDK the language servers are launched on: newest LTS that qualifies.
  local pick = jdk.server_jdk(MIN_BUILD_JDK)
  if not pick then return nil end
  return { JAVA_HOME = pick.path }
end

--- Start `cmd` for `target` and record it as that target's job.
local function start_terminal(target, cmd, mode)
  local term = M.run_in_terminal(cmd, {
    dir = target.dir,
    env = build_env(target),
    on_exit = function() M.refresh() end,
  })
  if not term then return nil end
  jobs[target.id] = { target = target, term = term, mode = mode }
  M.refresh()
  return term
end

--- Start `target`, or focus it if it is already running.
function M.run(kind, source)
  local target = M.target(kind, source)
  if not target then return no_target() end

  if M.is_running(target) then
    -- Not a second copy: two bootRuns fight over port 8080 and the second dies
    -- with an error about the first. Show the one that is running instead — the
    -- user pressing Run on something already running wants to see it.
    local job = jobs[target.id]
    if job.term then pcall(function() job.term:open() end) end
    vim.notify(target.label .. " is already running", vim.log.levels.INFO)
    return
  end

  if target.kind == "java" then return java_main(target, "run") end
  return start_terminal(target, target.cmd, "run")
end

--- Stop `target`. `cb` (optional) runs once it is actually down.
function M.stop(kind, source, cb)
  local target = M.target(kind, source)
  if not target then
    if cb then cb() end
    return no_target()
  end
  local job = jobs[target.id]
  if not M.is_running(target) then
    jobs[target.id] = nil
    vim.notify(target.label .. " is not running", vim.log.levels.INFO)
    if cb then cb() end
    return
  end

  if job.dap then
    -- terminate(), not disconnect(): a noDebug launch is still a real child
    -- process and disconnecting would leave it running with nothing attached.
    local dap = require("dap")
    jobs[target.id] = nil
    return dap.terminate(nil, nil, function()
      M.refresh()
      if cb then cb() end
    end)
  end

  -- jobstop on a pty job signals the whole foreground process group, which is
  -- what actually stops `gradlew bootRun` — the wrapper script is the direct
  -- child, and the JVM it forked is the process that has to hear about it.
  pcall(vim.fn.jobstop, job.term.job_id)
  local id = job.term.job_id
  jobs[target.id] = nil
  -- The exit is asynchronous, so a Restart that spawned immediately would race
  -- the old process off the port it is about to want back.
  vim.wait(3000, function() return vim.fn.jobwait({ id }, 0)[1] ~= -1 end, 50)
  M.refresh()
  if cb then cb() end
end

--- Stop and start again, in that order.
function M.restart(kind, source)
  local target = M.target(kind, source)
  if not target then return no_target() end
  local mode = (jobs[target.id] or {}).mode or "run"
  M.stop(target.kind, source, function()
    if mode == "debug" then
      M.debug(target.kind, source)
    else
      M.run(target.kind, source)
    end
  end)
end

--- Start `target` with a debugger attached.
function M.debug(kind, source)
  local target = M.target(kind, source)
  if not target then return no_target() end

  if target.kind == "java" then return java_main(target, "debug") end

  if target.kind == "spring" then
    if M.is_running(target) then
      -- Already up without JDWP: the flags are decided at JVM startup, so there
      -- is nothing to attach to and restarting is the only honest answer.
      vim.notify(
        target.label .. " is already running without a debug port — stopping it first",
        vim.log.levels.INFO
      )
      return M.stop(target.kind, source, function() M.debug(target.kind, source) end)
    end
    if not start_terminal(target, target.debug_cmd, "debug") then return end
    vim.notify(
      ("%s starting with JDWP on :%d — attaching when the port opens…"):format(target.label, target.port),
      vim.log.levels.INFO
    )
    return wait_for_port(target.port, 180000, function() return M.is_running(target) end, function(open)
      if not open then
        return vim.notify(
          ("No JVM on :%d — the build may have failed (see its terminal), or start-up took over 3 minutes."):format(
            target.port
          ),
          vim.log.levels.WARN
        )
      end
      attach_jvm(target.port, target.label)
    end)
  end

  -- Angular / node: the debugger is a browser (or a node inspector), so the dev
  -- server has to be up first. Starting it here rather than telling the user to
  -- is the whole difference between one click and three.
  if not M.is_running(target) then
    if not start_terminal(target, target.debug_cmd, "debug") then return end
  end
  vim.notify(
    ("%s — waiting for the dev server on :%d…"):format(target.label, target.port),
    vim.log.levels.INFO
  )
  wait_for_port(target.port, 180000, function() return M.is_running(target) end, function(open)
    if not open then
      return vim.notify(
        ("Nothing listening on :%d — see the dev server's terminal."):format(target.port),
        vim.log.levels.WARN
      )
    end
    M.attach(target.kind, source)
  end)
end

--- Attach a debugger to something already running.
---
--- The one action that is useful with no target at all: a JVM started by
--- someone else (a container, a colleague's staging box forwarded to a local
--- port) is exactly what "Remote JVM debug" means in an IDE.
function M.attach(kind, source)
  local target = M.target(kind, source)

  if target and (target.kind == "angular" or target.kind == "node") then
    local ok, dap = pcall(require, "dap")
    if not ok then
      return vim.notify("nvim-dap is not loaded", vim.log.levels.ERROR)
    end
    -- Reuse the pwa-chrome configuration from lua/plugins/debug.lua when it is
    -- there, so its webRoot/sourceMaps/outFiles stay the single place those are
    -- decided; the inline fallback exists because those configurations are only
    -- registered when js-debug-adapter is installed.
    for _, config in ipairs(dap.configurations.typescript or {}) do
      if config.type == "pwa-chrome" then
        return dap.run(vim.tbl_extend("force", config, {
          url = "http://localhost:" .. target.port,
          webRoot = target.dir,
        }))
      end
    end
    return dap.run({
      type = "pwa-chrome",
      request = "launch",
      name = "Chrome against :" .. target.port,
      url = "http://localhost:" .. target.port,
      webRoot = target.dir,
      sourceMaps = true,
    })
  end

  local default = tostring((target and target.port) or JDWP_PORT)
  vim.ui.input({ prompt = "Attach to JVM on port: ", default = default }, function(answer)
    local port = tonumber(answer)
    if not port then return end
    attach_jvm(port, target and target.label or nil)
  end)
end

--- Every action the toolbar and :Run* expose, by name.
M.actions = {
  run = M.run,
  restart = M.restart,
  stop = function(kind, source) M.stop(kind, source) end,
  debug = M.debug,
  attach = M.attach,
}

function M.dispatch(action, kind, source)
  local fn = M.actions[action]
  if not fn then
    return vim.notify("runner: no such action: " .. tostring(action), vim.log.levels.ERROR)
  end
  return fn(kind, source)
end

-- ── Toolbar ─────────────────────────────────────────────────────────────────

--- The buttons, in the order they are drawn. `when = "running"` buttons are
--- hidden while nothing is running: a Stop that cannot stop anything is a lie,
--- and the statusline is short.
local BUTTONS = {
  { action = "run", text = "▶ Run", hl = "DiagnosticOk" },
  { action = "restart", text = "⟳ Restart", hl = "DiagnosticWarn", when = "running" },
  { action = "stop", text = "■ Stop", hl = "DiagnosticError", when = "running" },
  { action = "debug", text = "● Debug", hl = "DiagnosticInfo" },
}

local hl_cache = {}

--- A lualine `color` table taking its foreground from highlight group `group`.
---
--- Read from the group rather than hardcoded so the buttons follow the
--- colorscheme, and cached because this is asked once per button per redraw.
--- M.setup clears the cache on ColorScheme.
local function fg(group)
  if hl_cache[group] == nil then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    hl_cache[group] = (ok and hl and hl.fg) and { fg = ("#%06x"):format(hl.fg) } or false
  end
  return hl_cache[group] or nil
end

function M.clear_highlight_cache()
  hl_cache = {}
end

--- Should `button` be drawn right now?
local function visible(button)
  local target = M.target()
  if not target then return false end
  if button.when == "running" then return M.is_running(target) end
  return true
end

--- The lualine components for the toolbar: a label saying what the buttons act
--- on, then the buttons. Spliced into a section in lua/plugins/ui.lua.
---
--- Each button is its own component rather than one component with click regions,
--- because lualine's on_click is per component — and separate components are also
--- what lets each one carry its own colour and its own cond.
function M.components()
  local components = {
    {
      function()
        local target = M.target()
        if not target then return "" end
        return M.is_running(target) and (target.label .. " ●") or target.label
      end,
      cond = function() return M.target() ~= nil end,
      color = function()
        return M.is_running(M.target()) and fg("DiagnosticOk") or fg("Comment")
      end,
      on_click = function() M.dispatch("run") end,
    },
  }
  for _, button in ipairs(BUTTONS) do
    table.insert(components, {
      function() return button.text end,
      cond = function() return visible(button) end,
      color = function() return fg(button.hl) end,
      on_click = function() M.dispatch(button.action) end,
    })
  end
  return components
end

--- The toolbar as one plain string, for a statusline that is not lualine — and
--- for tests, where asserting on this is asserting on what the user sees.
function M.status()
  local target = M.target()
  if not target then return "" end
  local parts = { target.label }
  for _, button in ipairs(BUTTONS) do
    if visible(button) then table.insert(parts, button.text) end
  end
  return table.concat(parts, "  ")
end

-- ── Wiring ──────────────────────────────────────────────────────────────────

--- Commands, cache invalidation and the colour cache hook. Called from init.lua.
function M.setup()
  local group = vim.api.nvim_create_augroup("runner", { clear = true })

  -- Detection reads these files, so a save can change the answer: adding the
  -- Spring Boot plugin to build.gradle, or a start script to package.json, has to
  -- change the toolbar without a restart.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = {
      "pom.xml", "build.gradle", "build.gradle.kts",
      "settings.gradle", "settings.gradle.kts",
      "package.json", "angular.json", "nx.json",
    },
    callback = function()
      M.invalidate()
      M.refresh()
    end,
  })

  -- A nameless buffer can fall back to the cwd, so :cd can change its answer.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      M.invalidate()
      M.refresh()
    end,
  })

  -- Same reasoning as the per-buffer state in config/autocmds.lua and
  -- lua/plugins/lsp.lua: an entry keyed by bufnr outlives the buffer, and a long
  -- session opens a lot of them.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(ev) M.invalidate(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function() M.clear_highlight_cache() end,
  })

  --- Completion over the kinds actually available here, which is what makes
  --- `:Run angular` in a monorepo discoverable rather than something to guess.
  local function complete()
    return vim.tbl_map(function(t) return t.kind end, M.targets())
  end

  local commands = {
    Run = "run",
    RunRestart = "restart",
    RunStop = "stop",
    RunDebug = "debug",
    RunAttach = "attach",
  }
  for name, action in pairs(commands) do
    vim.api.nvim_create_user_command(name, function(opts)
      M.dispatch(action, opts.args ~= "" and opts.args or nil)
    end, {
      nargs = "?",
      complete = complete,
      desc = "Runner: " .. action .. " the current project's target",
    })
  end
end

return M
