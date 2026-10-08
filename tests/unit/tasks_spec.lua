-- lua/config/tasks.lua — the "run any build task" picker.
--
-- Two things are worth testing here and the rest follows from them.
--
-- The first is `parse_gradle_tasks`, because it reads the output of a program
-- nobody wants to run in a unit test. The samples below are literal
-- `gradle tasks --all` output, including the parts that look like task names and
-- are not: section headers, their underlines, the "Rules" block, and the
-- description text of a task that happens to start a line.
--
-- The second is the COMMAND each entry runs, because that is where a wrong answer
-- is both plausible and silent: `npm lint` is not a thing, `npm run test` and
-- `npm test` both are, and a Gradle label built out of tool_cmd would be the
-- absolute path to ./gradlew rather than something a human can read in a picker.
--
-- The Gradle cache is tested by its *stamp*: whether the cached list is still
-- considered good after a build file changes. Running discovery is not in scope
-- for this tier — it starts a daemon.

local H = require("helpers")

local function tasks()
  package.loaded["config.tasks"] = nil
  package.loaded["config.runner"] = nil
  return require("config.tasks")
end

--- The target config.runner would produce for `dir`, built here rather than
--- detected: this module takes a target as input, and going through detection
--- would make every case below also a test of config.runner.
local function target(dir, tool, label)
  return { id = tool .. ":" .. dir, dir = dir, tool = tool, label = label or "demo", kind = "java" }
end

--- The { label, cmd } entry whose label ends with `name`.
local function entry(items, name)
  for _, item in ipairs(items) do
    if type(item) == "table" and item.label and vim.endswith(item.label, name) then return item end
  end
  return nil
end

local function labels(items)
  local out = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and item.label then table.insert(out, item.label) end
  end
  return out
end

describe("config.tasks", function()
  local T, system

  before_each(function()
    T = tasks()
    -- Every Gradle case would otherwise start a real daemon in the background:
    -- asking for a Gradle project's tasks launches discovery whenever the cache
    -- is cold, which is the point of the module and not something to do 8 times
    -- in a unit run. The log is also how the discovery invocation itself is
    -- checked below.
    system = H.spy(vim, "system")
  end)

  after_each(function()
    package.loaded["config.tasks"] = nil
    package.loaded["config.runner"] = nil
    H.cleanup()
  end)

  describe("parse_gradle_tasks", function()
    it("reads both shapes Gradle prints, with and without a description", function()
      local parsed = T.parse_gradle_tasks({
        "Build tasks",
        "-----------",
        "assemble - Assembles the outputs of this project.",
        "build - Assembles and tests this project.",
        "compileTestJava",
        "classes",
      })
      assert.same({ "assemble", "build", "classes", "compileTestJava" }, parsed)
    end)

    it("keeps section headers, underlines and blank lines out of the list", function()
      local parsed = T.parse_gradle_tasks({
        "",
        "Verification tasks",
        "------------------",
        "test - Runs the test suite.",
        "",
        "Rules",
        "-----",
        "Pattern: clean<TaskName>: Cleans the output files of a task.",
      })
      -- "Rules" is the hard one: a single capitalised word on its own line, which
      -- is exactly the shape of a description-less task.
      assert.same({ "test" }, parsed)
    end)

    it("does not read a description's own words as task names", function()
      local parsed = T.parse_gradle_tasks({
        "bootRun - Runs this project as a Spring Boot application.",
        "    (some continuation indented by Gradle)",
      })
      assert.same({ "bootRun" }, parsed)
    end)

    it("keeps subproject paths, which are the reason for --all", function()
      local parsed = T.parse_gradle_tasks({
        ":api:build - Assembles and tests project ':api'.",
        ":web:test",
      })
      assert.same({ ":api:build", ":web:test" }, parsed)
    end)

    it("reports each task once, however many sections list it", function()
      local parsed = T.parse_gradle_tasks({
        "build - Assembles and tests this project.",
        "Other tasks",
        "-----------",
        "build",
      })
      assert.same({ "build" }, parsed)
    end)
  end)

  describe("display_tool", function()
    it("shows the executable, not the build system's name", function()
      -- `tool` is "maven" internally because that is the name of the build
      -- system; what gets typed, and so what the picker should read like, is mvn.
      assert.equals("mvn", T.display_tool({ tool = "maven" }))
      assert.equals("gradle", T.display_tool({ tool = "gradle" }))
      assert.equals("pnpm", T.display_tool({ tool = "pnpm" }))
    end)
  end)

  describe("maven", function()
    it("offers the lifecycle in lifecycle order, not alphabetically", function()
      local dir = H.fixture("spring-gradle")
      local items = T.tasks(target(dir, "maven", "demo (maven)"))
      local names = labels(items)
      local function at(name)
        return vim.fn.index(names, "mvn " .. name) + 1
      end
      -- verify implies test implies compile: the order is the thing worth knowing
      -- about Maven, so the list has to preserve it.
      assert.is_true(at("compile") < at("test"), vim.inspect(names))
      assert.is_true(at("test") < at("verify"), vim.inspect(names))
      assert.is_true(at("verify") < at("install"), vim.inspect(names))
    end)

    it("runs the wrapper when the project has one", function()
      local dir = H.tmpdir("mvnw")
      H.write(dir .. "/pom.xml", { "<project/>" })
      H.write(dir .. "/mvnw", { "#!/bin/sh" })
      vim.fn.setfperm(dir .. "/mvnw", "rwxr-xr-x")

      local item = entry(T.tasks(target(dir, "maven")), "test")
      assert.is_not_nil(item)
      assert.is_true(item.cmd:find("mvnw", 1, true) ~= nil, item.cmd)
      -- And the label stays readable: it is not 70 characters of home directory.
      assert.equals("mvn test", item.label)
    end)
  end)

  describe("gradle", function()
    it("offers the curated list before anything has been discovered", function()
      local dir = H.fixture("spring-gradle")
      local items = T.tasks(target(dir, "gradle", "demo (gradle)"))
      local names = labels(items)
      for _, want in ipairs({ "gradle build", "gradle clean", "gradle test", "gradle bootRun" }) do
        assert.is_true(vim.tbl_contains(names, want), vim.inspect(names))
      end
    end)

    it("enumerates in the background, quietly and without the ANSI progress display", function()
      local dir = H.fixture("spring-gradle")
      T.tasks(target(dir, "gradle"))

      assert.equals(1, system.count)
      local argv, opts = system[1][1], system[1][2]
      local cmd = argv[#argv]
      assert.is_true(cmd:find("tasks --all", 1, true) ~= nil, cmd)
      -- --console=plain or the task list arrives interleaved with an animated
      -- progress display; -q drops the banners most likely to parse as a task.
      assert.is_true(cmd:find("--console=plain", 1, true) ~= nil, cmd)
      assert.is_true(cmd:find(" -q ", 1, true) ~= nil, cmd)
      assert.equals(dir, opts.cwd)
      assert.is_true(opts.text)
    end)

    it("does not start a second daemon while one enumeration is in flight", function()
      local dir = H.fixture("spring-gradle")
      local t = target(dir, "gradle")
      T.tasks(t)
      T.tasks(t)
      T.tasks(t)
      -- The spy never calls the callback, so the in-flight guard stays set —
      -- which is exactly the state a held-down key produces.
      assert.equals(1, system.count)
    end)

    it("prefers ./gradlew over whatever gradle is on PATH", function()
      local dir = H.tmpdir("gradlew")
      H.write(dir .. "/build.gradle", { "plugins { id 'java' }" })
      H.write(dir .. "/gradlew", { "#!/bin/sh" })
      vim.fn.setfperm(dir .. "/gradlew", "rwxr-xr-x")

      local item = entry(T.tasks(target(dir, "gradle")), "build")
      assert.is_not_nil(item)
      assert.is_true(item.cmd:find("gradlew", 1, true) ~= nil, item.cmd)
    end)

    it("uses a cached task list, and stops using it once a build file changes", function()
      local dir = H.tmpdir("gradle-cache")
      H.write(dir .. "/build.gradle", { "plugins { id 'java' }" })
      H.write(dir .. "/gradlew", { "#!/bin/sh\nexit 1" })
      vim.fn.setfperm(dir .. "/gradlew", "rwxr-xr-x")

      -- Write the cache the way discovery would, through the module's own stamp:
      -- a hand-written stamp would only prove that two literals compare equal.
      local t = target(dir, "gradle")
      local discovered = { "flywayMigrate", "integrationTest" }
      T.write_cache(dir, T.gradle_stamp(dir), discovered)

      local names = labels(T.tasks(t))
      assert.is_true(vim.tbl_contains(names, "gradle flywayMigrate"), vim.inspect(names))
      -- The curated list is gone once there is a real one.
      assert.is_false(vim.tbl_contains(names, "gradle bootJar"), vim.inspect(names))

      -- A build file touched into the future is a different stamp, so the cached
      -- list is no longer the answer for this project.
      H.touch(dir .. "/build.gradle", 10)
      names = labels(T.tasks(t))
      assert.is_false(vim.tbl_contains(names, "gradle flywayMigrate"), vim.inspect(names))
      assert.is_true(vim.tbl_contains(names, "gradle build"), vim.inspect(names))
    end)

    it("notices a subproject added in settings.gradle, not just build.gradle", function()
      local dir = H.tmpdir("gradle-settings")
      H.write(dir .. "/build.gradle", { "plugins { id 'java' }" })
      H.write(dir .. "/settings.gradle", { "rootProject.name = 'demo'" })
      local before = T.gradle_stamp(dir)
      H.touch(dir .. "/settings.gradle", 10)
      assert.are_not.equals(before, T.gradle_stamp(dir))
    end)
  end)

  describe("node", function()
    it("floats the conventionally-named scripts to the top, then sorts the rest", function()
      local dir = H.tmpdir("node")
      H.write(dir .. "/package.json", vim.split(vim.json.encode({
        name = "demo",
        scripts = {
          ["db:seed"] = "node seed.js",
          build = "ng build",
          start = "ng serve",
          analyze = "source-map-explorer",
          test = "ng test",
        },
      }), "\n"))

      local names = labels(T.tasks(target(dir, "npm", "demo (npm)")))
      assert.same({
        "npm start", "npm build", "npm test",
        "npm analyze", "npm db:seed",
      }, names)
    end)

    it("adds npm's `run` for an arbitrary script and omits it for the reserved ones", function()
      local dir = H.tmpdir("node-run")
      H.write(dir .. "/package.json", vim.split(vim.json.encode({
        scripts = { test = "jest", lint = "eslint .", start = "node ." },
      }), "\n"))

      local items = T.tasks(target(dir, "npm"))
      -- npm reserves start/test/stop/restart; `npm lint` is not a command.
      assert.equals("npm test", entry(items, "test").cmd)
      assert.equals("npm start", entry(items, "start").cmd)
      assert.equals("npm run lint", entry(items, "lint").cmd)
    end)

    it("passes any script straight through for pnpm, yarn and bun", function()
      local dir = H.tmpdir("node-pnpm")
      H.write(dir .. "/package.json", vim.split(vim.json.encode({
        scripts = { lint = "eslint .", test = "vitest" },
      }), "\n"))

      local items = T.tasks(target(dir, "pnpm"))
      assert.equals("pnpm lint", entry(items, "lint").cmd)
      assert.equals("pnpm test", entry(items, "test").cmd)
    end)

    it("survives a package.json that is missing, unparseable or script-less", function()
      local missing = H.tmpdir("node-missing")
      assert.same({ "custom…" }, vim.tbl_map(tostring, T.tasks(target(missing, "npm"))))

      local broken = H.tmpdir("node-broken")
      H.write(broken .. "/package.json", { "{ not json" })
      assert.same({}, labels(T.tasks(target(broken, "npm"))))
    end)
  end)

  describe("the list itself", function()
    it("always ends with the free-text entry, so the curated lists are not a ceiling", function()
      local dir = H.fixture("spring-gradle")
      for _, tool in ipairs({ "maven", "gradle", "npm" }) do
        local items = T.tasks(target(dir, tool))
        local last = items[#items]
        assert.equals("custom…", tostring(last))
        assert.is_nil(last.label)
      end
    end)

    it("has nothing to offer a target with no build tool", function()
      -- A loose .java file: tool = "jdtls", nothing to enumerate.
      assert.is_nil(T.tasks(target(H.tmpdir("loose"), "jdtls")))
      assert.is_nil(T.tasks(nil))
    end)
  end)

  describe("pick", function()
    it("says so rather than opening an empty picker when there is no project", function()
      -- A buffer in a bare directory: no pom.xml, no build.gradle, no
      -- package.json anywhere above it.
      H.quiet_buffer(H.tmpdir("bare") .. "/notes.md", "markdown")
      local selected = false
      local restore = vim.ui.select
      vim.ui.select = function() selected = true end
      local notes = H.capture_notifications(function() T.pick() end)
      vim.ui.select = restore

      assert.is_false(selected)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("build tool", 1, true) ~= nil, notes[1].msg)
    end)

    it("runs the chosen task through config.runner, with the project's directory", function()
      local dir = H.fixture("spring-gradle")
      H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", "java")

      local runner = require("config.runner")
      local ran = {}
      local restore_run = runner.run_task
      runner.run_task = function(t, cmd) table.insert(ran, { target = t, cmd = cmd }) end
      local restore_select = vim.ui.select
      vim.ui.select = function(items, _, on_choice)
        on_choice(entry(items, "test"))
      end

      T.pick()

      vim.ui.select = restore_select
      runner.run_task = restore_run

      assert.equals(1, #ran)
      assert.is_true(ran[1].cmd:find("test", 1, true) ~= nil, ran[1].cmd)
      assert.equals(vim.fs.normalize(vim.uv.fs_realpath(dir)), ran[1].target.dir)
    end)

    it("does nothing at all when the picker is dismissed", function()
      local dir = H.fixture("spring-gradle")
      H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", "java")

      local runner = require("config.runner")
      local ran = false
      local restore_run = runner.run_task
      runner.run_task = function() ran = true end
      local restore_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice) on_choice(nil) end

      T.pick()

      vim.ui.select = restore_select
      runner.run_task = restore_run
      assert.is_false(ran)
    end)

    it("appends whatever the free-text entry was given to the tool's own command", function()
      local dir = H.fixture("spring-gradle")
      H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", "java")

      local runner = require("config.runner")
      local got
      local restore_run = runner.run_task
      runner.run_task = function(_, cmd) got = cmd end
      local restore_select = vim.ui.select
      vim.ui.select = function(items, _, on_choice) on_choice(items[#items]) end
      local restore_input = vim.fn.input
      vim.fn.input = function() return "test --tests OrderServiceTest" end

      T.pick()

      vim.fn.input = restore_input
      vim.ui.select = restore_select
      runner.run_task = restore_run

      assert.is_not_nil(got)
      assert.is_true(got:find("test --tests OrderServiceTest", 1, true) ~= nil, got)
    end)

    it("treats an empty free-text answer as a cancel", function()
      local dir = H.fixture("spring-gradle")
      H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", "java")

      local runner = require("config.runner")
      local ran = false
      local restore_run = runner.run_task
      runner.run_task = function() ran = true end
      local restore_select = vim.ui.select
      vim.ui.select = function(items, _, on_choice) on_choice(items[#items]) end
      local restore_input = vim.fn.input
      vim.fn.input = function() return "   " end

      T.pick()

      vim.fn.input = restore_input
      vim.ui.select = restore_select
      runner.run_task = restore_run
      assert.is_false(ran)
    end)
  end)
end)
