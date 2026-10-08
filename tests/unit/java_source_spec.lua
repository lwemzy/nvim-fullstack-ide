-- lua/config/java_source.lua — jdtls's source-action generators on keys.
--
-- The kind strings are the subject of half this file, and they are tested as
-- literals on purpose. They are not names this config invented: they were read
-- out of the installed org.eclipse.jdt.ls.core jar (SourceAssistProcessor), and a
-- typo in one of them produces a key that asks the server for a kind it has never
-- heard of — which returns an empty action list, i.e. a key that does nothing and
-- reports nothing. Pinning them here makes that failure a test failure instead.
--
-- The other half is M.setup's two promises: that calling it twice is harmless
-- (ftplugin/java.lua runs on every .java buffer), and that it never takes over a
-- command someone else has already registered — because the one it registers is a
-- stand-in for nvim-jdtls not having one, and a future version that ships its own
-- should win.
--
-- The accessors round-trip itself needs a real client and nvim-jdtls's prompt, so
-- it lives in tests/integration/java_source_spec.lua.

local H = require("helpers")

local ACCESSORS_COMMAND = "java.action.generateAccessorsPrompt"

local function java_source()
  package.loaded["config.java_source"] = nil
  return require("config.java_source")
end

describe("config.java_source", function()
  local J, registered_before

  before_each(function()
    J = java_source()
    -- vim.lsp.commands is global and shared with every plugin in the session, so
    -- each case starts from "nobody has registered this" and the entry is put
    -- back afterwards.
    --
    -- rawset, not H.stub: core guards the table with a `__newindex` that rejects
    -- any value which is not a function, and __newindex fires for an absent key
    -- — so clearing the entry through a plain assignment raises.
    registered_before = vim.lsp.commands[ACCESSORS_COMMAND]
    rawset(vim.lsp.commands, ACCESSORS_COMMAND, nil)
  end)

  after_each(function()
    rawset(vim.lsp.commands, ACCESSORS_COMMAND, registered_before)
    package.loaded["config.java_source"] = nil
    H.cleanup()
  end)

  describe("KINDS", function()
    it("spells each generator the way jdtls does", function()
      assert.same({
        all = "source.generate",
        accessors = "source.generate.accessors",
        constructors = "source.generate.constructors",
        delegates = "source.generate.delegateMethods",
        hash_code_equals = "source.generate.hashCodeEquals",
        to_string = "source.generate.toString",
        final_modifiers = "source.generate.finalModifiers",
        override = "source.overrideMethods",
        sort_members = "source.sortMembers",
      }, J.KINDS)
    end)

    it("keeps overrideMethods and sortMembers outside the generate hierarchy", function()
      -- jdtls's own naming, not a typo: these two are siblings of
      -- source.generate, not children of it, and nesting them would filter to a
      -- kind the server never returns.
      assert.is_nil(J.KINDS.override:match("^source%.generate%."))
      assert.is_nil(J.KINDS.sort_members:match("^source%.generate%."))
    end)

    it("makes every kind a prefix-match under a valueSet Neovim already sends", function()
      -- jdtls gates custom kinds on ClientPreferences.isSupportedCodeActionKind,
      -- which is a startsWith against the client's codeActionKind valueSet. That
      -- set contains "source", so nothing here needs a capability change — but
      -- only while every kind stays under it.
      local valueSet = vim.lsp.protocol.make_client_capabilities()
        .textDocument.codeAction.codeActionLiteralSupport.codeActionKind.valueSet
      for name, kind in pairs(J.KINDS) do
        local supported = false
        for _, entry in ipairs(valueSet) do
          if entry ~= "" and vim.startswith(kind, entry) then supported = true end
        end
        assert.is_true(supported, name .. " = " .. kind .. " is under no advertised kind")
      end
    end)
  end)

  describe("generate", function()
    it("returns a function, so a keymap can hold it without asking anything yet", function()
      assert.equals("function", type(J.generate(J.KINDS.to_string)))
    end)

    it("asks for exactly one kind, and does not pay for quick-fix computation", function()
      local buf = H.quiet_buffer(H.tmpdir("gen") .. "/App.java", "java")
      -- A client has to appear attached, or the guard below short-circuits first.
      H.stub(vim.lsp, "get_clients", function() return { { name = "jdtls", id = 1 } } end)
      local calls = H.spy(vim.lsp.buf, "code_action")

      J.generate(J.KINDS.to_string)()

      assert.equals(1, calls.count)
      local opts = calls[1][1]
      assert.same({ "source.generate.toString" }, opts.context.only)
      assert.is_true(opts.apply)
      -- diagnostics = {} is not laziness: jdtls runs its quick-fix processors
      -- over whatever the context carries, and all of that work is then filtered
      -- away by `only`.
      assert.same({}, opts.context.diagnostics)
      assert.equals(buf, vim.api.nvim_get_current_buf())
    end)

    it("says jdtls is not attached rather than asking the wrong server", function()
      H.quiet_buffer(H.tmpdir("gen-none") .. "/App.java", "java")
      -- The Spring Boot language server also attaches to .java buffers and
      -- answers codeAction with its own, unrelated actions — which is why the
      -- lookup is by name.
      H.stub(vim.lsp, "get_clients", function() return {} end)
      local calls = H.spy(vim.lsp.buf, "code_action")

      local notes = H.capture_notifications(function() J.generate(J.KINDS.accessors)() end)

      assert.equals(0, calls.count)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("jdtls", 1, true) ~= nil, notes[1].msg)
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)
  end)

  describe("setup", function()
    it("registers the handler nvim-jdtls does not have", function()
      assert.is_nil(vim.lsp.commands[ACCESSORS_COMMAND])
      assert.is_true(J.setup())
      assert.equals("function", type(vim.lsp.commands[ACCESSORS_COMMAND]))
    end)

    it("is safe to call on every .java buffer, which is what ftplugin does", function()
      J.setup()
      local registered = vim.lsp.commands[ACCESSORS_COMMAND]
      assert.is_false(J.setup())
      assert.equals(registered, vim.lsp.commands[ACCESSORS_COMMAND])
    end)

    it("leaves an existing handler alone, so a future nvim-jdtls wins", function()
      local theirs = function() end
      vim.lsp.commands[ACCESSORS_COMMAND] = theirs
      assert.is_false(J.setup())
      assert.equals(theirs, vim.lsp.commands[ACCESSORS_COMMAND])
    end)
  end)

  describe("the registered handler", function()
    it("reports a command with no arguments instead of failing silently", function()
      J.setup()
      -- A client has to be found first, or the earlier guard answers instead and
      -- this case would pass on the wrong notification.
      H.stub(vim.lsp, "get_client_by_id", function()
        return { name = "jdtls", id = 1, request = function() error("should not be reached") end }
      end)
      local notes = H.capture_notifications(function()
        vim.lsp.commands[ACCESSORS_COMMAND]({ command = ACCESSORS_COMMAND }, { bufnr = 0, client_id = 1 })
      end)
      assert.equals(1, #notes)
      assert.equals(vim.log.levels.ERROR, notes[1].level)
    end)

    it("warns about a missing client rather than throwing out of the handler", function()
      J.setup()
      H.stub(vim.lsp, "get_client_by_id", function() return nil end)
      H.stub(vim.lsp, "get_clients", function() return {} end)
      local notes = H.capture_notifications(function()
        vim.lsp.commands[ACCESSORS_COMMAND](
          { command = ACCESSORS_COMMAND, arguments = { { kind = 3 } } },
          { bufnr = 0, client_id = 99 }
        )
      end)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("jdtls", 1, true) ~= nil, notes[1].msg)
    end)
  end)
end)
