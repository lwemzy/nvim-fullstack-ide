-- config.project — the bounded upward file search shared by the "does this
-- project have X?" checks in lua/plugins/editor.lua (prettier config) and
-- lua/plugins/java.lua (Spring Boot build files).
--
-- The bound is the whole subject. An unbounded vim.fs.find({ upward = true })
-- walks to `/`, so one stray dotfile in $HOME silently answers the question for
-- every project on the machine — which is exactly what used to happen. Every
-- case here is therefore about which directories the search may and may not
-- reach, built on the real filesystem: vim.fs.find's `stop` semantics are the
-- thing under test, and a fake of it would only restate this module's own code.

local H = require("helpers")

local project = require("config.project")

--- Realpath both sides before comparing. macOS's temp dir lives behind the
--- /var -> /private/var symlink, and nvim stores a buffer's name resolved, so
--- the raw H.tmpdir string would compare unequal for that reason alone.
local function same_path(expected, actual)
  assert.equals(vim.uv.fs_realpath(expected), vim.uv.fs_realpath(actual))
end

--- Point $HOME at `dir` until cleanup.
---
--- vim.uv.os_homedir() reads $HOME on unix, so this is what makes the $HOME
--- clamp testable at all: the real $HOME is an ancestor of nothing a spec can
--- build, and the cases that matter (a dotfiles repo at $HOME, a loose file
--- sitting directly in it) are exactly the ones that need $HOME to be somewhere
--- writable.
local function fake_home(dir)
  H.stub(vim.env, "HOME", dir)
  return dir
end

--- A repo-shaped tree: <root>/.git plus <sub> beneath it, and a buffer named
--- after a file in <sub> (never loaded — the buffer *name* is the whole input).
local function repo(label, sub)
  local root = H.tmpdir(label)
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/" .. sub, "p")
  local bufnr = H.named_buf(root .. "/" .. sub .. "/file.txt")
  return root, bufnr
end

describe("config.project", function()
  after_each(function()
    H.cleanup()
  end)

  describe("ceiling", function()
    it("is the parent of the VCS root", function()
      -- Exclusive, so the parent is what makes the VCS root itself searchable.
      local root, bufnr = repo("ceil-git", "src/deep")
      same_path(vim.fs.dirname(root), project.ceiling(bufnr))
    end)

    it("recognises .hg and .svn as roots too", function()
      -- Not decoration: a Mercurial or Subversion checkout has no .git, and
      -- without these markers the ceiling silently degrades to $HOME.
      for _, marker in ipairs({ ".hg", ".svn" }) do
        local root = H.tmpdir("ceil-" .. marker:sub(2))
        vim.fn.mkdir(root .. "/" .. marker, "p")
        vim.fn.mkdir(root .. "/pkg", "p")
        local bufnr = H.named_buf(root .. "/pkg/file.txt")
        same_path(vim.fs.dirname(root), project.ceiling(bufnr))
      end
    end)

    it("falls back to $HOME, not its parent, with no VCS root", function()
      -- $HOME itself and not vim.fs.dirname($HOME): the dotfiles that caused the
      -- original bug (~/.prettierrc, ~/pom.xml) sit directly in $HOME, and since
      -- `stop` is exclusive only naming $HOME excludes them.
      local bufnr = H.named_buf(H.tmpdir("ceil-none") .. "/loose.txt")
      assert.equals(vim.uv.os_homedir(), project.ceiling(bufnr))
    end)

    it("stops at the nearest VCS root, not the outermost one", function()
      -- A vendored or nested checkout: the inner repo is the project, so its
      -- parent is the bound even though an outer .git exists further up.
      local outer = H.tmpdir("ceil-nested")
      vim.fn.mkdir(outer .. "/.git", "p")
      local inner = outer .. "/vendor/dep"
      vim.fn.mkdir(inner .. "/.git", "p")
      vim.fn.mkdir(inner .. "/src", "p")
      local bufnr = H.named_buf(inner .. "/src/file.txt")
      same_path(outer .. "/vendor", project.ceiling(bufnr))
    end)

    it("clamps to $HOME when $HOME is itself a VCS root", function()
      -- A dotfiles repo (`git init` in $HOME) is a common setup, and the parent
      -- of that root is the parent of $HOME — which puts $HOME *inside* the
      -- searched range and hands every project under it the ~/.prettierrc and
      -- ~/pom.xml this module exists to ignore.
      local h = fake_home(H.tmpdir("home-is-repo"))
      vim.fn.mkdir(h .. "/.git", "p")
      vim.fn.mkdir(h .. "/project/src", "p")
      local bufnr = H.named_buf(h .. "/project/src/file.txt")
      same_path(h, project.ceiling(bufnr))
    end)

    it("clamps to $HOME when the VCS root is above $HOME", function()
      -- `/` under version control, or $HOME inside a checkout. Comparing for
      -- equality with $HOME alone would miss this and the clamp would not fire.
      local container = H.tmpdir("repo-above-home")
      vim.fn.mkdir(container .. "/.git", "p")
      local h = fake_home(container .. "/home")
      vim.fn.mkdir(h .. "/project", "p")
      local bufnr = H.named_buf(h .. "/project/file.txt")
      same_path(h, project.ceiling(bufnr))
    end)

    it("bounds at the outermost fallback marker when there is no VCS root", function()
      -- A multi-module build with no version control and outside $HOME: nothing
      -- else says where it begins, so without the fallback the search has no
      -- bound whatsoever. The OUTERMOST marker wins so the parent module stays
      -- readable from the child.
      local container = H.tmpdir("fallback-outermost")
      fake_home(H.tmpdir("fallback-elsewhere"))
      local module = container .. "/outer/module"
      vim.fn.mkdir(module .. "/src", "p")
      H.write(container .. "/outer/pom.xml", { "<project/>" })
      H.write(module .. "/pom.xml", { "<project/>" })
      local bufnr = H.named_buf(module .. "/src/file.txt")
      same_path(container, project.ceiling(bufnr, { "pom.xml" }))
    end)
  end)

  describe("find_upward", function()
    it("finds a file at the project root from a nested directory", function()
      -- The reason the ceiling is the root's *parent*: a config at the repo root
      -- has to remain visible from a package deep inside it.
      local root, bufnr = repo("up-root", "packages/app/src")
      local marker = H.write(root .. "/.prettierrc", { "{}" })
      same_path(marker, assert(project.find_upward(bufnr, ".prettierrc")[1]))
    end)

    it("finds a file in the buffer's own directory", function()
      local root, bufnr = repo("up-own", "packages/app")
      local marker = H.write(root .. "/packages/app/pom.xml", { "<project/>" })
      same_path(marker, assert(project.find_upward(bufnr, "pom.xml")[1]))
    end)

    it("does not look above the VCS root", function()
      -- The bug this module exists for. The file sits one level above the repo,
      -- which stands in for $HOME: before the bound, this was found and every
      -- project on the machine inherited it.
      local root, bufnr = repo("up-bound", "src")
      local outside = H.write(vim.fs.dirname(root) .. "/.prettierrc", { "{}" })
      assert.same({}, project.find_upward(bufnr, ".prettierrc"))
      -- Confirm the file really is there, so the empty result cannot be a
      -- mis-built fixture passing for a working bound.
      assert.equals(1, vim.fn.filereadable(outside))
    end)

    it("returns every match up to the root when limit allows", function()
      -- How java.lua reads multi-module builds: the module's own pom.xml AND the
      -- parent that declares spring-boot, nearest first.
      local root, bufnr = repo("up-limit", "module")
      local child = H.write(root .. "/module/pom.xml", { "<project/>" })
      local parent = H.write(root .. "/pom.xml", { "<project/>" })
      local found = project.find_upward(bufnr, "pom.xml", { limit = math.huge })
      assert.equals(2, #found)
      same_path(child, found[1])
      same_path(parent, found[2])
    end)

    it("returns only the nearest match by default", function()
      -- vim.fs.find's own default limit of 1, relied on by the prettier check:
      -- the nearest config wins and the walk stops there.
      local root, bufnr = repo("up-default", "module")
      local child = H.write(root .. "/module/pom.xml", { "<project/>" })
      H.write(root .. "/pom.xml", { "<project/>" })
      local found = project.find_upward(bufnr, "pom.xml")
      assert.equals(1, #found)
      same_path(child, found[1])
    end)

    it("accepts a list of names and reports whichever exists", function()
      local root, bufnr = repo("up-names", "src")
      local marker = H.write(root .. "/build.gradle.kts", { "" })
      local found = project.find_upward(bufnr, { "pom.xml", "build.gradle", "build.gradle.kts" })
      same_path(marker, assert(found[1]))
    end)

    it("returns an empty list for a buffer with no file name", function()
      -- Without this guard the search would start at dirname("") — the cwd —
      -- and answer a question about the wrong tree entirely. Every caller
      -- indexes [1] on the result, so it must be a list and not nil.
      local bufnr = H.track_buf(vim.api.nvim_create_buf(true, true))
      assert.same({}, project.find_upward(bufnr, "pom.xml"))
    end)

    it("finds nothing when the file simply is not there", function()
      local _, bufnr = repo("up-absent", "src")
      assert.same({}, project.find_upward(bufnr, "pom.xml"))
    end)

    it("does not read $HOME's own config for a loose file in $HOME", function()
      -- vim.fs.find tests `path` itself BEFORE it starts comparing parents
      -- against `stop`, so the starting directory is searched even when it *is*
      -- the ceiling. For a scratch file saved straight into $HOME that means
      -- reading exactly the ~/.prettierrc the ceiling is there to exclude, and
      -- the guard in find_upward is the only thing that prevents it.
      local h = fake_home(H.tmpdir("home-loose"))
      local marker = H.write(h .. "/.prettierrc", { "{}" })
      local bufnr = H.named_buf(h .. "/Scratch.txt")
      assert.same({}, project.find_upward(bufnr, ".prettierrc"))
      assert.equals(1, vim.fn.filereadable(marker))
    end)

    it("keeps the bound when $HOME is unnormalised and reached by a symlink", function()
      -- `stop` is compared against vim.fs.parents() output by raw string
      -- equality, so a $HOME with a trailing slash or a symlinked component
      -- matches no parent at all and the walk silently runs to `/` — the exact
      -- unbounded behaviour this module exists to remove, with no visible cause.
      local container = H.tmpdir("home-symlink")
      local real = container .. "/real-home"
      vim.fn.mkdir(real .. "/project", "p")
      assert(vim.uv.fs_symlink(real, container .. "/link"))
      fake_home(container .. "/link/") -- trailing slash AND a symlink

      local above = H.write(container .. "/.prettierrc", { "{}" })
      local bufnr = H.named_buf(real .. "/project/file.txt")
      assert.same({}, project.find_upward(bufnr, ".prettierrc"))
      assert.equals(1, vim.fn.filereadable(above))
    end)

    it("bounds a buffer whose directory does not exist yet", function()
      -- `:e src/new/thing.ts` in a directory that has not been created (what
      -- auto_create_dir in config/autocmds.lua exists for) names a path that
      -- cannot be symlink-resolved, because it is not on disk. Leaving it
      -- unresolved makes it incomparable with the resolved ceiling, and the bound
      -- silently disappears for exactly those buffers.
      local container = H.tmpdir("dir-missing")
      local root = container .. "/repo"
      vim.fn.mkdir(root .. "/.git", "p")
      local above = H.write(container .. "/.prettierrc", { "{}" })
      local bufnr = H.named_buf(root .. "/does/not/exist/file.txt")

      assert.same({}, project.find_upward(bufnr, ".prettierrc"))
      assert.equals(1, vim.fn.filereadable(above))

      -- And the search still reaches the project itself, so the empty result
      -- above is a bound and not a walk that never started.
      local inside = H.write(root .. "/.prettierrc", { "{}" })
      same_path(inside, assert(project.find_upward(bufnr, ".prettierrc")[1]))
    end)

    it("bounds a symlinked project path against the resolved ceiling", function()
      -- The other side of the same coin: the ceiling resolves symlinks, so the
      -- starting directory has to as well. A project opened through a symlinked
      -- parent (macOS's /var -> /private/var, a checkout reached via a symlink)
      -- otherwise produces parents that can never equal the bound.
      local container = H.tmpdir("path-symlink")
      local h = fake_home(container .. "/home")
      vim.fn.mkdir(h .. "/project/src", "p")
      assert(vim.uv.fs_symlink(h .. "/project", container .. "/link"))

      local above = H.write(container .. "/.prettierrc", { "{}" })
      local bufnr = H.named_buf(container .. "/link/src/file.txt")
      assert.same({}, project.find_upward(bufnr, ".prettierrc"))
      assert.equals(1, vim.fn.filereadable(above))
    end)

    describe("searching from a directory instead of a buffer", function()
      -- config.runner needs this form: "which project am I looking at?" has to be
      -- answerable while a buffer with no file name is focused — a terminal, the
      -- Claude panel, the dashboard — where the cwd is the only thing that says
      -- which project the user is in.
      it("accepts a directory path in place of a buffer number", function()
        local root, _ = repo("dir-form", "src/deep")
        local marker = H.write(root .. "/.prettierrc", { "{}" })
        same_path(marker, assert(project.find_upward(root .. "/src/deep", ".prettierrc")[1]))
      end)

      it("bounds a directory search exactly as it bounds a buffer's", function()
        -- The bound is the whole point of this module, so the new entry point must
        -- not be a way around it.
        local container = H.tmpdir("dir-form-bound")
        local root = container .. "/repo"
        vim.fn.mkdir(root .. "/src", "p")
        vim.fn.mkdir(root .. "/.git", "p")
        local above = H.write(container .. "/.prettierrc", { "{}" })
        assert.same({}, project.find_upward(root .. "/src", ".prettierrc"))
        assert.equals(1, vim.fn.filereadable(above))
      end)

      it("finds nothing for a buffer with no name, which is why the string form exists", function()
        -- Unchanged behaviour, and depended on by every other caller: an unnamed
        -- buffer has no directory of its own, and guessing the cwd for all of them
        -- would hand loose scratch buffers whatever project the shell was in.
        assert.same({}, project.find_upward(H.scratch(), ".prettierrc"))
      end)
    end)
  end)

  describe("java_build_files", function()
    it("returns every build file up to the project root, nearest first", function()
      -- Nearest first is what lets config.runner run Gradle/Maven in the module
      -- the open file belongs to; the outer ones still matter because a
      -- multi-module build declares its dependencies in the parent.
      local root = H.tmpdir("java-modules")
      vim.fn.mkdir(root .. "/.git", "p")
      H.write(root .. "/pom.xml", { "<project/>" })
      H.write(root .. "/api/pom.xml", { "<project/>" })
      local found = project.java_build_files(root .. "/api/src/main/java")
      assert.equals(2, #found)
      same_path(root .. "/api/pom.xml", found[1])
      same_path(root .. "/pom.xml", found[2])
    end)

    it("recognises Gradle's Kotlin DSL as well as Groovy", function()
      local root = H.tmpdir("java-kts")
      vim.fn.mkdir(root .. "/.git", "p")
      local build = H.write(root .. "/build.gradle.kts", { "plugins {}" })
      same_path(build, assert(project.java_build_files(root .. "/src")[1]))
    end)
  end)

  describe("declares_spring_boot", function()
    -- Shared by lua/plugins/java.lua (start the Spring Boot Language Server?) and
    -- config.runner (offer bootRun, or a plain main class?). The two disagreeing
    -- would mean a project whose properties complete but whose Run button runs the
    -- wrong thing, which is why there is one implementation.
    local function project_with(files)
      local root = H.tmpdir("spring-detect")
      vim.fn.mkdir(root .. "/.git", "p")
      for name, contents in pairs(files) do
        H.write(root .. "/" .. name, contents)
      end
      return root
    end

    it("sees the Gradle plugin id", function()
      local root = project_with({
        ["build.gradle"] = { "plugins { id 'org.springframework.boot' version '3.3.4' }" },
      })
      assert.is_true(project.declares_spring_boot(root .. "/src/main/java"))
    end)

    it("sees a Maven parent that the module inherits", function()
      -- The module's own pom says nothing about Spring; stopping at the nearest
      -- build file is how boot-ls used to miss multi-module projects entirely.
      local root = project_with({
        ["pom.xml"] = { "<parent><groupId>org.springframework.boot</groupId></parent>" },
        ["api/pom.xml"] = { "<project><artifactId>api</artifactId></project>" },
      })
      assert.is_true(project.declares_spring_boot(root .. "/api/src/main/java"))
    end)

    it("is false for a Java project that is not Spring", function()
      local root = project_with({ ["build.gradle"] = { "plugins { id 'application' }" } })
      assert.is_false(project.declares_spring_boot(root .. "/src/main/java"))
    end)

    it("ignores a Spring build file above the project root", function()
      -- The original bug: an unbounded search made every loose .java file on the
      -- machine look like a Spring project because of one pom.xml in $HOME.
      local container = H.tmpdir("spring-above")
      local root = container .. "/repo"
      vim.fn.mkdir(root .. "/src", "p")
      vim.fn.mkdir(root .. "/.git", "p")
      H.write(container .. "/pom.xml", { "<groupId>org.springframework.boot</groupId>" })
      assert.is_false(project.declares_spring_boot(root .. "/src"))
    end)
  end)
end)
