-- Jump between a file and its counterpart: class <-> test, component <-> template.
--
-- The pair is already decided by convention — Maven and Gradle both mandate
-- src/main/java and src/test/java with mirrored package directories, and the
-- Angular CLI generates foo.component.{ts,html,scss,spec.ts} as a set — but
-- nothing in this config knew it. Reaching a test meant the file picker and
-- retyping a name the project layout had already determined, which is the kind
-- of friction that ends with the test not being opened.
--
-- Grepped before writing this: `config.project` does bounded *upward* search
-- ("which project is this file in?"), which is a different question and cannot
-- answer this one — the counterpart is a sideways path transform, and src/test
-- is not an ancestor of src/main. None of the installed plugins cover it either
-- (checked telescope, nvim-tree, nvim-jdtls: jdtls has no textDocument/test
-- navigation request, only test *discovery* through java-test).
--
-- Pressing the key repeatedly walks the whole set rather than flipping between
-- two files. That is deliberate for Angular, where a component is three or four
-- files and no single one of them is "the other half": .ts -> .html -> .scss ->
-- .spec.ts -> .ts. For a Java class or a plain .ts module the set has two
-- members, so the walk is a toggle.

local M = {}

--- Test-class name suffixes, in the order they are offered.
---
--- Test first because it is what every generator emits and what Surefire's
--- default includes match first; Tests and IT are accepted because real projects
--- use them (IT is Failsafe's integration-test convention, and a project that
--- splits unit from integration tests names them that way).
local JAVA_TEST_SUFFIXES = { "Test", "Tests", "IT" }

--- Script extensions whose counterpart is a sibling spec file.
local SCRIPT_EXTS = { ts = true, tsx = true, js = true, jsx = true, mts = true, cts = true, mjs = true, cjs = true }

--- The infix that marks a script as the test of its sibling: foo.spec.ts.
local SCRIPT_TEST_INFIXES = { "spec", "test" }

--- Extensions an Angular component owns besides its .ts.
---
--- Both .scss and .css are listed because which one a project uses is a flag
--- passed to `ng new` months earlier; offering both and letting the existence
--- check decide is cheaper than reading angular.json.
local COMPONENT_EXTS = { "html", "scss", "css", "less", "sass" }

--- Which `.<word>.ts` suffixes are component-shaped, i.e. own a template and a
--- stylesheet. A service, pipe, guard or interceptor has a spec and nothing else,
--- so offering it an .html is offering a file that should never exist.
local COMPONENT_KINDS = { component = true, page = true, view = true }

local function exists(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

--- Rotate `ring` so the element after `current` comes first, and drop `current`.
---
--- The rotation is what makes repeated presses walk the set: the candidate list
--- is always read from where you are standing, so the answer depends on the
--- current file rather than on a fixed "primary" member. A `current` that is not
--- in the ring cannot happen (every rule builds the ring around it) but is
--- handled as "no rotation" rather than an error.
local function rotate(ring, current)
  local at
  for i, path in ipairs(ring) do
    if path == current then
      at = i
      break
    end
  end
  local out = {}
  for i = 1, #ring do
    local path = ring[((at or 1) + i - 1) % #ring + 1]
    if path ~= current then table.insert(out, path) end
  end
  return out
end

-- ── Java ────────────────────────────────────────────────────────────────────

--- Split an absolute .java path into { root, source set, package dir, class }.
---
--- Anchored on `/src/<set>/java/` rather than on the project root, because that
--- segment is the whole convention: it is what Maven and Gradle agree on, and it
--- is also what says which half of the pair the file is in. A .java file outside
--- it (a loose scratch file, or a non-standard layout) has no derivable
--- counterpart, and returning nil for it is more honest than guessing.
local function java_parts(path)
  local root, set, rest = path:match("^(.*)/src/([^/]+)/java/(.+)%.java$")
  if not (root and (set == "main" or set == "test")) then return nil end
  local pkg_dir, class = rest:match("^(.*)/([^/]+)$")
  return { root = root, set = set, pkg_dir = pkg_dir or "", class = class or rest }
end

--- `com.example.foo` for the package directory a .java file sits in, or nil for
--- the default package.
local function java_package(pkg_dir)
  if pkg_dir == "" then return nil end
  return (pkg_dir:gsub("/", "."))
end

local function java_path(parts, set, class)
  local dir = parts.root .. "/src/" .. set .. "/java"
  if parts.pkg_dir ~= "" then dir = dir .. "/" .. parts.pkg_dir end
  return dir .. "/" .. class .. ".java"
end

--- The class name with a test suffix stripped, plus which suffix that was.
---
--- Only applied to files in src/test: a *production* class legitimately named
--- `TestHarness` or `RetryTest` is not the test of anything, and stripping there
--- would send it to a source file that does not exist and then offer to create
--- it. The source set is the only reliable signal, so it is the one used.
local function java_strip_suffix(class)
  for _, suffix in ipairs(JAVA_TEST_SUFFIXES) do
    if #class > #suffix and class:sub(-#suffix) == suffix then
      return class:sub(1, #class - #suffix), suffix
    end
  end
  return class, nil
end

local function java_rule(path)
  local parts = java_parts(path)
  if not parts then return nil end

  local base = parts.class
  if parts.set == "test" then
    base = java_strip_suffix(parts.class)
  end

  local ring = { java_path(parts, "main", base) }
  for _, suffix in ipairs(JAVA_TEST_SUFFIXES) do
    table.insert(ring, java_path(parts, "test", base .. suffix))
  end

  -- The ring holds all three test spellings so that whichever one a project uses
  -- is found, but only one of them is worth *creating*. From a test, the thing to
  -- create is the production class; from production, the Test-suffixed test.
  local create = parts.set == "test" and ring[1] or java_path(parts, "test", base .. "Test")
  return { ring = ring, current = path, create = create }
end

-- ── TypeScript / JavaScript ─────────────────────────────────────────────────

--- Split a script or component-asset path into { dir, stem, ext, kind, test }.
---
--- `stem` is the name with any `.spec`/`.test` infix removed, so foo.spec.ts and
--- foo.ts produce the same stem and therefore the same ring — which is what lets
--- the walk work from either end. `kind` is the `.<word>` an Angular artifact
--- carries (`component` in foo.component.ts), used only to decide whether a
--- template and a stylesheet belong in the ring.
local function web_parts(path)
  local dir, name, ext = path:match("^(.*)/([^/]+)%.([%w]+)$")
  if not dir then return nil end

  local is_script = SCRIPT_EXTS[ext] or false
  local is_asset = vim.tbl_contains(COMPONENT_EXTS, ext)
  if not (is_script or is_asset) then return nil end

  local stem, test = name, nil
  if is_script then
    for _, infix in ipairs(SCRIPT_TEST_INFIXES) do
      local stripped = name:match("^(.+)%." .. infix .. "$")
      if stripped then
        stem, test = stripped, infix
        break
      end
    end
  end

  local kind = stem:match("%.([%a]+)$")
  return {
    dir = dir,
    stem = stem,
    ext = ext,
    script = is_script,
    kind = kind and COMPONENT_KINDS[kind] and kind or nil,
    test = test,
  }
end

local function web_rule(path)
  local parts = web_parts(path)
  if not parts then return nil end
  -- A template or stylesheet only has a counterpart if it belongs to a component:
  -- index.html and styles.scss are not half of anything, and without this guard
  -- their ring would be built around a .ts sibling that has no reason to exist —
  -- so the key would offer to create `styles.spec.ts`.
  if not parts.script and not parts.kind then return nil end

  -- A template or stylesheet names no extension of its own that the ring needs,
  -- so its script half is assumed to be .ts. Correct for anything the Angular
  -- CLI generated, which is the only thing that produces these sets.
  local script_ext = parts.script and parts.ext or "ts"
  local file = function(suffix) return parts.dir .. "/" .. parts.stem .. suffix end

  local ring = { file("." .. script_ext) }
  if parts.kind then
    for _, ext in ipairs(COMPONENT_EXTS) do
      table.insert(ring, file("." .. ext))
    end
  end
  -- Last in the ring, so a component walks .ts -> .html -> .scss -> .spec.ts
  -- rather than diverting into the spec on the first press.
  for _, infix in ipairs(SCRIPT_TEST_INFIXES) do
    table.insert(ring, file("." .. infix .. "." .. script_ext))
  end

  -- `test` and `spec` are interchangeable in the ring because both conventions
  -- are in the wild, but only `spec` is created: it is what both the Angular CLI
  -- and Vitest's default `include` use.
  local create = parts.test and ring[1] or file(".spec." .. script_ext)
  return { ring = ring, current = path, create = create }
end

local RULES = { java_rule, web_rule }

-- ── Public API ──────────────────────────────────────────────────────────────

--- The counterpart set for `path`, or nil when nothing here knows the convention.
---
--- `candidates` is ordered from the current file onwards (see rotate) and never
--- contains it; `create` is the one member worth offering to create when none of
--- them exist.
function M.resolve(path)
  if not path or path == "" then return nil end
  path = vim.fs.normalize(path)
  for _, rule in ipairs(RULES) do
    local found = rule(path)
    if found then
      return {
        candidates = rotate(found.ring, found.current),
        create = found.create,
      }
    end
  end
  return nil
end

--- The first counterpart of `path` that exists on disk, or nil.
function M.find(path)
  local set = M.resolve(path)
  if not set then return nil end
  for _, candidate in ipairs(set.candidates) do
    if exists(candidate) then return candidate end
  end
  return nil
end

--- Starting content for a counterpart that does not exist yet.
---
--- Java only, and only the two lines the compiler will not accept the file
--- without: the package declaration (wrong by default, because it is derived from
--- the directory the file is *in*, which is the one thing a new file already has
--- right) and the type declaration matching the file name. Deliberately no
--- imports, no @Test method, no framework assumption — jdtls completes those from
--- the project's own classpath, and a hard-coded `import org.junit.jupiter` is
--- wrong in any project still on JUnit 4.
---
--- Nothing for .ts, because the equivalent guess is the test framework
--- (`describe`/`it` is Jasmine and Vitest, Jest's globals differ, and an Angular
--- component spec needs TestBed) and there is no on-disk fact to derive it from.
function M.scaffold(path)
  local parts = java_parts(vim.fs.normalize(path))
  if not parts then return nil end

  local lines = {}
  local pkg = java_package(parts.pkg_dir)
  if pkg then
    table.insert(lines, "package " .. pkg .. ";")
    table.insert(lines, "")
  end
  -- Package-private for a test (JUnit 5 does not require public, and the
  -- generators stopped emitting it), public for a production class, which is
  -- almost always referenced from another package.
  local modifier = parts.set == "test" and "" or "public "
  table.insert(lines, modifier .. "class " .. parts.class .. " {")
  table.insert(lines, "")
  table.insert(lines, "}")
  return lines
end

--- Open the counterpart of the current buffer, offering to create it if there is
--- none.
---
--- The created file is an unwritten buffer, not a file touched on disk: the
--- scaffold is visible and editable before it is committed to, `:q!` abandons it
--- with nothing left behind, and the auto_create_dir autocmd in
--- lua/config/autocmds.lua makes the directory on the first write — so a test for
--- a package that has no src/test mirror yet needs no mkdir.
function M.toggle()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    return vim.notify("No file in this buffer", vim.log.levels.WARN)
  end

  local set = M.resolve(path)
  if not set then
    return vim.notify(
      "No counterpart convention for " .. vim.fs.basename(path),
      vim.log.levels.WARN
    )
  end

  local found = M.find(path)
  if found then
    return vim.cmd.edit(vim.fn.fnameescape(found))
  end

  local target = set.create
  local answer = vim.fn.confirm(
    ("%s does not exist. Create it?"):format(vim.fn.fnamemodify(target, ":~:.")),
    "&Yes\n&No",
    1
  )
  if answer ~= 1 then return end

  vim.cmd.edit(vim.fn.fnameescape(target))
  local lines = M.scaffold(target)
  -- Only into an empty buffer. `edit` on a path that has appeared since the
  -- existence check above (a generator, a git checkout, the other half of a
  -- rename) loads the real file, and overwriting it would be data loss.
  if lines and vim.api.nvim_buf_line_count(0) == 1 and vim.api.nvim_get_current_line() == "" then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    -- On the blank line inside the body, which is where typing starts.
    pcall(vim.api.nvim_win_set_cursor, 0, { #lines - 1, 0 })
  end
end

return M
