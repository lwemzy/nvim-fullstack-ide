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
      -- boot-ls needs 17+; ask for the newest such JDK. spring_boot.launch
      -- builds its command as { config.java_cmd or util.java_bin(), ...,
      -- "-XX:+UseZGC", ... } and util.java_bin() returns the bare string
      -- "java" whenever $JAVA_HOME is unset — whatever `java` on PATH
      -- happens to resolve to. On a machine where that's an old JRE, ZGC
      -- doesn't exist and the JVM aborts immediately; the only visible
      -- symptom is that nothing ever attaches to application.properties.
      -- Pin a JDK we actually verified instead.
      local java_cmd = require("config.jdk").java_bin(17)
      if not java_cmd then
        vim.notify(
          "spring-boot: no JDK 17+ found — Spring property completion disabled.\n"
            .. "Install one (e.g. `brew install openjdk@21`) or set $JAVA_HOME.",
          vim.log.levels.WARN
        )
        return
      end

      -- Heuristic: does any build file from this buffer's directory up to the
      -- project root actually declare Spring Boot? config.project.declares_spring_boot
      -- (which is also what the Run/Debug toolbar in config.runner asks, so the
      -- two cannot disagree about what a Spring project is).
      --
      -- The bound matters: an unbounded search upward would make a stray
      -- pom.xml above the project (in $HOME, say) turn every .java buffer on
      -- the machine into a false "Spring Boot project" — config.project's
      -- search stops at the VCS root rather than running to /, and stops
      -- there rather than at the nearest build file, so a parent POM in a
      -- multi-module Maven build (whose module inherits spring-boot without
      -- saying so itself) is still read correctly.
      local project = require("config.project")

      require("spring_boot").setup({
        java_cmd = java_cmd,
        server = {
          -- The plugin's own root_dir (spring_boot.launch.root_dir) already
          -- filename-gates .yaml/.jproperties (only application.yml /
          -- application.properties) but starts boot-ls for *every* .java
          -- file unconditionally. Wrap it to add the Spring Boot check
          -- specifically for .java — deliberately NOT applied to yaml/
          -- jproperties, which still deserve completion even outside a
          -- confirmed Spring Boot project.
          root_dir = function(bufnr, on_dir)
            if vim.bo[bufnr].filetype == "java" and not project.declares_spring_boot(bufnr) then
              return
            end
            require("spring_boot.launch").root_dir(bufnr, on_dir)
          end,
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
      -- No manual "start for the current buffer" call needed: setup() calls
      -- vim.lsp.enable("spring-boot") (auto_enable defaults true), and
      -- vim.lsp.enable() itself re-triggers FileType for already-open
      -- buffers when did_filetype() is true — exactly the buffer that
      -- lazy-loaded this plugin in the first place.
    end,
  },
}
