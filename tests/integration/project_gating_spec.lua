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
  -- Unlike angularls (built into nvim-lspconfig, configured once at startup),
  -- spring-boot.nvim is lazy-loaded on ft = {java, yaml, jproperties}, and its
  -- own config() function is what calls spring_boot.setup(), which registers
  -- vim.lsp.config["spring-boot"] (merging lua/plugins/java.lua's `server`
  -- override — including our root_dir gate — over the plugin's own
  -- lsp/spring-boot.lua defaults) and, by default, vim.lsp.enable("spring-boot").
  -- So the seam to test is the same one angularls's spec above uses:
  -- vim.lsp.config["spring-boot"].root_dir, called directly with a stubbed
  -- on_dir, rather than anything that would start a real client.
  local root_dir

  local skip_reason

  before_each(function()
    H.disable_autosave()

    -- boot-ls needs a JDK 17+; with none the config notifies and returns before
    -- calling setup() at all, so there is no gate to test rather than a broken one.
    if not require("config.jdk").java_bin(17) then
      skip_reason = "no JDK 17+ on this machine — spring-boot config returns early by design"
      return
    end

    H.load_plugin("spring-boot.nvim")
    root_dir = vim.lsp.config["spring-boot"] and vim.lsp.config["spring-boot"].root_dir

    -- setup() also bails (with its own warning) when the language-server jar is
    -- not installed, which likewise means root_dir was never overridden.
    if not root_dir then
      skip_reason = "vscode-spring-boot-tools not installed — spring_boot.setup() bailed"
    else
      skip_reason = nil
    end
  end)

  after_each(function() H.cleanup() end)

  --- H.quiet_buffer sets the filetype without firing FileType, which is what
  --- keeps ftplugin/java.lua (and the real jdtls) — and, now, the real
  --- vim.lsp.enable("spring-boot") autocmd itself — out of this spec. root_dir
  --- reads vim.bo[bufnr].filetype and nothing else, so the suppressed event
  --- changes nothing it can observe.
  local function quiet_buffer(path, ft)
    local buf = H.quiet_buffer(path, ft)
    assert.equals(ft, vim.bo[buf].filetype)
    return buf
  end

  --- Every root_dir call for a buffer at `path`/`ft`, with the arguments
  --- on_dir was invoked with.
  local function resolve(path, ft)
    local buf = quiet_buffer(path, ft)
    local dirs = {}
    root_dir(buf, function(...) table.insert(dirs, { ... }) end)
    return dirs
  end

  --- resolve(), specialised to the java gate's own fixture layout.
  local function gate_java(dir)
    return resolve(dir .. "/src/main/java/com/example/Probe.java", "java")
  end

  it("starts boot-ls for a Gradle project that declares Spring Boot", function()
    if skip_reason then return H.skip(skip_reason) end

    local dirs = gate_java(H.fixture("spring-gradle"))

    assert.equals(1, #dirs)
    -- The resolved root has to be non-empty: boot-ls builds file:// URIs from
    -- it, and an empty string yields a malformed "file://" that crashes the
    -- server on every document event.
    local resolved = dirs[1][1]
    assert.is_true(type(resolved) == "string" and #resolved > 0)
  end)

  it("does not start boot-ls in a Gradle project with no Spring Boot", function()
    if skip_reason then return H.skip(skip_reason) end

    -- java-plain has a build.gradle, just not a Spring one. This is the case
    -- the plugin's own default root_dir gets wrong: it starts a second JVM
    -- language server (plus its classpath listener against jdtls) for every
    -- Java file in every non-Spring project.
    assert.equals(0, #gate_java(H.fixture("java-plain")))
  end)

  it("does not start boot-ls for a Java file with no build files at all", function()
    if skip_reason then return H.skip(skip_reason) end

    local dir = H.tmpdir("java-loose")
    H.write(dir .. "/src/main/java/com/example/Probe.java", { "class Probe {}" })
    -- No pom.xml/build.gradle anywhere, so there is nothing that could declare
    -- Spring Boot and the gate must fall through to "not a Spring project".
    assert.equals(0, #gate_java(dir))
  end)

  it("gates on build-file content, not on the presence of a build file", function()
    if skip_reason then return H.skip(skip_reason) end

    -- Same tree, the org.springframework.boot coordinate the only difference —
    -- so the two outcomes above cannot both be explained by the fixture shape.
    local dir = H.tmpdir("gradle-flip")
    H.write(dir .. "/.git/HEAD", { "ref: refs/heads/main" })
    H.write(dir .. "/src/main/java/com/example/Probe.java", { "class Probe {}" })
    H.write(dir .. "/build.gradle", { "plugins {", "  id 'java'", "}" })
    assert.equals(0, #gate_java(dir))

    H.write(dir .. "/build.gradle", {
      "plugins {",
      "  id 'org.springframework.boot' version '3.3.4'",
      "}",
    })
    assert.equals(1, #gate_java(dir))
  end)

  it("ignores a Spring build file above the project's VCS root", function()
    if skip_reason then return H.skip(skip_reason) end

    -- The whole-machine failure the search bound exists for: one Spring pom.xml
    -- left in $HOME used to make every loose .java file on the machine start a
    -- second JVM language server. The repo's .git makes its parent the ceiling,
    -- and that parent is what stands in for $HOME here. Built by hand because
    -- the planted file has to live in the parent, and H.fixture's parent is a
    -- temp directory shared with every other fixture in the process.
    local above = H.tmpdir("spring-above")
    local dir = above .. "/repo"
    H.write(dir .. "/.git/HEAD", { "ref: refs/heads/main" })
    H.write(dir .. "/src/main/java/com/example/Probe.java", { "class Probe {}" })
    H.write(above .. "/pom.xml", {
      "<project><dependencies><dependency>",
      "  <groupId>org.springframework.boot</groupId>",
      "</dependency></dependencies></project>",
    })

    assert.equals(0, #gate_java(dir))
    assert.equals(1, vim.fn.filereadable(above .. "/pom.xml"))
  end)

  it("reads a parent module's pom.xml in a multi-module build", function()
    if skip_reason then return H.skip(skip_reason) end

    -- The other half of the same bound. It stops at the VCS root rather than at
    -- the nearest build file, so a module that inherits spring-boot from its
    -- parent POM — the normal shape of a multi-module Maven project — is still
    -- recognised. Bounding at the module (as an unbounded-then-nearest search
    -- effectively did) meant boot-ls never started for any of them.
    local dir = H.tmpdir("spring-multimodule")
    H.write(dir .. "/.git/HEAD", { "ref: refs/heads/main" })
    H.write(dir .. "/pom.xml", {
      "<project><dependencies><dependency>",
      "  <groupId>org.springframework.boot</groupId>",
      "</dependency></dependencies></project>",
    })
    -- The module's own POM says nothing about Spring; only the parent does.
    H.write(dir .. "/service/pom.xml", { "<project><artifactId>service</artifactId></project>" })

    assert.equals(1, #resolve(dir .. "/service/src/main/java/com/example/Probe.java", "java"))
  end)

  it("does not gate yaml/jproperties on the Spring check", function()
    if skip_reason then return H.skip(skip_reason) end

    -- Deliberate asymmetry: our wrapper only short-circuits filetype "java".
    -- application.yml / application.properties are filename-gated by the
    -- plugin's own spring_boot.launch.root_dir, and running the build-file
    -- heuristic on them as well would break the standalone-config-file case
    -- boot-ls is best at. Asserted so the asymmetry is a decision, not an
    -- accident. java-plain, i.e. the very project the java gate above refuses
    -- to start in.
    local dir = H.fixture("java-plain")
    local path = H.write(dir .. "/src/main/resources/application.properties", { "server.port=8080" })

    assert.equals(1, #resolve(path, "jproperties"))
  end)

  describe("client config", function()
    it("pins an explicit JDK 17+ as java_cmd", function()
      if skip_reason then return H.skip(skip_reason) end

      -- bootls_cmd is the same function vim.lsp.config["spring-boot"].cmd calls
      -- (via require("spring_boot.config")) once a client actually starts;
      -- calling it directly here gets the same command line without spawning a
      -- real JVM.
      local cmd = require("spring_boot.launch").bootls_cmd(require("spring_boot.config"))
      assert.is_truthy(cmd, "bootls_cmd returned nil — boot-ls jar not resolved")

      local java = cmd[1]
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
      assert.is_truthy(vim.tbl_contains(cmd, "-XX:+UseZGC"))
    end)

    it("strips documentSymbolProvider in on_init", function()
      if skip_reason then return H.skip(skip_reason) end

      local on_init = vim.lsp.config["spring-boot"].on_init
      assert.is_truthy(on_init)

      local client = {
        id = 1,
        name = "spring-boot",
        server_capabilities = { documentSymbolProvider = true, hoverProvider = true },
        -- boot_ls_init also pushes settings via client:notify(...); this test
        -- is only about the documentSymbolProvider strip, so the real push is
        -- a no-op stub rather than something to assert on here.
        notify = function() end,
      }
      on_init(client, {})

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
