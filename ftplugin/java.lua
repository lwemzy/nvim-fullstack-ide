local ok, jdtls = pcall(require, "jdtls")
if not ok then return end

local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
if vim.fn.executable(mason_bin) == 0 then
  vim.notify("jdtls not installed — run :MasonInstall jdtls", vim.log.levels.WARN)
  return
end

-- Resolve the project root ONCE and derive everything from it.
--
-- find_root returns the NEAREST ancestor holding any marker — the list is a set,
-- not a precedence order. That is why pom.xml / build.gradle / build.gradle.kts
-- are deliberately NOT in the first pass: every module of a multi-module build
-- has one, so a module's own build file beat the repository's .git and each
-- module became its own "project". Opening files from three modules of one build
-- started three jdtls JVMs (each committing -Xms1G immediately) and three
-- Gradle/Maven imports. For Gradle it is worse than just wasteful: a subproject
-- build.gradle imported standalone cannot resolve `project(':lib')`, so there is
-- no classpath and zero completions in a project that builds fine on the command
-- line.
--
-- These three markers only ever exist at a build ROOT: `mvnw`/`gradlew` are the
-- wrapper scripts, and `settings.gradle` is what declares a Gradle
-- multi-project build in the first place. Same set nvim-jdtls itself defaults to
-- ({ ".git", "gradlew", "mvnw" }), plus settings.gradle. The rule matches the one
-- lua/config/project.lua:69-72 states for this repo: "The VCS root rather than
-- the nearest package.json / pom.xml: in a monorepo or a multi-module Maven
-- build those stop at the package".
local root_dir = require("jdtls.setup").find_root({
  ".git", "mvnw", "gradlew", "settings.gradle", "settings.gradle.kts",
})
  -- Second pass, and only if the first found nothing: a single-module project
  -- with no wrapper, no settings.gradle and no VCS directory of its own. Here
  -- the module file IS the root, so the old behaviour is the right one.
  or require("jdtls.setup").find_root({ "pom.xml", "build.gradle", "build.gradle.kts" })
  -- The buffer's own directory, not getcwd(). getcwd() is wherever nvim happened
  -- to be started — frequently $HOME — and handing jdtls $HOME as a project root
  -- makes it index the entire home directory. getcwd() survives only for a
  -- buffer with no name at all, which cannot be a .java file on disk.
  or (function()
    local name = vim.api.nvim_buf_get_name(0)
    return name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  end)()

-- Per-project workspace to avoid cross-project class collisions.
-- Must key off root_dir, NOT getcwd(): root_dir is derived from the buffer's
-- path, so opening files from two different projects in one nvim session (or
-- from a cwd above/outside the project) produced two jdtls clients pointing at
-- the SAME -data dir. An Eclipse -data workspace is single-JVM (.metadata/.lock),
-- so the second server either never reaches ServiceReady — no completions at
-- all, stuck "Building…" — or both corrupt each other's index. The sha suffix
-- disambiguates distinct projects that share a basename (e.g. two `demo`s).
local workspace_dir = vim.fn.stdpath("data")
  .. "/jdtls-workspaces/"
  .. vim.fn.fnamemodify(root_dir, ":p:h:t")
  .. "-"
  .. vim.fn.sha256(root_dir):sub(1, 8)

-- The same table lua/plugins/lsp.lua gives every other server. Shared because
-- jdtls is the one client that does NOT go through vim.lsp.config("*"), and
-- workspace.fileOperations.willRename — which is what lets a package move in the
-- explorer rewrite imports — is only offered by jdtls if the client asks for it.
local capabilities = require("config.capabilities").make()

-- ── JDK 21+ discovery ───────────────────────────────────────────────────────
-- jdtls 1.60 hard-refuses to launch on anything below Java 21 ("jdtls requires
-- at least Java 21", mason/packages/jdtls/bin/jdtls.py). Its launcher only
-- honours $JAVA_HOME or bare `java` on PATH, so a Homebrew *keg-only* JDK (not
-- symlinked into /Library/Java/JavaVirtualMachines, invisible to
-- /usr/libexec/java_home) is never found and Java completion silently never
-- works. Locate a real 21+ home ourselves and pass it explicitly.
--
-- jdtls itself must RUN on 21+; a project may still target an older release, so
-- every JDK found gets registered as an available runtime below and the newest
-- one is marked default.
--
-- server_jdk, not "the newest JDK installed": the host JVM is picked as the
-- newest *LTS* that qualifies (see config.jdk), because that is what the Eclipse
-- stack is tested against — while the runtimes below still expose every JDK, so
-- capping the host does not cap what a project can target.
local jdk = require("config.jdk")
local launcher_jdk = jdk.server_jdk(21)

-- Bail rather than start. config.jdk now includes whatever bare `java` resolves
-- to on PATH, which is the launcher's own fallback, so nil here means nothing on
-- this machine can run jdtls at all — and starting it anyway produced the worst
-- possible symptom: the launcher aborts with "jdtls requires at least Java 21"
-- on stderr, nvim reports a client that attached and immediately exited, and
-- Java completion is simply absent with a one-line startup warning as the only
-- clue. An error and no client is the same outcome, said out loud.
if not launcher_jdk then
  vim.notify(
    "jdtls: no JDK 21+ found — Java completion/diagnostics are OFF.\n"
      .. "jdtls refuses to launch below Java 21. Install one and reopen the file:\n"
      .. "  macOS   brew install openjdk@21\n"
      .. "  Debian  sudo apt install openjdk-21-jdk\n"
      .. "  Fedora  sudo dnf install java-21-openjdk-devel\n"
      .. "  any     sdk install java 21-tem   (sdkman)\n"
      .. "Already have one? Point $JAVA_HOME at it — see :checkhealth nvim-ide.",
    vim.log.levels.ERROR
  )
  return
end

-- Lombok ships inside the Mason jdtls package. The old path
-- (stdpath("data") .. "/lombok.jar") never existed, and because it was wired up
-- with `and … or nil` it failed *silently* — so in every Lombok project the
-- @Data/@Getter/@Builder/@Slf4j members were simply absent from completion and
-- reported as unresolved symbols. Note java.jdt.ls.lombokSupport.enabled is a
-- VS Code-only setting; standalone jdtls needs the -javaagent explicitly.
local lombok_jar = vim.fn.stdpath("data") .. "/mason/packages/jdtls/lombok.jar"
if vim.fn.filereadable(lombok_jar) == 0 then
  lombok_jar = vim.fn.stdpath("data") .. "/mason/share/jdtls/lombok.jar"
end
local lombok_arg = vim.fn.filereadable(lombok_jar) == 1
  and "--jvm-arg=-javaagent:" .. lombok_jar
  or nil
if not lombok_arg then
  vim.notify("jdtls: lombok.jar not found — Lombok-generated members will be invisible", vim.log.levels.WARN)
end

-- ── jdtls heap ──────────────────────────────────────────────────────────────
-- Sized from the machine rather than hardcoded, because jdtls is only one of
-- several JVMs and language servers this config can have running at once: the
-- Gradle daemon Buildship spawns for the import, boot-ls (another JVM, pinned to
-- -Xmx1G by spring-boot.nvim's launch.lua), plus node for ts_ls /
-- angularls / eslint. A flat -Xmx4G is invisible on a big machine and reckless
-- on a small one, and it is worse than reckless on Linux specifically: the OOM
-- killer picks the largest RSS, which is jdtls, so the failure presents as Java
-- completion dying mid-session with nothing in nvim to explain it. (macOS just
-- swaps and gets slow, which is why this never showed up here.)
--
-- Total/6 to a 4G ceiling. The ceiling keeps the previous behaviour on anything
-- from ~24GB up; the divisor lands a 16GB box on ~2.7G and an 8GB box on ~1.4G,
-- against a reference point of 1G, which is what VS Code's Java extension
-- defaults java.jdt.ls.vmargs to. The floor is below that on purpose: on a 4GB
-- machine a smaller heap that GCs hard still completes, where a heap the machine
-- cannot back does not.
local heap_mb = (function()
  local total = vim.uv.get_total_memory()
  -- cgroup/container limit, which is the only number that matters inside Docker
  -- or a devcontainer — where the host's total is not ours to spend. Returns 0
  -- when unconstrained. (WSL2 needs no special case: it reports its own share as
  -- total inside the VM.)
  local constrained = vim.uv.get_constrained_memory() or 0
  if constrained > 0 then total = math.min(total, constrained) end
  return math.max(512, math.min(4096, math.floor(total / 6 / 1024 / 1024)))
end)()

-- The mason launcher hardcodes `-Xms1G` into exec_args BEFORE appending our
-- --jvm-arg values (mason/packages/jdtls/bin/jdtls.py:126-130), so on any
-- machine where heap_mb lands under 1024 the JVM was handed -Xms1G together with
-- a smaller -Xmx and refused to start outright:
--
--   $ java -Xms1G -Xmx682m -version
--   Error occurred during initialization of VM
--   Initial heap size set to a larger value than the maximum heap size
--
-- heap_mb is 682 on a 4GB laptop and on a 64GB host inside a 4GB devcontainer,
-- and 512 at 2GB — so jdtls attached and immediately exited, which is the
-- "worst possible symptom" this file's header describes: Java completion
-- silently absent with nothing in nvim to explain it.
--
-- Fixed by passing our own -Xms, which lands after the launcher's and therefore
-- wins (verified: `-Xms1G -Xms256m -Xmx512m` reports InitialHeapSize=256MB via
-- -XX:+PrintFlagsFinal). Raising the floor to 1024 instead would also have
-- started, but it would force a 1G commit on exactly the small machines the
-- sizing above exists to protect. A quarter of the heap, bounded below by 128MB
-- so a big machine still starts warm.
local initial_heap_mb = math.max(128, math.floor(heap_mb / 4))

-- Workspace dir must exist before jdtls starts; otherwise LaunchingPlugin can't save install info
vim.fn.mkdir(workspace_dir, "p")

local config = {
  cmd = (function()
    local c = {
      mason_bin,
      -- -Xms before -Xmx only for readability; both land after the launcher's
      -- own -Xms1G, which is what makes the override work.
      "--jvm-arg=-Xms" .. initial_heap_mb .. "m",
      "--jvm-arg=-Xmx" .. heap_mb .. "m",
      "--jvm-arg=-XX:+UseG1GC",
      "--jvm-arg=-XX:GCTimeRatio=4",
    }
    -- Unconditional: the no-JDK case returned above.
    c[#c + 1] = "--java-executable=" .. launcher_jdk.path .. "/bin/java"
    if lombok_arg then c[#c + 1] = lombok_arg end
    return c
  end)(),

  root_dir = root_dir,

  capabilities = capabilities,

  settings = {
    java = {
      configuration = {
        -- Built from the JDKs actually discovered above. The old hardcoded
        -- ~/.sdkman/... path did not exist on this machine, so jdtls had no
        -- registered runtime at all. `name` must be a real Eclipse execution
        -- environment id, so it has to track each detected major version.
        runtimes = jdk.runtimes(),
        -- Reimports the Gradle/Maven project model automatically whenever a
        -- build file changes (new deps, e.g. Lombok, resolve without having
        -- to remember to run :JdtUpdateConfig). Only costs anything at the
        -- moment a build file is actually saved, not continuously.
        updateBuildConfiguration = "automatic",
      },
      import = {
        gradle = {
          -- Run the Gradle tooling API on a JDK we actually located. Gradle
          -- otherwise inherits jdtls's own JVM, which is fine, but being
          -- explicit keeps the daemon off a stray old PATH java.
          java = { home = launcher_jdk.path },
          -- THE fix for "jdtls attaches but returns zero completions" in any
          -- Gradle project that declares a toolchain, e.g.
          --   java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }
          -- (the default for a Spring Initializr project). Gradle's toolchain
          -- auto-detection shares java_home's blind spot — it never looks in
          -- Homebrew's keg-only prefixes — so the import died with
          -- "Cannot find a Java installation on your machine matching:
          -- {languageVersion=17, ...}. Toolchain download repositories have not
          -- been configured." That aborts ':compileClasspath' resolution, so the
          -- project imports with NO classpath: every symbol is unresolved and
          -- completion returns nothing, while the server still looks healthy.
          -- Handing Gradle the homes we found makes the toolchain resolvable
          -- without needing a global ~/.gradle/gradle.properties.
          --
          -- This goes in `arguments` (Gradle *command-line* args) and NOT in
          -- `jvmArguments`. Both are forwarded to Buildship, but jvmArguments
          -- demonstrably never reached the daemon — with it set, the daemon still
          -- reported `Assuming the daemon was started with following jvm opts:
          -- [-Dfile.encoding=UTF-8, -Duser.country=US, -Duser.language=en,
          -- -Duser.variant]` and the toolchain error persisted. As a Gradle CLI
          -- argument it is exactly the `./gradlew -Dorg.gradle.java.
          -- installations.paths=…` invocation that resolves the toolchain.
          arguments = {
            "-Dorg.gradle.java.installations.paths=" .. jdk.gradle_installation_paths(),
          },
        },
      },
      eclipse = { downloadSources = true },
      maven = { downloadSources = true },
      -- The real jdtls key is `java.implementationCodeLens` (singular) and it is
      -- a string enum none|types|methods|all — NOT {enabled=bool}. The old
      -- `implementationsCodeLens = { enabled = true }` matched nothing in
      -- Preferences, so implementation lenses never rendered.
      implementationCodeLens = "all",
      referencesCodeLens = { enabled = true },
      references = { includeDecompiledSources = true },
      inlayHints = { parameterNames = { enabled = "all" } },
      -- Enable annotation processing so MapStruct/Lombok processors run in jdtls's JDT compiler
      autobuild = { enabled = true },
      format = {
        enabled = true,
        settings = {
          -- Google Java Style Guide (https://google.github.io/styleguide/javaguide.html),
          -- via Google's own official Eclipse formatter profile. Without a url set
          -- here, jdtls silently falls back to Eclipse's own default profile —
          -- which is NOT Google style (different import layout, no enforced
          -- 100-col wrap, etc.) — despite what this comment used to claim.
          url = vim.fn.stdpath("config") .. "/java-google-style.xml",
          profile = "GoogleStyle",
        },
      },
      signatureHelp = { enabled = true },
      -- The provider id registered in org.eclipse.jdt.ls.core's plugin.xml is
      -- "fernflowerContentProvider"; plain "fernflower" matched nothing.
      contentProvider = { preferred = "fernflowerContentProvider" },
      completion = {
        -- This setting REPLACES jdtls's defaults rather than extending them, so
        -- the previous short list silently dropped ArgumentMatchers (any()/eq()/
        -- anyString(), used in nearly every Mockito test), Answers, Assumptions
        -- and the JUnit 5 Dynamic* helpers from static-import completion.
        -- Full upstream default list + hamcrest.
        favoriteStaticMembers = {
          "org.junit.Assert.*",
          "org.junit.Assume.*",
          "org.junit.jupiter.api.Assertions.*",
          "org.junit.jupiter.api.Assumptions.*",
          "org.junit.jupiter.api.DynamicContainer.*",
          "org.junit.jupiter.api.DynamicTest.*",
          "org.mockito.Mockito.*",
          "org.mockito.ArgumentMatchers.*",
          "org.mockito.Answers.*",
          "org.hamcrest.Matchers.*",
        },
        -- Google style §3.3.3: static imports in their own block above the
        -- single ASCII-sorted non-static block. jdtls prefixes static imports
        -- with "#", so dropping that group (the old `{ "" }`) interleaved them
        -- into the ordinary block instead of separating them.
        importOrder = { "#", "" },
      },
      sources = {
        organizeImports = {
          starThreshold = 9999,
          staticStarThreshold = 9999,
        },
      },
    },
  },

  on_attach = function(client, bufnr)
    -- Re-firing FileType java (:e, :e!, :JdtRestart, and JdtlsClean's own
    -- `vim.cmd("edit")`) must REPLACE this buffer's autocmds instead of stacking
    -- another copy. Previously each reload added another blocking format-on-save
    -- round trip, another full codeLens+resolve sweep per BufEnter/InsertLeave/
    -- save, and another clear-namespace + extmark pass on every keystroke via
    -- CursorMovedI — i.e. visible typing lag that got worse the longer the
    -- session ran.
    --
    -- One SHARED augroup, cleared for this buffer only, rather than an augroup
    -- named per buffer. Both give identical replace-not-stack semantics, but a
    -- per-buffer name is never reclaimed: nvim deletes a wiped buffer's
    -- buffer-local autocmds, not the group they were in, so a long session
    -- accumulated one dead `java_ftplugin_<bufnr>` group per Java file ever
    -- opened. Measured: 500 opened-and-wiped buffers left 500 empty groups.
    local group = vim.api.nvim_create_augroup("java_ftplugin", { clear = false })
    vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })

    local map = function(keys, func, desc)
      vim.keymap.set("n", keys, func, { buffer = bufnr, desc = desc })
    end

    -- The standard LSP keymaps (gd/gD/gr/gi/K/<leader>lk/<leader>rn/<leader>ca/
    -- [d/]d/<leader>d/<leader>lt/<leader>ls/<leader>lw/<leader>lc/<leader>lC and
    -- inlay hints) now come from the shared LspAttach handler in
    -- lua/plugins/lsp.lua, which fires for jdtls too. They used to be
    -- re-implemented here because jdtls starts via vim.lsp.start (which ignores
    -- vim.lsp.config("*")), but that duplication had drifted: it bound
    -- <leader>ds/<leader>ws instead of <leader>ls/<leader>lw, omitted <leader>d
    -- and <leader>lt, never enabled inlay hints, and mapped gD unconditionally.

    -- Java-specific
    map("<F9>",  jdtls.organize_imports,        "Organize imports")
    map("<F10>", jdtls.test_nearest_method,     "Run nearest test")
    map("<F11>", jdtls.test_class,              "Run all tests in class")
    -- Shift+Alt+O is VS Code's Organize Imports; Ctrl+Shift+O is its Go to
    -- Symbol in File, which lua/plugins/lsp.lua gates on documentSymbol support
    -- for jdtls too. This mapping used to sit on <C-S-o> and shadow that.
    map("<M-O>", jdtls.organize_imports,        "Organize imports")
    map("<C-S-v>", jdtls.extract_variable,      "Extract variable")
    map("<C-S-c>", jdtls.extract_constant,      "Extract constant")

    -- Source generators (IntelliJ's Alt+Insert), under the existing <leader>j
    -- "java" group. Not Alt+Insert itself: Insert is not a key every keyboard
    -- this config runs on has, and <M-Insert> is not forwarded by several
    -- terminal emulators — the same reason <C-S-t> was rejected for <M-o>.
    --
    -- The kind strings and the client-side handler the accessors action needs
    -- live in lua/config/java_source.lua; see its header for why that handler has
    -- to exist at all.
    local java_source = require("config.java_source")
    java_source.setup()
    local generate = function(keys, kind, desc)
      map(keys, java_source.generate(java_source.KINDS[kind]), "Java: " .. desc)
    end
    -- <leader>jgg first because it is the one to reach for when you do not
    -- remember the others: source.generate is the parent kind, so it offers
    -- every generator below in one picker.
    generate("<leader>jgg", "all",              "Generate… (all source actions)")
    generate("<leader>jga", "accessors",        "Generate getters/setters")
    generate("<leader>jgc", "constructors",     "Generate constructor")
    generate("<leader>jgt", "to_string",        "Generate toString()")
    generate("<leader>jge", "hash_code_equals", "Generate equals()/hashCode()")
    generate("<leader>jgd", "delegates",        "Generate delegate methods")
    generate("<leader>jgo", "override",         "Override/implement methods")
    generate("<leader>jgf", "final_modifiers",  "Add final where possible")
    generate("<leader>jgs", "sort_members",     "Sort members")

    -- Debug keymaps (F9/F10/F11 are taken by Java tools above)
    map("<leader>db", function() require("dap").toggle_breakpoint() end, "Debug: Toggle breakpoint")
    map("<leader>dB", function()
      require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: "))
    end, "Debug: Conditional breakpoint")
    map("<leader>dt", function() require("dap").terminate() end,         "Debug: Terminate")
    map("<leader>du", function() require("dapui").toggle() end,          "Debug: Toggle UI")
    map("<leader>dr", function() require("dap").repl.toggle() end,       "Debug: Toggle REPL")

    -- Run without attaching the debugger (plain `java -cp ...` launch via jdtls).
    -- The implementation is config.runner.main_class, which is also what the
    -- toolbar's Run button uses for a project with no build-tool entry point — one
    -- copy, so the button and the key cannot come to disagree about which main
    -- class runs or how its output is shown.
    map("<leader>dR", function()
      require("config.runner").main_class("run")
    end, "Run without debugging")

    -- No format-on-save autocmd here. conform.nvim already formats every
    -- written buffer (plugins/editor.lua's format_after_save), and java has no
    -- entry in formatters_by_ft, so its `lsp_format = "fallback"` sends
    -- textDocument/formatting to this very client — the identical request this
    -- autocmd used to make. Having both meant a measured THREE formatting round
    -- trips per :write of one Java file, the slowest LSP request jdtls serves.
    --
    -- conform's copy is also the safer of the two. vim.lsp.buf.format's
    -- synchronous path applies whatever edits come back with no staleness check
    -- at all, while conform compares the buffer's changedtick before applying
    -- (conform/lsp_format.lua) and drops a result that a later edit has already
    -- invalidated — the difference between reformatting and silently reverting
    -- a keystroke that landed mid-format. conform then re-writes the buffer
    -- itself (vim.cmd.update), so saving still leaves formatted content on disk.
    --
    -- <M-l> (keymaps.lua) is the manual path; both go through conform now.

    -- Code lenses (implementations/references counts, java-test's Run/Debug Test
    -- lenses). Bypasses vim.lsp.codelens's built-in renderer, which draws every
    -- lens on its own virt_line above the code — instead: render only the
    -- lens(es) for the line the cursor is currently on, inline at end-of-line.
    if client.server_capabilities.codeLensProvider then
      -- One namespace for every Java buffer, not one per buffer. Namespaces are
      -- process-global and there is NO API to delete one, so a name built from
      -- bufnr leaked a permanent entry per Java file opened, for the life of the
      -- session (measured: 500 buffers -> 500 namespaces, surviving buf_delete
      -- and a full collectgarbage). Sharing is safe because every call below is
      -- already scoped to `bufnr`: clear_namespace and set_extmark both take the
      -- buffer, so two Java buffers cannot see each other's extmarks.
      local codelens_ns = vim.api.nvim_create_namespace("java_codelens")
      local codelens_by_row = {}

      local function render_cursor_lens()
        vim.api.nvim_buf_clear_namespace(bufnr, codelens_ns, 0, -1)
        local row = vim.api.nvim_win_get_cursor(0)[1] - 1
        local lenses = codelens_by_row[row]
        if not lenses then return end
        local titles = {}
        for _, lens in ipairs(lenses) do
          if lens.command and lens.command.title and lens.command.title ~= "" then
            table.insert(titles, lens.command.title)
          end
        end
        if #titles > 0 then
          vim.api.nvim_buf_set_extmark(bufnr, codelens_ns, row, 0, {
            virt_text = { { "  " .. table.concat(titles, " | "), "Comment" } },
            virt_text_pos = "eol",
            hl_mode = "combine",
          })
        end
      end

      local function fetch_codelens()
        local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
        client:request("textDocument/codeLens", params, function(err, result)
          if err or not result then return end
          codelens_by_row = {}
          local function place(lens)
            local row = lens.range.start.line
            codelens_by_row[row] = codelens_by_row[row] or {}
            table.insert(codelens_by_row[row], lens)
          end

          -- jdtls returns lenses unresolved (no command.title yet) — each one
          -- needs a codeLens/resolve round trip before it has anything to show.
          local pending = 0
          for _, lens in ipairs(result) do
            if lens.command then
              place(lens)
            else
              pending = pending + 1
              client:request("codeLens/resolve", lens, function(rerr, resolved)
                if not rerr and resolved then place(resolved) end
                pending = pending - 1
                if pending == 0 then render_cursor_lens() end
              end, bufnr)
            end
          end
          if pending == 0 then render_cursor_lens() end
        end, bufnr)
      end

      -- CursorHold deliberately excluded: it fires every 'updatetime' (default
      -- 4s) of no cursor movement, meaning jdtls would redo a references +
      -- implementations search across the whole file every few seconds while
      -- just reading code — real, avoidable, recurring CPU cost. BufEnter/
      -- InsertLeave/BufWritePost are meaningful state changes; idling isn't.
      vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "BufWritePost" }, {
        group = group,
        buffer = bufnr,
        callback = fetch_codelens,
      })
      -- CursorMovedI deliberately omitted: re-rendering the cursor-line lens on
      -- every keystroke costs a clear-namespace + extmark pass per character
      -- while typing (and while a completion menu is open) to show a lens for a
      -- line you are actively editing. CursorMoved covers normal-mode movement,
      -- and InsertLeave above re-fetches on exit.
      vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = bufnr,
        callback = render_cursor_lens,
      })
      fetch_codelens()

      map("<leader>cl", function()
        local row = vim.api.nvim_win_get_cursor(0)[1] - 1
        local lenses = codelens_by_row[row] or {}
        if #lenses == 0 then
          vim.notify("No code lens on this line", vim.log.levels.INFO)
        elseif #lenses == 1 then
          client:exec_cmd(lenses[1].command, { bufnr = bufnr })
        else
          vim.ui.select(lenses, {
            prompt = "Code lens:",
            format_item = function(l) return l.command and l.command.title or "?" end,
          }, function(choice)
            if choice then client:exec_cmd(choice.command, { bufnr = bufnr }) end
          end)
        end
      end, "Run code lens")
    end

    -- <leader>uh (toggle inlay hints) and the initial enable come from the
    -- shared LspAttach handler.

    vim.keymap.set("v", "<leader>jv", function()
      jdtls.extract_variable(true)
    end, { buffer = bufnr, desc = "Extract variable (visual)" })
    vim.keymap.set("v", "<leader>jm", function()
      jdtls.extract_method(true)
    end, { buffer = bufnr, desc = "Extract method (visual)" })
  end,

  init_options = {
    extendedClientCapabilities = jdtls.extendedClientCapabilities,
    bundles = (function()
      local bundles = {}
      -- java-debug-adapter (enables DAP debugging)
      --
      -- glob(pat, true, true) and not glob(pat, true): the two-argument form
      -- returns a newline-JOINED STRING, so when a mason upgrade leaves two
      -- plugin-*.jar versions side by side this pushed a single
      -- "…/plugin-0.53.1.jar\n…/plugin-0.54.0.jar" into bundles. That entry is
      -- not a readable file, and per the note below one bad entry makes jdtls's
      -- loadBundles throw and abort the WHOLE list — so F5, <leader>dR,
      -- <F10>/<F11> and the Run toolbar all go dead at once, silently. The
      -- java-test glob below already passed both flags; this one did not.
      local debug_jars = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar",
        true, true
      )
      vim.list_extend(bundles, debug_jars)
      -- java-test (enables running tests via jdtls)
      -- Excludes runner-jar-with-dependencies.jar and jacocoagent.jar: these are
      -- plain runtime jars for the test JVM's classpath, not OSGi bundles, and
      -- including them makes jdtls's loadBundles throw and abort the whole list
      -- (which silently breaks vscode.java.resolveMainClass / dap discovery).
      local test_jars = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/java-test/extension/server/*.jar",
        true, true
      )
      test_jars = vim.tbl_filter(function(jar)
        return not jar:match("runner%-jar%-with%-dependencies%.jar$")
          and not jar:match("jacocoagent%.jar$")
      end, test_jars)
      vim.list_extend(bundles, test_jars)
      -- spring-boot.nvim (Spring Boot Language Server <-> jdtls classpath sync).
      -- require() here force-loads the lazy plugin synchronously instead of
      -- relying on FileType-autocmd ordering between lazy.nvim and ftplugin.
      local sb_ok, spring_boot = pcall(require, "spring_boot")
      if sb_ok then
        vim.list_extend(bundles, spring_boot.java_extensions())
      end
      -- Last line of defence over every source above, including
      -- spring_boot.java_extensions(), which this config does not control. One
      -- unreadable entry aborts loadBundles entirely and takes debugging and
      -- test-running down with it, so dropping the bad entry and saying which
      -- one beats losing the list. Nothing above checks readability — the
      -- test-jar filter next to it matches on NAME, to exclude jars that exist
      -- but are not OSGi bundles, which is a different problem.
      return vim.tbl_filter(function(jar)
        if vim.fn.filereadable(jar) == 1 then return true end
        vim.notify("jdtls: skipping unreadable bundle " .. jar, vim.log.levels.WARN)
        return false
      end, bundles)
    end)(),
  },
}

-- Hand jdtls the SAME settings at initialize time, not just afterwards.
--
-- `config.settings` alone only reaches the server via workspace/
-- didChangeConfiguration, which nvim sends *after* initialize has returned — by
-- which point jdtls has already kicked off its first project import. So the
-- initial Gradle/Maven import ran with default preferences and kept failing
-- ("Cannot find a Java installation ... matching {languageVersion=17}") even
-- with the toolchain paths configured above; the later didChangeConfiguration
-- did not retry the import, so the project stayed classpath-less and completion
-- returned nothing. jdtls's BaseInitHandler reads a `settings` key out of
-- initializationOptions, so pointing it at the same table makes the very first
-- import see java.import.gradle.jvmArguments / configuration.runtimes.
config.init_options.settings = config.settings

-- Use workspace_dir so each project gets its own jdtls instance
-- Note: jdtls launcher uses single-dash -data (not --data)
config.cmd[#config.cmd + 1] = "-data"
config.cmd[#config.cmd + 1] = workspace_dir

-- Register _java.reloadBundles.command handler.
-- jdtls server sends this via workspace/executeClientCommand and expects a
-- response — returning the bundle list acknowledges the command without error.
vim.lsp.commands["_java.reloadBundles.command"] = function()
  return config.init_options and config.init_options.bundles or {}
end

-- console = "internalConsole" routes stdout through DAP output events into
-- dapui's console panel (already open), instead of spawning a separate
-- terminal split via run_in_terminal — the latter gets evicted by dapui's
-- own layout reorganization on session start, orphaning a buffer per run.
-- Trade-off: internalConsole doesn't support interactive stdin (Scanner);
-- switch back to "integratedTerminal" here if a program needs to read input.
pcall(jdtls.setup_dap, { hotcodereplace = "auto", config_overrides = { console = "internalConsole" } })
jdtls.start_or_attach(config)

-- Clean workspace and restart jdtls (use when Lombok/deps go stale)
--
-- Buffer-local, like the <leader>jc mapping below. This file is re-sourced per
-- java buffer, and `workspace_dir` is a per-project local — so a GLOBAL command
-- was silently rebound on every java buffer opened, and the one surviving
-- closure belonged to whichever project was sourced LAST. With two projects
-- open, :JdtlsClean from project A deleted project B's workspace and left A's
-- stale one exactly as it was: the command reported success and fixed nothing,
-- while B then had to re-import from scratch.
vim.api.nvim_buf_create_user_command(0, "JdtlsClean", function()
  local function wipe_and_restart()
    vim.fn.delete(workspace_dir, "rf")
    vim.notify("jdtls: workspace cleared — restarting…", vim.log.levels.INFO)
    -- doautocmd FileType, not `edit`. Both re-source this ftplugin (that is the
    -- only thing the reload was ever for — see the on_attach comment above), but
    -- a bare `:edit` aborts with E37 "No write since last change" on a modified
    -- buffer, which is the common case: you reach for :JdtlsClean precisely when
    -- completion has gone dead mid-edit. The workspace was already deleted by
    -- then, so the failure left no server, no workspace and no restart. Verified:
    -- `pcall(vim.cmd, "edit")` on a modified buffer → false, E37; doautocmd
    -- re-sources the ftplugin and leaves the unsaved lines untouched.
    vim.schedule(function() vim.cmd("doautocmd FileType") end)
  end

  -- This project's clients only. Unfiltered get_clients({ name = "jdtls" })
  -- force-stopped every Java project in the session, so cleaning one project
  -- cost a full re-import of all the others — and since only the current buffer
  -- is re-sourced above, those others stayed server-less until you touched them.
  local clients = vim.tbl_filter(function(c)
    return c.config and c.config.root_dir == root_dir
  end, vim.lsp.get_clients({ name = "jdtls" }))
  if #clients == 0 then
    wipe_and_restart()
    return
  end

  vim.notify("jdtls: stopping server…", vim.log.levels.INFO)
  local pending = {}
  for _, c in ipairs(clients) do pending[c.id] = true end

  local group = vim.api.nvim_create_augroup("JdtlsCleanWait", { clear = true })
  local done = false
  local function finish()
    if done then return end
    done = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    wipe_and_restart()
  end

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      pending[args.data.client_id] = nil
      if next(pending) == nil then
        finish()
      end
    end,
  })

  -- Fail-safe in case a detach event is missed
  vim.defer_fn(finish, 8000)

  -- client:stop(true), not vim.lsp.stop_client(clients, true): the latter is
  -- deprecated since 0.11 and removed in 0.13. get_clients already handed us
  -- client objects, so this is the same force-stop one client at a time.
  for _, c in ipairs(clients) do c:stop(true) end
end, { desc = "Clear jdtls workspace and restart" })

vim.keymap.set("n", "<leader>jc", "<cmd>JdtlsClean<CR>", { buffer = true, desc = "Java: Clean & restart jdtls" })
