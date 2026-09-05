-- The inlay-hint single-owner fix in lua/plugins/lsp.lua.
--
-- This is a regression suite for a real crash: nvim 0.12's inlay_hint.lua stores
-- hints per client but tracks staleness with one per-buffer version stamp, so a
-- second provider's response (even an empty one) re-validates the first
-- provider's stale columns and every redraw raises
--   inlay_hint.lua:362: Invalid 'col': out of range
--
-- The observable here is vim.lsp.inlay_hint.get(), which reads the same stored
-- hints the decoration provider renders. A hint that never gets stored can never
-- be rendered against the wrong text — so "exactly one client_id in get()" is
-- the property that makes the crash unreachable.
--
-- Fake in-process servers rather than jdtls/ts_ls: the point is the interaction
-- between two providers with known names and known responses, and the real
-- servers take tens of seconds to decide those things for themselves.

local H = require("helpers")
local fake_lsp = require("helpers.fake_lsp")

--- One hint per line, labelled so the producing server is identifiable.
local function hints_from(name)
  return function(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local out = {}
    for lnum = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
      table.insert(out, {
        position = { line = lnum, character = 0 },
        label = name .. ":",
        kind = 2,
      })
    end
    return out
  end
end

--- client_ids that currently have hints stored for the buffer.
local function hint_sources(bufnr)
  local ids = {}
  for _, h in ipairs(vim.lsp.inlay_hint.get({ bufnr = bufnr })) do
    ids[h.client_id] = true
  end
  return vim.tbl_keys(ids)
end

local function hint_labels(bufnr)
  local labels = {}
  for _, h in ipairs(vim.lsp.inlay_hint.get({ bufnr = bufnr })) do
    labels[h.inlay_hint.label] = true
  end
  return labels
end

describe("inlay hint ownership", function()
  local bufnr

  --- A real on-disk file with a neutral filetype. Not a .java buffer: setting
  --- ft=java runs ftplugin/java.lua and launches the actual jdtls, which makes
  --- the spec slow, machine-dependent, and no longer about the ownership rule.
  --- The rule keys off client *name*, which the fakes control, so the buffer's
  --- filetype is irrelevant to what is being tested.
  local function sample_buffer(lines)
    local path = H.write(H.tmpdir("hints") .. "/sample.txt", lines)
    return H.edit(path)
  end

  before_each(function()
    H.load_plugin("nvim-lspconfig")
    H.disable_autosave()
    bufnr = sample_buffer({ "class A {", "  void f(int x) {}", "}" })
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
  end)

  after_each(function()
    pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
    H.cleanup()
  end)

  --- Start a fake server that supplies hints, wait for it to have answered.
  local function start_hinting_server(name, opts)
    opts = opts or {}
    local srv = fake_lsp.start({
      name = name,
      bufnr = bufnr,
      -- Unique root per instance: vim.lsp.start reuses an existing client whose
      -- config matches, which would silently hand back the previous test's
      -- client instead of starting a new one.
      root_dir = H.tmpdir("root-" .. name),
      capabilities = opts.dynamic and {} or { inlayHintProvider = true },
      responses = {
        ["textDocument/inlayHint"] = opts.empty and function() return {} end
          or hints_from(name),
      },
    })
    H.track_client(srv.id)
    return srv
  end

  it("stores hints for a single provider", function()
    local srv = start_hinting_server("jdtls")
    H.wait_for("jdtls hints stored", function()
      return #vim.lsp.inlay_hint.get({ bufnr = bufnr }) > 0
    end)
    assert.same({ srv.id }, hint_sources(bufnr))
    assert.is_true(hint_labels(bufnr)["jdtls:"])
  end)

  it("drops a second provider's hints, leaving exactly one source", function()
    local first = start_hinting_server("spring-boot")
    H.wait_for("first provider stored", function()
      return #hint_sources(bufnr) == 1
    end)

    -- angularls/spring-boot vs ts_ls/jdtls is the shape that crashed: two
    -- providers, one buffer.
    local second = start_hinting_server("some-other-ls")
    vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    H.wait_for("both servers asked", function()
      return #second.requests_for("textDocument/inlayHint") > 0
    end)

    -- Equal rank (neither is jdtls/ts_ls), so the incumbent keeps it.
    assert.same({ first.id }, hint_sources(bufnr))
    assert.is_nil(hint_labels(bufnr)["some-other-ls:"])
  end)

  it("lets a higher-ranked server take ownership from the incumbent", function()
    local boot = start_hinting_server("spring-boot")
    H.wait_for("spring-boot owns", function()
      return vim.deep_equal({ boot.id }, hint_sources(bufnr))
    end)

    -- Ranked takeover exists because the useful server is never the first to
    -- answer: spring-boot attaches before jdtls and returns nothing for .java,
    -- so a permanent first-responder rule left Java buffers with no hints.
    local jdtls = start_hinting_server("jdtls")
    H.wait_for("jdtls takes over", function()
      return vim.deep_equal({ jdtls.id }, hint_sources(bufnr))
    end)

    -- The incumbent's hints are gone, not merely outnumbered: leaving them
    -- stored is exactly the stale-column resurrection being prevented.
    assert.is_nil(hint_labels(bufnr)["spring-boot:"])
    assert.is_true(hint_labels(bufnr)["jdtls:"])
  end)

  it("does not hand ownership back to a lower-ranked server", function()
    local jdtls = start_hinting_server("jdtls")
    H.wait_for("jdtls owns", function()
      return vim.deep_equal({ jdtls.id }, hint_sources(bufnr))
    end)

    local boot = start_hinting_server("spring-boot")
    vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    H.wait_for("spring-boot asked", function()
      return #boot.requests_for("textDocument/inlayHint") > 0
    end)

    -- A takeover needs a STRICTLY higher rank, which is what bounds it to one
    -- per buffer and rules out two servers trading ownership on every keystroke.
    assert.same({ jdtls.id }, hint_sources(bufnr))
  end)

  it("keeps one source across an edit that shortens a line", function()
    local boot = start_hinting_server("spring-boot")
    local jdtls = start_hinting_server("jdtls")
    H.wait_for("jdtls owns", function()
      return vim.deep_equal({ jdtls.id }, hint_sources(bufnr))
    end)

    -- The crashing sequence: hints computed against long text, then the text
    -- gets shorter. With two stored sources the older columns would be
    -- re-validated by the other server's response and rendered out of range.
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "  void f(int averyverylongparametername) {}" })
    vim.wait(50)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "  x" })
    H.wait_for("re-requested after the edit", function()
      return #jdtls.requests_for("textDocument/inlayHint") > 1
    end)

    assert.same({ jdtls.id }, hint_sources(bufnr))
    -- spring-boot is still attached and still being asked — it is its *stored
    -- hints* that are suppressed, not its participation.
    assert.is_true(#boot.requests_for("textDocument/inlayHint") > 0)

    -- Every stored hint must sit inside the line it points at; a column past
    -- end-of-line is precisely what nvim_buf_set_extmark rejects.
    for _, h in ipairs(vim.lsp.inlay_hint.get({ bufnr = bufnr })) do
      local line = vim.api.nvim_buf_get_lines(bufnr, h.inlay_hint.position.line, h.inlay_hint.position.line + 1, false)[1]
      assert.is_not_nil(line)
      assert.is_true(h.inlay_hint.position.character <= #line)
    end
  end)

  it("re-requests hints when a server registers the capability dynamically", function()
    -- jdtls advertises no inlayHintProvider at initialize and registers
    -- textDocument/inlayHint afterwards. Upstream only requests hints on
    -- didOpen/didChange and does not re-attach for this method, so without the
    -- client/registerCapability wrapper a freshly opened Java buffer is never
    -- asked at all — hints appeared only after the first keystroke.
    local srv = start_hinting_server("jdtls", { dynamic = true })
    assert.equals(0, #srv.requests_for("textDocument/inlayHint"))
    assert.is_not_true(srv.client.server_capabilities.inlayHintProvider)

    srv.register({ { id = "1", method = "textDocument/inlayHint" } })

    H.wait_for("hints requested after registration", function()
      return #srv.requests_for("textDocument/inlayHint") > 0
    end)
    H.wait_for("hints stored after registration", function()
      return hint_labels(bufnr)["jdtls:"] == true
    end)
  end)

  -- The other half of that re-request, and the reason on_attach tracks "hints
  -- have been switched on for this buffer" separately from is_enabled(): those
  -- two states — never enabled yet, and deliberately switched off with
  -- <leader>uh — look identical to is_enabled(), and the re-run must treat them
  -- oppositely. Getting this wrong makes <leader>uh unusable in a Java buffer:
  -- jdtls keeps registering capabilities, and each one turned the hints back on.
  it("leaves hints off after a toggle-off when a later registration re-runs on_attach", function()
    local srv = start_hinting_server("jdtls")
    H.wait_for("hints stored", function()
      return #hint_sources(bufnr) > 0
    end)

    -- What <leader>uh does (the mapping's own wiring is lsp_attach_spec's
    -- subject; this is about what a re-run may not undo).
    vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
    assert.is_not_true(vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }))

    -- An unrelated registration, which is the common case: nearly everything
    -- jdtls registers has nothing to do with hints.
    srv.register({ { id = "1", method = "textDocument/codeAction" } })
    H.wait_for("on_attach re-ran", function()
      return H.buf_keymap("n", "<leader>ca", bufnr) ~= nil
    end)

    assert.is_not_true(vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }))
    assert.same({}, vim.lsp.inlay_hint.get({ bufnr = bufnr }))
  end)

  it("leaves hints off after a toggle-off when a second provider attaches", function()
    -- An attaching hint provider IS a reason to re-request (that is how a
    -- higher-ranked server gets asked at all), so this is the case where that
    -- rule has to yield to the user's toggle.
    start_hinting_server("spring-boot")
    H.wait_for("hints stored", function()
      return #hint_sources(bufnr) > 0
    end)
    vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })

    -- Deleting K first makes the second attach observable: on_attach sets it
    -- unconditionally, so its reappearance means that callback has run.
    vim.keymap.del("n", "K", { buffer = bufnr })
    start_hinting_server("jdtls")
    H.wait_for("jdtls's on_attach ran", function()
      return H.buf_keymap("n", "K", bufnr) ~= nil
    end)

    assert.is_not_true(vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }))
    assert.same({}, vim.lsp.inlay_hint.get({ bufnr = bufnr }))
  end)

  it("releases ownership when the owning client detaches", function()
    local first = start_hinting_server("spring-boot")
    H.wait_for("first owns", function()
      return vim.deep_equal({ first.id }, hint_sources(bufnr))
    end)

    -- :LspRestart hands the same server a NEW client_id, so ownership that
    -- outlived its client would leave the buffer permanently hint-less.
    first.stop()
    H.wait_for("client gone", function()
      return vim.lsp.get_client_by_id(first.id) == nil
    end)

    local second = start_hinting_server("spring-boot")
    H.wait_for("replacement owns", function()
      return vim.deep_equal({ second.id }, hint_sources(bufnr))
    end)
  end)

  it("does not carry ownership over to a recycled buffer number", function()
    local first = start_hinting_server("spring-boot")
    H.wait_for("first owns", function()
      return vim.deep_equal({ first.id }, hint_sources(bufnr))
    end)

    local wiped = bufnr
    first.stop()
    vim.api.nvim_buf_delete(wiped, { force = true })

    -- bufnrs are reused, so ownership keyed by bufnr has to be dropped with the
    -- buffer or a later, unrelated buffer inherits a dead owner.
    bufnr = sample_buffer({ "class B {}" })
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    local srv = start_hinting_server("spring-boot")
    H.wait_for("new buffer gets hints", function()
      return vim.deep_equal({ srv.id }, hint_sources(bufnr))
    end)
  end)
end)
