-- lua/config/lsp_reap.lua — reclaiming idle JVM language servers.
--
-- The whole design question here is "when is it safe to stop a server", and both
-- ways of getting it wrong are expensive: too eager costs a ~30s jdtls project
-- import the user did not ask for, too lazy leaves multi-GB JVMs resident until
-- the Linux OOM killer picks the largest RSS and takes Java completion out
-- mid-session. So these tests are almost all about the grace period.
--
-- sweep() takes the clock as an argument precisely so that can be tested: driving
-- it through the real vim.defer_fn would mean a five-minute spec.

local H = require("helpers")
local fake_lsp = require("helpers.fake_lsp")

local reap = require("config.lsp_reap")

describe("config.lsp_reap", function()
  local TIMEOUT = reap.idle_timeout_ms

  before_each(function()
    -- sweep() carries idle bookkeeping between calls, so without this a spec that
    -- marked a client idle would decide the next spec's outcome.
    reap.reset()
  end)

  after_each(function()
    H.cleanup()
    reap.reset()
  end)

  --- A fake server called `name`, attached to a fresh scratch buffer.
  --- Returns the server and its buffer.
  local function server(name)
    local buf = H.scratch({ lines = { "x" } })
    local srv = fake_lsp.start({
      name = name,
      bufnr = buf,
      -- Unique root: vim.lsp.start reuses a client whose config matches, which
      -- would hand two specs the same client and the same idle bookkeeping.
      root_dir = H.tmpdir("reap-" .. name .. "-" .. buf),
    })
    H.track_client(srv.id)
    return srv, buf
  end

  --- Retire `buf` the way closing a project's last file does.
  local function wipe(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  --- Is this client still in get_clients and not shutting down?
  local function running(srv)
    local c = vim.lsp.get_client_by_id(srv.id)
    return c ~= nil and not c:is_stopped()
  end

  describe("what it will not touch", function()
    it("leaves a JVM server that still has a live buffer alone forever", function()
      local srv = server("jdtls")
      -- Far past the timeout, repeatedly: an open project must never be reclaimed
      -- no matter how long the session runs.
      for i = 1, 5 do
        local stopped = reap.sweep(i * TIMEOUT * 10)
        assert.equals(0, #stopped)
      end
      assert.is_true(running(srv))
    end)

    it("leaves non-JVM servers alone however long they are idle", function()
      -- The cost being traded away is a ~30s restart. That is only worth paying
      -- for the JVMs; a node server's footprint does not justify the risk, so
      -- ts_ls must be invisible to this regardless of idleness.
      local srv, buf = server("ts_ls")
      wipe(buf)
      assert.equals(0, #reap.sweep(0))
      assert.equals(0, #reap.sweep(TIMEOUT * 100))
      assert.is_true(running(srv))
    end)
  end)

  describe("the grace period", function()
    it("does not stop a server on the first sweep that finds it idle", function()
      -- The first sweep can only start the clock. Stopping here would mean any
      -- buffer close that happened to coincide with a sweep killed the server.
      local srv, buf = server("jdtls")
      wipe(buf)
      assert.equals(0, #reap.sweep(0))
      assert.is_true(running(srv))
    end)

    it("does not stop a server one millisecond before the period is up", function()
      -- The assertion that pins the period itself. An off-by-one here is not
      -- visible in normal use, which is exactly why it needs a test.
      local srv, buf = server("jdtls")
      wipe(buf)
      reap.sweep(0)
      assert.equals(0, #reap.sweep(TIMEOUT - 1))
      assert.is_true(running(srv))
    end)

    it("stops a server once it has been idle for the whole period", function()
      local srv, buf = server("jdtls")
      wipe(buf)
      reap.sweep(0)
      local stopped = reap.sweep(TIMEOUT)
      assert.same({ "jdtls" }, stopped)
      H.wait_for("jdtls stopped", function() return not running(srv) end)
    end)

    it("restarts the clock when a buffer comes back", function()
      -- Idle -> busy -> idle has to earn the full grace period again. Measuring
      -- from the FIRST time it went idle would stop a server the user had come
      -- back to and was actively using.
      local srv, buf = server("jdtls")
      wipe(buf)
      reap.sweep(0)

      -- Reattach: a second file from the same project being opened.
      local buf2 = H.scratch({ lines = { "y" } })
      vim.lsp.buf_attach_client(buf2, srv.id)
      assert.equals(0, #reap.sweep(TIMEOUT))
      assert.is_true(running(srv))

      -- Now idle again from TIMEOUT onwards, so TIMEOUT*2 - 1 is still too early.
      wipe(buf2)
      assert.equals(0, #reap.sweep(TIMEOUT + 1))
      assert.equals(0, #reap.sweep(TIMEOUT * 2 - 1))
      assert.is_true(running(srv))
      assert.same({ "jdtls" }, reap.sweep(TIMEOUT * 2 + 1))
    end)

    it("measures each server's idleness separately", function()
      -- The bug this pins: with one shared timer instead of per-client stamps, a
      -- server that fell idle just before the deadline was stopped moments later
      -- rather than a full period later.
      local jdtls, jbuf = server("jdtls")
      local boot, bbuf = server("spring-boot")

      wipe(jbuf)
      reap.sweep(0) -- jdtls idle from 0; spring-boot still busy

      wipe(bbuf)
      reap.sweep(TIMEOUT - 1) -- spring-boot idle only from here

      -- jdtls is due, spring-boot is not.
      assert.same({ "jdtls" }, reap.sweep(TIMEOUT))
      assert.is_true(running(boot))

      -- spring-boot becomes due a full period after ITS first idle sighting.
      assert.equals(0, #reap.sweep(TIMEOUT * 2 - 3))
      assert.same({ "spring-boot" }, reap.sweep(TIMEOUT * 2 - 1))
    end)
  end)

  describe("idleness detection", function()
    it("counts a server as idle however its last buffer was retired", function()
      -- This module's entire premise is that attached_buffers empties when a
      -- buffer goes away, and nvim is what makes that true: :bwipeout, :bdelete
      -- and :bunload all route through nvim_buf_attach's on_detach, which ends in
      -- attached_buffers[bufnr] = nil. Measured on 0.12.4 — and only :bwipeout
      -- leaves the buffer invalid, so a check written against validity alone
      -- would miss the other two. If that ever changes, this module silently
      -- stops reclaiming anything, which is exactly the leak it exists to fix.
      for _, retire in ipairs({
        { "bwipeout", function(b) vim.api.nvim_buf_delete(b, { force = true }) end },
        { "bdelete", function(b) vim.cmd("silent! bdelete! " .. b) end },
        { "bunload", function(b) vim.cmd("silent! bunload! " .. b) end },
      }) do
        local how, retire_fn = retire[1], retire[2]
        reap.reset()
        local srv, buf = server("jdtls")
        retire_fn(buf)

        local client = assert(vim.lsp.get_client_by_id(srv.id))
        assert.equals(0, vim.tbl_count(client.attached_buffers), how .. " left an entry behind")

        reap.sweep(0)
        assert.same({ "jdtls" }, reap.sweep(TIMEOUT), how .. " did not make the server reclaimable")
        H.wait_for(how .. " stopped", function() return not running(srv) end)
      end
    end)

    it("reports whether anything is left to reap, so the timer can stop", function()
      -- The second return value is what stops the periodic sweep rescheduling
      -- itself. If it were always true, an editing session with no Java in it
      -- would still wake up every minute for the rest of the session.
      local _, buf = server("jdtls")
      local _, live = reap.sweep(0)
      assert.is_true(live)

      wipe(buf)
      reap.sweep(0)
      reap.sweep(TIMEOUT) -- stops it
      H.wait_for("no jvm clients left", function()
        local _, still_live = reap.sweep(TIMEOUT * 3)
        return still_live == false
      end)
    end)
  end)

  describe("bookkeeping", function()
    it("forgets a client that went away on its own", function()
      -- A crash or :LspRestart retires the client without us stopping it. Its id
      -- would otherwise sit in the idle table for the rest of the session — the
      -- same unbounded-growth shape this module exists to prevent.
      local srv, buf = server("jdtls")
      wipe(buf)
      reap.sweep(0)

      local client = assert(vim.lsp.get_client_by_id(srv.id))
      client:stop(true)
      H.wait_for("client gone", function() return not running(srv) end)

      -- A sweep after it has gone must not stop anything and must not error.
      assert.equals(0, #reap.sweep(TIMEOUT * 2))
    end)
  end)

  describe("setup", function()
    it("watches every event that can retire a buffer", function()
      -- LspDetach alone is not enough: nvim fires it from _on_detach behind an
      -- nvim_buf_is_valid guard, so :bwipeout can retire a buffer without it
      -- arriving at all. BufDelete/BufWipeout are the backstop, and LspAttach
      -- starts the sweep running before there is anything to reap.
      H.track_augroup("user_lsp_reap_idle")
      reap.setup()
      local events = {}
      for _, a in ipairs(H.autocmds({ group = "user_lsp_reap_idle" })) do
        events[a.event] = true
      end
      for _, e in ipairs({ "LspAttach", "LspDetach", "BufDelete", "BufWipeout" }) do
        assert.is_true(events[e] == true, "not watching " .. e)
      end
    end)
  end)
end)
