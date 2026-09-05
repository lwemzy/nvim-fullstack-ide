-- config.jdk — JDK discovery.
--
-- The JDK layouts are built for real on disk (a `release` file, an executable
-- bin/java) and only vim.fn.glob is faked, because glob's patterns are absolute
-- system paths that a test cannot create. That keeps jdk_major's parsing and
-- resolve_home's Homebrew nesting under test against the real filesystem calls
-- rather than against a mock of them.

local H = require("helpers")

--- Create a JDK-shaped directory. version is the raw JAVA_VERSION value.
--- opts.release = false omits the release file (an unusable candidate);
--- opts.bin = false omits bin/java.
local function make_jdk(dir, version, opts)
  opts = opts or {}
  vim.fn.mkdir(dir .. "/bin", "p")
  if opts.release ~= false then
    H.write(dir .. "/release", {
      'IMPLEMENTOR="Test"',
      ('JAVA_VERSION="%s"'):format(version),
      'OS_NAME="Darwin"',
    })
  end
  if opts.bin ~= false then
    H.write(dir .. "/bin/java", { "#!/bin/sh", "echo test" })
    vim.fn.setfperm(dir .. "/bin/java", "rwxr-xr-x")
  end
  return dir
end

--- Point config.jdk at exactly `paths` and nothing else, then load it fresh.
--- The module caches its result in a module-local, so the require cache has to
--- be dropped between cases or the first case decides them all.
---
--- Returns the module and the list of glob patterns it asked for, in order, so a
--- case can assert on *which* locations are searched rather than only on what a
--- fixture happened to return.
local function jdk_with(paths)
  package.loaded["config.jdk"] = nil
  H.stub(vim.env, "JAVA_HOME", nil)
  H.stub(vim.env, "JDK_HOME", nil)
  -- Bare `java` on PATH is a real candidate now, and on Linux /usr/bin/java is a
  -- symlink into a real JDK — so without this the machine running the suite
  -- would inject a JDK of its own into every expectation below. (It does not on
  -- macOS, where /usr/bin/java is a stub with no `release` file, which is
  -- exactly the kind of accident that makes a suite pass on one OS only.)
  H.stub(vim.fn, "exepath", function() return "" end)
  local globbed = {}
  H.stub(vim.fn, "glob", function(pat)
    table.insert(globbed, pat)
    -- All of the module's globbed candidates come from this one function;
    -- returning the full set for the first pattern and nothing after is
    -- equivalent to them being found, and keeps the fixture independent of the
    -- pattern list's order and length.
    if #globbed == 1 then return vim.deepcopy(paths) end
    return {}
  end)
  return require("config.jdk"), globbed
end

--- Make bare `java` on PATH resolve into `home`, the way /usr/bin/java does on
--- Linux. `home` need not be a JDK — the shim case is a case too.
local function fake_path_java(home)
  H.stub(vim.fn, "exepath", function(name)
    return name == "java" and (home .. "/bin/java") or ""
  end)
  -- The module resolves symlinks before deriving the home; the fixture is
  -- already a real directory, so resolve is identity here.
  H.stub(vim.fn, "resolve", function(p) return p end)
end

describe("config.jdk", function()
  local root

  before_each(function()
    root = H.tmpdir("jdk")
  end)

  after_each(function()
    package.loaded["config.jdk"] = nil
    H.cleanup()
  end)

  describe("version parsing", function()
    it("reads the major version from the release file", function()
      local jdk = jdk_with({ make_jdk(root .. "/j21", "21.0.5") })
      assert.same({ { path = root .. "/j21", major = 21 } }, jdk.list())
    end)

    it("normalises legacy 1.8.0_x versions to 8", function()
      local jdk = jdk_with({ make_jdk(root .. "/j8", "1.8.0_503") })
      local list = jdk.list()
      assert.equals(1, #list)
      -- 8, not 1: a "1" here would sort a Java 8 above a Java 21 and hand jdtls
      -- an execution environment named JavaSE-1.
      assert.equals(8, list[1].major)
    end)

    it("ignores a candidate with no release file", function()
      local jdk = jdk_with({
        make_jdk(root .. "/broken", "21", { release = false }),
        make_jdk(root .. "/j17", "17.0.9"),
      })
      assert.same({ { path = root .. "/j17", major = 17 } }, jdk.list())
    end)

    it("ignores a candidate with no java binary", function()
      local jdk = jdk_with({ make_jdk(root .. "/nobin", "21", { bin = false }) })
      assert.same({}, jdk.list())
    end)

    it("ignores a release file with no JAVA_VERSION line", function()
      local dir = make_jdk(root .. "/nover", "21")
      H.write(dir .. "/release", { 'IMPLEMENTOR="Test"' })
      local jdk = jdk_with({ dir })
      assert.same({}, jdk.list())
    end)
  end)

  describe("resolve_home", function()
    it("resolves a Homebrew keg-only prefix to libexec/openjdk.jdk/Contents/Home", function()
      -- The shape this module exists for: the prefix has a working bin/java but
      -- no release file, and the real home is nested two levels down.
      local prefix = root .. "/opt/openjdk@21"
      local home = prefix .. "/libexec/openjdk.jdk/Contents/Home"
      make_jdk(home, "21.0.5")
      vim.fn.mkdir(prefix .. "/bin", "p")
      H.write(prefix .. "/bin/java", { "#!/bin/sh", "exec " .. home .. "/bin/java \"$@\"" })
      vim.fn.setfperm(prefix .. "/bin/java", "rwxr-xr-x")

      local jdk = jdk_with({ prefix })
      -- The nested home, not the prefix: Gradle and jdtls both read `release`,
      -- so handing them the prefix fails the same way discovery did.
      assert.same({ { path = home, major = 21 } }, jdk.list())
    end)

    it("resolves a bare .jdk bundle to Contents/Home", function()
      local bundle = root .. "/temurin-17.jdk"
      local home = bundle .. "/Contents/Home"
      make_jdk(home, "17.0.9")
      local jdk = jdk_with({ bundle })
      assert.same({ { path = home, major = 17 } }, jdk.list())
    end)

    it("strips trailing slashes from candidates", function()
      make_jdk(root .. "/j21", "21.0.5")
      local jdk = jdk_with({ root .. "/j21//" })
      assert.same({ { path = root .. "/j21", major = 21 } }, jdk.list())
    end)
  end)

  describe("list", function()
    it("sorts newest major first regardless of discovery order", function()
      local jdk = jdk_with({
        make_jdk(root .. "/j17", "17.0.9"),
        make_jdk(root .. "/j25", "25.0.4"),
        make_jdk(root .. "/j8", "1.8.0_503"),
        make_jdk(root .. "/j21", "21.0.5"),
      })
      local majors = vim.tbl_map(function(j) return j.major end, jdk.list())
      assert.same({ 25, 21, 17, 8 }, majors)
    end)

    it("keeps exactly one entry per major, the highest-sorting path", function()
      local jdk = jdk_with({
        make_jdk(root .. "/openjdk-21.0.1", "21.0.1"),
        make_jdk(root .. "/openjdk-21.0.5", "21.0.5"),
      })
      local list = jdk.list()
      -- One per major, because runtimes() turns these into Eclipse execution
      -- environment ids and two JavaSE-21 entries would be invalid.
      assert.equals(1, #list)
      -- The survivor is decided by the descending sort M.list applies to each
      -- glob's hits, which is how "openjdk@21.0.5" beats "openjdk@21.0.1"
      -- without parsing the minor version.
      assert.equals(root .. "/openjdk-21.0.5", list[1].path)
    end)

    it("prefers JAVA_HOME over globbed candidates", function()
      local home = make_jdk(root .. "/java-home-21", "21.0.5")
      make_jdk(root .. "/glob-21", "21.0.1")
      local jdk = jdk_with({ root .. "/glob-21" })
      H.stub(vim.env, "JAVA_HOME", home)
      -- Same major, so the dedupe decides — and JAVA_HOME is inserted first
      -- precisely so an explicit choice wins.
      assert.equals(home, jdk.list()[1].path)
    end)

    it("reads $JDK_HOME as well as $JAVA_HOME", function()
      -- Gradle and several JDK installers set JDK_HOME and not JAVA_HOME, so a
      -- machine whose only JDK is named that way looked JDK-less.
      local home = make_jdk(root .. "/jdk-home-21", "21.0.5")
      local jdk = jdk_with({})
      H.stub(vim.env, "JDK_HOME", home)
      assert.equals(home, assert(jdk.server_jdk(21)).path)
    end)

    it("searches every installed sdkman JDK, not only the selected one", function()
      -- The bug: only ~/.sdkman/candidates/java/current was probed, so a machine
      -- with 21 installed but 17 selected reported no JDK 21 at all — and jdtls,
      -- which refuses to launch below 21, silently never started. `current` is
      -- still searched first so an explicit `sdk use` wins the same-major dedupe.
      local _, globbed = jdk_with({})
      require("config.jdk").list()
      local current = vim.fn.index(globbed, "~/.sdkman/candidates/java/current")
      local all = vim.fn.index(globbed, "~/.sdkman/candidates/java/*")
      assert.is_true(current >= 0, "sdkman's selected JDK is not searched")
      assert.is_true(all >= 0, "sdkman's other installed JDKs are not searched")
      assert.is_true(current < all, "the selected JDK must be searched first")
    end)

    it("searches the version-manager and IntelliJ install dirs", function()
      -- These are shim-based (jenv/asdf/mise) or IDE-managed, so nothing on PATH
      -- or under /usr/lib/jvm points at them — on a Linux box IntelliJ's ~/.jdks
      -- is very often the only JDK present.
      local _, globbed = jdk_with({})
      require("config.jdk").list()
      for _, pat in ipairs({
        "~/.jdks/*",
        "~/.local/share/mise/installs/java/*",
        "~/.asdf/installs/java/*",
      }) do
        assert.is_true(vim.fn.index(globbed, pat) >= 0, pat .. " is not searched")
      end
    end)

    it("falls back to bare java on PATH when no known location matches", function()
      -- The catch-all, and the reason ftplugin/java.lua can now treat "no JDK
      -- 21+" as fatal: this is the same JDK the mason jdtls launcher would pick
      -- for itself given no --java-executable, so once it is a candidate here,
      -- nil really does mean nothing on the machine can run jdtls. Covers Nix, a
      -- hand-unpacked tarball, and any distro layout not globbed above.
      local jdk = jdk_with({})
      fake_path_java(make_jdk(root .. "/path-jdk-21", "21.0.5"))
      assert.equals(root .. "/path-jdk-21", assert(jdk.server_jdk(21)).path)
    end)

    it("ignores a PATH java that is a version-manager shim", function()
      -- jenv/asdf put a wrapper *script* on PATH, so ../.. is the manager's own
      -- directory and not a JDK home. Accepting it would register a runtime with
      -- no `release` file, which poisons jdtls's java.configuration.runtimes.
      local shim = root .. "/.jenv"
      vim.fn.mkdir(shim .. "/bin", "p")
      H.write(shim .. "/bin/java", { "#!/bin/sh", "exec real-java \"$@\"" })
      vim.fn.setfperm(shim .. "/bin/java", "rwxr-xr-x")
      local jdk = jdk_with({})
      fake_path_java(shim)
      -- Executable bin/java, but no release file anywhere resolve_home looks.
      assert.same({}, jdk.list())
    end)

    it("prefers JAVA_HOME over bare java on PATH", function()
      -- PATH java is a fallback, not an override: a project switched with
      -- JAVA_HOME must not lose to whatever the shell's default happens to be.
      local home = make_jdk(root .. "/env-21", "21.0.5")
      local jdk = jdk_with({})
      fake_path_java(make_jdk(root .. "/path-21", "21.0.1"))
      H.stub(vim.env, "JAVA_HOME", home)
      assert.equals(home, jdk.list()[1].path)
    end)

    it("caches, so repeated consumers do not re-glob", function()
      local jdk = jdk_with({ make_jdk(root .. "/j21", "21.0.5") })
      local first = jdk.list()
      local globs = H.spy(vim.fn, "glob", function() return {} end)
      local second = jdk.list()
      assert.equals(0, globs.count)
      assert.equals(first, second)
    end)
  end)

  describe("server_jdk", function()
    it("returns the newest LTS at or above the minimum", function()
      local jdk = jdk_with({
        make_jdk(root .. "/j25", "25.0.4"),
        make_jdk(root .. "/j17", "17.0.9"),
        make_jdk(root .. "/j8", "1.8.0_503"),
      })
      assert.equals(25, jdk.server_jdk(17).major)
      assert.equals(25, jdk.server_jdk(21).major)
      -- min_major is a floor, not a preference: an old JDK is never chosen just
      -- because it matches more exactly.
      assert.equals(25, jdk.server_jdk(8).major)
    end)

    it("skips a newer non-LTS release in favour of the LTS below it", function()
      -- The case this exists for: this machine has both, and was launching jdtls
      -- on 26. The host JVM for a long-lived Eclipse/OSGi server is where an LTS
      -- is worth having — a non-LTS gets six months of updates and is where JEP
      -- removals land first.
      local jdk = jdk_with({
        make_jdk(root .. "/j26", "26.0.2"),
        make_jdk(root .. "/j25", "25.0.4"),
      })
      assert.equals(25, jdk.server_jdk(21).major)
      -- ...and 26 is still discovered, so it can be registered as a runtime and
      -- targeted by a project. Capping the host must not cap the compiler.
      assert.equals(26, jdk.list()[1].major)
    end)

    it("uses a non-LTS release when it is the only qualifying JDK", function()
      -- Preference, not a requirement. On a machine whose only JDK is 26 this is
      -- the difference between a working server and none at all.
      local jdk = jdk_with({
        make_jdk(root .. "/j26", "26.0.2"),
        make_jdk(root .. "/j17", "17.0.9"),
      })
      assert.equals(26, jdk.server_jdk(21).major)
    end)

    it("recognises an LTS released after this config was written", function()
      -- The cadence is every fourth release from 21, encoded as a rule rather
      -- than a list so 29 does not have to be a code change in 2027.
      local jdk = jdk_with({
        make_jdk(root .. "/j31", "31.0.1"),
        make_jdk(root .. "/j29", "29.0.1"),
        make_jdk(root .. "/j25", "25.0.4"),
      })
      assert.equals(29, jdk.server_jdk(21).major)
    end)

    it("returns nil when nothing meets the minimum", function()
      local jdk = jdk_with({ make_jdk(root .. "/j8", "1.8.0_503") })
      -- jdtls hard-refuses to launch below 21; a wrong answer here would be a
      -- server that dies at startup instead of a clean "no suitable JDK".
      assert.is_nil(jdk.server_jdk(21))
    end)

    it("defaults the minimum to 21", function()
      local jdk = jdk_with({ make_jdk(root .. "/j17", "17.0.9") })
      assert.is_nil(jdk.server_jdk())
    end)
  end)

  describe("java_bin", function()
    it("returns bin/java of the newest matching JDK", function()
      local jdk = jdk_with({ make_jdk(root .. "/j21", "21.0.5") })
      assert.equals(root .. "/j21/bin/java", jdk.java_bin(17))
    end)

    it("returns nil rather than a bare 'java' when nothing matches", function()
      -- spring-boot.nvim falls back to PATH java when this is nil; returning a
      -- path that does not exist would be worse than saying so.
      local jdk = jdk_with({})
      assert.is_nil(jdk.java_bin(17))
    end)
  end)

  describe("runtimes", function()
    it("names each runtime JavaSE-<major> and marks only the newest default", function()
      local jdk = jdk_with({
        make_jdk(root .. "/j21", "21.0.5"),
        make_jdk(root .. "/j17", "17.0.9"),
      })
      assert.same({
        { name = "JavaSE-21", path = root .. "/j21", default = true },
        { name = "JavaSE-17", path = root .. "/j17" },
      }, jdk.runtimes())
    end)

    it("is empty when no JDK was found", function()
      assert.same({}, jdk_with({}).runtimes())
    end)
  end)

  describe("gradle_installation_paths", function()
    it("comma-joins every JDK home, newest first", function()
      local jdk = jdk_with({
        make_jdk(root .. "/j17", "17.0.9"),
        make_jdk(root .. "/j21", "21.0.5"),
      })
      assert.equals(root .. "/j21," .. root .. "/j17", jdk.gradle_installation_paths())
    end)

    it("is an empty string when no JDK was found", function()
      -- Passed straight into -Porg.gradle.java.installations.paths=, so it must
      -- be a string in every case.
      assert.equals("", jdk_with({}).gradle_installation_paths())
    end)
  end)
end)
