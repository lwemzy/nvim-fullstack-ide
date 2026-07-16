local ok, jdtls = pcall(require, "jdtls")
if not ok then return end

local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
if vim.fn.executable(mason_bin) == 0 then
  vim.notify("jdtls not installed — run :MasonInstall jdtls", vim.log.levels.WARN)
  return
end

-- Per-project workspace to avoid cross-project class collisions
local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":p:h:t")
local workspace_dir = vim.fn.stdpath("data") .. "/jdtls-workspaces/" .. project_name

local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
local capabilities = cmp_ok
  and cmp_lsp.default_capabilities()
  or vim.lsp.protocol.make_client_capabilities()

local lombok_jar = vim.fn.stdpath("data") .. "/lombok.jar"
local lombok_arg = vim.fn.filereadable(lombok_jar) == 1
  and "--jvm-arg=-javaagent:" .. lombok_jar
  or nil

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
    if lombok_arg then c[#c + 1] = lombok_arg end
    return c
  end)(),

  root_dir = require("jdtls.setup").find_root({
    ".git", "mvnw", "gradlew", "pom.xml", "build.gradle", "build.gradle.kts",
  }) or vim.fn.getcwd(),

  capabilities = capabilities,

  settings = {
    java = {
      configuration = {
        runtimes = {
          {
            name = "JavaSE-21",
            path = vim.fn.expand("~/.sdkman/candidates/java/current"),
            default = true,
          },
        },
        -- "automatic" silently reimports the Gradle/Maven project model on
        -- every build-file-adjacent change — real, recurring CPU cost for
        -- something that rarely needs to happen. "interactive" prompts
        -- instead of doing it silently in the background.
        updateBuildConfiguration = "interactive",
      },
      eclipse = { downloadSources = true },
      maven = { downloadSources = true },
      implementationsCodeLens = { enabled = true },
      referencesCodeLens = { enabled = true },
      references = { includeDecompiledSources = true },
      inlayHints = { parameterNames = { enabled = "all" } },
      -- Enable annotation processing so MapStruct/Lombok processors run in jdtls's JDT compiler
      autobuild = { enabled = true },
      format = {
        enabled = true,
        settings = {
          -- Uses Google Java Style by default; point to a custom XML if needed
          -- url = vim.fn.expand("~/.config/nvim/java-style.xml"),
        },
      },
      signatureHelp = { enabled = true },
      contentProvider = { preferred = "fernflower" },
      completion = {
        favoriteStaticMembers = {
          "org.junit.Assert.*",
          "org.junit.Assume.*",
          "org.junit.jupiter.api.Assertions.*",
          "org.mockito.Mockito.*",
          "org.hamcrest.Matchers.*",
        },
        importOrder = {
          "java", "javax", "jakarta",
          "org.springframework", "com", "org", "net", "",
        },
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
    jdtls.setup.add_commands()

    local map = function(keys, func, desc)
      vim.keymap.set("n", keys, func, { buffer = bufnr, desc = desc })
    end

    -- Standard LSP
    map("gd", "<cmd>Telescope lsp_definitions<CR>", "Go to definition")
    map("gD", vim.lsp.buf.declaration, "Go to declaration")
    map("gr", "<cmd>Telescope lsp_references<CR>", "Find references")
    map("gi", "<cmd>Telescope lsp_implementations<CR>", "Find implementations")
    map("<leader>ds", "<cmd>Telescope lsp_document_symbols<CR>", "Document symbols")
    map("<leader>ws", "<cmd>Telescope lsp_dynamic_workspace_symbols<CR>", "Workspace symbols")
    map("K", vim.lsp.buf.hover, "Hover docs")
    map("<C-k>", vim.lsp.buf.signature_help, "Signature help")
    map("<leader>rn", vim.lsp.buf.rename, "Rename symbol")
    map("<leader>ca", vim.lsp.buf.code_action, "Code action")
    map("[d", vim.diagnostic.goto_prev, "Prev diagnostic")
    map("]d", vim.diagnostic.goto_next, "Next diagnostic")

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
        buffer = bufnr,
        callback = fetch_codelens,
      })
      vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
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

    -- Inlay hints (parameter names) can get noisy in heavily-chained code
    map("<leader>uh", function()
      vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }), { bufnr = bufnr })
    end, "Toggle inlay hints")

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
