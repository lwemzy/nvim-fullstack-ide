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
  end)
end)
