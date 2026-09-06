-- Bounded upward file search.
--
-- vim.fs.find({ upward = true }) walks to `/` unless given a `stop`, which makes
-- "does this project have X?" answerable by a file that has nothing to do with
-- the project. A stray ~/.prettierrc marked every JS/TS project on the machine as
-- having its own formatting opinion; a stray ~/pom.xml made every loose .java
-- file look like a Spring Boot project. Both are single-file, whole-machine
-- behaviour changes with no visible cause, which is the worst kind.
--
-- Shared rather than inlined at each call site because the ceiling is a judgement
-- call (below), and two copies of a judgement call drift.

local M = {}

--- Normalised and symlink-resolved, including for a path that does not exist yet.
---
--- The not-yet-existing case is not exotic: a buffer for a new file in a new
--- directory (which this config's auto_create_dir autocmd exists to support) has
--- exactly that name, and fs_realpath returns nil for it. Normalising alone would
--- then leave an UNRESOLVED path being compared against a resolved ceiling, which
--- is the very mismatch described below — so resolve the deepest ancestor that
--- does exist and re-attach the rest.
---
--- EVERY path this module compares goes through here, and that consistency is the
--- point. vim.fs.find compares `stop` against vim.fs.parents() output with raw
--- string equality (runtime/lua/vim/fs.lua: `if stop and parent == stop`), and
--- parents() just chops components off the path it was given — it resolves
--- nothing. So a bound and a starting directory that disagree about symlinks or
--- trailing slashes never meet, the comparison silently never fires, and the walk
--- reaches `/` exactly as if no bound had been passed. Two ways that happens in
--- practice: `HOME` set with a trailing slash or via a symlink, and a project
--- opened through a symlinked path (macOS's /var, which is really /private/var,
--- or a checkout reached through a symlinked parent).
local function resolve(path)
  path = vim.fs.normalize(path)
  local real = vim.uv.fs_realpath(path)
  if real then return vim.fs.normalize(real) end
  local parent = vim.fs.dirname(path)
  if parent == path then return path end -- at the root; nothing left to resolve
  local resolved = resolve(parent)
  return (resolved == "/" and "" or resolved) .. "/" .. vim.fs.basename(path)
end

--- $HOME, resolved, or nil if there is no usable one.
local function home()
  local h = vim.uv.os_homedir()
  if not h or h == "" then return nil end
  return resolve(h)
end

--- The directory a search starts from: a buffer's own directory, or `source`
--- itself when it is already a directory path.
---
--- The string form exists for config.runner, whose question ("which project am I
--- looking at?") has to be answerable from a buffer that has no file name at all
--- — a terminal, the Claude panel, the dashboard — where the cwd is the only
--- thing that says which project the user is in. Returning nil for the nameless
--- case is what the file-name form does instead, and every caller of that one
--- depends on it (see find_upward below).
local function start_dir(source)
  if type(source) == "string" then return resolve(source) end
  local name = vim.api.nvim_buf_get_name(source or 0)
  if name == "" then return nil end
  return resolve(vim.fs.dirname(name))
end

--- The directory to stop at, exclusive: `stop` is never itself searched.
---
--- The parent of the VCS root, so the search covers the whole project and nothing
--- above it. The VCS root rather than the nearest package.json / pom.xml: in a
--- monorepo or a multi-module Maven build those stop at the package, hiding the
--- shared config at the repository root that the package actually inherits.
---
--- Never above $HOME, whatever the markers say. `~/.git` (a dotfiles repo) is a
--- common setup and would otherwise put $HOME *inside* the searched range and
--- hand every project under it the ~/.prettierrc and ~/pom.xml this module exists
--- to ignore.
---
--- `fallback_markers` are consulted only when there is no VCS root at all, where
--- without them a project outside $HOME has no bound whatsoever ($HOME matches no
--- parent, so the walk reaches `/`). The OUTERMOST match wins, which keeps
--- multi-module builds working. The cost of that choice: a stray build file
--- immediately above such a project is read as its parent module. With no VCS
--- root the two are indistinguishable on disk, so this picks the reading that
--- breaks real projects less often.
---
--- `source` is a buffer number (default: the current buffer) or a directory path.
function M.ceiling(source, fallback_markers)
  local h = home()

  -- vim.fs.root takes either form itself, and for a buffer with no name it falls
  -- back to the cwd — which is the same answer start_dir's string form gives.
  local root = vim.fs.root(source or 0, { ".git", ".hg", ".svn" })
  if root then
    root = resolve(root)
    -- Not `root ~= h`: a VCS root that is an *ancestor* of $HOME (`/` under
    -- version control) has to be clamped the same way $HOME itself is.
    local under_root = h and (root == h or vim.startswith(h, root == "/" and "/" or root .. "/"))
    if not under_root then return vim.fs.dirname(root) end
    return h
  end

  if fallback_markers then
    local found = M.find_upward(source, fallback_markers, { limit = math.huge }, h)
    local outermost = found[#found]
    if outermost then return vim.fs.dirname(vim.fs.dirname(outermost)) end
  end

  return h
end

--- vim.fs.find upward from the buffer's own directory, bounded by M.ceiling.
---
--- `source` is a buffer number (default: the current buffer) or a directory to
--- search from. `opts.limit` is passed through to vim.fs.find;
--- `opts.fallback_markers` is forwarded to M.ceiling. `stop` overrides the ceiling
--- outright and exists so M.ceiling can call this without recursing.
function M.find_upward(source, names, opts, stop)
  local dir = start_dir(source or 0)
  if not dir then return {} end
  opts = opts or {}
  stop = stop or M.ceiling(source, opts.fallback_markers)

  -- vim.fs.find tests `path` itself BEFORE it starts comparing parents against
  -- `stop` (runtime/lua/vim/fs.lua), so the starting directory is searched even
  -- when it *is* the ceiling — which for a loose ~/Scratch.java means reading
  -- exactly the ~/pom.xml the ceiling is there to exclude.
  if stop and dir == stop then return {} end

  -- The search fields are set here rather than merged from `opts`: a caller that
  -- overrode `stop` or `path` would be opting out of the bound, which is the one
  -- thing this function is for.
  return vim.fs.find(names, { path = dir, upward = true, stop = stop, limit = opts.limit })
end

-- ── Java build files ────────────────────────────────────────────────────────

--- The build files that mark a Java project, in the order vim.fs.find matches
--- them. Also usable as `fallback_markers`: a Java project with no version
--- control has nothing else to say where it begins, and without them the search
--- is unbounded for one that also sits outside $HOME.
M.JAVA_BUILD_FILES = { "pom.xml", "build.gradle", "build.gradle.kts" }

--- Every Java build file from `source` up to the project root, nearest first.
---
--- limit = math.huge rather than the nearest one, because a multi-module build
--- declares its dependencies (and its Spring Boot plugin) in the parent: stopping
--- at the module reads a file that inherits everything interesting.
function M.java_build_files(source)
  return M.find_upward(source, M.JAVA_BUILD_FILES, {
    limit = math.huge,
    fallback_markers = M.JAVA_BUILD_FILES,
  })
end

--- Does any build file above `source` actually declare Spring Boot?
---
--- Checks build.gradle/build.gradle.kts/pom.xml content for the
--- org.springframework.boot group id, which is present as either a Gradle plugin
--- id or a Maven/Gradle dependency coordinate in essentially every real Spring
--- Boot project.
---
--- Shared by two callers that must agree: lua/plugins/java.lua decides whether to
--- start the Spring Boot Language Server for a .java buffer, and config.runner
--- decides whether the toolbar offers `bootRun`/`spring-boot:run` instead of a
--- plain main-class launch. Two copies of this heuristic would drift into a
--- project whose properties complete but whose Run button runs the wrong thing.
function M.declares_spring_boot(source)
  for _, file in ipairs(M.java_build_files(source)) do
    local ok, lines = pcall(vim.fn.readfile, file)
    if ok and table.concat(lines, "\n"):find("org%.springframework%.boot") then
      return true
    end
  end
  return false
end

return M
