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
      require("spring_boot").setup({ autocmd = true })
    end,
  },
}
