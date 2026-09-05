-- Structural checks on the lazy.nvim specs in lua/plugins/.
--
-- Everything here is read statically with helpers.specs (dofile, no lazy, no
-- plugin loaded), because the failures this file exists to catch are silent at
-- runtime: lazy.nvim does not warn about a merged duplicate spec, an `opts`
-- table that no `config` ever receives, a `keys` entry shadowed by another
-- plugin's identical lhs, or a `desc` it will render as a blank which-key row.
-- The config still boots in every one of those cases — just with part of the
-- IDE quietly missing — so a boot test cannot stand in for these assertions.

local H = require("helpers")
local S = require("helpers.specs")

--- The two text-level assertions below (the Cmd-key ban and the colorscheme
--- call) need the source rather than the evaluated table.
local read_text = H.read_text

--- Files whose raw text the Cmd-key ban applies to: the plugin specs plus the
--- global keymap table, which is where a Mac binding would most plausibly land.
local function keymap_sources()
  local files = S.files()
  table.insert(files, vim.fn.fnamemodify(S.plugins_dir, ":h") .. "/config/keymaps.lua")
  return files
end

--- Why a "owner/repo" short name is malformed, or nil if it is well-formed.
--- lazy derives the install path and the plugin's `name` from this string, so a
--- URL, a trailing ".git" or a stray space produces a plugin lazy will try to
--- clone under a mangled directory name instead of a clear error.
local function repo_shape_error(repo)
  if repo:find("^https?://") or repo:find("^git@") then
    return "must be a short owner/repo name, not a URL"
  end
  if repo:find("%s") then return "contains whitespace" end
  if repo:find("%.git$") then return "has a .git suffix" end
  if repo:find("^/") or repo:find("/$") then return "has a leading or trailing slash" end
  local _, slashes = repo:gsub("/", "")
  if slashes ~= 1 then
    return ("has %d slashes, expected exactly one (owner/repo)"):format(slashes)
  end
  return nil
end

--- ft/event/keys `ft` fields are all "string or list of strings" in lazy's
--- schema; normalise so the checks below can treat them uniformly.
local function as_list(v)
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  return v
end

local function is_string_or_string_list(v)
  if type(v) == "string" then return true end
  if type(v) ~= "table" then return false end
  for _, item in ipairs(v) do
    if type(item) ~= "string" then return false end
  end
  return true
end

--- Do two keys entries fight over the same lhs? Filetype-scoped entries with
--- disjoint `ft` lists never both apply to one buffer, so they do not.
local function filetypes_overlap(a, b)
  local a_ft, b_ft = as_list(a.ft), as_list(b.ft)
  -- An unscoped entry applies to every buffer, so it overlaps everything.
  if #a_ft == 0 or #b_ft == 0 then return true end
  for _, x in ipairs(a_ft) do
    if vim.tbl_contains(b_ft, x) then return true end
  end
  return false
end

local function describe_key(k)
  return ("%s (%s) from %s in %s"):format(
    k.lhs, table.concat(k.modes, ","), k.repo, vim.fn.fnamemodify(k.file, ":t"))
end

describe("lua/plugins specs", function()
  describe("files", function()
    it("finds spec files at all", function()
      -- A rename of lua/plugins/, or a helpers.specs glob that stops matching,
      -- would otherwise make every other test in this file vacuously pass.
      assert.is_true(#S.files() > 0, "no spec files found in " .. S.plugins_dir)
    end)

    it("loads every file as a table of specs", function()
      -- S.load asserts both halves (it evaluates and type-checks); naming the
      -- files here is what turns "one of them is broken" into "this one is".
      for _, file in ipairs(S.files()) do
        assert.is_table(S.load(file), file .. " did not return a table")
      end
    end)

    it("declares at least one plugin overall", function()
      -- lua/plugins/ai.lua legitimately returns {} (its logic lives in
      -- lua/claude_cli.lua), so per-file emptiness is not an error — but an
      -- empty *set* means lazy.setup("plugins") has nothing to install.
      assert.is_true(#S.all() > 0, "no plugin specs declared anywhere")
    end)
  end)

  describe("spec identity", function()
    it("gives every spec a repo name or a dir", function()
      for _, p in ipairs(S.all()) do
        -- helpers.specs skips entries with neither, so anything that reaches
        -- S.all() already has one — assert on the spec tables directly.
        for _, entry in ipairs(S.load(p.file)) do
          local has_id = type(entry) == "string"
            or (type(entry) == "table" and (type(entry[1]) == "string" or type(entry.dir) == "string"))
          assert.is_true(has_id,
            ("a spec in %s has neither a [1] repo string nor a dir"):format(p.file))
        end
      end
    end)

    it("uses a well-formed owner/repo short name", function()
      for _, p in ipairs(S.all()) do
        local is_dir_spec = type(p.spec) == "table" and p.spec[1] == nil and p.spec.dir ~= nil
        if not is_dir_spec then
          local err = repo_shape_error(p.repo)
          assert.is_nil(err,
            ("%s in %s %s"):format(p.repo, vim.fn.fnamemodify(p.file, ":t"), tostring(err)))
        end
      end
    end)
  end)

  describe("duplicate specs", function()
    it("declares each plugin as a top-level spec at most once", function()
      -- lazy merges two specs for the same plugin, and the merge is not a
      -- union: single-valued fields (notably `config`) are taken from one of
      -- them, so a second declaration silently decides which config function
      -- runs. Only top-level entries are checked — a `dependencies` entry that
      -- repeats a top-level plugin is the normal, documented way to express an
      -- ordering constraint (nvim-web-devicons and plenary appear under half
      -- the specs here for exactly that reason) and merges harmlessly.
      local seen = {}
      for _, p in ipairs(S.toplevel()) do
        assert.is_nil(seen[p.repo],
          ("%s is declared top-level twice: %s and %s"):format(p.repo, tostring(seen[p.repo]), p.file))
        seen[p.repo] = p.file
      end
    end)
  end)

  describe("opts and config", function()
    it("never pairs opts with a config that cannot receive them", function()
      -- lazy calls config(plugin, opts). A `config = function() ... end` is
      -- accepted, runs, and drops the opts table on the floor — the plugin ends
      -- up with its own defaults and the spec reads as if it were configured.
      -- `config = function(_, opts)` is the correct shape.
      for _, p in ipairs(S.all()) do
        local spec = p.spec
        if type(spec) == "table" and spec.opts ~= nil and type(spec.config) == "function" then
          local nparams = debug.getinfo(spec.config, "u").nparams
          assert.is_true(nparams >= 2,
            ("%s in %s sets opts but its config takes %d parameter(s) — the opts are discarded"):
              format(p.repo, vim.fn.fnamemodify(p.file, ":t"), nparams))
        end
      end
    end)
  end)

  describe("keys", function()
    it("gives every keys entry a non-empty desc", function()
      -- which-key renders `desc` verbatim; a missing one is a blank row in the
      -- popup, which is how a keybinding becomes undiscoverable without being
      -- broken.
      for _, k in ipairs(S.keys()) do
        assert.is_string(k.desc, "no desc for " .. describe_key(k))
        assert.is_true(#(k.desc or "") > 0, "empty desc for " .. describe_key(k))
      end
    end)

    it("declares no lhs twice in the same mode", function()
      -- lazy turns each keys entry into a real keymap, so the later definition
      -- wins outright: the other plugin's key never fires and nothing reports
      -- it. Filetype-scoped entries are exempt when their filetypes are
      -- disjoint (kulala's <M-p> in http buffers vs render-markdown's in
      -- markdown ones) because only one of them is ever mapped at a time.
      local by_mode_lhs = {}
      for _, k in ipairs(S.keys()) do
        for _, mode in ipairs(k.modes) do
          local slot = mode .. " " .. k.lhs
          for _, prev in ipairs(by_mode_lhs[slot] or {}) do
            assert.is_false(filetypes_overlap(prev, k),
              ("%s collides with %s"):format(describe_key(k), describe_key(prev)))
          end
          by_mode_lhs[slot] = by_mode_lhs[slot] or {}
          table.insert(by_mode_lhs[slot], k)
        end
      end
    end)

    it("uses no Mac Cmd (<D-...>) lhs", function()
      -- Project rule: this branch is the Windows/Linux config and its shortcuts
      -- are Ctrl-based; Mac Cmd bindings live on a separate branch. A <D-...>
      -- here is also dead weight on the platforms this branch targets, since
      -- nothing outside macOS ever sends that keycode.
      for _, k in ipairs(S.keys()) do
        assert.is_nil(k.lhs:find("<[dD]%-"), "Cmd binding in a keys entry: " .. describe_key(k))
      end
    end)

    it("mentions no Cmd binding anywhere in the plugin or keymap sources", function()
      -- The keys-entry check above misses every vim.keymap.set call inside a
      -- `config` function (terminal.lua, tools.lua and treesitter.lua all map
      -- keys that way) and all of lua/config/keymaps.lua, which is where a Mac
      -- binding would most likely be added.
      for _, file in ipairs(keymap_sources()) do
        local text = read_text(file)
        assert.is_nil(text:find("<[dD]%-"),
          ("%s contains a Mac Cmd (<D-...>) binding"):format(file))
      end
    end)
  end)

  describe("dependencies", function()
    it("declares each dependency as a repo string or a spec table", function()
      for _, p in ipairs(S.all()) do
        local deps = type(p.spec) == "table" and p.spec.dependencies or nil
        for _, dep in ipairs(deps or {}) do
          local ok = type(dep) == "string"
            or (type(dep) == "table" and (type(dep[1]) == "string" or type(dep.dir) == "string"))
          assert.is_true(ok,
            ("%s has a dependency that is neither a repo string nor a spec table"):format(p.repo))
        end
      end
    end)

    it("resolves every local-dir dependency to a directory on disk", function()
      -- A plain "owner/repo" dependency needs no declaration of its own — lazy
      -- installs it implicitly — so there is nothing to verify there. A `dir`
      -- dependency is different: lazy does not clone it, it just adds the path
      -- to the runtimepath, and a stale path yields a plugin that is "loaded"
      -- and does nothing.
      local checked = 0
      for _, p in ipairs(S.all()) do
        local deps = type(p.spec) == "table" and p.spec.dependencies or nil
        for _, dep in ipairs(deps or {}) do
          if type(dep) == "table" and type(dep.dir) == "string" then
            checked = checked + 1
            local dir = vim.fn.expand(dep.dir)
            assert.equals(1, vim.fn.isdirectory(dir),
              ("%s depends on local dir %s, which does not exist"):format(p.repo, dir))
          end
        end
      end
      -- Recorded rather than asserted: this config currently uses no local-dir
      -- dependencies, and the check is here to cover the day one appears.
      assert.is_true(checked >= 0)
    end)
  end)

  describe("lazy-loading fields", function()
    it("types ft, event, lazy and priority the way lazy expects", function()
      -- lazy does not validate these; it indexes them. A number `ft` or a
      -- string `priority` surfaces as an error inside lazy's own handler setup
      -- during startup, which is the point in the boot where a stack trace is
      -- least readable.
      for _, p in ipairs(S.all()) do
        local spec = p.spec
        if type(spec) == "table" then
          local where = ("%s in %s"):format(p.repo, vim.fn.fnamemodify(p.file, ":t"))
          if spec.ft ~= nil then
            assert.is_true(is_string_or_string_list(spec.ft), where .. ": ft must be a string or list of strings")
          end
          if spec.event ~= nil then
            assert.is_true(is_string_or_string_list(spec.event), where .. ": event must be a string or list of strings")
          end
          if spec.cmd ~= nil then
            assert.is_true(is_string_or_string_list(spec.cmd), where .. ": cmd must be a string or list of strings")
          end
          if spec.lazy ~= nil then
            assert.equals("boolean", type(spec.lazy), where .. ": lazy must be a boolean")
          end
          if spec.priority ~= nil then
            assert.equals("number", type(spec.priority), where .. ": priority must be a number")
          end
        end
      end
    end)

    it("gives every keys entry that is filetype-scoped a string or list ft", function()
      for _, k in ipairs(S.keys()) do
        if k.ft ~= nil then
          assert.is_true(is_string_or_string_list(k.ft), "bad ft on " .. describe_key(k))
        end
      end
    end)
  end)

  describe("colorscheme", function()
    --- The single spec in theme.lua that actually applies the colorscheme.
    local function theme_spec()
      local file = S.plugins_dir .. "/theme.lua"
      assert.equals(1, vim.fn.filereadable(file), "no theme.lua in " .. S.plugins_dir)
      local specs = S.load(file)
      assert.equals(1, #specs, "theme.lua is expected to declare exactly one plugin")
      return specs[1], file
    end

    it("loads the colorscheme eagerly and before every other plugin", function()
      local spec, file = theme_spec()
      -- Both halves are load-bearing and neither implies the other.
      -- lazy = false is what makes the plugin load during startup at all: with
      -- no event/ft/keys/cmd trigger, a lazy spec would simply never load and
      -- the session would sit on the default colorscheme.
      assert.is_false(spec.lazy, spec[1] .. " must set lazy = false to apply at startup")
      -- priority only orders the start plugins among themselves, and the
      -- colorscheme has to win: plugins that read highlight groups at setup
      -- time (lualine's ayu_mirage theme, barbecue's "auto" theme,
      -- rainbow-delimiters' RainbowDelimiter* overrides from this same config
      -- block) capture whatever palette is current when they load. lazy's
      -- documented value for a colorscheme is 1000, above the default 50.
      assert.is_true((spec.priority or 50) >= 1000,
        ("%s needs priority >= 1000, has %s"):format(spec[1], tostring(spec.priority)))
      -- Installing and configuring the plugin is not the same as selecting the
      -- scheme; without this call ayu is merely available.
      assert.is_not_nil(read_text(file):find("colorscheme", 1, true),
        "theme.lua never applies a colorscheme")
    end)
  end)
end)
