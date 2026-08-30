return {
  -- nvim-jdtls is loaded on-demand via ftplugin/java.lua
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
  },

  -- Spring Boot Language Server (STS4) — application.yml/application.properties only.
  --
  -- Deliberately NOT attached to .java buffers: boot-ls is a single LSP
  -- client shared across every filetype it serves, and completionProvider is
  -- a client-wide capability with no per-filetype scoping in the LSP
  -- protocol. Previously, with .java included, boot-ls's completion requests
  -- hung indefinitely for ordinary (non-Spring) Java identifiers — since
  -- nvim-cmp waits on every attached source before rendering, that silently
  -- broke autocomplete across the board. jdtls already covers .java
  -- completion comprehensively (see plugins/lsp.lua's cmp.setup.filetype
  -- override for "java", which excludes even buffer-word fallback on that
  -- basis) and has zero awareness of YAML/properties files — so the one
  -- genuinely non-redundant thing boot-ls provides is live application.yml/
  -- application.properties property-key completion, hover, and validation,
  -- none of which requires its client to ever attach to a .java buffer.
  -- Scoping it this way avoids the hang at its root instead of working
  -- around it. jdtls itself still gets separate Spring-aware extras (bean/
  -- request-mapping code lenses, etc.) via spring_boot.java_extensions()'s
  -- bundle jars, loaded directly into jdtls's own bundle list in
  -- ftplugin/java.lua — an independent mechanism that doesn't need boot-ls's
  -- client attached to .java at all.
  {
    "JavaHello/spring-boot.nvim",
    ft = { "yaml", "jproperties" },
    dependencies = { "mfussenegger/nvim-jdtls" },
    config = function()
      -- root_dir is intentionally NOT set here: spring_boot.launch's own
      -- fallback computes it fresh per-call via vim.fs.root(0, {...}),
      -- which needs real per-buffer context. A static string computed once
      -- at config-time (find_root() with no buffer, run whenever this
      -- plugin first lazy-loads) can resolve to an empty string, which gets
      -- baked in permanently and produces a malformed "file://" URI
      -- (crashing the server on every document event) for the rest of the
      -- session.
      local resolved_opts = require("spring_boot").setup({
        -- autocmd=false: the plugin's own FileType autocmd starts boot-ls on
        -- every buffer of a configured filetype unconditionally (it only
        -- filename-gates .yaml/.jproperties, checking they're actually
        -- application.yml/application.properties — nothing checks the
        -- project itself is Spring Boot). Register our own below instead,
        -- adding that project-level check.
        autocmd = false,
        server = {
          -- Overrides ls_config.lua's own default filetypes = { "java",
          -- "yaml", "jproperties" } (merge is tbl_deep_extend("keep",
          -- opts.server, ls_config), so this wins). vim.lsp.start() itself
          -- no-ops for a buffer whose filetype isn't in this list, so this
          -- is a hard guarantee against ever attaching to .java — not just
          -- an untriggered autocmd.
          filetypes = { "yaml", "jproperties" },
          on_init = function(client, ctx)
            require("spring_boot.util").boot_ls_init(client, ctx)
          end,
          -- Confirmed live (lsp.log): even scoped away from .java buffers
          -- above, boot-ls still background-reconciles the whole project's
          -- .java files via a separate classpath/java-data service it
          -- registers unconditionally (launch.lua's update_ls_config calls
          -- classpath.register_classpath_service/java_data.register_java_
          -- data_service regardless of filetypes). Its Spring Security
          -- lambda-DSL reconciler throws a real NullPointerException
          -- ("AbstractSecurityLambdaDslReconciler", MethodInvocation with a
          -- null getExpression()) repeatedly while walking real project
          -- code. Key/values read directly from the language server's own
          -- VSCode extension package.json (mason/packages/vscode-spring-
          -- boot-tools/extension/package.json) — settings are LSP
          -- workspace/configuration, resolved by Neovim's default handler
          -- via nested-table lookup matching each dot-separated segment, so
          -- the VSCode dotted key becomes this nested shape.
          settings = {
            ["spring-boot"] = {
              ls = {
                problem = {
                  boot2 = {
                    HTTP_SECURITY_AUTHORIZE_HTTP_REQUESTS = "IGNORE",
                  },
                },
              },
            },
          },
        },
      })
      if not resolved_opts then return end -- boot-ls jar not installed; setup() already warned

      -- Heuristic: does any build file from this buffer's directory up to
      -- the project root actually declare Spring Boot? Checks build.gradle/
      -- build.gradle.kts/pom.xml content for the org.springframework.boot
      -- group id — present as either a Gradle plugin id or a Maven/Gradle
      -- dependency coordinate in essentially every real Spring Boot project.
      -- Applied uniformly to every filetype boot-ls now serves (previously
      -- only gated .java, trusting the application.yml/.properties filename
      -- check alone for yaml/properties) — that convention isn't
      -- Spring-exclusive (Quarkus and Micronaut use it too), so without this
      -- check opening either file in a non-Spring JVM project would still
      -- launch boot-ls's JVM process for nothing.
      local function is_spring_boot_project(bufnr)
        local dirname = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
        local root = vim.fs.root(bufnr, { ".git", "mvnw", "gradlew", "pom.xml", "build.gradle", "build.gradle.kts" })
        local build_files = vim.fs.find(
          { "pom.xml", "build.gradle", "build.gradle.kts" },
          { path = dirname, upward = true, stop = root and vim.fs.dirname(root) or nil, limit = math.huge }
        )
        for _, f in ipairs(build_files) do
          local ok, lines = pcall(vim.fn.readfile, f)
          if ok and table.concat(lines, "\n"):find("org%.springframework%.boot") then
            return true
          end
        end
        return false
      end

      local function maybe_start(bufnr)
        if not is_spring_boot_project(bufnr) then
          return
        end
        -- setup()'s return value has no cmd/root_dir — those are only
        -- computed by update_ls_config (root_dir via vim.fs.root(0, ...),
        -- so it must run per-buffer, not once). The plugin's own ls_autocmd
        -- always did this before calling start(); skipping it silently
        -- passes cmd=nil to vim.lsp.start(), which just no-ops.
        local launch = require("spring_boot.launch")
        launch.start(launch.update_ls_config(resolved_opts))
      end

      -- Handle every *future* yaml/jproperties buffer...
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("spring_boot_ls_gated", { clear = true }),
        pattern = { "yaml", "jproperties" },
        callback = function(ev) maybe_start(ev.buf) end,
      })
      -- ...and the current one too: lazy.nvim loads this plugin (running
      -- this whole config function) *in response to* FileType already
      -- firing for the buffer that triggered it — that event doesn't get
      -- replayed for an autocmd only just registered above, so without
      -- this the very file you opened to trigger the ft=yaml/jproperties
      -- load would silently never get boot-ls started (confirmed: the
      -- autocmd above never fires for the triggering buffer, only later
      -- ones).
      maybe_start(vim.api.nvim_get_current_buf())
    end,
  },
}
