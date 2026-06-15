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
      "--jvm-arg=-Xmx2G",
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
        updateBuildConfiguration = "automatic",
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

  on_attach = function(_, bufnr)
    jdtls.setup.add_commands()

    local map = function(keys, func, desc)
      vim.keymap.set("n", keys, func, { buffer = bufnr, desc = desc })
    end

    -- Standard LSP
    map("gd", "<cmd>Telescope lsp_definitions<CR>", "Go to definition")
    map("gD", vim.lsp.buf.declaration, "Go to declaration")
    map("gr", "<cmd>Telescope lsp_references<CR>", "Find references")
    map("gi", "<cmd>Telescope lsp_implementations<CR>", "Find implementations")
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

    vim.keymap.set("v", "<leader>jv", function()
      jdtls.extract_variable(true)
    end, { buffer = bufnr, desc = "Extract variable (visual)" })
    vim.keymap.set("v", "<leader>jm", function()
      jdtls.extract_method(true)
    end, { buffer = bufnr, desc = "Extract method (visual)" })
  end,

  init_options = {
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
      local test_jars = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/java-test/extension/server/*.jar",
        true, true
      )
      vim.list_extend(bundles, test_jars)
      return bundles
    end)(),
  },
}

-- Use workspace_dir so each project gets its own jdtls instance
-- Note: jdtls launcher uses single-dash -data (not --data)
config.cmd[#config.cmd + 1] = "-data"
config.cmd[#config.cmd + 1] = workspace_dir

-- Configure nvim-dap's Java adapter BEFORE start_or_attach so the
-- _java.reloadBundles.command handler is registered before jdtls initialises.
pcall(jdtls.setup_dap, { hotcodereplace = "auto" })

jdtls.start_or_attach(config)

-- Clean workspace and restart jdtls (use when Lombok/deps go stale)
vim.api.nvim_create_user_command("JdtlsClean", function()
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients > 0 then
    vim.notify("jdtls: stopping server…", vim.log.levels.INFO)
    vim.lsp.stop_client(clients, true)  -- true = force
  end
  -- Wait for jdtls to fully exit before wiping the workspace
  vim.defer_fn(function()
    vim.fn.delete(workspace_dir, "rf")
    vim.notify("jdtls: workspace cleared — restarting…", vim.log.levels.INFO)
    vim.defer_fn(function()
      vim.cmd("edit")
    end, 500)
  end, 3000)  -- 3s gives jdtls time to flush and exit cleanly
end, { desc = "Clear jdtls workspace and restart" })

vim.keymap.set("n", "<leader>jc", "<cmd>JdtlsClean<CR>", { buffer = true, desc = "Java: Clean & restart jdtls" })
