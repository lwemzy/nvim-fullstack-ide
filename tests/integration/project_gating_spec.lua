-- Two "don't start unless this really is that kind of project" gates.
--
--   angularls        lua/plugins/lsp.lua   — root_dir returns without calling
--                                            on_dir outside an Angular project
--   spring-boot.nvim lua/plugins/java.lua  — a FileType autocmd that only
--                                            starts boot-ls for .java when the
--                                            build files declare Spring Boot
--
-- Both are negative properties: the thing that must be observed is a server
-- NOT starting. So both are driven through the exact seam the framework uses
-- (root_dir's on_dir callback, the gate autocmd's own callback) with the launch
-- path stubbed, rather than by starting servers and looking at what attached.
-- Starting the real angularls/boot-ls would take tens of seconds, depend on
-- mason state, and — for the negative cases — could only ever prove "nothing
-- attached *yet*".

local H = require("helpers")

--- vim.fs.root resolves through symlinks (on macOS /var is a link to
--- /private/var, and the temp dirs fixtures live in are under /var), so a raw
--- fixture path never compares equal to what root_dir hands back.
local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

describe("angularls root_dir gating", function()
  local root_dir
  before_each(function()
    -- angularls's base config (cmd, filetypes, root_markers) comes from
    -- nvim-lspconfig's runtime/lsp/angularls.lua; vim.lsp.config.angularls only
    -- merges the override on top of it once that is on the runtimepath.
    H.load_plugin("nvim-lspconfig")
    H.disable_autosave()
    root_dir = vim.lsp.config.angularls.root_dir
  end)

  after_each(function() H.cleanup() end)

  --- Left UNLOADED on purpose: root_dir only needs a buffer name (vim.fs.root
  --- reads it), and loading a .ts file would set filetype=typescript, which fires
  --- the FileType autocmd vim.lsp.enable installs and starts ts_ls/angularls for
  --- real — the very thing this gate is about. Unloaded also keeps the spec
  --- independent of whether ts_ls is installed.
  local ts_buffer = H.named_buf

  --- Every root_dir call, with the arguments on_dir was invoked with.
  local function resolve(path)
    local dirs = {}
    local ret = root_dir(ts_buffer(path), function(...) table.insert(dirs, { ... }) end)
    return dirs, ret
  end

  it("is a function, not a static path", function()
    -- A string root_dir is computed once for the whole session, which is what
    -- makes angularls attach with a stale (or empty) root in the next project.
    assert.equals("function", type(root_dir))
  end)

  it("resolves the project root from a nested component file", function()
    local dir = H.fixture("angular-project")
    local dirs = resolve(dir .. "/src/app/app.component.ts")

    -- Exactly one call, with the directory holding angular.json — not the
    -- buffer's own directory, or angularls would treat src/app as the workspace
    -- and resolve none of the project's templates or tsconfig paths.
    assert.equals(1, #dirs)
    assert.same({ realpath(dir) }, dirs[1])
  end)

  it("does not call on_dir at all in a plain TypeScript project", function()
    local dir = H.fixture("ts-project")
    local dirs, ret = resolve(dir .. "/src/main.ts")

    -- THE assertion of this block. vim.lsp's framework starts the server if and
    -- only if on_dir is called, and it falls back to cwd as a "single file"
    -- root when no marker matches — so on_dir(nil) or on_dir(cwd) here would
    -- attach angularls to *every* TypeScript file on the machine. angularls
    -- hardcodes angularOnly:true, so those extra clients contribute nothing
    -- while duplicating navic attaches and adding a second inlay-hint provider
    -- per buffer (the exact two-provider shape inlay_hint_spec.lua exists for).
    assert.equals(0, #dirs)
    -- And it returns nothing, so nothing downstream can mistake a value for a
    -- resolved root either.
    assert.is_nil(ret)
  end)

  it("resolves an nx.json-only workspace", function()
    -- Nx monorepos have no angular.json at all; the marker list has to cover
    -- both or Angular support silently disappears in every Nx repo.
    local dir = H.tmpdir("nx-workspace")
    H.write(dir .. "/nx.json", { '{ "npmScope": "acme" }' })
    H.write(dir .. "/apps/web/src/app/app.component.ts", { "export class AppComponent {}" })

    local dirs = resolve(dir .. "/apps/web/src/app/app.component.ts")
    assert.same({ realpath(dir) }, dirs[1])
  end)

  it("does not call on_dir for a buffer with no file at all", function()
    -- Scratch/terminal/quickfix buffers reach root_dir too, and for a non-empty
    -- buftype vim.fs.root searches upward from the CWD instead of the buffer —
    -- so whether angularls starts for them is decided by wherever Neovim was
    -- launched. It must still take the "no marker, no server" path.
    if vim.fs.root(vim.uv.cwd(), { "angular.json", "nx.json" }) then
      return H.skip("test suite is being run from inside an Angular workspace")
    end
    local dirs = {}
    root_dir(H.scratch(), function(...) table.insert(dirs, { ... }) end)
    assert.equals(0, #dirs)
  end)
end)

describe("spring-boot.nvim project gating", function()
  -- The plugin config runs exactly once per Neovim process, and it calls
  -- maybe_start(current_buf) while running. So the launch seam has to be stubbed
  -- *before* the first load, and what that load did is captured here for the
  -- java_cmd / on_init assertions rather than re-triggered per test.
  local config_time_starts

  local skip_reason

  --- Record every vim.lsp.start the plugin would make and suppress it.
  --- vim.lsp.start (rather than spring_boot.launch.start) is the seam because
  --- launch.start does its own yaml/pom.xml filename gating that is part of what
  --- the config relies on, and because spring_boot.launch cannot even be
  --- required until lazy has put the plugin on the runtimepath.
  local function capture_starts()
    return H.spy(vim.lsp, "start", function() return nil end)
  end

  before_each(function()
    H.disable_autosave()

    -- boot-ls needs a JDK 17+; with none the config notifies and returns before
    -- creating anything, so there is no gate to test rather than a broken one.
    if not require("config.jdk").java_bin(17) then
      skip_reason = "no JDK 17+ on this machine — spring-boot config returns early by design"
      return
    end

    local starts = capture_starts()
    H.load_plugin("spring-boot.nvim")
    config_time_starts = config_time_starts or starts

    -- setup() also bails (with its own warning) when the language-server jar is
    -- not installed, which likewise means no augroup exists to assert on.
    if #H.autocmds({ group = "spring_boot_ls_gated", event = "FileType" }) == 0 then
      skip_reason = "vscode-spring-boot-tools not installed — spring_boot.setup() bailed"
    else
      skip_reason = nil
    end
  end)

  after_each(function() H.cleanup() end)

  --- H.quiet_buffer sets the filetype without firing FileType, which is what
  --- keeps ftplugin/java.lua (and the real jdtls) out of this spec. The gate
  --- reads vim.bo[bufnr].filetype and nothing else, so the suppressed event
  --- changes nothing it can observe. Made current because
  --- spring_boot.launch.start inspects the *current* buffer for its own
  --- yaml/pom.xml filename checks.
  local function quiet_buffer(path, ft)
    local buf = H.quiet_buffer(path, ft)
    assert.equals(ft, vim.bo[buf].filetype)
    return buf
  end

  --- The gate autocmd's own callback for `pattern`. Invoked directly rather than
  --- via nvim_exec_autocmds because FileType matches on the filetype *value*,
  --- and nvim_exec_autocmds cannot be given both a buffer and a pattern.
  local function gate_callback(pattern)
    for _, ac in ipairs(H.autocmds({ group = "spring_boot_ls_gated", event = "FileType" })) do
      if ac.pattern == pattern then return ac.callback end
    end
  end

  --- Run the java gate for a buffer in `dir` and return the vim.lsp.start log.
  local function gate_java(dir)
    local buf = quiet_buffer(dir .. "/src/main/java/com/example/Probe.java", "java")
    local starts = capture_starts()
    gate_callback("java")({ buf = buf })
    return starts
  end

  it("registers its own gated FileType autocmd", function()
    if skip_reason then return H.skip(skip_reason) end

    -- One per filetype the plugin cares about. Missing "java" would mean no
    -- Spring support at all; missing yaml/jproperties would mean no property or
    -- application.yml completion, which is the main reason boot-ls is here.
    local patterns = {}
    for _, ac in ipairs(H.autocmds({ group = "spring_boot_ls_gated", event = "FileType" })) do
      patterns[ac.pattern] = true
    end
    assert.same({ java = true, jproperties = true, yaml = true }, patterns)

    -- ...and the plugin's OWN autocmd group must not exist. It is what
    -- autocmd=false suppresses, and it starts boot-ls for every .java file with
    -- no Spring check whatsoever — leaving both registered would make the gate
    -- below decorative.
    assert.equals(0, #H.autocmds({ group = "spring_boot_ls" }))
  end)

  it("starts boot-ls for a Gradle project that declares Spring Boot", function()
    if skip_reason then return H.skip(skip_reason) end

    -- is_spring_boot_project and maybe_start are locals inside the plugin's
    -- config closure and cannot be called directly, so they are tested through
    -- their only observable effect: whether a client is started.
    local starts = gate_java(H.fixture("spring-gradle"))

    assert.equals(1, starts.count)
    local client_config = starts[1][1]
    assert.equals("spring-boot", client_config.name)
    -- root_dir has to be present and non-empty: boot-ls builds file:// URIs from
    -- it, and an empty string yields a malformed "file://" that crashes the
    -- server on every document event.
    assert.is_true(type(client_config.root_dir) == "string" and #client_config.root_dir > 0)
    assert.is_truthy(client_config.init_options.workspaceFolders)
  end)

  it("does not start boot-ls in a Gradle project with no Spring Boot", function()
    if skip_reason then return H.skip(skip_reason) end

    -- java-plain has a build.gradle, just not a Spring one. This is the case
    -- the plugin's own autocmd gets wrong: it starts a second JVM language
    -- server (plus its classpath listener against jdtls) for every Java file in
    -- every non-Spring project.
    assert.equals(0, gate_java(H.fixture("java-plain")).count)
  end)

  it("does not start boot-ls for a Java file with no build files at all", function()
    if skip_reason then return H.skip(skip_reason) end

    local dir = H.tmpdir("java-loose")
    H.write(dir .. "/src/main/java/com/example/Probe.java", { "class Probe {}" })
    -- No pom.xml/build.gradle anywhere, so there is nothing that could declare
    -- Spring Boot and the gate must fall through to "not a Spring project".
    assert.equals(0, gate_java(dir).count)
  end)

  it("gates on build-file content, not on the presence of a build file", function()
    if skip_reason then return H.skip(skip_reason) end

    -- Same tree, the org.springframework.boot coordinate the only difference —
    -- so the two outcomes above cannot both be explained by the fixture shape.
    local dir = H.tmpdir("gradle-flip")
    H.write(dir .. "/.git/HEAD", { "ref: refs/heads/main" })
    H.write(dir .. "/src/main/java/com/example/Probe.java", { "class Probe {}" })
    H.write(dir .. "/build.gradle", { "plugins {", "  id 'java'", "}" })
    assert.equals(0, gate_java(dir).count)

    H.write(dir .. "/build.gradle", {
      "plugins {",
      "  id 'org.springframework.boot' version '3.3.4'",
      "}",
    })
    assert.equals(1, gate_java(dir).count)
  end)

  it("does not gate yaml/jproperties on the Spring check", function()
    if skip_reason then return H.skip(skip_reason) end

    -- Deliberate asymmetry: the gate only short-circuits filetype "java".
    -- application.yml / application.properties are filename-gated by
    -- spring_boot.launch.start itself, and running the build-file heuristic on
    -- them as well would break the standalone-config-file case boot-ls is best
    -- at. Asserted so the asymmetry is a decision, not an accident.
    -- java-plain, i.e. the very project the java gate above refuses to start in.
    local dir = H.fixture("java-plain")
    local path = H.write(dir .. "/src/main/resources/application.properties", { "server.port=8080" })
    local buf = quiet_buffer(path, "jproperties")

    local starts = capture_starts()
    gate_callback("jproperties")({ buf = buf })
    assert.equals(1, starts.count)
  end)

  describe("client config", function()
    local client_config

    before_each(function()
      if skip_reason then return end
      -- The config-time maybe_start call: same resolved_opts every later start
      -- is built from, so its client config is the one to inspect.
      client_config = config_time_starts and config_time_starts[1] and config_time_starts[1][1]
    end)

    it("pins an explicit JDK 17+ as java_cmd", function()
      if skip_reason then return H.skip(skip_reason) end
      assert.is_truthy(client_config, "the config-time maybe_start never reached vim.lsp.start")

      local java = client_config.cmd[1]
      -- An absolute path, never the bare string "java": the plugin's fallback
      -- resolves whatever `java` is on PATH, and boot-ls's command line uses
      -- -XX:+UseZGC, which does not exist before JDK 11. On a machine whose
      -- PATH java is a Java 8 JRE the JVM aborts with "Unrecognized VM option
      -- 'UseZGC'" and the only symptom is that nothing ever attaches.
      assert.is_truthy(java:match("^/"), "java_cmd is not absolute: " .. tostring(java))
      assert.is_truthy(java:match("/bin/java$"), "java_cmd is not a bin/java: " .. tostring(java))
      assert.equals(1, vim.fn.executable(java))
      -- ...and it is the JDK config.jdk picked, not something the plugin guessed.
      assert.equals(require("config.jdk").java_bin(17), java)
      assert.is_truthy(vim.tbl_contains(client_config.cmd, "-XX:+UseZGC"))
    end)

    it("strips documentSymbolProvider in on_init", function()
      if skip_reason then return H.skip(skip_reason) end
      assert.is_truthy(client_config)

      local client = {
        id = 1,
        name = "spring-boot",
        server_capabilities = { documentSymbolProvider = true, hoverProvider = true },
      }
      client_config.on_init(client, {})

      -- barbecue/navic auto-attach to any client advertising document symbols
      -- and have no per-client exclusion. jdtls already claims it for Java and
      -- covers breadcrumbs fully, so a second claimant only produces
      -- "Already attached to jdtls" on every Java file.
      assert.is_false(client.server_capabilities.documentSymbolProvider)
      -- Everything else must survive: the wrapper still calls the plugin's own
      -- boot_ls_init, and dropping that would break boot-ls's client setup.
      assert.is_true(client.server_capabilities.hoverProvider)
    end)
  end)
end)
