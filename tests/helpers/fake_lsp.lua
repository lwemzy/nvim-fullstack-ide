-- An in-process fake language server.
--
-- vim.lsp.start accepts a *function* as `cmd`, in which case it is used as the
-- RPC transport directly instead of spawning a process. That gives a real
-- vim.lsp.Client — real capability resolution, real LspAttach, real handler
-- dispatch, real dynamic registration — with no server binary, no filesystem
-- project, and no waiting. It is the only practical way to test capability-
-- dependent behaviour (which keymaps get set, which client is allowed to supply
-- inlay hints) deterministically: the real servers decide those things for
-- themselves and take tens of seconds to start.
--
--   local srv = fake_lsp.start({ capabilities = { hoverProvider = true } })
--   srv.register({ { id = "1", method = "textDocument/inlayHint" } })  -- like jdtls
--   srv.requests_for("textDocument/inlayHint")                         -- what was asked
--
local F = {}

--- Start a fake server and attach it to a buffer.
---
--- opts:
---   name             client name (default "fake_ls")
---   capabilities     server_capabilities advertised at initialize
---   responses        map method -> value or function(params, srv) -> result[, err]
---   bufnr            buffer to attach to (default current)
---   root_dir         default cwd
---   offset_encoding  default "utf-16"
function F.start(opts)
  opts = opts or {}
  local srv = {
    name = opts.name or "fake_ls",
    requests = {},      -- { {method, params}, ... } in arrival order
    notifications = {},
    responses = vim.deepcopy(opts.responses or {}),
    capabilities = vim.deepcopy(opts.capabilities or {}),
  }

  --- Every request the server received for `method`.
  function srv.requests_for(method)
    return vim.tbl_filter(function(r) return r.method == method end, srv.requests)
  end

  function srv.notifications_for(method)
    return vim.tbl_filter(function(r) return r.method == method end, srv.notifications)
  end

  --- Change (or add) a canned response mid-spec.
  function srv.respond(method, value)
    srv.responses[method] = value
  end

  local dispatchers
  local closing = false

  local id = vim.lsp.start({
    name = srv.name,
    cmd = function(d)
      dispatchers = d
      return {
        request = function(method, params, callback)
          table.insert(srv.requests, { method = method, params = params })
          if method == "initialize" then
            callback(nil, {
              capabilities = srv.capabilities,
              serverInfo = { name = srv.name, version = "0.0.0-test" },
            })
          elseif method == "shutdown" then
            callback(nil, nil)
          else
            local canned = srv.responses[method]
            if type(canned) == "function" then
              local result, err = canned(params, srv)
              callback(err, result)
            else
              -- nil is a legitimate LSP result (and, for inlay hints, the one
              -- that clears them), so an absent entry answers nil rather than
              -- erroring — a server that does not implement a method would
              -- never have advertised it in the first place.
              callback(nil, canned)
            end
          end
          return true, #srv.requests
        end,
        notify = function(method, params)
          table.insert(srv.notifications, { method = method, params = params })
          return true
        end,
        is_closing = function() return closing end,
        -- A real transport reports the process exit back through on_exit, and
        -- that callback is what makes the client actually go away (LspDetach,
        -- removal from get_clients). Without it client:stop() leaves a client
        -- that is shutting down forever.
        terminate = function()
          if closing then return end
          closing = true
          vim.schedule(function() d.on_exit(0, 0) end)
        end,
      }
    end,
    root_dir = opts.root_dir or vim.uv.cwd(),
    offset_encoding = opts.offset_encoding,
  }, { bufnr = opts.bufnr or vim.api.nvim_get_current_buf() })

  assert(id, "fake server failed to start")
  srv.id = id
  srv.client = assert(vim.lsp.get_client_by_id(id))

  --- Send client/registerCapability from the server, the way jdtls registers
  --- textDocument/inlayHint *after* initialize. This is a genuinely different
  --- code path from advertising the capability up front: server_capabilities
  --- stays false while supports_method() starts returning true.
  function srv.register(registrations)
    assert(dispatchers, "server not connected")
    return dispatchers.server_request("client/registerCapability", {
      registrations = registrations,
    })
  end

  function srv.unregister(unregisterations)
    assert(dispatchers, "server not connected")
    return dispatchers.server_request("client/unregisterCapability", {
      unregisterations = unregisterations,
    })
  end

  --- Push a server->client notification (e.g. workspace/inlayHint/refresh).
  function srv.notify_client(method, params)
    assert(dispatchers, "server not connected")
    return dispatchers.notification(method, params)
  end

  function srv.stop()
    if vim.lsp.get_client_by_id(id) then
      srv.client:stop(true)
      vim.wait(500, function() return vim.lsp.get_client_by_id(id) == nil end, 10)
    end
  end

  return srv
end

--- Capability sets mirroring what the real servers advertise, so a spec can say
--- "behave like ts_ls" without hand-assembling a capability table each time.
--- Trimmed to the capabilities this config's on_attach actually branches on.
F.caps = {
  full = {
    hoverProvider = true,
    declarationProvider = true,
    referencesProvider = true,
    implementationProvider = true,
    typeDefinitionProvider = true,
    signatureHelpProvider = { triggerCharacters = { "(" } },
    renameProvider = true,
    codeActionProvider = true,
    documentSymbolProvider = true,
    workspaceSymbolProvider = true,
    inlayHintProvider = true,
    callHierarchyProvider = true,
    completionProvider = { triggerCharacters = { "." } },
    codeLensProvider = { resolveProvider = true },
  },
  -- A server with nothing but hover: everything gated on a capability must be
  -- absent, which is what proves the gating is real.
  minimal = {
    hoverProvider = true,
  },
}

return F
