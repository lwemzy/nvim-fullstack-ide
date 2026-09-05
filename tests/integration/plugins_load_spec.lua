-- The real, fully-booted config: does lazy.nvim end up with the plugin set
-- lua/plugins/ declares, and does loading it actually work?
--
-- The static counterpart (tests/unit/plugin_specs_spec.lua) can only see what is
-- written down. This file is the other half: it compares the declaration against
-- lazy's resolved state, runs each plugin's `config` for real, and checks the
-- user commands the config's own keymaps type at those plugins.
--
-- lazy does NOT let a config error propagate — Util.try (lazy/core/util.lua)
-- xpcalls every `config`/`init`/dependency load and reports the failure through
-- vim.notify instead. So a pcall around the loader would report success for a
-- plugin whose setup blew up; the load checks below watch the reported error
-- rather than a raised one.

local H = require("helpers")
local S = require("helpers.specs")

-- Snapshotted at file-load time, which is immediately after startup and before
-- any test has loaded a plugin or printed anything — otherwise the tests
-- themselves would be part of what "startup produced no errors" is measuring.
local STARTUP = {
  errmsg = vim.v.errmsg,
  messages = vim.fn.execute("messages"),
}

--- Plugins that must not be force-loaded here, with the reason each one is out.
--- Every entry either spawns a process or reaches the network, which would make
--- this spec slow, machine-dependent, or capable of hanging the whole run.
local SKIP_LOAD = {
  ["spring-boot.nvim"] = "its config calls launch.start() for the current buffer, starting the Spring Boot language server",
  ["nvim-dap"] = "its config runs mason-nvim-dap setup with automatic_installation, which downloads debug adapters",
}

--- Commands a plugin registers, and the plugin that must be loaded first.
--- Chosen from the ones this config actually depends on: lua/config/keymaps.lua
--- types NvimTreeToggle/Telescope/Gitsigns/Trouble, the `keys` entries in
--- lua/plugins/ type TodoTelescope/DiffviewOpen/RenderMarkdown, and
--- nvim-treesitter's own spec declares `build = ":TSUpdate"`, so a missing
--- TSUpdate breaks installing the plugin rather than merely using it.
local PLUGIN_COMMANDS = {
  { cmd = "Lazy", plugin = "lazy.nvim" },
  { cmd = "Mason", plugin = "mason.nvim" },
  { cmd = "MasonInstall", plugin = "mason.nvim" },
  { cmd = "MasonLog", plugin = "mason.nvim" },
  { cmd = "MasonToolsInstall", plugin = "mason-tool-installer.nvim" },
  { cmd = "MasonToolsUpdate", plugin = "mason-tool-installer.nvim" },
  { cmd = "ConformInfo", plugin = "conform.nvim" },
  { cmd = "Telescope", plugin = "telescope.nvim" },
  { cmd = "NvimTreeToggle", plugin = "nvim-tree.lua" },
  { cmd = "NvimTreeFindFile", plugin = "nvim-tree.lua" },
  { cmd = "Gitsigns", plugin = "gitsigns.nvim" },
  { cmd = "Trouble", plugin = "trouble.nvim" },
  { cmd = "TodoTelescope", plugin = "todo-comments.nvim" },
  { cmd = "DiffviewOpen", plugin = "diffview.nvim" },
  { cmd = "DiffviewFileHistory", plugin = "diffview.nvim" },
  { cmd = "RenderMarkdown", plugin = "render-markdown.nvim" },
  { cmd = "GrugFar", plugin = "grug-far.nvim" },
  { cmd = "Neotest", plugin = "neotest" },
  { cmd = "TSUpdate", plugin = "nvim-treesitter" },
  { cmd = "TSInstall", plugin = "nvim-treesitter" },
}

--- Commands lua/config/keymaps.lua invokes that genuinely do not exist on this
--- Neovim, with the reason. `check` re-verifies the reason still holds, so this
--- allowlist cannot quietly outlive the situation that justified it.
local KNOWN_MISSING_COMMANDS = {
  LspLog = {
    reason = "nvim-lspconfig's plugin/lspconfig.lua returns early when `:lsp` exists "
      .. "(Neovim 0.12 ships it), so it registers no Lsp* commands at all — "
      .. "keymaps.lua's <F1> mapping needs `:lsp log` or `:checkhealth vim.lsp`",
    check = function() return vim.fn.exists(":lsp") == 2 end,
  },
}

local lazy_config = require("lazy.core.config")
local lazy_plugin = require("lazy.core.plugin")

--- lazy's name for a spec: the `name` override, else the repo's last segment.
local function lazy_name(p)
  if type(p.spec) == "table" and type(p.spec.name) == "string" then return p.spec.name end
  return p.repo:match("([^/]+)$")
end

local function plugin_names()
  local names = vim.tbl_keys(lazy_config.plugins)
  table.sort(names)
  return names
end

--- Load `name` and return the error lazy reported, or nil.
---
--- The vim.wait is required, not defensive: Util.try's handler defers to
--- vim.schedule, so the notification lands on the next loop tick — without it
--- every load would look clean.
local function load_error(name)
  local reported
  local seen = H.capture_notifications(function()
    local ok, err = pcall(H.load_plugin, name)
    if not ok then reported = tostring(err) end
    vim.wait(50, function() return false end)
  end)
  for _, n in ipairs(seen) do
    local msg = type(n.msg) == "table" and table.concat(n.msg, "\n") or tostring(n.msg)
    -- Only lazy's own wrapper messages ("Failed to run `config` for **x**",
    -- "Failed to load deps for x"). Other ERROR notifications during the wait
    -- window can come from unrelated background work (a mason download), and
    -- failing on those would make this spec depend on network weather.
    if n.level == vim.log.levels.ERROR and msg:find("Failed to", 1, true) then
      reported = (reported and (reported .. "\n") or "") .. msg
    end
  end
  return reported
end

describe("booted config", function()
  describe("startup", function()
    it("left no Lua error in the message history", function()
      -- A `config` function that throws does not stop startup: lazy catches it
      -- and the session comes up with that one plugin unconfigured. The stack
      -- trace in :messages is the only trace left, which is exactly why it is
      -- worth asserting on.
      for _, pattern in ipairs({ "E5108", "Error executing", "stack traceback" }) do
        assert.is_nil(STARTUP.messages:find(pattern, 1, true),
          ("startup messages contain %q:\n%s"):format(pattern, STARTUP.messages))
      end
    end)

    it("left no unexpected error in v:errmsg", function()
      -- nvim-tree runs `silent! autocmd! FileExplorer *` to disable netrw
      -- (nvim-tree/config.lua). Neovim 0.12 no longer ships netrw, so the group
      -- does not exist and `silent!` suppresses the message while still setting
      -- v:errmsg. It is cosmetic and comes from a plugin, not this config, so it
      -- is allowed by exact text rather than swallowing every E-code.
      local benign = "^E216: No such group or event"
      if vim.v.errmsg ~= "" and STARTUP.errmsg:find(benign) then
        H.skip(("ignoring known nvim-tree/netrw startup v:errmsg: %q"):format(STARTUP.errmsg))
        return
      end
      assert.equals("", STARTUP.errmsg)
    end)
  end)

  describe("lazy's resolved plugin set", function()
    it("knows every top-level spec declared in lua/plugins", function()
      -- The failure this catches: a spec file that lazy never reads (wrong
      -- directory, a stray `return` above the table, a file that errors while
      -- being sourced). lazy reports nothing — the plugins simply are not there.
      local missing = {}
      for _, p in ipairs(S.toplevel()) do
        local name = lazy_name(p)
        if not lazy_config.plugins[name] then
          table.insert(missing, ("%s (%s in %s)"):format(name, p.repo, vim.fn.fnamemodify(p.file, ":t")))
        end
      end
      assert.same({}, missing)
    end)

    it("records no error against any plugin", function()
      -- lazy keeps per-plugin task errors (clone/checkout/build failures) and
      -- refuses to load a plugin that has them, so this is the difference
      -- between "declared" and "usable".
      for _, name in ipairs(plugin_names()) do
        assert.is_false(lazy_plugin.has_errors(lazy_config.plugins[name]),
          name .. " has a recorded lazy task error — see :Lazy")
      end
    end)

    it("resolves every installed plugin to a real directory", function()
      -- A plugin lazy believes is installed but whose dir is gone loads
      -- "successfully" and contributes nothing: the rtp entry is a dead path.
      -- A plugin that was never downloaded is an environment problem (no
      -- :Lazy sync on this machine), so it is reported and skipped instead.
      local not_installed = {}
      for _, name in ipairs(plugin_names()) do
        local p = lazy_config.plugins[name]
        if p._.installed then
          assert.equals(1, vim.fn.isdirectory(p.dir),
            ("%s is marked installed but %s is not a directory"):format(name, p.dir))
        else
          table.insert(not_installed, name)
        end
      end
      if #not_installed > 0 then
        H.skip("not installed on this machine (run :Lazy sync): " .. table.concat(not_installed, ", "))
      end
    end)

    it("loaded every non-lazy plugin during startup", function()
      -- `lazy = false` (explicit or by default, for a spec with no
      -- event/ft/cmd/keys trigger) is a promise that the plugin is active in a
      -- fresh session. Nothing re-checks that promise at runtime: the plugin
      -- just never loads and its keymaps/commands never exist.
      for _, name in ipairs(plugin_names()) do
        local p = lazy_config.plugins[name]
        if p.lazy == false and p._.installed then
          assert.is_not_nil(p._.loaded, name .. " is a start plugin but was not loaded at startup")
        end
      end
    end)
  end)

  describe("force-loading", function()
    it("skips the plugins that would spawn a server or a download", function()
      -- Printed rather than silent: the skip list is part of this spec's
      -- coverage story, and a plugin quietly sitting on it forever is the
      -- failure mode of an exclusion list.
      for name, reason in pairs(SKIP_LOAD) do
        assert.is_not_nil(lazy_config.plugins[name], "SKIP_LOAD names an unknown plugin: " .. name)
        H.skip(("not force-loading %s — %s"):format(name, reason))
      end
    end)

    it("loads every other plugin without lazy reporting a failure", function()
      -- One at a time, so the assertion message names the plugin whose config
      -- broke rather than saying that something, somewhere, did.
      for _, name in ipairs(plugin_names()) do
        local p = lazy_config.plugins[name]
        if not SKIP_LOAD[name] and p._.installed then
          local err = load_error(name)
          assert.is_nil(err, ("loading %s failed: %s"):format(name, tostring(err)))
        end
      end
    end)
  end)

  describe("user commands", function()
    it("registers each plugin's commands once that plugin is loaded", function()
      for _, entry in ipairs(PLUGIN_COMMANDS) do
        local p = lazy_config.plugins[entry.plugin]
        assert.is_not_nil(p, "no such plugin: " .. entry.plugin)
        if SKIP_LOAD[entry.plugin] then
          H.skip(("cannot check :%s — %s"):format(entry.cmd, SKIP_LOAD[entry.plugin]))
        elseif not p._.installed then
          H.skip(("cannot check :%s — %s is not installed"):format(entry.cmd, entry.plugin))
        else
          H.load_plugin(entry.plugin)
          assert.is_true(vim.fn.exists(":" .. entry.cmd) >= 1,
            (":%s does not exist even though %s is loaded"):format(entry.cmd, entry.plugin))
        end
      end
    end)

    it("resolves every capitalised command lua/config/keymaps.lua types", function()
      -- These are the ones a keypress runs verbatim. A mapping to a command
      -- that no longer exists is invisible until it is pressed, and then it is
      -- just "E492: Not an editor command".
      local text = H.read_text(S.plugins_dir:gsub("/plugins$", "/config/keymaps.lua"))
      local wanted = {}
      -- Both spellings used in that file: "<cmd>Name<CR>" and ":Name<CR>".
      -- Lowercase names are builtins (:w, :bnext, :nohlsearch) and are not
      -- interesting here; plugin commands are capitalised by convention.
      for cmd in text:gmatch("<cmd>(%u[%w_]*)") do wanted[cmd] = true end
      for cmd in text:gmatch(":(%u[%w_]*)<CR>") do wanted[cmd] = true end
      assert.is_true(vim.tbl_count(wanted) > 0, "no commands found in keymaps.lua — has the syntax changed?")

      local names = vim.tbl_keys(wanted)
      table.sort(names)
      for _, cmd in ipairs(names) do
        local known = KNOWN_MISSING_COMMANDS[cmd]
        if known and vim.fn.exists(":" .. cmd) == 0 then
          assert.is_true(known.check(),
            (":%s is missing but the recorded reason no longer applies: %s"):format(cmd, known.reason))
          H.skip((":%s is mapped in keymaps.lua but does not exist — %s"):format(cmd, known.reason))
        else
          assert.is_true(vim.fn.exists(":" .. cmd) >= 1,
            (":%s is mapped in lua/config/keymaps.lua but no plugin registers it"):format(cmd))
        end
      end
    end)

    it("registers JdtlsClean from ftplugin/java.lua", function()
      -- Defined at the bottom of ftplugin/java.lua, i.e. only after jdtls has
      -- been started for a real Java buffer — which is why it is behind
      -- NVIM_IDE_TEST_SLOW (see tests/run.sh) like the other jdtls specs.
      -- The static half of the check runs either way, so a rename of the
      -- command cannot hide behind the skip.
      local ftplugin = vim.fn.fnamemodify(S.plugins_dir, ":h:h") .. "/ftplugin/java.lua"
      local text = H.read_text(ftplugin)
      assert.is_not_nil(text:find('nvim_create_user_command("JdtlsClean"', 1, true),
        "ftplugin/java.lua no longer defines JdtlsClean")

      local jdtls_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
      if not vim.env.NVIM_IDE_TEST_SLOW then
        return H.skip("JdtlsClean needs a Java buffer, which starts jdtls — set NVIM_IDE_TEST_SLOW=1 to check it")
      end
      if vim.fn.executable(jdtls_bin) == 0 then
        return H.skip("jdtls is not installed by mason, so ftplugin/java.lua returns before defining JdtlsClean")
      end

      local project = H.fixture("java-plain")
      H.disable_autosave()
      H.edit(project .. "/src/main/java/com/example/App.java")
      assert.is_true(vim.fn.exists(":JdtlsClean") >= 1,
        ":JdtlsClean was not defined after opening a Java buffer")
    end)

    after_each(function()
      H.cleanup()
    end)
  end)

  describe("lazy.setup options from init.lua", function()
    -- The only assertions that prove init.lua's own setup call took effect: the
    -- options are lazy's defaults-plus-overrides, so a table passed to the wrong
    -- argument (or a setup call that never ran) shows up here and nowhere else.
    it("silences change-detection notifications", function()
      -- Without this, editing any file under ~/.config/nvim pops a
      -- "Config Change Detected" notification over whatever you are doing.
      assert.is_false(lazy_config.options.change_detection.notify)
    end)

    it("uses a rounded border for lazy's own windows", function()
      -- Matches every other float in this config (mason's ui.border, cmp's
      -- windows, vim.o.winborder in lua/config/options.lua).
      assert.equals("rounded", lazy_config.options.ui.border)
    end)
  end)
end)
