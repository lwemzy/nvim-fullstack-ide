-- The capability-gated on_attach in lua/plugins/lsp.lua.
--
-- Two properties are under test, and they are the two that broke in real use:
--
--   1. GATING IS REAL, AND IT SEES DYNAMIC REGISTRATIONS. Every LSP mapping past
--      the unconditional five is wrapped in
--      `if client:supports_method(<method>, bufnr) then`. If that gating
--      regressed to "set them all", the maps would still *exist* on every buffer
--      and would fail only when pressed — vim.lsp.buf.references() on a server
--      without referencesProvider notifies "server does not support …" and does
--      nothing. A missing map is discoverable (which-key shows the truth); a
--      present-but-dead map is not. So the minimal-capability run asserts
--      ABSENCE, which is the only direction that can catch that regression.
--      The opposite failure is just as real: gating on the static
--      client.server_capabilities table missed everything a server registers
--      after initialize, which for jdtls is nearly all of it — see the
--      dynamic-registration specs at the bottom of the on_attach block.
--
--   2. on_attach REACHES CLIENTS STARTED OUTSIDE vim.lsp.enable(). The config
--      deliberately does NOT pass on_attach to vim.lsp.config("*"): config
--      resolution is tbl_deep_extend('force', configs['*'], <rtp lsp/*.lua>,
--      configs[name]) (runtime/lua/vim/lsp.lua), and 'force' OVERWRITES function
--      values, so lspconfig's own on_attach in lsp/ts_ls.lua and lsp/eslint.lua
--      silently discarded the wildcard's. An LspAttach autocmd is per-client and
--      unclobberable, and it also fires for clients nvim never resolved a config
--      for at all — jdtls via ftplugin/java.lua, and the fake clients below.
--
-- Fake in-process servers rather than real ones: the whole subject is "which
-- capabilities did the server advertise", and a fake is the only way to state
-- that exactly. The buffer is a real on-disk .txt file — never ft=java, because
-- setting that filetype runs ftplugin/java.lua and launches the actual jdtls.
-- The config branches on client *name* and *capabilities*, never on filetype.

local H = require("helpers")
local fake_lsp = require("helpers.fake_lsp")

--- The five mappings on_attach sets for every server, whatever it supports.
local UNCONDITIONAL = {
  { lhs = "gd", mode = "n", desc = "Go to definition" },
  { lhs = "K", mode = "n", desc = "Hover docs" },
  { lhs = "[d", mode = "n", desc = "Prev diagnostic" },
  { lhs = "]d", mode = "n", desc = "Next diagnostic" },
  { lhs = "<leader>d", mode = "n", desc = "Show diagnostic" },
}

--- Every capability-gated mapping, with the server_capabilities field a server
--- sets to advertise it at initialize. on_attach gates on
--- client:supports_method(<method>) rather than on the field directly, but the
--- field is what these fakes advertise and what supports_method resolves the
--- method to (vim.lsp.protocol._request_name_to_server_capability), so the two
--- agree for a statically advertised capability. Transcribed from on_attach; the
--- point of the table is that both the "present with full caps" and "absent with
--- hover-only caps" runs iterate the SAME list, so a mapping can never be added
--- to one check and forgotten in the other.
local GATED = {
  { lhs = "gD", mode = "n", cap = "declarationProvider" },
  { lhs = "gr", mode = "n", cap = "referencesProvider" },
  { lhs = "gi", mode = "n", cap = "implementationProvider" },
  { lhs = "<leader>lt", mode = "n", cap = "typeDefinitionProvider" },
  { lhs = "<C-k>", mode = "n", cap = "signatureHelpProvider" },
  -- Insert mode as well, and <M-k> rather than insert <C-k>: cmp owns insert
  -- <C-k> for select_prev_item, so a buffer-local insert <C-k> here would
  -- shadow cmp's global one and break menu navigation.
  { lhs = "<M-k>", mode = "i", cap = "signatureHelpProvider" },
  { lhs = "<leader>rn", mode = "n", cap = "renameProvider" },
  { lhs = "<leader>ca", mode = "n", cap = "codeActionProvider" },
  { lhs = "<leader>ls", mode = "n", cap = "documentSymbolProvider" },
  { lhs = "<leader>lw", mode = "n", cap = "workspaceSymbolProvider" },
  { lhs = "<leader>uh", mode = "n", cap = "inlayHintProvider" },
  { lhs = "<leader>lc", mode = "n", cap = "callHierarchyProvider" },
  { lhs = "<leader>lC", mode = "n", cap = "callHierarchyProvider" },
}

--- Mappings that are safe to actually press, with the request each must produce.
---
--- Deliberately excluded: gd / gr / gi / <leader>lt / <leader>ls / <leader>lw
--- are `<cmd>Telescope …<CR>` and would open a picker window and leave the
--- session in it; <leader>rn calls vim.lsp.buf.rename, which blocks on
--- vim.ui.input; <leader>uh toggles inlay hints, whose behaviour belongs to
--- inlay_hint_spec.lua. For those, existence + mode + desc is all this spec
--- claims.
local INVOCABLE = {
  { lhs = "K", method = "textDocument/hover" },
  { lhs = "gD", method = "textDocument/declaration" },
  { lhs = "<C-k>", method = "textDocument/signatureHelp" },
  { lhs = "<leader>ca", method = "textDocument/codeAction" },
  { lhs = "<leader>lc", method = "textDocument/prepareCallHierarchy" },
}

--- A mapping that is genuinely BUFFER-LOCAL, or nil.
---
--- H.keymap/H.has_keymap use maparg, which falls back to the global mapping when
--- no buffer-local one exists. That fallback would quietly turn the
--- absence-of-gated-mappings assertions into no-ops the moment any global
--- mapping shares an lhs (nvim ships global gr*/K LSP defaults, and
--- config/keymaps.lua owns a pile of <leader> maps), so buffer-locality has to
--- be part of the predicate rather than assumed.
local buf_map = H.buf_keymap

describe("lsp on_attach", function()
  local bufnr

  before_each(function()
    -- The LspAttach autocmd lives in nvim-lspconfig's `config` function; nothing
    -- under test exists until that has run.
    H.load_plugin("nvim-lspconfig")
    H.disable_autosave()
    bufnr = H.edit(H.write(H.tmpdir("attach") .. "/sample.txt", {
      "one(two)",
      "three",
    }))
  end)

  after_each(function()
    pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
    H.cleanup()
  end)

  --- Attach a fake server to the spec's buffer and wait for on_attach to run.
  ---
  --- Unique root_dir per server: vim.lsp.start REUSES a client whose config
  --- matches, in which case `cmd` is never called again and the new fake never
  --- gets connected at all.
  local function attach(name, capabilities)
    local srv = fake_lsp.start({
      name = name,
      bufnr = bufnr,
      root_dir = H.tmpdir("root-" .. name),
      capabilities = capabilities,
    })
    H.track_client(srv.id)
    -- K is unconditional, so its arrival is the signal that this client's
    -- LspAttach callback has been through on_attach.
    H.wait_for("on_attach ran for " .. name, function()
      return buf_map("n", "K", bufnr) ~= nil
    end)
    return srv
  end

  it("sets every mapping for a fully capable server", function()
    attach("full_ls", fake_lsp.caps.full)

    for _, m in ipairs(UNCONDITIONAL) do
      local d = buf_map(m.mode, m.lhs, bufnr)
      assert.is_not_nil(d, m.lhs .. " should be mapped")
      assert.equals(m.desc, d.desc)
    end

    for _, m in ipairs(GATED) do
      local d = buf_map(m.mode, m.lhs, bufnr)
      assert.is_not_nil(d, ("%s (%s) should be mapped when %s is advertised")
        :format(m.lhs, m.mode, m.cap))
      -- A desc is not cosmetic here: which-key and :Telescope keymaps are the
      -- only discovery surface these buffer-local maps have.
      assert.is_string(d.desc)
      assert.is_true(#d.desc > 0, m.lhs .. " needs a desc")
    end
  end)

  it("sets no gated mapping for a hover-only server", function()
    local srv = attach("minimal_ls", fake_lsp.caps.minimal)

    -- Guard the guard: if the fake somehow came up with more than hover, the
    -- absence assertions below would pass for the wrong reason.
    assert.is_true(srv.client.server_capabilities.hoverProvider)

    for _, m in ipairs(UNCONDITIONAL) do
      assert.is_not_nil(buf_map(m.mode, m.lhs, bufnr),
        m.lhs .. " is unconditional and must still be mapped")
    end

    for _, m in ipairs(GATED) do
      assert.is_nil(srv.client.server_capabilities[m.cap],
        "fixture drift: minimal caps should not include " .. m.cap)
      -- The regression this catches: a mapping present here would be a dead key
      -- that reports "server does not support …" when pressed.
      assert.is_nil(buf_map(m.mode, m.lhs, bufnr),
        ("%s (%s) must not be mapped without %s"):format(m.lhs, m.mode, m.cap))
    end
  end)

  it("maps only into the mode it is meant for", function()
    attach("full_ls", fake_lsp.caps.full)

    -- Signature help is the one mapping that exists in two modes, under two
    -- different keys. Crossing them over is silent: <C-k> in insert mode is
    -- cmp's select_prev_item, so a stray insert-mode <C-k> here breaks menu
    -- navigation without any error message.
    assert.is_not_nil(buf_map("n", "<C-k>", bufnr))
    assert.is_nil(buf_map("i", "<C-k>", bufnr))
    assert.is_not_nil(buf_map("i", "<M-k>", bufnr))
    assert.is_nil(buf_map("n", "<M-k>", bufnr))
  end)

  it("reaches a client started outside the vim.lsp.enable path", function()
    -- fake_lsp uses vim.lsp.start() directly, so nvim never resolves a
    -- vim.lsp.config entry for it: there is no name in lsp/*.lua, no wildcard
    -- merge, no `on_attach` in any config table. The mappings can therefore only
    -- have come from the LspAttach autocmd. This is exactly the shape of jdtls
    -- (started by ftplugin/java.lua) — the case a wildcard on_attach would still
    -- have covered, but which any per-config on_attach would miss.
    local srv = attach("started_by_hand", fake_lsp.caps.full)
    assert.is_nil(vim.lsp.config._configs[srv.client.name])
    assert.is_nil(srv.client.config.on_attach)
    assert.is_not_nil(buf_map("n", "gr", bufnr))

    -- And the autocmd is the mechanism, in a single named group.
    assert.equals(1, H.count_autocmds("LspAttach", "user_lsp_attach"))
  end)

  it("cannot put on_attach on the wildcard config", function()
    -- Not a style preference — a mechanical fact about how nvim resolves
    -- configs. Deep-extending with 'force' replaces function values outright, so
    -- a wildcard on_attach loses to any lsp/<name>.lua that defines one.
    local wildcard = function() end
    local per_server = function() end
    local merged = vim.tbl_deep_extend("force", { on_attach = wildcard }, { on_attach = per_server })
    assert.equals(per_server, merged.on_attach)

    -- The two servers that made this bite: both ship an on_attach in
    -- nvim-lspconfig's lsp/ dir, so both would have won.
    assert.is_function(vim.lsp.config["ts_ls"].on_attach)
    assert.is_function(vim.lsp.config["eslint"].on_attach)

    -- Hence: the wildcard carries capabilities and nothing else.
    assert.is_nil(vim.lsp.config["*"].on_attach)
    assert.same({ "capabilities" }, vim.tbl_keys(vim.lsp.config["*"]))
  end)

  it("advertises nvim-cmp's completion capabilities to every server", function()
    -- vim.lsp.config['*'] is asserted rather than a fake's initialize params
    -- because vim.lsp.start() consumes the config table it is handed verbatim
    -- (runtime/lua/vim/lsp.lua) — only the vim.lsp.enable path reads
    -- vim.lsp.config[name]. A fake started by the helper therefore never sees
    -- the wildcard at all, so its initialize params would prove nothing.
    local completion = vim.lsp.config["*"].capabilities.textDocument.completion
    local item = completion.completionItem

    -- Snippet support is what makes a server send `foo(${1:arg})` instead of
    -- plain `foo`; without it luasnip has nothing to expand and the whole
    -- snippet.expand wiring in the cmp spec is unreachable.
    assert.is_true(item.snippetSupport)

    -- These four are cmp_nvim_lsp's contribution specifically. Asserted against
    -- nvim's own defaults so the test stays meaningful: if a future nvim adopts
    -- these values, this assertion stops discriminating and the base-caps checks
    -- below are what will say so.
    local base = vim.lsp.protocol.make_client_capabilities().textDocument.completion.completionItem
    assert.is_false(base.commitCharactersSupport)
    assert.is_false(base.preselectSupport)
    assert.is_true(item.commitCharactersSupport)
    assert.is_true(item.preselectSupport)
    assert.same({ 1, 2 }, item.insertTextModeSupport.valueSet)

    -- resolveSupport is how cmp asks for documentation/edits lazily, on the
    -- highlighted entry only. Lose insertTextFormat/insertTextMode here and
    -- servers stop sending the fields cmp resolves an entry with.
    for _, prop in ipairs({
      "documentation", "additionalTextEdits", "insertTextFormat", "insertTextMode", "command",
    }) do
      assert.is_true(vim.list_contains(item.resolveSupport.properties, prop),
        "resolveSupport should request " .. prop)
    end

    -- The wildcard is only useful if it survives merging into a real server's
    -- resolved config — this is the exact table nvim hands to vim.lsp.start for
    -- ts_ls, lspconfig's own lsp/ts_ls.lua included.
    local resolved = vim.lsp.config["ts_ls"].capabilities.textDocument.completion.completionItem
    assert.is_true(resolved.snippetSupport)
    assert.is_true(resolved.preselectSupport)
  end)

  it("issues the matching LSP request when a mapping is pressed", function()
    local srv = attach("full_ls", fake_lsp.caps.full)

    for _, m in ipairs(INVOCABLE) do
      assert.equals(0, #srv.requests_for(m.method))
      -- The fake answers nil for everything, and vim.lsp.buf.* reports "no
      -- result" through vim.notify; capturing keeps that off the test output.
      H.capture_notifications(function()
        H.run_keymap("n", m.lhs, bufnr)
      end)
      -- The fake's transport records the request synchronously, so no wait is
      -- needed — and its absence would mean the mapping is bound to something
      -- other than the LSP call it advertises.
      assert.is_true(#srv.requests_for(m.method) > 0,
        ("%s should have produced %s"):format(m.lhs, m.method))
    end
  end)

  it("does not duplicate mappings or the augroup when a second client attaches", function()
    attach("first_ls", fake_lsp.caps.full)
    local n_maps = #vim.api.nvim_buf_get_keymap(bufnr, "n")
    local n_imaps = #vim.api.nvim_buf_get_keymap(bufnr, "i")

    -- Deleting K first makes the second attach observable: every on_attach sets
    -- it unconditionally, so its reappearance is proof the callback ran again
    -- (all the other maps are idempotent overwrites and would look identical
    -- whether or not the second client was ever processed).
    vim.keymap.del("n", "K", { buffer = bufnr })
    assert.is_nil(buf_map("n", "K", bufnr))

    local second = attach("second_ls", fake_lsp.caps.full)
    assert.equals(2, #vim.lsp.get_clients({ bufnr = bufnr }))
    assert.is_true(#second.requests_for("initialize") > 0)

    -- Two servers on one buffer is the normal case here (ts_ls + eslint,
    -- jdtls + spring-boot), so this runs on every Java and TS buffer.
    assert.equals(n_maps, #vim.api.nvim_buf_get_keymap(bufnr, "n"))
    assert.equals(n_imaps, #vim.api.nvim_buf_get_keymap(bufnr, "i"))
    assert.equals(1, H.count_autocmds("LspAttach", "user_lsp_attach"))
  end)

  it("keeps a capable server's mappings when a weaker one attaches too", function()
    attach("full_ls", fake_lsp.caps.full)
    assert.is_not_nil(buf_map("n", "gr", bufnr))

    -- eslint advertises far less than ts_ls and attaches to the same buffer. The
    -- mappings are per-client and additive, so the weaker client must not be
    -- able to take away what the capable one installed.
    vim.keymap.del("n", "K", { buffer = bufnr })
    attach("weak_ls", fake_lsp.caps.minimal)

    assert.is_not_nil(buf_map("n", "gr", bufnr))
    assert.is_not_nil(buf_map("n", "<leader>ca", bufnr))
    assert.is_not_nil(buf_map("i", "<M-k>", bufnr))
  end)

  -- The case the whole supports_method()/registerCapability arrangement exists
  -- for, and the one with the most user-visible impact: jdtls advertises very
  -- little at initialize and registers most of its capabilities dynamically once
  -- the project is imported.
  --
  -- Neither half works alone. Gating on client.server_capabilities can never see
  -- a dynamic registration (it holds only the initialize response — asserted
  -- below, so this spec fails if the config drifts back to it), and nvim never
  -- fires LspAttach a second time: its client/registerCapability handler only
  -- calls vim.lsp._set_defaults and re-attaches the internal vim.lsp._capability
  -- providers (runtime/lua/vim/lsp/handlers.lua). lsp.lua therefore wraps that
  -- handler and re-runs on_attach itself.
  it("gains a mapping when the capability is registered dynamically", function()
    local srv = attach("late_ls", fake_lsp.caps.minimal)
    assert.is_nil(buf_map("n", "<leader>ca", bufnr))

    srv.register({ { id = "1", method = "textDocument/codeAction" } })

    -- The re-run is scheduled from the handler, so wait on the mapping itself
    -- rather than on supports_method (which is true one tick earlier).
    H.wait_for("<leader>ca mapped after dynamic registration", function()
      return buf_map("n", "<leader>ca", bufnr) ~= nil
    end)

    -- Not via server_capabilities: that stayed empty, which is exactly why the
    -- static gate could not have produced this mapping.
    assert.is_nil(srv.client.server_capabilities.codeActionProvider)
    assert.equals("Code action", buf_map("n", "<leader>ca", bufnr).desc)
    -- Idempotent: the re-run overwrites, it does not stack duplicates. Matched on
    -- desc, because nvim_buf_get_keymap reports the lhs already resolved
    -- (<leader> expanded to the mapleader in force at map time).
    assert.equals(1, #vim.tbl_filter(function(m) return m.desc == "Code action" end,
      vim.api.nvim_buf_get_keymap(bufnr, "n")))
  end)

  it("leaves an unregistered capability's mapping absent after a re-run", function()
    -- The re-run must not degrade into "set them all": a registration for one
    -- method may not hand the buffer keys for every other one.
    local srv = attach("partial_ls", fake_lsp.caps.minimal)
    srv.register({ { id = "1", method = "textDocument/codeAction" } })
    H.wait_for("<leader>ca mapped after dynamic registration", function()
      return buf_map("n", "<leader>ca", bufnr) ~= nil
    end)

    assert.is_nil(buf_map("n", "<leader>rn", bufnr))
    assert.is_nil(buf_map("n", "gr", bufnr))
    assert.is_nil(buf_map("n", "<leader>uh", bufnr))
  end)
end)

describe("eslint on_attach chaining", function()
  local bufnr

  before_each(function()
    H.load_plugin("nvim-lspconfig")
    H.disable_autosave()
    bufnr = H.edit(H.write(H.tmpdir("eslint") .. "/index.ts", { "const a = 1" }))
  end)

  after_each(function()
    H.cleanup()
  end)

  --- The resolved on_attach is invoked directly rather than by attaching a fake
  --- named "eslint", because vim.lsp.start() ignores vim.lsp.config entirely —
  --- only the vim.lsp.enable path looks up vim.lsp.config[name] and calls this
  --- hook. This function IS the one nvim calls at attach time for a real eslint
  --- client, so calling it with a fake client is the same code path minus the
  --- process. (A helper gap: fake_lsp cannot yet start a server *through*
  --- vim.lsp.config/enable, which would make this an end-to-end attach.)
  local function attach_as_eslint()
    local srv = fake_lsp.start({
      name = "eslint",
      bufnr = bufnr,
      root_dir = H.tmpdir("root-eslint"),
      capabilities = fake_lsp.caps.full,
    })
    H.track_client(srv.id)
    H.track_augroup("eslint_fix_" .. bufnr)
    local on_attach = vim.lsp.config["eslint"].on_attach
    assert.is_function(on_attach)
    on_attach(srv.client, bufnr)
    return srv
  end

  it("keeps lspconfig's LspEslintFixAll command", function()
    attach_as_eslint()

    -- lsp/eslint.lua's own on_attach is the ONLY thing that creates this buffer
    -- command. Setting on_attach in vim.lsp.config("eslint", …) without calling
    -- the base handler first overwrites it (tbl_deep_extend 'force' again), and
    -- the fix-on-save autocmd below then pcall'd a nonexistent command forever —
    -- silently, which is why the command's existence is the assertion.
    assert.is_not_nil(vim.api.nvim_buf_get_commands(bufnr, {})["LspEslintFixAll"])
  end)

  it("registers exactly one fix-on-save autocmd per buffer", function()
    attach_as_eslint()
    local group = "eslint_fix_" .. bufnr
    assert.equals(1, H.count_autocmds("BufWritePre", group, bufnr))

    -- Re-entering the buffer re-attaches, and without the per-buffer augroup's
    -- clear=true each pass stacked another BufWritePre — N runs of
    -- eslint --fix on a single save.
    vim.lsp.config["eslint"].on_attach(assert(vim.lsp.get_clients({ name = "eslint" })[1]), bufnr)
    assert.equals(1, H.count_autocmds("BufWritePre", group, bufnr))
  end)

  it("gives the command to no other server", function()
    -- The shared on_attach (the LspAttach one) must not create it: a differently
    -- named client on an identical buffer gets mappings and nothing else.
    local srv = fake_lsp.start({
      name = "ts_ls",
      bufnr = bufnr,
      root_dir = H.tmpdir("root-ts"),
      capabilities = fake_lsp.caps.full,
    })
    H.track_client(srv.id)
    H.wait_for("on_attach ran", function()
      return H.keymap("n", "K", bufnr) ~= nil
    end)

    assert.is_nil(vim.api.nvim_buf_get_commands(bufnr, {})["LspEslintFixAll"])
    assert.equals(0, #H.autocmds({ event = "BufWritePre", group = "eslint_fix_" .. bufnr }))
  end)
end)
