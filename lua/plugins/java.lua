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

      local resolved_opts = require("spring_boot").setup({
        java_cmd = java_cmd,
        -- autocmd=false: the plugin's own FileType autocmd starts boot-ls on
        -- *every* .java file unconditionally (it only filename-gates .yaml/
        -- .jproperties, checking they are actually application.yml/
        -- application.properties — nothing gates .java on whether the project
        -- even has Spring Boot as a dependency). Register our own below
        -- instead, adding that check specifically for .java.
        --
        -- This is NOT a `server.root_dir` wrapper, which is the obvious-looking
        -- alternative and is broken against this plugin. spring_boot.launch
        -- still exposes the pre-native-LSP API (update_ls_config/start/
        -- ls_autocmd) as of 98c6ff1, upstream main's tip, and
        -- update_ls_config only substitutes its own root when root_dir is
        -- falsy — so a function survives into
        --   client_config.init_options.workspaceFolders = client_config.root_dir
        -- (launch.lua:78) and the initialize request dies in the JSON encoder:
        --   vim/lsp/rpc.lua:269: Cannot serialise function: type not supported
        -- Verified: every .java and application.properties file in a Spring
        -- project threw that on BufReadPost, boot-ls never attached, and each
        -- session leaked one orphaned JVM (the process spawns before
        -- initialize fails, so nvim never tracks it and never stops it).
        -- Its M.root_dir also takes no arguments and *returns* the root
        -- instead of calling on_dir, so it cannot serve as a vim.lsp.config
        -- root_dir callback either.
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

      local function maybe_start(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if vim.bo[bufnr].filetype == "java" and not project.declares_spring_boot(bufnr) then
          return
        end
        local launch = require("spring_boot.launch")
        -- nvim_buf_call, because neither function reads the buffer it is about:
        -- launch.update_ls_config derives root_dir from vim.fs.root(0, ...) and
        -- launch.start calls nvim_get_current_buf()/vim.uri_from_bufnr itself
        -- (launch.lua:9 and :102-103). Passing bufnr around is not enough — it
        -- has to actually BE the current buffer while they run, or a Spring file
        -- that gets a FileType while not focused (session restore, :bufdo,
        -- quickfix population, the bufload in config.file_ops) starts boot-ls
        -- with another buffer's root and another buffer's file URI.
        --
        -- update_ls_config per call rather than once: setup()'s return value has
        -- no cmd/root_dir, and root_dir must be recomputed per buffer anyway.
        -- Skipping it passes cmd=nil to vim.lsp.start, which just no-ops.
        vim.api.nvim_buf_call(bufnr, function()
          launch.start(launch.update_ls_config(resolved_opts))
        end)
      end

      -- Handle every *future* java/yaml/jproperties buffer...
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("spring_boot_ls_gated", { clear = true }),
        pattern = { "java", "yaml", "jproperties" },
        callback = function(ev) maybe_start(ev.buf) end,
      })
      -- ...and the current one too: lazy.nvim loads this plugin (running this
      -- whole config function) *in response to* FileType already firing for the
      -- buffer that triggered it. That event is not replayed for an autocmd only
      -- just registered above, so without this the very file you opened to
      -- trigger the ft=java/yaml load never gets boot-ls started.
      maybe_start(vim.api.nvim_get_current_buf())
    end,
  },
}
