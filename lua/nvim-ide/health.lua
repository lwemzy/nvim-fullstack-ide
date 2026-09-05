-- :checkhealth nvim-ide
--
-- Exists because this config's most common failure is invisible: Java completion
-- either works or is silently absent, and every reason for the latter is an
-- environment fact rather than a config error. Diagnosing it by reading
-- ~/.local/state/nvim/lsp.log is not a reasonable thing to ask of anyone, and
-- the startup vim.notify warnings scroll past before the first buffer is drawn.
--
-- Scoped deliberately to the things that differ BETWEEN MACHINES — JDK
-- discovery, mason payloads, the LSP file-watching backend, external formatters.
-- Anything that would fail identically everywhere is a bug for the test suite to
-- catch, not something to re-report here.

local M = {}

-- The table, not its functions: each name is looked up at call time, so the
-- report is observable from a test without re-implementing checkhealth.
local health = vim.health

--- Mason's install prefix. Every payload below is relative to it, and getting it
--- wrong is the difference between "not installed" and "looked in the wrong
--- place" — which read identically in a health report, so resolve it once.
local function mason(sub)
  return vim.fn.stdpath("data") .. "/mason/" .. sub
end

--- `label` -> the platform-appropriate install hint, or nil.
---
--- One table rather than a string per call site: the same three-way choice
--- (macOS/Debian/Fedora) is needed by several checks, and a report that suggests
--- `brew install` on a Linux box is worse than one that suggests nothing.
local function hint(brew, apt, dnf)
  if vim.fn.has("mac") == 1 then return "brew install " .. brew end
  if vim.fn.executable("apt") == 1 then return "sudo apt install " .. apt end
  if vim.fn.executable("dnf") == 1 then return "sudo dnf install " .. dnf end
  return nil
end

local function platform()
  health.start("Platform")
  local uname = vim.uv.os_uname()
  health.info(("%s %s (%s)"):format(uname.sysname, uname.release, uname.machine))
  health.info("nvim " .. tostring(vim.version()))
  health.info("config " .. vim.fn.stdpath("config"))
  health.info("data   " .. vim.fn.stdpath("data"))
end

local function jdks()
  health.start("Java (jdtls)")

  local jdk = require("config.jdk")
  local list = jdk.list()

  if #list == 0 then
    health.error("no JDK found anywhere this config looks", {
      hint("openjdk@21", "openjdk-21-jdk", "java-21-openjdk-devel")
        or "install a JDK 21+",
      "or `sdk install java 21-tem` (sdkman), or set $JAVA_HOME",
    })
  else
    for i, j in ipairs(list) do
      health.info(("Java %d  %s%s"):format(j.major, j.path, i == 1 and "  (newest)" or ""))
    end
  end

  -- The one that decides whether Java works at all. jdtls 1.60+ aborts at
  -- launch below 21 (mason/packages/jdtls/bin/jdtls.py), so this is not a
  -- preference — it is the difference between a working server and none.
  local launcher = jdk.server_jdk(21)
  if launcher then
    health.ok(("jdtls will launch on Java %d (%s)"):format(launcher.major, launcher.path))
    -- Said out loud because otherwise it looks like a discovery bug: the newest
    -- JDK on the machine is right there in the list above, and the server is not
    -- using it. The host JVM is deliberately the newest LTS.
    if list[1] and list[1].major > launcher.major then
      health.info(("Java %d is newer but not LTS — kept as a runtime, not used to launch")
        :format(list[1].major))
    end
  else
    health.error("no JDK 21+ — jdtls refuses to launch, so Java completion is OFF", {
      hint("openjdk@21", "openjdk-21-jdk", "java-21-openjdk-devel")
        or "install a JDK 21+",
      "already have one? set $JAVA_HOME to it, or `sdk use java 21-tem`",
    })
  end

  -- Reported separately from the list above because a project that declares an
  -- older `--release` needs that older JDK *registered*, not installed-and-
  -- ignored: without a matching runtime jdtls compiles against the newest one
  -- and invents errors that the real build does not have.
  local runtimes = vim.tbl_map(function(r) return r.name end, jdk.runtimes())
  if #runtimes > 0 then
    health.info("registered runtimes: " .. table.concat(runtimes, ", "))
  end

  local launcher_bin = mason("bin/jdtls")
  if vim.fn.executable(launcher_bin) == 1 then
    health.ok("jdtls launcher installed")
  else
    health.error("jdtls not installed — Java completion is OFF", {
      ":MasonInstall jdtls  (or wait for mason's automatic install and reopen the file)",
    })
  end

  -- Silent-failure payloads: jdtls starts and looks healthy without any of
  -- these, and each one's absence removes a feature rather than raising an
  -- error, so nothing ever says which.
  local payloads = {
    {
      "Lombok",
      { mason("packages/jdtls/lombok.jar"), mason("share/jdtls/lombok.jar") },
      "@Data/@Getter/@Builder members are invisible and reported as unresolved",
      ":MasonInstall jdtls",
    },
    {
      "java-debug-adapter",
      { mason("packages/java-debug-adapter/extension/server") },
      "no breakpoints, no <leader>dR run",
      ":MasonInstall java-debug-adapter",
    },
    {
      "java-test",
      { mason("packages/java-test/extension/server") },
      "<F10>/<F11> cannot discover or run tests",
      ":MasonInstall java-test",
    },
    {
      "vscode-spring-boot-tools",
      { mason("packages/vscode-spring-boot-tools") },
      "no Spring property or application.yml completion",
      ":MasonInstall vscode-spring-boot-tools",
    },
  }
  for _, p in ipairs(payloads) do
    local label, paths, consequence, fix = p[1], p[2], p[3], p[4]
    local found = false
    for _, path in ipairs(paths) do
      if vim.uv.fs_stat(path) then
        found = true
        break
      end
    end
    if found then
      health.ok(label .. " present")
    else
      health.warn(label .. " missing — " .. consequence, { fix })
    end
  end
end

local function watchfiles()
  health.start("LSP file watching")

  -- The sharpest platform difference in the whole stack, and it is Neovim's, not
  -- this config's: on macOS and Windows nvim watches recursively with one
  -- fs_event handle; on Linux it shells out to inotifywait, and WITHOUT that
  -- binary it degrades to one inotify watch per directory, walked once at
  -- registration. jdtls leans on these notifications to notice a file it has not
  -- been told about — which is why "create a new .java file and get no
  -- completion" is a Linux-only symptom on an otherwise identical config.
  -- Both modules are private, so guard the lookup: a health check that throws
  -- takes the whole report down, and the sections after this one are the ones
  -- someone with a broken editor came here to read.
  local got, watch = pcall(require, "vim._watch")
  local got_wf, watchfiles = pcall(require, "vim.lsp._watchfiles")
  if not (got and got_wf) then
    return health.info("cannot determine the backend on this Neovim version")
  end

  local backend = watchfiles._watchfunc
  if backend == watch.watch then
    health.ok("recursive fs_event (nvim's default on macOS/Windows)")
  elseif backend == watch.inotify then
    health.ok("inotifywait")
  elseif backend == watch.watchdirs then
    health.warn("per-directory fs_event polling — nvim's fallback when inotifywait is absent", {
      "one inotify watch per directory, so a large project can exhaust "
        .. "fs.inotify.max_user_watches and silently stop reporting changes",
      "jdtls may not notice newly created files: completion in a new .java "
        .. "file stays empty until :JdtlsClean or a restart",
      hint("inotify-tools", "inotify-tools", "inotify-tools")
        or "install inotify-tools",
    })
  else
    health.info("custom or unrecognised watch backend")
  end
end

local function formatters()
  health.start("Formatters")

  -- conform's JS/TS selection needs BOTH: prettierd for speed, and plain
  -- prettier because the daemon rejects the ad-hoc --single-quote that carries
  -- the Google-style fallback (see lua/plugins/editor.lua). With only prettierd
  -- installed, every JS/TS file with no project prettier config formats with
  -- Prettier's stock double quotes instead.
  for _, name in ipairs({ "prettierd", "prettier" }) do
    if vim.fn.executable(name) == 1 or vim.fn.executable(mason("bin/" .. name)) == 1 then
      health.ok(name .. " available")
    else
      health.warn(name .. " not found", { ":MasonInstall " .. name })
    end
  end

  local style = vim.fn.stdpath("config") .. "/java-google-style.xml"
  if vim.fn.filereadable(style) == 1 then
    health.ok("Google Java Style profile present")
  else
    -- jdtls does not error on an unreadable formatter url; it quietly uses
    -- Eclipse's own default profile, which is a different style entirely.
    health.warn("java-google-style.xml missing — jdtls falls back to Eclipse's default profile", {
      "restore it from the repo: " .. style,
    })
  end
end

function M.check()
  platform()
  jdks()
  watchfiles()
  formatters()
end

return M
