-- mcp/nvim_context_server.py — the MCP server that tells Claude which file
-- Neovim has in focus.
--
-- This half of the integration had no test of any kind. It is a protocol
-- implementation talking to a client nobody in this repo controls, which is the
-- worst possible thing to leave unpinned: a malformed reply does not crash
-- anything, it just makes `claude` quietly decide the server is broken and stop
-- calling the tool — and the visible symptom is "Claude does not know what file
-- I am in", which looks identical to the registration being missing, to the
-- context file not being written, and to the model simply not bothering. Three
-- of those four causes have already happened here.
--
-- The server is driven as a real subprocess over stdio rather than by importing
-- and calling handle(): the framing (newline-delimited JSON on stdout, nothing
-- else on stdout) is part of the contract and is exactly what a unit test that
-- called the function directly would not check.

local H = require("helpers")

local PYTHON = vim.fn.exepath("python3")
local SERVER = vim.fn.stdpath("config") .. "/mcp/nvim_context_server.py"

--- Protocol version this repo was written against. The server echoes whatever
--- the client asks for, so this is only the fallback's expected value.
local FALLBACK_VERSION = "2024-11-05"
local TOOL = "get_current_file"
local NO_CONTEXT = "No Neovim file context available yet."

describe("mcp/nvim_context_server.py", function()
  local ctx_file

  before_each(function()
    ctx_file = H.tmpdir("mcp") .. "/nvim-claude-ctx"
  end)

  --- Feed `messages` to a fresh server on stdin and return its parsed replies.
  ---
  --- Batched and the pipe closed, one process per call: the server answers in the
  --- order it reads, so nothing is lost by not interleaving, and every case stays
  --- a single spawn. A string element is sent verbatim, which is how the
  --- malformed-input cases get to send something that is not JSON at all.
  --- Anything stdout produced that is not parseable comes back as
  --- { unparsed = ... } rather than being dropped, because "printed something
  --- that is not a JSON-RPC message on stdout" is itself a protocol violation:
  --- it desynchronises the client's framing.
  local function rpc(messages)
    local stdin = {}
    for _, m in ipairs(messages) do
      table.insert(stdin, type(m) == "string" and m or vim.json.encode(m))
    end
    local res = vim.system({ PYTHON, SERVER }, {
      stdin = table.concat(stdin, "\n") .. "\n",
      env = { NVIM_CLAUDE_CTX = ctx_file },
      text = true,
    }):wait(10000)

    local replies = {}
    for _, line in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
      local ok, msg = pcall(vim.json.decode, line)
      table.insert(replies, ok and msg or { unparsed = line })
    end
    return replies, res
  end

  local function call_tool(name, id)
    return { jsonrpc = "2.0", id = id or 1, method = "tools/call",
             params = { name = name or TOOL, arguments = vim.empty_dict() } }
  end

  --- The text of a tools/call result, or nil if the reply is not shaped like one.
  local function tool_text(reply)
    local content = reply and reply.result and reply.result.content
    return content and content[1] and content[1].text
  end

  local function missing_python()
    if PYTHON == "" then
      return H.skip("python3 not installed: cannot exercise the MCP server")
    end
    return false
  end

  it("is present and syntactically valid", function()
    -- The Lua side registers this path with `claude`; a typo there or a moved
    -- file is a silently dead integration, which is the state it was found in.
    assert.equals(1, vim.fn.filereadable(SERVER), "no server script at " .. SERVER)
    if missing_python() then return end
    local res = vim.system({ PYTHON, "-m", "py_compile", SERVER }, { text = true }):wait(10000)
    assert.equals(0, res.code, "py_compile failed: " .. tostring(res.stderr))
  end)

  it("echoes the client's protocol version on initialize", function()
    if missing_python() then return end
    -- The spec asks the server to agree with the client's version or propose its
    -- own. Answering a fixed old version when the client asked for a newer one is
    -- how a working server starts looking obsolete to a client that has moved on.
    local replies = rpc({
      { jsonrpc = "2.0", id = 1, method = "initialize",
        params = { protocolVersion = "2025-06-18", capabilities = vim.empty_dict() } },
    })
    assert.equals(1, #replies)
    assert.equals("2.0", replies[1].jsonrpc)
    assert.equals(1, replies[1].id)
    assert.equals("2025-06-18", replies[1].result.protocolVersion)
    -- Claiming a tools capability is what makes the client ask for tools/list at
    -- all; without it the tool is never discovered no matter what tools/list says.
    assert.is_not_nil(replies[1].result.capabilities.tools)
    assert.equals("nvim-context", replies[1].result.serverInfo.name)
  end)

  it("falls back to a known version when the client names none", function()
    if missing_python() then return end
    local replies = rpc({ { jsonrpc = "2.0", id = 1, method = "initialize" } })
    assert.equals(FALLBACK_VERSION, replies[1].result.protocolVersion)
  end)

  it("advertises exactly one tool, with an object input schema", function()
    if missing_python() then return end
    local replies = rpc({ { jsonrpc = "2.0", id = 7, method = "tools/list" } })
    assert.equals(1, #replies)
    assert.equals(7, replies[1].id)
    local tools = replies[1].result.tools
    assert.equals(1, #tools)
    assert.equals(TOOL, tools[1].name)
    -- A tool with no inputSchema, or one that is not an object, is rejected by the
    -- client rather than being treated as taking no arguments.
    assert.equals("object", tools[1].inputSchema.type)
    -- The description is the only thing telling the model *when* to call this;
    -- the integration is meant to be invisible, so it has to self-trigger on
    -- "this file" rather than waiting to be asked.
    assert.is_true(tools[1].description:find("this file", 1, true) ~= nil)
  end)

  it("returns the context file's contents for the advertised tool", function()
    if missing_python() then return end
    H.write(ctx_file, { "File: src/Main.java", "Language: java", "Line: 12" })
    local replies = rpc({ call_tool() })
    assert.equals(1, #replies)
    assert.is_false(replies[1].result.isError)
    assert.equals("File: src/Main.java\nLanguage: java\nLine: 12", tool_text(replies[1]))
  end)

  it("reads the path from NVIM_CLAUDE_CTX rather than a fixed location", function()
    if missing_python() then return end
    -- The Lua side passes this so there is one definition of where the file
    -- lives. A hardcoded copy on the Python side is how the two halves drift
    -- apart without either of them looking wrong — and the path they used to
    -- share was /tmp/nvim-claude-ctx, a fixed name in a world-writable directory.
    H.write(ctx_file, { "File: only-findable-via-env.txt" })
    assert.is_false(vim.startswith(ctx_file, "/tmp/nvim-claude-ctx"))
    assert.equals("File: only-findable-via-env.txt", tool_text(rpc({ call_tool() })[1]))
  end)

  it("says so plainly when there is no context yet", function()
    if missing_python() then return end
    -- nvim writes nothing until the chat panel has been opened, so this is the
    -- state of a brand-new session, not an error. Reporting a tool failure here
    -- would make Claude announce that something is broken; this way it just asks
    -- which file you mean.
    assert.equals(0, vim.fn.filereadable(ctx_file))
    local replies = rpc({ call_tool() })
    assert.equals(NO_CONTEXT, tool_text(replies[1]))
    assert.is_false(replies[1].result.isError)
  end)

  it("treats an empty context file the same as a missing one", function()
    if missing_python() then return end
    -- This used to come back as an empty text block with isError false: a
    -- successful answer that said nothing, which the model has no way to read.
    -- nvim now renames the record into place so a torn read cannot produce it,
    -- but a zero-length file from an interrupted write or an older version still
    -- can.
    H.write(ctx_file, { "" })
    assert.equals(1, vim.fn.filereadable(ctx_file))
    assert.equals(NO_CONTEXT, tool_text(rpc({ call_tool() })[1]))
  end)

  it("refuses a tool name it never advertised", function()
    if missing_python() then return end
    H.write(ctx_file, { "File: real.txt" })
    local replies = rpc({ call_tool("get_current_buffer", 3) })
    assert.equals(1, #replies)
    assert.equals(3, replies[1].id)
    -- It used to answer any name at all with the context, so a client's typo or a
    -- stale tool list looked like a working call. -32602 is "invalid params".
    assert.is_nil(replies[1].result)
    assert.equals(-32602, replies[1].error.code)
    assert.is_true(replies[1].error.message:find("get_current_buffer", 1, true) ~= nil)
  end)

  it("answers an unknown method with method-not-found, not an empty success", function()
    if missing_python() then return end
    -- The previous version replied {} to everything it did not recognise. That is
    -- a schema violation for any method whose result has required fields —
    -- resources/list needs a `resources` array — so a client probing for
    -- resources got a malformed reply instead of an honest "no such method", and
    -- had to decide for itself whether the server was broken.
    local replies = rpc({
      { jsonrpc = "2.0", id = 4, method = "resources/list" },
      { jsonrpc = "2.0", id = 5, method = "prompts/list" },
    })
    assert.equals(2, #replies)
    for _, reply in ipairs(replies) do
      assert.is_nil(reply.result)
      assert.equals(-32601, reply.error.code)
    end
    assert.equals(4, replies[1].id)
    assert.equals(5, replies[2].id)
  end)

  it("answers ping", function()
    if missing_python() then return end
    -- Some clients use this as a liveness check and drop the server if it does
    -- not come back.
    local replies = rpc({ { jsonrpc = "2.0", id = 9, method = "ping" } })
    assert.equals(9, replies[1].id)
    assert.same(vim.empty_dict(), replies[1].result)
  end)

  it("stays silent for a notification", function()
    if missing_python() then return end
    -- A message with no id must get no reply at all. Answering one desynchronises
    -- the client, which is matching replies to ids it is still waiting on.
    local replies = rpc({
      { jsonrpc = "2.0", method = "notifications/initialized" },
      { jsonrpc = "2.0", method = "notifications/cancelled", params = { requestId = 1 } },
      { jsonrpc = "2.0", id = 1, method = "ping" },
    })
    assert.equals(1, #replies)
    assert.equals(1, replies[1].id)
  end)

  it("survives a malformed line and answers the next request", function()
    if missing_python() then return end
    -- One bad line must not end the session: the server is long-lived and a
    -- crash here takes the tool away for the rest of the conversation, with the
    -- symptom appearing several turns later.
    H.write(ctx_file, { "File: after-garbage.txt" })
    local replies, res = rpc({
      "this is not json at all",
      '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"',  -- truncated
      "",
      call_tool(TOOL, 2),
    })
    -- No reply for either bad line — there is no id to answer with — and nothing
    -- but JSON-RPC on stdout.
    assert.equals(1, #replies)
    assert.is_nil(replies[1].unparsed)
    assert.equals(2, replies[1].id)
    assert.equals("File: after-garbage.txt", tool_text(replies[1]))
    -- Diagnostics go to stderr, where the client logs them, instead of corrupting
    -- the stdout framing.
    assert.is_true((res.stderr or ""):find("could not parse", 1, true) ~= nil)
    assert.equals(0, res.code)
  end)

  it("puts nothing but JSON-RPC on stdout across a full session", function()
    if missing_python() then return end
    -- A stray print() anywhere in this file breaks the client's framing, and the
    -- failure looks like the server being unresponsive rather than noisy.
    H.write(ctx_file, { "File: session.txt", "Language: text", "Line: 1" })
    local replies = rpc({
      { jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18" } },
      { jsonrpc = "2.0", method = "notifications/initialized" },
      { jsonrpc = "2.0", id = 2, method = "tools/list" },
      call_tool(TOOL, 3),
      { jsonrpc = "2.0", id = 4, method = "ping" },
    })
    assert.equals(4, #replies)
    for i, reply in ipairs(replies) do
      assert.is_nil(reply.unparsed, "non-JSON on stdout: " .. tostring(reply.unparsed))
      assert.equals("2.0", reply.jsonrpc)
      assert.equals(i, reply.id)
    end
  end)
end)
