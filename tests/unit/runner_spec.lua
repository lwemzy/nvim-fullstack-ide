-- lua/config/runner.lua — what the Run / Restart / Stop / Debug toolbar decides.
--
-- The subject here is DETECTION and the COMMAND it produces, because that is the
-- part with a wrong answer available for every project: the old <F3> chose between
-- mvnw and gradlew with a CWD-relative filereadable(), so opening nvim one level
-- above the project ran the wrong wrapper or refused to run at all while the
-- project was plainly open. Every case below therefore asks the question from a
-- buffer somewhere *inside* a tree, never from the tree's root with a matching cwd.
--
-- Starting processes is the integration spec's job (tests/integration/runner_spec.lua);
-- this tier has no plugins, so the actions are only checked for degrading into a
-- notification instead of an error.

local H = require("helpers")

--- Symlink-resolved, because config.project resolves every path it compares (a
--- ceiling and a starting directory that disagree about symlinks never meet) and
--- the system temp dir is /var -> /private/var on macOS.
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function runner()
  package.loaded["config.runner"] = nil
  return require("config.runner")
end

--- Detection asked from a file inside `dir`, the way a real editing session does.
--- The file need not exist: only its *name* feeds the upward search.
local function targets_from(dir, relative)
  local R = runner()
  H.named_buf(dir .. "/" .. (relative or "src/main/java/com/example/App.java"))
  return R, R.targets(vim.fn.bufnr(dir .. "/" .. (relative or "src/main/java/com/example/App.java")))
end

--- The one target of `kind`, asserted to exist.
local function target_of(targets, kind)
  for _, t in ipairs(targets) do
    if t.kind == kind then return t end
  end
  assert(false, "no " .. kind .. " target in " .. vim.inspect(vim.tbl_map(function(t) return t.kind end, targets)))
end

describe("config.runner", function()
  after_each(function()
    package.loaded["config.runner"] = nil
    H.cleanup()
  end)

  describe("detection", function()
    it("offers bootRun for a Spring Gradle project", function()
      local dir = H.fixture("spring-gradle")
      local _, targets = targets_from(dir, "src/main/java/com/example/demo/DemoApplication.java")
      local t = target_of(targets, "spring")
      assert.equals(real(dir), t.dir)
      assert.equals("gradle", t.tool)
      assert.is_true(t.cmd:find("bootRun", 1, true) ~= nil, t.cmd)
    end)

    it("offers a plain Java target when no build file declares Spring Boot", function()
      -- java-plain's build.gradle uses the `application` plugin, so it is a
      -- perfectly runnable project — just not through bootRun. Getting this wrong
      -- means a Run button whose command fails with "task 'bootRun' not found".
      local dir = H.fixture("java-plain")
      local _, targets = targets_from(dir)
      local t = target_of(targets, "java")
      assert.equals(real(dir), t.dir)
      -- No shell command at all: a main class is launched through jdtls, which is
      -- the only thing that knows the classpath.
      assert.is_nil(t.cmd)
    end)

    it("uses the wrapper by absolute path, not ./gradlew", function()
      -- The command runs with cwd = the module directory, and in a multi-module
      -- build the wrapper lives at the repository root — several levels up. A
      -- relative path is exactly the bug this replaced.
      local dir = H.fixture("spring-gradle")
      H.write(dir .. "/gradlew", "#!/bin/sh\n")
      vim.fn.setfperm(dir .. "/gradlew", "rwxr-xr-x")
      local _, targets = targets_from(dir, "src/main/java/com/example/demo/DemoApplication.java")
      local t = target_of(targets, "spring")
      assert.is_true(t.cmd:find(real(dir) .. "/gradlew", 1, true) ~= nil, t.cmd)
      assert.is_nil(t.cmd:find("./gradlew", 1, true))
    end)

    it("falls back to the gradle on PATH when there is no wrapper", function()
      -- Refusing to run is worse than trying: a project without a committed
      -- wrapper is unusual but legal, and `gradle` may well be installed.
      local dir = H.fixture("spring-gradle")
      local _, targets = targets_from(dir, "src/main/java/com/example/demo/DemoApplication.java")
      assert.equals("gradle bootRun", target_of(targets, "spring").cmd)
    end)

    it("uses mvnw and spring-boot:run for a Maven Spring project", function()
      local dir = H.tmpdir("spring-maven")
      H.write(dir .. "/pom.xml", {
        "<project>",
        "  <parent><groupId>org.springframework.boot</groupId>",
        "    <artifactId>spring-boot-starter-parent</artifactId></parent>",
        "</project>",
      })
      H.write(dir .. "/mvnw", "#!/bin/sh\n")
      vim.fn.setfperm(dir .. "/mvnw", "rwxr-xr-x")
      vim.fn.mkdir(dir .. "/.git", "p")

      local _, targets = targets_from(dir)
      local t = target_of(targets, "spring")
      assert.equals("maven", t.tool)
      -- Shell-quoted, because a project path with a space in it is otherwise two
      -- arguments and mvnw is "not found".
      assert.equals(vim.fn.shellescape(real(dir) .. "/mvnw") .. " spring-boot:run", t.cmd)
    end)

    it("finds a Spring parent pom above the module (multi-module build)", function()
      -- The module's own pom declares nothing; the Spring plugin is inherited.
      -- Stopping at the nearest build file reads a file with none of the
      -- interesting content in it.
      local root = H.tmpdir("multimodule")
      vim.fn.mkdir(root .. "/.git", "p")
      H.write(root .. "/pom.xml", {
        "<project><groupId>org.springframework.boot</groupId>",
        "  <modules><module>api</module></modules></project>",
      })
      H.write(root .. "/api/pom.xml", { "<project><artifactId>api</artifactId></project>" })

      local _, targets = targets_from(root, "api/src/main/java/com/example/Api.java")
      local t = target_of(targets, "spring")
      -- The command still runs in the *module*, so Maven and Gradle resolve the
      -- subproject the open file belongs to.
      assert.equals(real(root) .. "/api", t.dir)
    end)

    it("runs an Angular project with npx ng serve when package.json has no scripts", function()
      local dir = H.fixture("angular-project")
      local _, targets = targets_from(dir, "src/app/app.component.ts")
      local t = target_of(targets, "angular")
      assert.equals("npx ng serve", t.cmd)
      assert.equals(4200, t.port)
    end)

    it("prefers the project's own start script over npx", function()
      local dir = H.fixture("angular-project")
      H.write(dir .. "/package.json", '{ "scripts": { "start": "ng serve --port 4300" } }')
      local _, targets = targets_from(dir, "src/app/app.component.ts")
      assert.equals("npm start", target_of(targets, "angular").cmd)
    end)

    it("uses the package manager the lockfile names", function()
      -- `npm run` in a pnpm workspace resolves a different node_modules layout and
      -- fails with a missing-binary error that says nothing about the real cause.
      local dir = H.fixture("ts-project")
      H.write(dir .. "/package.json", '{ "scripts": { "dev": "vite" } }')
      H.write(dir .. "/pnpm-lock.yaml", "lockfileVersion: '9.0'")
      local _, targets = targets_from(dir, "src/index.ts")
      local expected = vim.fn.executable("pnpm") == 1 and "pnpm dev" or "npm run dev"
      assert.equals(expected, target_of(targets, "node").cmd)
    end)

    it("ignores a package.json that starts nothing", function()
      local dir = H.fixture("prettier-pkgjson")
      local _, targets = targets_from(dir, "src/index.js")
      assert.same({}, vim.tbl_filter(function(t) return t.kind == "node" end, targets))
    end)

    it("offers the nearest project first in a monorepo", function()
      -- The whole point of asking from the buffer: a backend/ and a frontend/ under
      -- one repo are both targets, and Run has to mean the one the open file is in.
      local root = H.tmpdir("monorepo")
      vim.fn.mkdir(root .. "/.git", "p")
      H.write(root .. "/backend/build.gradle", "plugins { id 'org.springframework.boot' }")
      H.write(root .. "/frontend/angular.json", "{}")
      H.write(root .. "/frontend/package.json", '{ "scripts": { "start": "ng serve" } }')

      local _, from_backend = targets_from(root, "backend/src/main/java/com/example/App.java")
      assert.equals("spring", from_backend[1].kind)
      local R = runner()
      assert.equals("angular", R.targets(root .. "/frontend/src")[1].kind)
    end)

    it("answers a nameless buffer from the file you were last in", function()
      -- Measured against a real gradlew bootRun: Run opens its terminal and moves
      -- focus there, that buffer has no name, and Stop then answered "No run target
      -- here" with the build plainly on screen while the toolbar sat empty. The
      -- alternate file is the project the user is actually in.
      local dir = H.fixture("spring-gradle")
      local elsewhere = H.tmpdir("cwd-elsewhere")
      local cwd = vim.fn.getcwd()
      vim.cmd("silent lcd " .. vim.fn.fnameescape(elsewhere))
      local ok, err = pcall(function()
        local R = runner()
        -- Enter the project file, then a nameless buffer: exactly what opening a
        -- terminal does, and it makes the project file the alternate.
        H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", nil)
        H.scratch()
        -- The cwd is deliberately somewhere else, so a pass here cannot come from
        -- the cwd fallback.
        assert.equals(real(dir), target_of(R.targets(), "spring").dir)
      end)
      vim.cmd("silent lcd " .. vim.fn.fnameescape(cwd))
      assert(ok, err)
    end)

    it("falls back to the cwd when nothing on screen has a name", function()
      -- Startup with a dashboard, or `nvim` with no arguments in a project.
      local dir = H.fixture("spring-gradle")
      local cwd = vim.fn.getcwd()
      vim.cmd("silent lcd " .. vim.fn.fnameescape(dir))
      local ok, err = pcall(function()
        local R = runner()
        H.scratch()
        -- No alternate file: the harness runs several cases in one session, so the
        -- previous case's buffer would otherwise answer this one.
        local real_bufnr = vim.fn.bufnr
        H.stub(vim.fn, "bufnr", function(arg)
          if arg == "#" then return -1 end
          return real_bufnr(arg)
        end)
        assert.equals(real(dir), target_of(R.targets(), "spring").dir)
      end)
      vim.cmd("silent lcd " .. vim.fn.fnameescape(cwd))
      assert(ok, err)
    end)

    it("finds nothing in a directory with no project markers", function()
      local dir = H.tmpdir("empty")
      vim.fn.mkdir(dir .. "/.git", "p")
      local _, targets = targets_from(dir, "notes.txt")
      assert.same({}, targets)
    end)
  end)

  describe("debug launches", function()
    it("puts a JDWP agent on 5005 for a Maven Spring app, without suspending it", function()
      -- suspend=y would hold a web app before its first line of code; the attach
      -- happens as soon as the port opens instead.
      local dir = H.tmpdir("spring-maven-debug")
      vim.fn.mkdir(dir .. "/.git", "p")
      H.write(dir .. "/pom.xml", "<project>org.springframework.boot</project>")
      local _, targets = targets_from(dir)
      local cmd = target_of(targets, "spring").debug_cmd
      assert.is_true(cmd:find("agentlib:jdwp", 1, true) ~= nil, cmd)
      assert.is_true(cmd:find("address=*:5005", 1, true) ~= nil, cmd)
      assert.is_true(cmd:find("suspend=n", 1, true) ~= nil, cmd)
    end)

    it("uses Gradle's own --debug-jvm for bootRun", function()
      -- The only way to get JVM args into bootRun without editing build.gradle.
      local dir = H.fixture("spring-gradle")
      local _, targets = targets_from(dir, "src/main/java/com/example/demo/DemoApplication.java")
      assert.equals("gradle bootRun --debug-jvm", target_of(targets, "spring").debug_cmd)
    end)
  end)

  describe("cache", function()
    it("does not re-read build files once it has an answer", function()
      -- The statusline asks on every redraw. Uncached, that is file I/O per redraw
      -- of a component nobody is looking at.
      local dir = H.fixture("spring-gradle")
      local R, targets = targets_from(dir, "src/main/java/com/example/demo/DemoApplication.java")
      assert.equals("spring", targets[1].kind)

      local reads = H.spy(vim.fn, "readfile", function() return {} end)
      R.targets(vim.fn.bufnr(dir .. "/src/main/java/com/example/demo/DemoApplication.java"))
      assert.equals(0, reads.count)
    end)

    it("notices a build file that starts declaring Spring Boot", function()
      -- Adding the plugin to build.gradle has to change the toolbar without a
      -- restart, which is what the BufWritePost hook in M.setup is for.
      local dir = H.fixture("java-plain")
      local R, targets = targets_from(dir)
      assert.equals("java", targets[1].kind)

      H.write(dir .. "/build.gradle", "plugins { id 'org.springframework.boot' }")
      R.invalidate()
      local again = R.targets(vim.fn.bufnr(dir .. "/src/main/java/com/example/App.java"))
      assert.equals("spring", again[1].kind)
    end)

    it("forgets a single buffer without forgetting the rest", function()
      local dir = H.fixture("spring-gradle")
      local R, _ = targets_from(dir, "src/main/java/com/example/demo/DemoApplication.java")
      local buf = vim.fn.bufnr(dir .. "/src/main/java/com/example/demo/DemoApplication.java")
      R.invalidate(buf)
      local reads = H.spy(vim.fn, "readfile", function() return {} end)
      R.targets(buf)
      -- Re-read means the entry really was dropped.
      assert.is_true(reads.count > 0)
    end)
  end)

  describe("toolbar", function()
    it("shows the project and only the buttons that can do something", function()
      -- A Stop button with nothing to stop is a lie, and the statusline is short.
      local dir = H.fixture("spring-gradle")
      local cwd = vim.fn.getcwd()
      vim.cmd("silent lcd " .. vim.fn.fnameescape(dir))
      local ok, err = pcall(function()
        local R = runner()
        H.quiet_buffer(dir .. "/src/main/java/com/example/demo/DemoApplication.java", nil)
        local status = R.status()
        assert.is_true(status:find("spring:", 1, true) ~= nil, status)
        assert.is_true(status:find("Run", 1, true) ~= nil, status)
        assert.is_true(status:find("Debug", 1, true) ~= nil, status)
        -- Nothing is running, so these are hidden.
        assert.is_nil(status:find("Stop", 1, true))
        assert.is_nil(status:find("Restart", 1, true))
      end)
      vim.cmd("silent lcd " .. vim.fn.fnameescape(cwd))
      assert(ok, err)
    end)

    it("is empty where there is no project", function()
      local dir = H.tmpdir("no-project")
      vim.fn.mkdir(dir .. "/.git", "p")
      local R = runner()
      H.named_buf(dir .. "/notes.txt")
      assert.equals("", R.status(vim.fn.bufnr(dir .. "/notes.txt")) or R.status())
    end)

    it("gives lualine a clickable component per button", function()
      -- lualine's on_click is per component, which is why these are separate
      -- components rather than one string with click regions.
      local R = runner()
      local components = R.components()
      assert.is_true(#components >= 5)
      local clicked = {}
      H.stub(R, "dispatch", function(action) table.insert(clicked, action) end)
      for _, c in ipairs(components) do
        assert.equals("function", type(c[1]))
        assert.equals("function", type(c.cond))
        assert.equals("function", type(c.on_click))
        c.on_click()
      end
      -- The label doubles as Run; then one dispatch per button, in draw order.
      assert.same({ "run", "run", "restart", "stop", "debug" }, clicked)
    end)

    it("renders every component without error where there is no target", function()
      -- These run inside a statusline redraw, where an error is a screenful of
      -- repeating E5108 rather than a missing button.
      local R = runner()
      H.scratch()
      for _, c in ipairs(R.components()) do
        assert.is_false(c.cond() and false)
        c[1]()
        if type(c.color) == "function" then c.color() end
      end
    end)
  end)

  describe("actions with no target", function()
    local function warned(fn)
      local dir = H.tmpdir("nothing-here")
      vim.fn.mkdir(dir .. "/.git", "p")
      local R = runner()
      H.named_buf(dir .. "/notes.txt")
      vim.api.nvim_set_current_buf(vim.fn.bufnr(dir .. "/notes.txt"))
      return H.capture_notifications(function() fn(R) end)
    end

    it("says what it looked for instead of failing silently", function()
      -- "Nothing happened" is the worst outcome for a Run button; the message
      -- names the markers so the answer is actionable.
      local notes = warned(function(R) R.run() end)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("No run target", 1, true) ~= nil, notes[1].msg)
      assert.is_true(notes[1].msg:find("pom.xml", 1, true) ~= nil, notes[1].msg)
    end)

    it("warns rather than errors for restart, stop and debug", function()
      for _, action in ipairs({ "restart", "stop", "debug" }) do
        local notes = warned(function(R) R.dispatch(action) end)
        assert.is_true(#notes >= 1, action .. " said nothing")
      end
    end)

    it("rejects an unknown action by name", function()
      local notes = warned(function(R) R.dispatch("frobnicate") end)
      assert.is_true(notes[1].msg:find("frobnicate", 1, true) ~= nil, notes[1].msg)
    end)
  end)

  describe("without plugins", function()
    it("notifies instead of erroring when toggleterm is absent", function()
      -- This tier has no plugins, which is also a real state early in startup.
      local R = runner()
      local notes = H.capture_notifications(function() R.run_in_terminal("true") end)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("toggleterm", 1, true) ~= nil, notes[1].msg)
    end)

    it("notifies instead of erroring when nvim-jdtls is absent", function()
      local dir = H.fixture("java-plain")
      local R = runner()
      H.quiet_buffer(dir .. "/src/main/java/com/example/App.java", nil)
      local notes = H.capture_notifications(function() R.main_class("run") end)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("jdtls", 1, true) ~= nil, notes[1].msg)
    end)
  end)

  describe("commands", function()
    it("registers :Run and friends, completing over the targets here", function()
      local R = runner()
      R.setup()
      local commands = vim.api.nvim_get_commands({})
      for _, name in ipairs({ "Run", "RunRestart", "RunStop", "RunDebug", "RunAttach" }) do
        assert.is_not_nil(commands[name], name .. " was not registered")
      end
      vim.api.nvim_del_augroup_by_name("runner")
      for _, name in ipairs({ "Run", "RunRestart", "RunStop", "RunDebug", "RunAttach" }) do
        vim.api.nvim_del_user_command(name)
      end
    end)
  end)
end)
