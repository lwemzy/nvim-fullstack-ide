-- Run any build task, not just the project's run target.
--
-- lua/config/runner.lua resolves exactly two commands per project — the one Run
-- starts and the one Debug starts — because that is what a toolbar needs. It
-- does the hard part already: walking up for pom.xml / build.gradle /
-- package.json, preferring ./gradlew and ./mvnw over the system tool, reading
-- the lockfile to pick between npm/pnpm/yarn/bun, and detecting Spring Boot. But
-- `npm run lint`, `gradlew test`, `mvn dependency:tree` had no route through any
-- of it, so they were typed into a terminal by hand, in a directory that had to
-- be remembered, with whatever `gradle` happened to be on PATH.
--
-- So this is a picker over runner's detection rather than a second detector:
-- `runner.target()` says which project and which tool, `runner.tool_cmd()` gives
-- the wrapper-aware invocation, and `runner.run_task()` runs it — with the right
-- cwd, the JAVA_HOME correction runner already applies for old Gradle/Maven, and
-- the quickfix capture from lua/config/problems.lua. A task that fails to compile
-- therefore leaves a navigable list, same as Run does.
--
-- ── Where the task names come from, and why they differ per tool ──
--
-- The three build tools answer "what can I run?" at three completely different
-- costs, and treating them the same would make this the slowest key in the
-- config:
--
--   npm    Free. `scripts` in package.json is the authoritative list and it is
--          one file read, so these are always real, never guessed.
--
--   Maven  No discovery needed and none possible: the lifecycle phases are fixed
--          by Maven itself, identical in every project. A literal list is not a
--          shortcut here, it is the correct answer.
--
--   Gradle Expensive. Tasks are whatever the build script declares, and the only
--          way to enumerate them is `gradlew tasks`, which starts a daemon and
--          takes seconds on a cold one. So: show a curated list of the tasks
--          every Gradle build has immediately, and run the real enumeration in
--          the background, cached on disk against the build files' mtimes. The
--          first use of the picker in a project is the curated list; from then on
--          it is the project's actual tasks, with no wait either time.
--
-- Every list ends with a free-text entry, which is what keeps the curated lists
-- from being a ceiling: `-Dtest=OrderServiceTest`, `--refresh-dependencies`, a
-- task added five minutes ago, or a subproject path all go through it.

local M = {}

local runner = require("config.runner")

--- Maven's build lifecycle, plus the four goals worth a key.
---
--- In lifecycle order rather than alphabetical, because that order is the thing
--- worth knowing about Maven: `verify` implies `test` implies `compile`, so
--- picking the right one is picking how far down the list to go.
---
--- dependency:tree and help:effective-pom are here because they are the two
--- goals reached for while debugging a build rather than running one.
--- spring-boot:run is here too even though the toolbar's Run already does it:
--- in a multi-module build the toolbar runs the module the open file belongs to,
--- and sometimes the one wanted is the one being looked at from a sibling.
local MAVEN_TASKS = {
  "clean",
  "compile",
  "test-compile",
  "test",
  "package",
  "verify",
  "install",
  "clean install",
  "clean package",
  "dependency:tree",
  "help:effective-pom",
  "spring-boot:run",
}

--- Tasks present in essentially every Gradle build, shown before discovery has
--- run (and as the answer when discovery fails — an unresolvable build is
--- exactly when `clean` and `--refresh-dependencies` are wanted most).
---
--- bootRun and bootJar are included unconditionally even though they only exist
--- in a Spring Boot build: a task Gradle does not have fails in one second with
--- "Task 'bootJar' not found", which is a cheaper mistake than hiding it behind a
--- second build-file parse that config.runner has already done once.
local GRADLE_TASKS = {
  "build",
  "clean",
  "test",
  "check",
  "assemble",
  "classes",
  "bootRun",
  "bootJar",
  "jar",
  "javadoc",
  "dependencies",
  "tasks --all",
}

--- The npm scripts to float to the top of the list. The rest follow
--- alphabetically.
---
--- These are the ones with a conventional meaning across projects, so they are
--- the ones muscle memory expects first; a project's own `db:seed` has no such
--- expectation and is better found by reading.
local NODE_SCRIPT_ORDER = { "start", "dev", "serve", "build", "test", "lint", "watch" }

-- ── npm ─────────────────────────────────────────────────────────────────────

--- Every script in `dir`'s package.json, NODE_SCRIPT_ORDER first.
local function node_tasks(dir)
  local ok, text = pcall(vim.fn.readfile, dir .. "/package.json")
  if not ok then return {} end
  local decoded, json = pcall(vim.json.decode, table.concat(text, "\n"))
  if not decoded or type(json) ~= "table" or type(json.scripts) ~= "table" then return {} end

  local rest = {}
  for name, body in pairs(json.scripts) do
    if type(body) == "string" then table.insert(rest, name) end
  end
  table.sort(rest)

  local ordered, seen = {}, {}
  for _, name in ipairs(NODE_SCRIPT_ORDER) do
    if type(json.scripts[name]) == "string" then
      table.insert(ordered, name)
      seen[name] = true
    end
  end
  for _, name in ipairs(rest) do
    if not seen[name] then table.insert(ordered, name) end
  end
  return ordered
end

--- `npm run x`, except for the handful npm exposes directly.
---
--- Separate from config.runner's node_cmd, which answers a different question:
--- that one is only ever called for a start-the-app script, so it can treat
--- `start` as the special case it is. Here the script is arbitrary, and `npm test`
--- and `npm run test` are both valid while `npm lint` is not — the three names npm
--- reserves are the whole list below.
local NPM_DIRECT = { start = true, test = true, stop = true, restart = true }

local function node_cmd(pm, script)
  if pm == "npm" then
    return NPM_DIRECT[script] and ("npm " .. script) or ("npm run " .. script)
  end
  -- pnpm, yarn and bun all accept `<pm> <script>` for any script name.
  return pm .. " " .. script
end

-- ── Gradle discovery ────────────────────────────────────────────────────────

--- The build files whose mtime decides whether a cached task list is still good.
---
--- settings.gradle is in the list because it is what declares subprojects, and
--- `tasks --all` output changes when one is added or removed even though no
--- build.gradle was touched.
local GRADLE_BUILD_FILES = {
  "build.gradle", "build.gradle.kts",
  "settings.gradle", "settings.gradle.kts",
  "gradle.properties",
}

--- A value that changes whenever any of `dir`'s build files does.
---
--- mtimes concatenated, not hashed contents: reading and hashing every build file
--- on each press is exactly the per-keystroke cost this cache exists to avoid,
--- and an mtime is one stat. The failure mode of mtime (a build file rewritten
--- within the same second with the same size) costs a stale task list until the
--- next edit, which is recoverable by pressing the key again later.
---
--- On M rather than local, with write_cache below, because the behaviour worth
--- testing is "a cached list stops being used once a build file changes" — and a
--- spec that wrote the cache file itself would have to spell the stamp format out
--- a second time, which would then agree with itself no matter what this did.
function M.gradle_stamp(dir)
  local parts = {}
  for _, name in ipairs(GRADLE_BUILD_FILES) do
    local stat = vim.uv.fs_stat(dir .. "/" .. name)
    table.insert(parts, name .. ":" .. (stat and stat.mtime.sec or 0))
  end
  return table.concat(parts, ",")
end

--- Where a project's discovered task list is kept.
---
--- stdpath("cache"), not "data": this is reconstructible from the project in a
--- few seconds, so it belongs in the directory the user is invited to delete.
--- Hashed, because the key is an absolute path and the whole point is one file
--- per project with no nesting.
local function cache_path(dir)
  return ("%s/nvim-ide/gradle-tasks/%s.json"):format(
    vim.fn.stdpath("cache"),
    vim.fn.sha256(dir):sub(1, 16)
  )
end

local function read_cache(dir)
  local path = cache_path(dir)
  local ok, text = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local decoded, json = pcall(vim.json.decode, table.concat(text, "\n"))
  if not decoded or type(json) ~= "table" or type(json.tasks) ~= "table" then return nil end
  return json
end

function M.write_cache(dir, stamp, tasks)
  local path = cache_path(dir)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  pcall(vim.fn.writefile, { vim.json.encode({ stamp = stamp, tasks = tasks }) }, path)
end

--- Bare words `gradle tasks` prints that are not tasks.
---
--- The section headers ("Build tasks") and their underlines are excluded by the
--- patterns below — a header contains a space, an underline starts with `-` — but
--- "Rules" is a single capitalised word on its own line and would otherwise come
--- through as a task name.
local GRADLE_NOISE = { Rules = true, Pattern = true }

--- Task names out of `gradle tasks --all` output.
---
--- Two shapes, because Gradle prints a description only when the build script
--- sets one: `test - Runs the test suite.` and a bare `compileTestJava`. Both are
--- anchored to the start of the line, which is what keeps the description text of
--- one task from being read as the name of another.
---
--- The leading `:` is optional because a subproject's task is a path, and which
--- spelling of it gets printed depends on the Gradle version and on whether the
--- report was run from the root: `api:build` and `:api:build` both appear, and
--- both are valid to pass straight back to the tool.
function M.parse_gradle_tasks(lines)
  local seen, tasks = {}, {}
  for _, line in ipairs(lines) do
    local name = line:match("^(:?[%a][%w:_%.%-]*)%s+%-%s") or line:match("^(:?[%a][%w:_%.%-]*)%s*$")
    if name and not seen[name] and not GRADLE_NOISE[name] then
      seen[name] = true
      table.insert(tasks, name)
    end
  end
  table.sort(tasks)
  return tasks
end

-- dir -> true while a discovery run is in flight, so holding the key down does
-- not start four Gradle daemons.
local discovering = {}

--- Enumerate `target`'s Gradle tasks in the background and cache the result.
---
--- Nothing is reported on success: the user asked for a task list, got one, and
--- the only observable effect of this finishing is that the *next* press has more
--- entries. Announcing it would be a notification for something nobody is waiting
--- on. Failures are equally silent — a build that cannot be configured is already
--- going to say so the moment a task is actually run, and this would say it first
--- and out of context.
local function discover_gradle(target)
  local dir = target.dir
  if discovering[dir] then return end
  local cmd = runner.tool_cmd(target)
  if not cmd then return end
  discovering[dir] = true

  -- --console=plain, or the output is an ANSI-animated progress display with the
  -- task list interleaved into it. -q drops the "Welcome to Gradle"/configuration
  -- banners, which are the lines most likely to parse as a bare task name.
  --
  -- Through the shell because tool_cmd's wrapper path is already shell-quoted
  -- (config.runner escapes it for exactly the paths-with-spaces case), so
  -- splitting it back into an argv here would undo that.
  vim.system({ vim.o.shell, "-c", cmd .. " tasks --all -q --console=plain" }, {
    cwd = dir,
    text = true,
  }, function(result)
    discovering[dir] = nil
    if result.code ~= 0 or not result.stdout then return end
    local tasks = M.parse_gradle_tasks(vim.split(result.stdout, "\n", { plain = true }))
    if #tasks == 0 then return end
    -- Stamped AFTER the run, not before: a build file edited while Gradle was
    -- configuring produced a list for the old version of it, and stamping with
    -- the new mtime would cache that stale list as current.
    vim.schedule(function() M.write_cache(dir, M.gradle_stamp(dir), tasks) end)
  end)
end

--- `target`'s Gradle tasks: the cached real list when it is still valid, the
--- curated list otherwise — and a discovery run started either way.
local function gradle_tasks(target)
  local stamp = M.gradle_stamp(target.dir)
  local cached = read_cache(target.dir)
  if cached and cached.stamp == stamp and #cached.tasks > 0 then
    return cached.tasks
  end
  discover_gradle(target)
  return GRADLE_TASKS
end

-- ── Assembling the list ─────────────────────────────────────────────────────

--- The free-text entry every list ends with. A table rather than a string so it
--- cannot collide with a real task called "custom".
local CUSTOM = setmetatable({}, { __tostring = function() return "custom…" end })

--- The tool's name as a human would write it. `tool` is "maven"/"gradle"
--- internally (that is the name of the build system), but what gets typed and
--- what the picker should show is the executable.
function M.display_tool(target)
  if target.tool == "maven" then return "mvn" end
  if target.tool == "gradle" then return "gradle" end
  return target.tool
end

--- The tasks offered for `target`, as a list of { label, cmd } plus CUSTOM.
---
--- `label` is what the picker shows and `cmd` is what runs, and they differ for a
--- good reason: tool_cmd returns a shell-quoted absolute path to ./gradlew, so a
--- label built from it would be 70 characters of the user's home directory.
function M.tasks(target)
  if not target then return nil end
  local cmd = runner.tool_cmd(target)
  if not cmd then return nil end

  local names
  if target.tool == "maven" then
    names = MAVEN_TASKS
  elseif target.tool == "gradle" then
    names = gradle_tasks(target)
  else
    names = node_tasks(target.dir)
  end

  local display = M.display_tool(target)

  local items = {}
  for _, name in ipairs(names) do
    table.insert(items, {
      label = display .. " " .. name,
      -- npm's `run` prefix is not optional for arbitrary scripts, so the command
      -- cannot be built by concatenation the way the Java tools' can.
      cmd = (target.tool == "maven" or target.tool == "gradle")
        and (cmd .. " " .. name)
        or node_cmd(target.tool, name),
    })
  end
  table.insert(items, CUSTOM)
  return items
end

--- Pick a task for the current buffer's project and run it.
function M.pick()
  local target = runner.target()
  if not target then
    return vim.notify("No build tool found for this file", vim.log.levels.WARN)
  end

  local items = M.tasks(target)
  if not items then
    -- A `java` target with tool = "jdtls": a loose .java file with no build
    -- script. There is nothing to enumerate, and <leader>dR already runs it.
    return vim.notify(
      ("%s has no build tool to run tasks with"):format(target.label),
      vim.log.levels.WARN
    )
  end

  vim.ui.select(items, {
    prompt = "Task (" .. target.label .. "): ",
    format_item = function(item) return item == CUSTOM and tostring(CUSTOM) or item.label end,
  }, function(choice)
    if not choice then return end
    if choice ~= CUSTOM then
      return runner.run_task(target, choice.cmd)
    end
    -- Everything after the tool name, so `-Dtest=OrderServiceTest` and
    -- `test --info` and `:api:build` are all one keystroke away without this
    -- module needing to know they exist.
    local args = vim.fn.input({ prompt = M.display_tool(target) .. " " })
    if args:match("^%s*$") then return end
    runner.run_task(target, runner.tool_cmd(target) .. " " .. args)
  end)
end

return M
