-- Shared test helpers.
--
-- Everything that creates state (buffers, files, stubs, autocmd groups) records
-- it and is undone by H.cleanup(), which every spec calls from after_each. A
-- spec that leaks a stubbed vim.fn function or a modified global option would
-- otherwise silently decide the outcome of a later spec in the same file.

local H = {}

local tracked = {
  restores = {}, -- functions that undo a stub
  bufs = {},
  dirs = {},
  clients = {},
  augroups = {},
}

-- ── Stubbing ────────────────────────────────────────────────────────────────

--- Replace tbl[key] until cleanup. Returns the original value.
function H.stub(tbl, key, value)
  local original = tbl[key]
  local had_key = tbl[key] ~= nil
  tbl[key] = value
  table.insert(tracked.restores, function()
    tbl[key] = had_key and original or nil
  end)
  return original
end

--- Record every call to tbl[key] and (by default) suppress the real one.
--- Returns the call log: a list of argument tables, plus `.count`.
function H.spy(tbl, key, impl)
  local log = setmetatable({}, {
    __index = function(t, k)
      if k == "count" then return #t end
    end,
  })
  local original = tbl[key]
  H.stub(tbl, key, function(...)
    table.insert(log, { ... })
    if impl then return impl(...) end
    return nil
  end)
  log.original = original
  return log
end

--- Collect vim.notify calls made inside fn. Returns { {msg, level}, ... }.
---
--- opts.settle_ms waits that long (draining the event loop) before restoring
--- vim.notify. Needed whenever the code under test notifies from a
--- vim.schedule/vim.schedule_wrap callback — lazy.nvim reports config errors
--- that way, and so does conform's async formatting — because those fire after
--- fn() has already returned and would otherwise be missed entirely.
function H.capture_notifications(fn, opts)
  local seen = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    table.insert(seen, { msg = msg, level = level })
  end
  local ok, err = pcall(fn)
  if (opts or {}).settle_ms then
    vim.wait(opts.settle_ms, function() return false end)
  end
  vim.notify = original
  if not ok then error(err, 0) end
  return seen
end

--- The ex-commands run while fn() executes, in order. The real vim.cmd still
--- runs, so behaviour is unchanged; this only observes.
---
--- Some code paths are *only* observable this way: auto_save's and auto_reload's
--- entire job is deciding whether to reach `silent! write` / `silent! checktime`,
--- and for an unnamed buffer (or a write that would fail anyway) the filesystem
--- looks identical either way.
function H.capture_ex(fn)
  local seen = {}
  local original = vim.cmd
  vim.cmd = function(cmd, ...)
    if type(cmd) == "string" then table.insert(seen, cmd) end
    return original(cmd, ...)
  end
  local ok, err = pcall(fn)
  vim.cmd = original
  if not ok then error(err, 0) end
  return seen
end

--- Did any command captured by H.capture_ex match `pattern`?
function H.ran_ex(seen, pattern)
  for _, cmd in ipairs(seen) do
    if cmd:find(pattern) then return true end
  end
  return false
end

-- ── Files and fixtures ──────────────────────────────────────────────────────

local uniq = 0

--- A fresh empty directory under the system temp dir, removed at cleanup.
function H.tmpdir(label)
  uniq = uniq + 1
  local dir = ("%s/nvim-ide-tests/%d-%d-%s"):format(
    vim.fn.fnamemodify(vim.fn.tempname(), ":h"), vim.uv.os_getpid(), uniq, label or "t")
  vim.fn.mkdir(dir, "p")
  table.insert(tracked.dirs, dir)
  return dir
end

--- Write lines (string or list) to `path`, creating parent directories.
function H.write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  if type(lines) == "string" then lines = vim.split(lines, "\n") end
  vim.fn.writefile(lines, path)
  return path
end

--- A file's lines, or nil if it does not exist. The counterpart to H.write:
--- "nil rather than error" is what lets a spec assert that a file was *not*
--- written without branching on filereadable at every call site.
function H.read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
end

--- A file's whole contents as one string, for specs that assert against source
--- text rather than lines.
function H.read_text(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

--- Move a file's mtime `seconds` into the future.
---
--- vim.fn.getftime() has one-second resolution and auto-save's guard compares
--- those integers, so a file rewritten in the same second as the read looks
--- untouched. Stamping the time is exact, and does not cost a second per case.
function H.touch(path, seconds)
  local t = os.time() + (seconds or 30)
  assert(vim.uv.fs_utime(path, t, t))
  return t
end

--- Rewrite `path` behind nvim's back, the way git, Claude or a formatter would:
--- new contents plus an mtime that is provably newer than the buffer's stamp.
function H.external_write(path, lines)
  vim.fn.writefile(lines, path)
  H.touch(path)
  return path
end

H.fixtures_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures"

--- Copy tests/fixtures/<name> into a temp dir and return the copy's path.
---
--- Copied rather than used in place because specs open buffers in these trees
--- and the config auto-saves on BufLeave — running against the originals would
--- rewrite the fixtures. `.git` is created (not committed) so root-marker
--- detection finds a project root without nesting a real repo in this one.
function H.fixture(name, opts)
  opts = opts or {}
  local src = H.fixtures_dir .. "/" .. name
  assert(vim.fn.isdirectory(src) == 1, "no such fixture: " .. src)
  local dst = H.tmpdir("fx-" .. name)
  vim.fn.system({ "cp", "-R", src .. "/.", dst })
  assert(vim.v.shell_error == 0, "failed to copy fixture " .. name)
  if opts.git ~= false then vim.fn.mkdir(dst .. "/.git", "p") end
  return dst
end

-- ── Buffers ─────────────────────────────────────────────────────────────────

--- Scratch buffer, made current. Wiped at cleanup.
---
--- `scratch = false` forces a normal (buftype "") buffer even with no name.
--- That combination is not cosmetic: unnamed-but-normal is one of auto_save's
--- exclusions, and the default (scratch whenever unnamed) makes buftype "nofile"
--- instead, which is a *different* exclusion.
function H.scratch(opts)
  opts = opts or {}
  local scratch = opts.scratch
  if scratch == nil then scratch = not opts.name end
  local buf = vim.api.nvim_create_buf(opts.listed ~= false, scratch)
  if opts.name then vim.api.nvim_buf_set_name(buf, opts.name) end
  if opts.lines then vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines) end
  if opts.ft then vim.bo[buf].filetype = opts.ft end
  vim.api.nvim_set_current_buf(buf)
  table.insert(tracked.bufs, buf)
  return buf
end

--- :edit a real file and return its buffer. Wiped at cleanup.
function H.edit(path)
  vim.cmd("silent! edit! " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  table.insert(tracked.bufs, buf)
  return buf
end

--- A buffer that has `path` as its name but is never loaded.
---
--- The point is that nothing reads the file, so no filetype is detected and no
--- language server attaches — while every root-detection code path in the config
--- (vim.fs.root, vim.fs.find upward, nvim_buf_get_name) sees exactly what it
--- would see for the real thing. Use this instead of H.edit whenever the buffer
--- *name* is the whole input.
function H.named_buf(path)
  local buf = vim.fn.bufadd(path)
  table.insert(tracked.bufs, buf)
  return buf
end

--- Like H.named_buf, but loaded, made current and given filetype `ft` with the
--- FileType event suppressed.
---
--- Suppressing FileType is what keeps a `java`/`typescript` buffer from starting
--- the real jdtls or ts_ls (tens of seconds, machine-dependent). Code that reads
--- vim.bo[buf].filetype cannot tell the difference; code that relies on the
--- event firing can, so do not use this to test an autocmd's registration.
function H.quiet_buffer(path, ft)
  local buf = H.named_buf(path)
  local saved = vim.o.eventignore
  vim.o.eventignore = "FileType"
  local ok, err = pcall(function()
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    if ft then vim.bo[buf].filetype = ft end
  end)
  vim.o.eventignore = saved
  if not ok then error(err, 0) end
  return buf
end

-- ── Keymaps ─────────────────────────────────────────────────────────────────

--- The mapping for `lhs` in `mode`, or nil. maparg (not nvim_get_keymap) so
--- "<C-e>"/"<leader>d" notation resolves the same way the config wrote it.
--- Pass bufnr to look up a buffer-local mapping (temporarily switches buffers).
function H.keymap(mode, lhs, bufnr)
  local function lookup()
    local d = vim.fn.maparg(lhs, mode, false, true)
    if not d or vim.tbl_isempty(d) then return nil end
    return d
  end
  if not bufnr then return lookup() end
  local cur = vim.api.nvim_get_current_buf()
  if cur == bufnr then return lookup() end
  vim.api.nvim_set_current_buf(bufnr)
  local d = lookup()
  vim.api.nvim_set_current_buf(cur)
  return d
end

function H.has_keymap(mode, lhs, bufnr)
  return H.keymap(mode, lhs, bufnr) ~= nil
end

--- The *buffer-local* mapping for `lhs`, or nil.
---
--- maparg falls back to the global mapping when the buffer has none, which turns
--- every "this mapping must NOT exist" assertion into a no-op the moment
--- something global shares the lhs — and plenty does (nvim ships global gr*/K
--- LSP defaults, config/keymaps.lua owns most of <leader>). Any spec asserting
--- the absence of a capability-gated mapping has to use this, not H.keymap.
function H.buf_keymap(mode, lhs, bufnr)
  local d = H.keymap(mode, lhs, bufnr)
  if d and d.buffer == 1 then return d end
  return nil
end

function H.has_buf_keymap(mode, lhs, bufnr)
  return H.buf_keymap(mode, lhs, bufnr) ~= nil
end

--- Invoke a mapping's callback (or feed its rhs) without depending on the
--- terminal keycodes a real keypress would produce.
function H.run_keymap(mode, lhs, bufnr)
  local d = H.keymap(mode, lhs, bufnr)
  assert(d, ("no %s mapping for %s"):format(mode, lhs))
  if d.callback then return d.callback() end
  local keys = vim.api.nvim_replace_termcodes(d.rhs, true, true, true)
  vim.api.nvim_feedkeys(keys, "mx", false)
end

-- ── Autocmds ────────────────────────────────────────────────────────────────

function H.autocmds(filter)
  local ok, res = pcall(vim.api.nvim_get_autocmds, filter)
  return ok and res or {}
end

--- How many autocmds a given group has for an event. Used to prove the config
--- replaces rather than stacks its autocmds when a FileType/attach re-fires.
function H.count_autocmds(event, group, bufnr)
  local filter = { event = event }
  if group then filter.group = group end
  if bufnr then filter.buffer = bufnr end
  return #H.autocmds(filter)
end

--- Delete the config's auto-save autocmds for the rest of the spec.
--- Any spec that modifies a buffer in a fixture needs this: the real config
--- writes on BufLeave, which would rewrite files mid-test.
function H.disable_autosave()
  pcall(vim.api.nvim_del_augroup_by_name, "auto_save")
end

-- ── Waiting ─────────────────────────────────────────────────────────────────

--- Wait until fn() is truthy. Fails the spec (with `label`) on timeout.
function H.wait_for(label, fn, timeout, interval)
  local ok = vim.wait(timeout or 5000, function()
    local success, res = pcall(fn)
    return success and res and true or false
  end, interval or 20)
  assert(ok, "timed out waiting for: " .. label)
  return true
end

-- ── Plugins (integration mode) ──────────────────────────────────────────────

--- Force a lazy-loaded plugin to load now. `event`-gated plugins otherwise load
--- on VimEnter/VeryLazy, which has not necessarily fired when a spec starts.
---
--- lazy.core.loader rather than the public require("lazy").load: the public
--- entry point routes through lazy.manage, whose task module reads
--- Config.options.headless at require time and errors in a headless session.
--- The core loader is what the public API eventually calls anyway.
function H.load_plugin(...)
  local names = { ... }
  local ok, loader = pcall(require, "lazy.core.loader")
  assert(ok, "lazy.nvim is not available — integration spec run with minimal_init?")
  for _, name in ipairs(names) do
    loader.load(name, { test = "helpers.load_plugin" })
  end
  return true
end

function H.is_integration()
  return (_G.NVIM_IDE_TEST or {}).mode == "integration"
end

--- Is a plugin's Lua module require-able? Use this rather than checking
--- lazy's plugin list: a plugin can be *declared* and not installed on this
--- machine, and a spec that asserts on its behaviour should skip in that case
--- rather than fail for an environment problem.
function H.has_plugin(module)
  return (pcall(require, module))
end

--- Skip the remainder of a spec, loudly enough to be visible in the log.
---
--- plenary's `it` has no runtime skip, so a spec that returns early still prints
--- Success. The "SKIP:" prefix is the contract with tests/run.sh, which counts
--- these lines and reports them next to the pass count — otherwise a green suite
--- on a machine missing every mason package would look like it proved something.
--- When the gate is known at declaration time, prefer plenary's `pending()`.
function H.skip(reason)
  print("SKIP: " .. reason)
  return true
end

-- ── Cleanup ─────────────────────────────────────────────────────────────────

function H.track_client(id)
  table.insert(tracked.clients, id)
  return id
end

--- Register a buffer created some other way (nvim_create_buf, :split, a plugin)
--- so H.cleanup wipes it. H.scratch/H.edit/H.named_buf do this already.
function H.track_buf(bufnr)
  table.insert(tracked.bufs, bufnr)
  return bufnr
end

function H.track_augroup(name)
  table.insert(tracked.augroups, name)
  return name
end

function H.cleanup()
  for i = #tracked.restores, 1, -1 do
    pcall(tracked.restores[i])
  end
  tracked.restores = {}

  for _, id in ipairs(tracked.clients) do
    local client = vim.lsp.get_client_by_id(id)
    if client then pcall(function() client:stop(true) end) end
  end
  tracked.clients = {}

  for _, name in ipairs(tracked.augroups) do
    pcall(vim.api.nvim_del_augroup_by_name, name)
  end
  tracked.augroups = {}

  for _, buf in ipairs(tracked.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true, unload = false })
    end
  end
  tracked.bufs = {}

  for _, dir in ipairs(tracked.dirs) do
    if dir:find("nvim%-ide%-tests") then pcall(vim.fn.delete, dir, "rf") end
  end
  tracked.dirs = {}
end

return H
