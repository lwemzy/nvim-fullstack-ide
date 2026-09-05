-- lua/nvim-ide/health.lua — :checkhealth nvim-ide.
--
-- A health check that is wrong is worse than none: it is read exactly once, by
-- someone whose editor is already broken, and every line of it is a claim about
-- their machine. So the subject here is the *verdict* — which findings come back
-- as error rather than warn, and whether each one fires for the right reason.
--
-- vim.health's five reporters are stubbed rather than driven through a real
-- :checkhealth run, because the report buffer's rendering is Neovim's business
-- and this module's only output is the sequence of calls it makes.

local H = require("helpers")

--- Stub vim.health and return the report as a list of
--- { kind = "start"|"ok"|"warn"|"error"|"info", msg = string, advice = table? }.
---
--- The module resolves each name off the vim.health table at call time, which is
--- what makes this possible; hoisting them into locals at require time would put
--- the report out of reach.
local function report_of(fn)
  local report = {}
  for _, kind in ipairs({ "start", "ok", "warn", "error", "info" }) do
    H.stub(vim.health, kind, function(msg, advice)
      table.insert(report, { kind = kind, msg = msg, advice = advice })
    end)
  end
  fn()
  return report
end

--- Every entry of `kind` whose message contains `needle`.
local function matching(report, kind, needle)
  return vim.tbl_filter(function(entry)
    return entry.kind == kind and type(entry.msg) == "string" and entry.msg:find(needle, 1, true) ~= nil
  end, report)
end

local function has(report, kind, needle)
  return #matching(report, kind, needle) > 0
end

--- Replace config.jdk wholesale. Stubbing the module's functions is not enough:
--- it caches its scan in a module-local, so a real list() during a spec would
--- report whatever JDKs the machine running the suite happens to have — and the
--- interesting cases are the ones no developer machine is in.
local function fake_jdk(list)
  package.loaded["config.jdk"] = {
    list = function() return list end,
    newest = function(min)
      for _, j in ipairs(list) do
        if j.major >= (min or 21) then return j end
      end
      return nil
    end,
    runtimes = function()
      return vim.tbl_map(function(j) return { name = "JavaSE-" .. j.major, path = j.path } end, list)
    end,
  }
end

local function check()
  package.loaded["nvim-ide.health"] = nil
  return report_of(function() require("nvim-ide.health").check() end)
end

describe("nvim-ide.health", function()
  after_each(function()
    package.loaded["config.jdk"] = nil
    package.loaded["nvim-ide.health"] = nil
    H.cleanup()
  end)

  it("reports a section for each subject", function()
    -- Missing a section is silent: checkhealth prints what it is given, so a
    -- subject that stops being reported simply disappears from the report.
    local report = check()
    local sections = vim.tbl_map(function(e) return e.msg end, matching(report, "start", ""))
    assert.same({ "Platform", "Java (jdtls)", "LSP file watching", "Formatters" }, sections)
  end)

  describe("Java", function()
    it("errors when no JDK 21+ was found", function()
      -- The whole reason this file exists. jdtls refuses to launch below 21, so
      -- this is not advice — Java completion is off, and ftplugin/java.lua now
      -- declines to start the server at all.
      fake_jdk({ { path = "/opt/java-17", major = 17 } })
      local report = check()
      assert.is_true(has(report, "error", "no JDK 21+"))
      -- The 17 is still listed: it is a valid runtime for a project that targets
      -- 17, just not something jdtls can run on.
      assert.is_true(has(report, "info", "/opt/java-17"))
    end)

    it("errors when no JDK was found at all", function()
      fake_jdk({})
      local report = check()
      assert.is_true(has(report, "error", "no JDK found"))
    end)

    it("names the JDK jdtls will launch on when one qualifies", function()
      -- The launcher choice is invisible otherwise, and "which java is jdtls
      -- actually using" is the first question any Java LSP problem raises.
      fake_jdk({ { path = "/opt/java-25", major = 25 }, { path = "/opt/java-17", major = 17 } })
      local report = check()
      assert.is_true(has(report, "ok", "Java 25 (/opt/java-25)"))
      assert.is_true(has(report, "info", "JavaSE-25, JavaSE-17"))
    end)

    it("errors when mason's jdtls launcher is missing", function()
      local real = vim.fn.executable
      H.stub(vim.fn, "executable", function(path)
        if type(path) == "string" and path:find("mason/bin/jdtls", 1, true) then return 0 end
        return real(path)
      end)
      local report = check()
      assert.is_true(has(report, "error", "jdtls not installed"))
    end)

    it("warns per missing payload, with what each absence costs", function()
      -- These are the silent ones: jdtls starts and looks completely healthy
      -- without any of them, and each absence removes a feature rather than
      -- raising an error, so nothing else ever says which.
      H.stub(vim.uv, "fs_stat", function() return nil end)
      local report = check()
      for _, expected in ipairs({
        { "Lombok", "unresolved" },
        { "java-debug-adapter", "breakpoints" },
        { "java-test", "tests" },
        { "vscode-spring-boot-tools", "Spring" },
      }) do
        local found = matching(report, "warn", expected[1])
        assert.equals(1, #found, expected[1] .. " should warn exactly once")
        assert.is_true(
          found[1].msg:find(expected[2], 1, true) ~= nil,
          expected[1] .. " should say what its absence costs, got: " .. found[1].msg
        )
        -- Advice is the actionable half; a warning with no fix is just noise.
        assert.is_true(type(found[1].advice) == "table" and #found[1].advice > 0)
      end
    end)
  end)

  describe("LSP file watching", function()
    local watch = require("vim._watch")
    local watchfiles = require("vim.lsp._watchfiles")

    it("passes on the recursive fs_event backend", function()
      H.stub(watchfiles, "_watchfunc", watch.watch)
      assert.is_true(has(check(), "ok", "recursive fs_event"))
    end)

    it("passes on the inotifywait backend", function()
      H.stub(watchfiles, "_watchfunc", watch.inotify)
      assert.is_true(has(check(), "ok", "inotifywait"))
    end)

    it("warns on the per-directory fallback and says what it breaks", function()
      -- nvim picks this on Linux when inotifywait is absent, and it is the one
      -- real behavioural difference between this config on macOS and on Linux:
      -- jdtls can miss a newly created .java file entirely, so completion in it
      -- stays empty. Nothing in the editor says so.
      H.stub(watchfiles, "_watchfunc", watch.watchdirs)
      local found = matching(check(), "warn", "per-directory")
      assert.equals(1, #found)
      assert.is_true(
        table.concat(found[1].advice, " "):find("newly created", 1, true) ~= nil,
        "the advice should name the new-file symptom"
      )
    end)
  end)

  describe("install hints", function()
    it("suggests apt on a Debian machine and never brew", function()
      -- A macOS `brew install` line on a Linux box is worse than no hint: it
      -- reads as authoritative and cannot work.
      fake_jdk({})
      H.stub(vim.fn, "has", function(f) return f == "mac" and 0 or 1 end)
      local real = vim.fn.executable
      H.stub(vim.fn, "executable", function(c) return c == "apt" and 1 or real(c) end)
      local advice = table.concat(matching(check(), "error", "no JDK found")[1].advice, "\n")
      assert.is_true(advice:find("apt install openjdk-21-jdk", 1, true) ~= nil, advice)
      assert.is_nil(advice:find("brew", 1, true))
    end)

    it("suggests brew on macOS", function()
      fake_jdk({})
      H.stub(vim.fn, "has", function(f) return f == "mac" and 1 or 0 end)
      local advice = table.concat(matching(check(), "error", "no JDK found")[1].advice, "\n")
      assert.is_true(advice:find("brew install openjdk@21", 1, true) ~= nil, advice)
    end)
  end)
end)
