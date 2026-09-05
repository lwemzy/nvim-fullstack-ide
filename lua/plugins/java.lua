return {
  -- nvim-jdtls is loaded on-demand via ftplugin/java.lua
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
  },

  -- Spring Boot Language Server (STS4) <-> jdtls bridge
  {
    "JavaHello/spring-boot.nvim",
    ft = { "java", "yaml", "jproperties" },
    dependencies = { "mfussenegger/nvim-jdtls" },
    config = function()
      -- root_dir is intentionally NOT set here: spring_boot.launch's own
      -- fallback computes it fresh per-call via vim.fs.root(0, {...}),
      -- which needs real per-buffer context. A static string computed once
      -- at config-time (find_root() with no buffer, run whenever this
      -- plugin first lazy-loads — possibly from a .yaml/.properties buffer
      -- before any .java file is open) can resolve to an empty string,
      -- which gets baked in permanently and produces a malformed "file://"
      -- URI (crashing the server on every document event) for the rest of
      -- the session.
      -- Without this, the Spring Boot Language Server never starts at all.
      -- spring_boot.launch builds its command as
      --   { config.java_cmd or util.java_bin(), ..., "-XX:+UseZGC", ... }
      -- (launch.lua:32-35) and util.java_bin() returns the bare string "java"
      -- (util.lua:27) whenever $JAVA_HOME is unset — i.e. whatever `java` PATH
      -- happens to resolve to. On this machine that is a Java 8 JRE, and ZGC
      -- does not exist before 11, so the JVM aborts immediately:
      --   Unrecognized VM option 'UseZGC'
      --   Error: Could not create the Java Virtual Machine.
      -- vim.lsp.start then has nothing to talk to. The failure is invisible
      -- unless you read ~/.local/state/nvim/lsp.log, and the symptom is simply
      -- that NOTHING attaches to application.properties and Spring property /
      -- YAML key completion never appears. Pin a JDK we actually verified.
      -- boot-ls needs 17+; ask for the newest such JDK.
      local java_cmd = require("config.jdk").java_bin(17)
      if not java_cmd then
        vim.notify(
          "spring-boot: no JDK 17+ found — Spring property completion disabled.\n"
            .. "Install one (e.g. `brew install openjdk@21`) or set $JAVA_HOME.",
          vim.log.levels.WARN
        )
        return
      end

      local resolved_opts = require("spring_boot").setup({
        java_cmd = java_cmd,
        -- autocmd=false: the plugin's own FileType autocmd starts boot-ls on
        -- *every* .java file unconditionally (it only filename-gates .yaml/
        -- .jproperties, checking they're actually application.yml/
        -- application.properties — nothing gates .java on whether the
        -- project even has Spring Boot as a dependency). Register our own
        -- below instead, adding that check specifically for .java.
        autocmd = false,
        server = {
          -- barbecue.nvim (winbar breadcrumbs) auto-attaches nvim-navic to
          -- any client advertising documentSymbolProvider, with no way to
          -- exclude a client by name. jdtls already claims that capability
          -- for Java buffers, so boot-ls attaching it too makes navic log
          -- "Failed to attach to spring-boot ... Already attached to jdtls"
          -- on every Java file. jdtls already covers breadcrumbs fully, so
          -- just wrap on_init (preserving the plugin's own init logic) and
          -- strip the capability before any LspAttach handler sees it.
          on_init = function(client, ctx)
            require("spring_boot.util").boot_ls_init(client, ctx)
            client.server_capabilities.documentSymbolProvider = false
          end,
        },
      })
      if not resolved_opts then return end -- boot-ls jar not installed; setup() already warned

      -- Heuristic: does any build file from this buffer's directory up to
      -- the project root actually declare Spring Boot? Checks build.gradle/
      -- build.gradle.kts/pom.xml content for the org.springframework.boot
      -- group id — present as either a Gradle plugin id or a Maven/Gradle
      -- dependency coordinate in essentially every real Spring Boot project.
      -- The bound matters: the previous `stop` was nil whenever vim.fs.root found
      -- no marker — i.e. exactly the loose-file case it was meant to protect — so
      -- the search ran to / and a stray pom.xml above the file (in $HOME, say)
      -- made every .java buffer look like a Spring Boot project and started
      -- boot-ls for it. config.project.ceiling is never nil-bounded.
      --
      -- It also bounds at the VCS root rather than the nearest build file, which
      -- fixes multi-module projects: the old bound stopped at the module, so a
      -- parent pom.xml declaring spring-boot (with the module inheriting it) was
      -- never read and boot-ls never started.
      local project = require("config.project")
      local function is_spring_boot_project(bufnr)
        local build_files = project.find_upward(
          bufnr,
          { "pom.xml", "build.gradle", "build.gradle.kts" },
          { limit = math.huge }
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
        if vim.bo[bufnr].filetype == "java" and not is_spring_boot_project(bufnr) then
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

      -- Handle every *future* java/yaml/jproperties buffer...
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("spring_boot_ls_gated", { clear = true }),
        pattern = { "java", "yaml", "jproperties" },
        callback = function(ev) maybe_start(ev.buf) end,
      })
      -- ...and the current one too: lazy.nvim loads this plugin (running
      -- this whole config function) *in response to* FileType already
      -- firing for the buffer that triggered it — that event doesn't get
      -- replayed for an autocmd only just registered above, so without
      -- this the very file you opened to trigger the ft=java/yaml load
      -- would silently never get boot-ls started (confirmed: the autocmd
      -- above never fires for the triggering buffer, only later ones).
      maybe_start(vim.api.nvim_get_current_buf())
    end,
  },
}
