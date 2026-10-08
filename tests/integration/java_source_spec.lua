-- lua/config/java_source.lua — the accessors handler nvim-jdtls does not ship.
--
-- Integration tier because the subject is a two-request conversation with a real
-- vim.lsp.Client plus nvim-jdtls's own multi-select prompt, and the bug it exists
-- to fix lives exactly in that seam: with no client-side handler for
-- `java.action.generateAccessorsPrompt`, Neovim forwards the command to the
-- server as workspace/executeCommand, which jdtls does not implement for the
-- *Prompt commands — so <leader>jga silently did nothing at all. A unit test can
-- check the handler is registered; only this tier can check it actually generates
-- anything.
--
-- The server is fake (helpers.fake_lsp) but the client is not: real request
-- dispatch, real offset encoding, real apply_workspace_edit. A real jdtls would
-- mean a Gradle import and tens of seconds per case to assert something about
-- this config's plumbing.

local H = require("helpers")
local fake_lsp = require("helpers.fake_lsp")

local ACCESSORS_COMMAND = "java.action.generateAccessorsPrompt"

--- What jdtls's SourceAssistProcessor puts in the command's argument list: an
--- AccessorCodeActionParams, i.e. CodeActionParams plus the `kind` enum saying
--- which of getters / setters / both the chosen action meant. It is passed
--- through untouched, which is the reason one handler serves all three actions.
local function accessor_params(uri)
  return {
    textDocument = { uri = uri },
    range = {
      start = { line = 2, character = 2 },
      ["end"] = { line = 2, character = 2 },
    },
    context = { diagnostics = {} },
    kind = 3, -- BOTH
  }
end

describe("config.java_source accessors", function()
  local J, dir, path, buf, srv, picked

  --- A class with two private fields and no accessors — the state the generator
  --- is for.
  local function java_file()
    dir = H.tmpdir("accessors")
    path = dir .. "/Order.java"
    H.write(path, {
      "public class Order {",
      "  private String id;",
      "  private int quantity;",
      "}",
    })
    return H.edit(path)
  end

  --- The two fields jdtls would answer java/resolveUnimplementedAccessors with.
  local FIELDS = {
    { fieldName = "id", isStatic = false, typeName = "String", generateGetter = true, generateSetter = true },
    { fieldName = "quantity", isStatic = false, typeName = "int", generateGetter = true, generateSetter = false },
  }

  --- Start a fake jdtls on `buf` whose generateAccessors reply inserts one line
  --- per selected field. The *content* is arbitrary; what matters is that an
  --- edit computed from the selection reaches the buffer.
  local function serve(responses)
    srv = fake_lsp.start({
      name = "jdtls",
      bufnr = buf,
      root_dir = dir,
      capabilities = { codeActionProvider = { codeActionKinds = { "source.generate" } } },
      responses = responses,
    })
    H.track_client(srv.id)
    return srv
  end

  local function generate_accessors_reply(params)
    local names = {}
    for _, field in ipairs(params.accessors or {}) do
      table.insert(names, "  // accessors for " .. field.fieldName)
    end
    return {
      changes = {
        [vim.uri_from_fname(path)] = {
          {
            range = {
              start = { line = 3, character = 0 },
              ["end"] = { line = 3, character = 0 },
            },
            newText = table.concat(names, "\n") .. "\n",
          },
        },
      },
    }
  end

  --- Fire the command the way Neovim does when a code action resolves to it.
  local function run_command(command)
    vim.lsp.commands[ACCESSORS_COMMAND](
      command or { command = ACCESSORS_COMMAND, arguments = { accessor_params(vim.uri_from_fname(path)) } },
      { bufnr = buf, client_id = srv.id }
    )
  end

  before_each(function()
    H.load_plugin("nvim-jdtls")
    H.disable_autosave()

    package.loaded["config.java_source"] = nil
    J = require("config.java_source")
    -- The entry may already be there from a previous case or from the real
    -- ftplugin having run: rawset because core's __newindex rejects nil.
    rawset(vim.lsp.commands, ACCESSORS_COMMAND, nil)
    assert.is_true(J.setup())

    buf = java_file()
    picked = nil
  end)

  after_each(function()
    if srv then srv.stop() end
    srv = nil
    rawset(vim.lsp.commands, ACCESSORS_COMMAND, nil)
    package.loaded["config.java_source"] = nil
    H.cleanup()
  end)

  it("resolves the fields, prompts, and applies the edit the server computes", function()
    serve({
      ["java/resolveUnimplementedAccessors"] = FIELDS,
      ["java/generateAccessors"] = generate_accessors_reply,
    })
    -- nvim-jdtls's prompt is a blocking vim.fn.inputlist; stubbing it is what
    -- makes the selection deterministic. It is also the only thing stubbed on
    -- this side of the conversation.
    H.stub(require("jdtls.ui"), "pick_many", function(items)
      picked = items
      return { items[1] }
    end)

    run_command()
    assert.is_true(vim.wait(2000, function()
      return vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1] ~= "}"
    end, 10), "the edit never reached the buffer")

    -- Both requests went out, in order, to the right methods.
    local resolved = srv.requests_for("java/resolveUnimplementedAccessors")
    local generated = srv.requests_for("java/generateAccessors")
    assert.equals(1, #resolved)
    assert.equals(1, #generated)
    -- The command's own argument is handed straight back, `kind` included: that
    -- is what distinguishes "generate getters" from "generate getters and
    -- setters", and it cannot be reconstructed from the action's title.
    assert.equals(3, resolved[1].params.kind)
    assert.equals(3, generated[1].params.context.kind)
    assert.same({ FIELDS[1] }, generated[1].params.accessors)
    -- Only the selected field, so deselecting in the prompt means something.
    assert.equals("  // accessors for id", vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1])
  end)

  it("offers every field the server returned, labelled with what it would add", function()
    serve({
      ["java/resolveUnimplementedAccessors"] = FIELDS,
      ["java/generateAccessors"] = generate_accessors_reply,
    })
    local labels
    H.stub(require("jdtls.ui"), "pick_many", function(items, _, label)
      labels = vim.tbl_map(label, items)
      return items
    end)

    run_command()
    assert.is_true(vim.wait(2000, function() return labels ~= nil end, 10), "the prompt never opened")

    assert.equals(2, #labels)
    assert.is_true(labels[1]:find("id", 1, true) ~= nil, labels[1])
    assert.is_true(labels[1]:find("String", 1, true) ~= nil, labels[1])
    -- generateGetter and generateSetter are separate booleans on one field, so
    -- "get/set" and "get" are different offers and the label is the only place
    -- the difference is visible.
    assert.is_true(labels[1]:find("get/set", 1, true) ~= nil, labels[1])
    assert.is_true(labels[2]:find("get)", 1, true) ~= nil, labels[2])
  end)

  it("says so, and asks for nothing, when every field already has accessors", function()
    -- The answer Lombok's @Data produces, and an ordinary one rather than an
    -- error.
    serve({ ["java/resolveUnimplementedAccessors"] = {} })
    local prompted = false
    H.stub(require("jdtls.ui"), "pick_many", function() prompted = true end)

    local notes = H.capture_notifications(function() run_command() end, { settle_ms = 500 })

    assert.is_false(prompted)
    assert.equals(0, #srv.requests_for("java/generateAccessors"))
    assert.equals(1, #notes)
    assert.equals(vim.log.levels.INFO, notes[1].level)
  end)

  it("generates nothing when the prompt is dismissed", function()
    serve({
      ["java/resolveUnimplementedAccessors"] = FIELDS,
      ["java/generateAccessors"] = generate_accessors_reply,
    })
    H.stub(require("jdtls.ui"), "pick_many", function() return nil end)

    run_command()
    vim.wait(300, function() return false end)

    assert.equals(1, #srv.requests_for("java/resolveUnimplementedAccessors"))
    assert.equals(0, #srv.requests_for("java/generateAccessors"))
    assert.same({ "}" }, vim.api.nvim_buf_get_lines(buf, 3, 4, false))
  end)

  it("reports a server error instead of leaving the key looking broken", function()
    serve({
      ["java/resolveUnimplementedAccessors"] = function()
        return nil, { code = -32603, message = "Unable to resolve accessors" }
      end,
    })
    H.stub(require("jdtls.ui"), "pick_many", function() error("should not be reached") end)

    local notes = H.capture_notifications(function() run_command() end, { settle_ms = 500 })

    assert.equals(1, #notes)
    assert.equals(vim.log.levels.ERROR, notes[1].level)
    assert.is_true(notes[1].msg:find("Unable to resolve accessors", 1, true) ~= nil, notes[1].msg)
  end)

  describe("generate", function()
    it("asks the attached jdtls for one kind of source action", function()
      serve({ ["textDocument/codeAction"] = {} })

      J.generate(J.KINDS.accessors)()
      assert.is_true(vim.wait(2000, function()
        return #srv.requests_for("textDocument/codeAction") > 0
      end, 10), "no code action request was sent")

      local params = srv.requests_for("textDocument/codeAction")[1].params
      assert.same({ "source.generate.accessors" }, params.context.only)
      assert.same({}, params.context.diagnostics)
    end)
  end)
end)
