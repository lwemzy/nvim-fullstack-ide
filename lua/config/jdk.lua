-- JDK discovery, shared by every Java-adjacent consumer in this config.
--
-- Extracted from ftplugin/java.lua because a second consumer appeared:
-- spring-boot.nvim launches the Spring Boot Language Server with a hardcoded
-- `-XX:+UseZGC` but resolves its interpreter as bare `java` from PATH
-- (spring_boot/util.lua:27). On any machine whose PATH java is old — a Java 8
-- JRE here — that flag is an unrecognized VM option, so the JVM refuses to
-- start at all and boot-ls dies silently at launch. Both it and jdtls need
-- "find me a real, modern JDK home", so the logic lives in one place.
--
-- Why not /usr/libexec/java_home: it only knows about JDKs registered under
-- /Library/Java/JavaVirtualMachines. Homebrew's openjdk formulae are keg-only
-- and are NOT symlinked there, so the most common macOS install is invisible
-- to it. We glob the real locations instead, and cover Linux/Windows too.

local M = {}

-- Read the major version out of a JDK's `release` file, which every JDK 9+ and
-- most 8 builds ship. Returns nil when it can't be determined.
local function jdk_major(home)
  local release = home .. "/release"
  if vim.fn.filereadable(release) == 0 then return nil end
  for _, line in ipairs(vim.fn.readfile(release)) do
    -- JAVA_VERSION="21.0.5" -> 21, JAVA_VERSION="1.8.0_503" -> 1 (see below)
    local major = line:match('^JAVA_VERSION="(%d+)')
    if major then
      major = tonumber(major)
      -- Pre-9 versions are "1.8.0_x" style, where the meaningful major is the
      -- second component. Normalize so an 8 sorts below a 17 rather than as 1.
      if major == 1 then
        local legacy = line:match('^JAVA_VERSION="1%.(%d+)')
        major = legacy and tonumber(legacy) or nil
      end
      return major
    end
  end
  return nil
end

-- Resolve a candidate path to a real JDK *home* (the dir containing `release`
-- and `bin/`), or nil if it isn't one.
--
-- Needed because Homebrew's `openjdk@N` prefix is NOT a JDK home: it has a
-- working bin/java symlink but no `release` file, because the real home is
-- nested at libexec/openjdk.jdk/Contents/Home. Probing the prefix directly
-- therefore looked executable but yielded no version, so every Homebrew JDK was
-- silently discarded — the exact keg-only case this module exists to handle.
-- Handing the un-normalized prefix to Gradle/jdtls fails the same way, since
-- they read `release` too.
local function resolve_home(candidate)
  for _, home in ipairs({
    candidate,
    -- Homebrew openjdk / openjdk@N
    candidate .. "/libexec/openjdk.jdk/Contents/Home",
    -- A bare *.jdk bundle (e.g. a DMG install pointed at by JAVA_HOME)
    candidate .. "/Contents/Home",
  }) do
    if vim.fn.executable(home .. "/bin/java") == 1 and jdk_major(home) then
      return home
    end
  end
  return nil
end

local cached

-- Every usable JDK found, newest major first, as { path = string, major = n }.
-- Cached: two consumers now ask for this, and it is ~10 globs of filesystem
-- work that cannot change within a session in any way we care about.
function M.list()
  if cached then return cached end

  local candidates = {}
  if vim.env.JAVA_HOME and vim.env.JAVA_HOME ~= "" then
    table.insert(candidates, vim.env.JAVA_HOME)
  end
  table.insert(candidates, vim.fn.expand("~/.sdkman/candidates/java/current"))
  -- Newest match first within each pattern. Covers Homebrew keg-only JDKs
  -- (macOS), the standard Linux JVM dir, and Windows install roots.
  for _, pat in ipairs({
    "/opt/homebrew/opt/openjdk@*",
    "/usr/local/opt/openjdk@*",
    "/opt/homebrew/opt/openjdk",
    "/usr/local/opt/openjdk",
    "/Library/Java/JavaVirtualMachines/*/Contents/Home",
    "/usr/lib/jvm/*",
    "/usr/java/*",
    "C:/Program Files/Java/*",
    "C:/Program Files/Eclipse Adoptium/*",
  }) do
    local hits = vim.fn.glob(pat, true, true)
    table.sort(hits, function(a, b) return a > b end)
    vim.list_extend(candidates, hits)
  end

  local found, seen = {}, {}
  for _, candidate in ipairs(candidates) do
    -- No readable version => can't tell what it is; skip rather than guess,
    -- since naming a runtime "JavaSE-nil" would poison jdtls's settings.
    local home = resolve_home((candidate:gsub("/+$", "")))
    if home then
      local major = jdk_major(home)
      if major and not seen[major] then
        seen[major] = true
        table.insert(found, { path = home, major = major })
      end
    end
  end
  table.sort(found, function(a, b) return a.major > b.major end)

  cached = found
  return cached
end

-- Newest JDK that is at least `min_major`, or nil. jdtls 1.60+ hard-refuses to
-- launch below 21 (mason/packages/jdtls/bin/jdtls.py); boot-ls needs 17+.
function M.newest(min_major)
  for _, jdk in ipairs(M.list()) do
    if jdk.major >= (min_major or 21) then return jdk end
  end
  return nil
end

-- Path to a `java` binary of at least `min_major`, or nil.
function M.java_bin(min_major)
  local jdk = M.newest(min_major)
  return jdk and (jdk.path .. "/bin/java") or nil
end

-- java.configuration.runtimes for jdtls: every JDK found, newest marked
-- default. `name` must be a real Eclipse execution environment id.
function M.runtimes()
  local runtimes = {}
  for i, jdk in ipairs(M.list()) do
    table.insert(runtimes, {
      name = "JavaSE-" .. jdk.major,
      path = jdk.path,
      default = i == 1 or nil,
    })
  end
  return runtimes
end

-- Comma-joined JDK homes for Gradle's `org.gradle.java.installations.paths`.
--
-- Load-bearing for Gradle projects that declare a toolchain, e.g.
--   java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }
-- Gradle's own auto-detection has the same blind spot as java_home — it does
-- not look inside Homebrew's keg-only prefixes — so its import fails with
-- "Cannot find a Java installation on your machine matching:
-- {languageVersion=17, ...}. Toolchain download repositories have not been
-- configured." That aborts :compileClasspath resolution, which means jdtls
-- imports the project with NO classpath and therefore returns zero completions
-- while still looking perfectly healthy (server attached, no visible error).
function M.gradle_installation_paths()
  local paths = {}
  for _, jdk in ipairs(M.list()) do
    table.insert(paths, jdk.path)
  end
  return table.concat(paths, ",")
end

return M
