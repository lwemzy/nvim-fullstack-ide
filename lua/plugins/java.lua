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
      require("spring_boot").setup({
        autocmd = true,
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
    end,
  },
}
