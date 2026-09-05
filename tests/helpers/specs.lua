-- Static loader for the lazy.nvim plugin specs in lua/plugins/.
--
-- dofile, not require: these files are pure data (a table of specs) and reading
-- them without lazy.nvim lets the structural specs assert on what is declared —
-- keys, events, dependencies, keymaps — without loading a single plugin. The
-- `config`/`init` functions inside are never called here.

local S = {}

S.plugins_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  .. "/lua/plugins"

function S.files()
  local files = vim.fn.glob(S.plugins_dir .. "/*.lua", true, true)
  table.sort(files)
  return files
end

--- The raw spec list a single file returns.
function S.load(file)
  local chunk = assert(loadfile(file))
  local ok, result = pcall(chunk)
  assert(ok, ("%s failed to load: %s"):format(file, result))
  assert(type(result) == "table", file .. " must return a table of specs")
  return result
end

local function repo_of(entry)
  if type(entry) == "string" then return entry end
  if type(entry) == "table" then
    if type(entry[1]) == "string" then return entry[1] end
    if type(entry.dir) == "string" then return entry.dir end
  end
  return nil
end

--- Every spec across every file, flattened, including specs nested inside
--- `dependencies`. Each item: { repo, spec, file, nested }.
---
--- Nested dependency specs are included because that is where several plugins
--- in this config are really configured (nvim-dap-ui under nvim-dap,
--- telescope-fzf-native under telescope), so a check that skipped them would
--- miss them entirely.
function S.all()
  local out = {}

  local function visit(entry, file, nested)
    local repo = repo_of(entry)
    if not repo then return end
    table.insert(out, { repo = repo, spec = entry, file = file, nested = nested })
    if type(entry) == "table" and type(entry.dependencies) == "table" then
      for _, dep in ipairs(entry.dependencies) do
        visit(dep, file, true)
      end
    end
  end

  for _, file in ipairs(S.files()) do
    for _, entry in ipairs(S.load(file)) do
      visit(entry, file, false)
    end
  end
  return out
end

--- Just the top-level specs (what lazy.setup("plugins") reads directly).
function S.toplevel()
  return vim.tbl_filter(function(p) return not p.nested end, S.all())
end

--- Every `keys = { ... }` entry declared by any spec, normalised to
--- { lhs, modes = {...}, desc, spec_repo, file }.
function S.keys()
  local out = {}
  for _, p in ipairs(S.all()) do
    local keys = type(p.spec) == "table" and p.spec.keys or nil
    if type(keys) == "table" then
      for _, k in ipairs(keys) do
        local lhs = type(k) == "string" and k or k[1]
        if lhs then
          local mode = (type(k) == "table" and k.mode) or "n"
          table.insert(out, {
            lhs = lhs,
            modes = type(mode) == "table" and mode or { mode },
            desc = type(k) == "table" and k.desc or nil,
            ft = type(k) == "table" and k.ft or nil,
            repo = p.repo,
            file = p.file,
          })
        end
      end
    end
  end
  return out
end

return S
