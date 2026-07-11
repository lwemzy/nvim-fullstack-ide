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
      require("spring_boot").setup({
        autocmd = true,
        server = {
          root_dir = require("jdtls.setup").find_root({
            ".git", "mvnw", "gradlew", "pom.xml", "build.gradle", "build.gradle.kts",
          }),
        },
      })
    end,
  },
}
