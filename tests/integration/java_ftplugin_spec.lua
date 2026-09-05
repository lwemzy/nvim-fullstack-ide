-- ftplugin/java.lua — the jdtls launch configuration.
--
-- jdtls is never actually started here. `jdtls.start_or_attach(config)` is the
-- last thing the ftplugin does, so spying on it captures the fully assembled
-- config and every decision that went into it: the resolved root, the derived
-- workspace dir, the JVM args, the settings table, the OSGi bundle list. That
-- makes almost all of a 509-line file testable in milliseconds instead of the
-- ~30s a real server start costs, and without depending on whether this machine
-- has finished importing a Gradle project.
--
-- on_attach is exercised by calling the captured function with a real (fake)
-- client, which is exactly what nvim would do.

local H = require("helpers")
local fake_lsp = require("helpers.fake_lsp")

local MASON_JDTLS = vim.fn.stdpath("data") .. "/mason/bin/jdtls"

describe("ftplugin/java.lua", function()
  local jdtls, captured, notifications

  --- A minimal Java project: a root marker and one source file. Deliberately
  --- NOT the spring-gradle fixture — a Spring build file makes plugins/java.lua
  --- start the Spring Boot language server, which is a different spec's subject.
  local function java_project(name, class)
    local dir = H.tmpdir(name or "javaproj")
    vim.fn.mkdir(dir .. "/.git", "p")
    H.write(dir .. "/src/main/java/com/example/" .. (class or "App") .. ".java", {
      "package com.example;",
      "",
      "public class " .. (class or "App") .. " {",
      "  public String greeting() {",
      "    return \"hello\";",
      "  }",
      "}",
    })
    return dir
  end

  --- Open a .java file with the real filetype-detection path, capturing the
  --- config the ftplugin would have handed jdtls.
  local function open_java(dir, class)
    local path = dir .. "/src/main/java/com/example/" .. (class or "App") .. ".java"
    local buf
    notifications = H.capture_notifications(function()
      buf = H.edit(path)
    end)
    return buf, path
  end

  before_each(function()
    if vim.fn.executable(MASON_JDTLS) == 0 then
      return H.skip("mason jdtls is not installed; run :MasonInstall jdtls")
    end
    H.load_plugin("nvim-jdtls")
    H.disable_autosave()

    jdtls = require("jdtls")
    captured = nil
    -- Intercept the launch. Without this the spec would start a real Eclipse
    -- JDT LS per project, each with its own workspace and multi-second import.
    H.spy(jdtls, "start_or_attach", function(config)
      captured = config
    end)
    -- setup_dap registers real DAP adapters; the ftplugin already pcall-wraps
    -- it, so suppressing it changes nothing about what is under test.
    H.spy(jdtls, "setup_dap")
  end)

  after_each(function()
    H.cleanup()
  end)

  describe("preconditions", function()
    it("refuses to start and warns when mason's jdtls is missing", function()
      local real_executable = vim.fn.executable
      H.stub(vim.fn, "executable", function(path)
        if path == MASON_JDTLS then return 0 end
        return real_executable(path)
      end)

      open_java(java_project("nojdtls"))

      -- Starting the launcher when it does not exist produces a stream of
      -- unreadable job errors instead of one actionable message.
      assert.is_nil(captured)
      local warned = false
      for _, n in ipairs(notifications) do
        if type(n.msg) == "string" and n.msg:find("jdtls not installed", 1, true) then
          warned = true
        end
      end
      assert.is_true(warned)
    end)

    it("refuses to start and errors when no JDK 21+ was found", function()
      -- It used to warn and start anyway. The launcher then aborted on its own
      -- ("jdtls requires at least Java 21", mason/packages/jdtls/bin/jdtls.py),
      -- leaving a client that attached and immediately exited — so the visible
      -- symptom was Java completion silently absent, with a one-line startup
      -- warning as the only clue. Safe to treat as fatal now that config.jdk also
      -- considers bare `java` on PATH, which is the launcher's own fallback: nil
      -- here means nothing on this machine can run jdtls.
      package.loaded["config.jdk"] = nil
      local jdk = require("config.jdk")
      -- list(), not server_jdk(): everything else in that module reads through
      -- it, so this is "the machine has no JDK" rather than "one function was
      -- told to say no", and the real selection code still runs.
      H.stub(jdk, "list", function() return {} end)

      open_java(java_project("nojdk"))

      assert.is_nil(captured)
      local level
      for _, n in ipairs(notifications) do
        if type(n.msg) == "string" and n.msg:find("no JDK 21+", 1, true) then
          level = n.level
        end
      end
      -- ERROR, not WARN: nothing about Java works, and the message carries the
      -- per-platform install command that fixes it.
      assert.equals(vim.log.levels.ERROR, level)
    end)
  end)

  describe("project root and workspace", function()
    it("derives the root from the buffer's path, not the cwd", function()
      local dir = java_project("rooted")
      open_java(dir)
      assert.is_not_nil(captured)
      assert.equals(vim.fn.resolve(dir), vim.fn.resolve(captured.root_dir))
    end)

    it("passes -data with a per-project workspace under stdpath('data')", function()
      open_java(java_project("wsdir"))
      local cmd = captured.cmd
      local data_index
      for i, arg in ipairs(cmd) do
        if arg == "-data" then data_index = i end
      end
      -- Single-dash -data: the jdtls launcher does not accept --data, and getting
      -- this wrong means every project shares the default workspace.
      assert.is_not_nil(data_index)
      local workspace = cmd[data_index + 1]
      assert.is_not_nil(workspace)
      assert.is_true(
        workspace:find(vim.fn.stdpath("data") .. "/jdtls-workspaces/", 1, true) == 1,
        "workspace should live under stdpath('data')/jdtls-workspaces, got " .. workspace
      )
      -- It must already exist: LaunchingPlugin cannot save install info into a
      -- missing -data dir.
      assert.equals(1, vim.fn.isdirectory(workspace))
    end)

    it("gives two different projects two different workspaces", function()
      open_java(java_project("proj-a"))
      local first = captured.cmd[#captured.cmd]
      open_java(java_project("proj-b"))
      local second = captured.cmd[#captured.cmd]
      -- An Eclipse -data workspace is single-JVM (.metadata/.lock). Two clients
      -- sharing one means the second never reaches ServiceReady — no completions
      -- at all, stuck "Building…" — or both corrupt the same index.
      assert.not_equals(first, second)
    end)

    it("distinguishes two projects that share a basename", function()
      -- The sha suffix exists for exactly this case: two directories both called
      -- `demo`, which a basename-only workspace name would collide.
      local a = H.tmpdir("same-a") .. "/demo"
      local b = H.tmpdir("same-b") .. "/demo"
      for _, dir in ipairs({ a, b }) do
        vim.fn.mkdir(dir .. "/.git", "p")
        H.write(dir .. "/src/main/java/com/example/App.java", { "package com.example;", "public class App {}" })
      end

      open_java(a)
      local first = captured.cmd[#captured.cmd]
      open_java(b)
      local second = captured.cmd[#captured.cmd]

      assert.equals("demo", vim.fn.fnamemodify(first, ":t"):gsub("%-%x+$", ""))
      assert.not_equals(first, second)
    end)
  end)

  describe("launcher command", function()
    before_each(function()
      open_java(java_project("cmd"))
    end)

    it("invokes mason's jdtls launcher", function()
      assert.equals(MASON_JDTLS, captured.cmd[1])
    end)

    it("sets the GC JVM args", function()
      -- G1 with a throughput-biased GCTimeRatio is what keeps a large Gradle
      -- project's import from thrashing; passed as --jvm-arg because the launcher
      -- is a python wrapper, not the JVM.
      assert.is_true(vim.tbl_contains(captured.cmd, "--jvm-arg=-XX:+UseG1GC"))
      assert.is_true(vim.tbl_contains(captured.cmd, "--jvm-arg=-XX:GCTimeRatio=4"))
    end)
    it("pins the launcher to a discovered JDK 21+ when one exists", function()
      local newest = require("config.jdk").server_jdk(21)
      local found
      for _, arg in ipairs(captured.cmd) do
        found = found or arg:match("^%-%-java%-executable=(.*)$")
      end
      if not newest then
        -- jdtls 1.60+ hard-refuses to launch below Java 21, so on a machine with
        -- nothing suitable the flag must be absent rather than pointing at a JDK
        -- that would be rejected.
        assert.is_nil(found)
        return H.skip("no JDK 21+ on this machine")
      end
      -- The launcher only honours $JAVA_HOME or bare `java` on PATH, so a
      -- keg-only Homebrew JDK is invisible to it without this flag.
      assert.equals(newest.path .. "/bin/java", found)
    end)

    it("attaches the lombok javaagent, or warns that it could not", function()
      local agent
      for _, arg in ipairs(captured.cmd) do
        agent = agent or arg:match("^%-%-jvm%-arg=%-javaagent:(.*lombok%.jar)$")
      end
      if agent then
        -- Standalone jdtls needs the -javaagent explicitly: the
        -- java.jdt.ls.lombokSupport.enabled setting is VS Code-only. Without it
        -- every @Data/@Getter/@Builder member is an unresolved symbol.
        assert.equals(1, vim.fn.filereadable(agent))
      else
        local warned = false
        for _, n in ipairs(notifications) do
          if type(n.msg) == "string" and n.msg:find("lombok.jar not found", 1, true) then
            warned = true
          end
        end
        -- Silence was the original bug: the agent path was wrong and wired with
        -- `and ... or nil`, so Lombok projects were simply broken with no clue.
        assert.is_true(warned, "missing lombok.jar must be reported, not silent")
      end
    end)
  end)

  describe("heap sizing", function()
    --- The -Xmx value the ftplugin chose, in MB.
    local function heap_mb(total_gb, constrained_gb)
      local gb = 1024 * 1024 * 1024
      H.stub(vim.uv, "get_total_memory", function() return total_gb * gb end)
      H.stub(vim.uv, "get_constrained_memory", function()
        return (constrained_gb or 0) * gb
      end)
      -- The heap is computed at ftplugin load time, so the stubs have to be in
      -- place before the buffer is opened, not before start_or_attach.
      open_java(java_project("heap-" .. total_gb .. "-" .. (constrained_gb or 0)))
      for _, arg in ipairs(captured.cmd) do
        local mb = arg:match("^%-%-jvm%-arg=%-Xmx(%d+)m$")
        if mb then return tonumber(mb) end
      end
      error("no -Xmx arg in: " .. vim.inspect(captured.cmd))
    end

    it("caps at 4G on a large machine", function()
      -- The previous hardcoded value. Anything from ~24GB up must be unchanged,
      -- so this is not a behaviour change for the machine it was tuned on.
      assert.equals(4096, heap_mb(64))
    end)

    it("scales down on a small machine", function()
      -- jdtls is one of several JVMs and node servers this config can run at
      -- once. On Linux an over-committed box does not degrade, it OOM-kills the
      -- largest RSS — jdtls — so Java completion dies mid-session with nothing
      -- in nvim to explain it.
      assert.equals(2730, heap_mb(16))
      assert.equals(1365, heap_mb(8))
    end)

    it("keeps a floor so a tiny machine still gets a usable heap", function()
      -- A heap that GCs hard still completes; one the machine cannot back does
      -- not start at all.
      assert.equals(512, heap_mb(2))
    end)

    it("obeys a cgroup limit over the host's total", function()
      -- Inside Docker or a devcontainer the host's RAM is not ours to spend, and
      -- get_total_memory still reports the host's. Exceeding the cgroup limit is
      -- an instant kill, not a slowdown.
      assert.equals(682, heap_mb(64, 4))
    end)
  end)

  describe("settings", function()
    before_each(function()
      open_java(java_project("settings"))
    end)

    it("registers every discovered JDK as a runtime", function()
      local jdk = require("config.jdk")
      assert.same(jdk.runtimes(), captured.settings.java.configuration.runtimes)
    end)

    it("hands Gradle the JDK homes as a command-line argument", function()
      local args = captured.settings.java.import.gradle.arguments
      local expected = "-Dorg.gradle.java.installations.paths="
        .. require("config.jdk").gradle_installation_paths()
      -- Must be `arguments`, not `jvmArguments`: jvmArguments demonstrably never
      -- reached the Gradle daemon, so a toolchain project imported with no
      -- classpath and completion returned nothing while the server looked fine.
      assert.is_true(vim.tbl_contains(args, expected))
      assert.is_nil(captured.settings.java.import.gradle.jvmArguments)
    end)

    it("uses the string-enum form of implementationCodeLens", function()
      -- The real jdtls key is singular and takes none|types|methods|all. The
      -- table form `implementationsCodeLens = { enabled = true }` matches nothing
      -- in Preferences, so the lenses never render.
      assert.equals("all", captured.settings.java.implementationCodeLens)
      assert.is_nil(captured.settings.java.implementationsCodeLens)
    end)

    it("points the formatter at the Google style profile that exists on disk", function()
      local format = captured.settings.java.format
      assert.is_true(format.enabled)
      assert.equals("GoogleStyle", format.settings.profile)
      -- Without a url jdtls silently uses Eclipse's own default profile, which is
      -- not Google style at all.
      assert.equals(1, vim.fn.filereadable(format.settings.url))
    end)

    it("enables parameter-name inlay hints", function()
      -- This is the only reason a Java buffer has any inlay hints to show; see
      -- tests/integration/inlay_hint_spec.lua for the ownership rules that
      -- decide whether they survive.
      assert.equals("all", captured.settings.java.inlayHints.parameterNames.enabled)
    end)

    it("keeps the full favoriteStaticMembers list", function()
      local favorites = captured.settings.java.completion.favoriteStaticMembers
      -- This setting REPLACES jdtls's defaults instead of extending them, so
      -- anything missing here is missing from static-import completion entirely.
      for _, required in ipairs({
        "org.junit.jupiter.api.Assertions.*",
        "org.junit.jupiter.api.Assumptions.*",
        "org.mockito.Mockito.*",
        "org.mockito.ArgumentMatchers.*",
        "org.hamcrest.Matchers.*",
      }) do
        assert.is_true(vim.tbl_contains(favorites, required), "missing " .. required)
      end
    end)

    it("separates static imports into their own block", function()
      -- jdtls prefixes static imports with "#", so a bare { "" } interleaves them
      -- into the ordinary import block (Google style §3.3.3 wants them apart).
      assert.same({ "#", "" }, captured.settings.java.completion.importOrder)
    end)

    it("names the content provider by its registered plugin.xml id", function()
      -- Plain "fernflower" matches nothing; decompiled sources then never appear.
      assert.equals("fernflowerContentProvider", captured.settings.java.contentProvider.preferred)
    end)

    it("enables autobuild and automatic build-config updates", function()
      assert.is_true(captured.settings.java.autobuild.enabled)
      assert.equals("automatic", captured.settings.java.configuration.updateBuildConfiguration)
    end)

    it("hands the SAME settings table to initialize", function()
      -- Identity, not a copy: config.settings alone only reaches the server via
      -- didChangeConfiguration, which nvim sends AFTER initialize returns — by
      -- which point jdtls has already started its first project import with
      -- default preferences and failed to resolve the toolchain.
      assert.equals(captured.settings, captured.init_options.settings)
    end)
  end)

  describe("OSGi bundles", function()
    before_each(function()
      open_java(java_project("bundles"))
    end)

    it("excludes the plain runtime jars that break loadBundles", function()
      for _, jar in ipairs(captured.init_options.bundles) do
        -- These two are ordinary classpath jars, not OSGi bundles. Including
        -- either makes jdtls's loadBundles throw and abort the WHOLE list, which
        -- silently kills resolveMainClass and all DAP discovery.
        assert.is_nil(jar:match("runner%-jar%-with%-dependencies%.jar$"), jar)
        assert.is_nil(jar:match("jacocoagent%.jar$"), jar)
      end
    end)

    it("includes java-test bundles when the mason package is installed", function()
      local installed = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/java-test/extension/server/*.jar", true, true)
      if #installed == 0 then return H.skip("java-test not installed") end
      local has_test_bundle = false
      for _, jar in ipairs(captured.init_options.bundles) do
        has_test_bundle = has_test_bundle or jar:find("java-test", 1, true) ~= nil
      end
      assert.is_true(has_test_bundle)
    end)

    it("includes spring-boot's java extensions", function()
      local sb_ok, spring_boot = pcall(require, "spring_boot")
      if not sb_ok then return H.skip("spring-boot.nvim not available") end
      -- require()d rather than left to autocmd ordering, because lazy.nvim and
      -- the ftplugin race on FileType and the bundles must be present before
      -- jdtls initializes.
      for _, jar in ipairs(spring_boot.java_extensions()) do
        assert.is_true(vim.tbl_contains(captured.init_options.bundles, jar), "missing " .. jar)
      end
    end)

    it("answers _java.reloadBundles.command with the bundle list", function()
      local handler = vim.lsp.commands["_java.reloadBundles.command"]
      -- The server sends this via workspace/executeClientCommand and waits for a
      -- response; returning the list acknowledges it without an error.
      assert.equals("function", type(handler))
      assert.same(captured.init_options.bundles, handler())
    end)
  end)

  describe("on_attach", function()
    local bufnr, client

    before_each(function()
      bufnr = select(1, open_java(java_project("attach")))
      assert.is_not_nil(captured)
      local srv = fake_lsp.start({
        name = "jdtls",
        bufnr = bufnr,
        root_dir = H.tmpdir("attach-root"),
        capabilities = fake_lsp.caps.full,
      })
      H.track_client(srv.id)
      client = srv.client
      captured.on_attach(client, bufnr)
    end)

    it("maps the Java-specific refactorings buffer-locally", function()
      for _, m in ipairs({
        { "<F9>", "Organize imports" },
        { "<F10>", "Run nearest test" },
        { "<F11>", "Run all tests in class" },
        { "<C-S-o>", "Organize imports" },
        { "<C-S-v>", "Extract variable" },
        { "<C-S-c>", "Extract constant" },
      }) do
        local map = H.keymap("n", m[1], bufnr)
        assert.is_not_nil(map, "no mapping for " .. m[1])
        assert.equals(m[2], map.desc)
        -- Buffer-local: these must not leak into non-Java buffers, where <F10>
        -- and <C-S-v> mean something else entirely.
        assert.equals(1, map.buffer)
      end
    end)

    it("maps the debug keys that F9-F11 displaced", function()
      for _, lhs in ipairs({ "<leader>db", "<leader>dB", "<leader>dt", "<leader>du", "<leader>dr", "<leader>dR" }) do
        assert.is_not_nil(H.keymap("n", lhs, bufnr), "no mapping for " .. lhs)
      end
    end)

    it("replaces this buffer's autocmds on re-attach", function()
      local before = H.count_autocmds("BufWritePre", "java_ftplugin", bufnr)
      assert.is_true(before > 0)

      -- FileType java re-fires on :e, :e!, :JdtRestart and JdtlsClean's own
      -- `vim.cmd("edit")`. Stacking instead of replacing added another blocking
      -- format-on-save round trip and another full codeLens sweep per event —
      -- typing lag that got worse the longer the session ran.
      captured.on_attach(client, bufnr)
      assert.equals(before, H.count_autocmds("BufWritePre", "java_ftplugin", bufnr))
    end)

    it("uses one shared augroup, and clears only the re-attaching buffer", function()
      -- The group is shared across buffers because a name built from bufnr is
      -- never reclaimed (nvim deletes a wiped buffer's autocmds, not its group),
      -- so it leaked one empty augroup per Java file opened. The risk that
      -- introduces is the opposite one: clearing the whole group on attach would
      -- silently delete every other Java buffer's format-on-save.
      local other = H.scratch({ lines = { "x" } })
      local srv = fake_lsp.start({
        name = "jdtls",
        bufnr = other,
        root_dir = H.tmpdir("shared-group-root"),
        capabilities = { codeLensProvider = true },
      })
      H.track_client(srv.id)
      captured.on_attach(srv.client, other)

      -- Re-attaching `other` must leave `bufnr` alone.
      captured.on_attach(srv.client, other)
      assert.is_true(H.count_autocmds("BufWritePre", "java_ftplugin", bufnr) > 0)
      assert.equals(1, H.count_autocmds("BufWritePre", "java_ftplugin", other))

      -- And no per-buffer group name exists to be left behind. Note this cannot
      -- be checked with H.autocmds: nvim has no API that lists augroups, and
      -- nvim_get_autocmds only returns groups that still HAVE autocmds — an empty
      -- group is invisible to it, which is precisely why the leak was silent.
      -- Asking for a group by name errors iff the group does not exist.
      assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = "java_ftplugin_" .. bufnr }))
    end)

    it("registers format-on-save against the attaching client only", function()
      local autocmds = H.autocmds({ event = "BufWritePre", group = "java_ftplugin", buffer = bufnr })
      assert.equals(1, #autocmds)
      -- Scoped to this client id so a second attached server (spring-boot) is
      -- never asked to format Java.
      local formats = H.spy(vim.lsp.buf, "format")
      vim.api.nvim_exec_autocmds("BufWritePre", { buffer = bufnr })
      assert.equals(1, formats.count)
      assert.equals(client.id, formats[1][1].id)
      assert.is_false(formats[1][1].async)
    end)

    it("only sets up the codelens renderer when the server offers lenses", function()
      -- A server without codeLensProvider would otherwise get a CursorMoved
      -- handler doing extmark work on every keystroke for lenses that never come.
      local other = H.scratch({ lines = { "x" } })
      local srv = fake_lsp.start({
        name = "jdtls",
        bufnr = other,
        root_dir = H.tmpdir("nolens-root"),
        capabilities = { hoverProvider = true },
      })
      H.track_client(srv.id)
      captured.on_attach(srv.client, other)

      assert.equals(0, H.count_autocmds("CursorMoved", "java_ftplugin", other))
      assert.is_true(H.count_autocmds("CursorMoved", "java_ftplugin", bufnr) > 0)
    end)

    it("shares one codelens namespace across buffers", function()
      -- Namespaces are process-global and nvim has NO API to delete one, so a
      -- name built from bufnr leaked a permanent entry per Java file opened —
      -- for the whole session, surviving buffer wipe and collectgarbage.
      local names = vim.api.nvim_get_namespaces()
      assert.is_not_nil(names["java_codelens"])
      for name in pairs(names) do
        assert.is_nil(
          name:match("^java_codelens_%d+$"),
          "per-buffer codelens namespace leaked: " .. name
        )
      end
    end)
  end)

  describe("JdtlsClean", function()
    local bufnr

    before_each(function()
      bufnr = select(1, open_java(java_project("clean")))
    end)

    it("registers the command and its buffer-local mapping", function()
      assert.is_not_nil(vim.api.nvim_get_commands({})["JdtlsClean"])
      local map = H.keymap("n", "<leader>jc", bufnr)
      assert.is_not_nil(map)
      assert.equals(1, map.buffer)
    end)

    it("wipes the workspace directory it was given", function()
      local workspace = captured.cmd[#captured.cmd]
      assert.equals(1, vim.fn.isdirectory(workspace))
      H.write(workspace .. "/.metadata/marker", { "stale" })

      -- Force the no-clients path. Asserting on "no jdtls is running" would be
      -- a lie in a suite that starts fake clients named jdtls, and the
      -- with-clients path waits on LspDetach (or an 8s fail-safe), which is the
      -- next test's subject.
      H.stub(vim.lsp, "get_clients", function() return {} end)

      local real_delete = vim.fn.delete
      local deletes = H.spy(vim.fn, "delete", function(...) return real_delete(...) end)
      H.capture_notifications(function()
        vim.cmd("JdtlsClean")
        vim.wait(200)
      end)

      assert.same({ workspace, "rf" }, deletes[1])
      -- The directory itself is back: the command schedules `vim.cmd("edit")`,
      -- which re-runs this ftplugin and re-creates the workspace before jdtls
      -- starts. What must be gone is its CONTENTS — a stale .metadata is exactly
      -- what makes Lombok/dependency changes fail to take effect.
      assert.equals(0, vim.fn.filereadable(workspace .. "/.metadata/marker"))
    end)

    it("waits for the server to detach before wiping", function()
      local workspace = captured.cmd[#captured.cmd]
      local srv = fake_lsp.start({
        name = "jdtls",
        bufnr = bufnr,
        root_dir = H.tmpdir("clean-root"),
        capabilities = fake_lsp.caps.full,
      })
      H.track_client(srv.id)
      H.spy(vim.cmd, "edit")

      local stopped = H.spy(vim.lsp, "stop_client")
      H.capture_notifications(function()
        vim.cmd("JdtlsClean")
        vim.wait(100)
      end)

      -- Deleting a live Eclipse workspace underneath a running JDT LS leaves the
      -- server writing into a deleted .metadata and the restart inherits a
      -- half-built index, so the wipe must not happen until it is gone.
      assert.equals(1, stopped.count)
      assert.equals(1, vim.fn.isdirectory(workspace))
    end)
  end)
end)
