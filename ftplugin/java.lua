local ok, jdtls = pcall(require, "jdtls")
if not ok then return end

local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
if vim.fn.executable(mason_bin) == 0 then
  vim.notify("jdtls not installed — run :MasonInstall jdtls", vim.log.levels.WARN)
  return
end

-- Resolve the project root ONCE and derive everything from it.
local root_dir = require("jdtls.setup").find_root({
  ".git", "mvnw", "gradlew", "pom.xml", "build.gradle", "build.gradle.kts",
}) or vim.fn.getcwd()

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

local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
local capabilities = vim.tbl_deep_extend(
  "force",
  vim.lsp.protocol.make_client_capabilities(),
  cmp_ok and cmp_lsp.default_capabilities() or {}
)

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
local jdk = require("config.jdk")
local launcher_jdk = jdk.newest(21)

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

-- Workspace dir must exist before jdtls starts; otherwise LaunchingPlugin can't save install info
vim.fn.mkdir(workspace_dir, "p")

local config = {
  cmd = (function()
    local c = {
      mason_bin,
      "--jvm-arg=-Xmx4G",
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
    -- One augroup per buffer, so re-firing FileType java (:e, :e!, :JdtRestart,
    -- and JdtlsClean's own `vim.cmd("edit")`) REPLACES these autocmds instead of
    -- stacking another copy. Previously each reload added another blocking
    -- format-on-save round trip, another full codeLens+resolve sweep per
    -- BufEnter/InsertLeave/save, and another clear-namespace + extmark pass on
    -- every keystroke via CursorMovedI — i.e. visible typing lag that got worse
    -- the longer the session ran.
    local group = vim.api.nvim_create_augroup("java_ftplugin_" .. bufnr, { clear = true })

    local map = function(keys, func, desc)
      vim.keymap.set("n", keys, func, { buffer = bufnr, desc = desc })
    end

    -- The standard LSP keymaps (gd/gD/gr/gi/K/<C-k>/<leader>rn/<leader>ca/
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
    map("<C-S-o>", jdtls.organize_imports,      "Organize imports")
    map("<C-S-v>", jdtls.extract_variable,      "Extract variable")
    map("<C-S-c>", jdtls.extract_constant,      "Extract constant")

    -- Debug keymaps (F9/F10/F11 are taken by Java tools above)
    map("<leader>db", function() require("dap").toggle_breakpoint() end, "Debug: Toggle breakpoint")
    map("<leader>dB", function()
      require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: "))
    end, "Debug: Conditional breakpoint")
    map("<leader>dt", function() require("dap").terminate() end,         "Debug: Terminate")
    map("<leader>du", function() require("dapui").toggle() end,          "Debug: Toggle UI")
    map("<leader>dr", function() require("dap").repl.toggle() end,       "Debug: Toggle REPL")

    -- Run without attaching the debugger (plain `java -cp ...` launch via jdtls)
    -- Opens dapui explicitly rather than relying on the global
    -- event_initialized listener: noDebug launches don't reliably fire that
    -- event the same way a real debug session does, so the panel showing
    -- internalConsole output could otherwise never appear even though the
    -- program genuinely ran (confirmed via jdtls logs: LaunchWithoutDebuggingDelegate
    -- fires fine, nothing was actually broken except visibility).
    map("<leader>dR", function()
      require("jdtls.dap").fetch_main_configs({
        config_overrides = { noDebug = true, console = "internalConsole" },
      }, function(configs)
        vim.schedule(function()
          if #configs == 0 then
            vim.notify("No runnable main classes found", vim.log.levels.WARN)
          elseif #configs == 1 then
            require("dap").run(configs[1])
            require("dapui").open()
          else
            vim.ui.select(configs, {
              prompt = "Run (no debug):",
              format_item = function(c) return c.name end,
            }, function(choice)
              if choice then
                require("dap").run(choice)
                require("dapui").open()
              end
            end)
          end
        end)
      end)
    end, "Run without debugging")

    -- Format on save
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      buffer = bufnr,
      callback = function()
        vim.lsp.buf.format({ async = false, id = client.id })
      end,
    })

    -- Code lenses (implementations/references counts, java-test's Run/Debug Test
    -- lenses). Bypasses vim.lsp.codelens's built-in renderer, which draws every
    -- lens on its own virt_line above the code — instead: render only the
    -- lens(es) for the line the cursor is currently on, inline at end-of-line.
    if client.server_capabilities.codeLensProvider then
      local codelens_ns = vim.api.nvim_create_namespace("java_codelens_" .. bufnr)
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
      local debug_jar = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar",
        true
      )
      if debug_jar ~= "" then
        vim.list_extend(bundles, { debug_jar })
      end
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
      return bundles
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
vim.api.nvim_create_user_command("JdtlsClean", function()
  local function wipe_and_restart()
    vim.fn.delete(workspace_dir, "rf")
    vim.notify("jdtls: workspace cleared — restarting…", vim.log.levels.INFO)
    vim.schedule(function() vim.cmd("edit") end)
  end

  local clients = vim.lsp.get_clients({ name = "jdtls" })
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

  vim.lsp.stop_client(clients, true)  -- true = force
end, { desc = "Clear jdtls workspace and restart" })

vim.keymap.set("n", "<leader>jc", "<cmd>JdtlsClean<CR>", { buffer = true, desc = "Java: Clean & restart jdtls" })
