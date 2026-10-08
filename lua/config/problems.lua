-- Build output -> quickfix.
--
-- A failed build used to end here: `gradlew bootRun` writes
--
--     /abs/path/Foo.java:12: error: ';' expected
--
-- into the terminal lua/config/runner.lua opened, and that was the whole
-- interaction. The error is on screen and unreachable — no jump, no :cnext, no
-- list. Grepped before writing this: there was no `errorformat`, `setqflist` or
-- `copen` anywhere in this config, so the quickfix list went unused by every
-- build path in it.
--
-- Two decisions worth stating, because both could reasonably have gone the other
-- way:
--
-- * The error formats are Neovim's own, read out of $VIMRUNTIME/compiler at
--   first use (javac.vim, maven.vim, tsc.vim), not written here. Maven's alone is
--   1112 characters across POM parse errors, javac messages with and without
--   columns, SpotBugs and JUnit failures — all upstream-maintained. The only
--   hand-written patterns in this file are the two in EXTRA_TSC, for a tsc output
--   shape the bundled file predates.
--
-- * The output is read from the terminal *buffer* on exit, not captured through
--   `on_stdout`. The job is a pty, so on_stdout delivers ANSI colour, cursor
--   moves and Gradle's carriage-return progress bar as raw bytes that would have
--   to be stripped and reassembled; libvterm has already done exactly that work
--   by the time the lines are in the buffer. The cost is that output older than
--   'scrollback' is gone — which matters for a long bootRun log and not at all
--   for a failed compile, the case this is for.

local M = {}

--- tsc's newer one-line diagnostic, which $VIMRUNTIME/compiler/tsc.vim predates.
--- It ships `%f (%l,%c): %trror TS%n: %m` (the parenthesised form, still what
--- `tsc --pretty false` emits); Angular 17+ and plain `tsc --noEmit` print
--- `src/app/x.ts:14:25 - error TS2322: …` instead, which that pattern misses
--- entirely — so without these two the web targets would parse to an empty list
--- and look like a module that does not work.
local EXTRA_TSC = {
  [[%f:%l:%c\ -\ %trror\ TS%n:\ %m]],
  [[%f:%l:%c\ -\ %tarning\ TS%n:\ %m]],
}

--- Resolves relative paths in the output against the directory the build ran in.
---
--- Load-bearing, and not obvious: `getqflist({ lines = … })` resolves `%f`
--- against Neovim's cwd, while the build ran with cwd = target.dir (the module
--- directory, so Gradle and Maven pick the right subproject). tsc and Angular
--- print project-relative paths, so every item would point at a file under
--- whatever directory nvim was started in. This is make's own directory-stack
--- convention — a synthetic "Entering directory" line is prepended to the output
--- in M.parse, and vim pushes it onto the stack.
---
--- An alternative considered and rejected: chdir to the build directory around
--- the parse. It fires DirChanged, which lua/config/runner.lua listens to in
--- order to drop its detection cache — a build finishing would invalidate the
--- toolbar for no reason.
local DIR_ENTRY = [[%DEntering\ directory\ '%f']]

--- Which $VIMRUNTIME compiler definitions apply to a run target, by its build
--- tool. Keyed on `tool` rather than `kind`: what produces the diagnostics is the
--- command, and a Spring target and a plain Java target on the same Gradle build
--- emit identical javac output.
---
--- Maven gets `maven` only, not `maven` plus `javac`: maven.vim already carries
--- the javac patterns in `[ERROR] %f:[%l,%c] %m` form, and its `%-G[INFO] %.%#`
--- is what drops the lifecycle noise. Appending javac's `%-G%.%#` catch-all after
--- it would be harmless, appending javac's error patterns before it would not —
--- `%f:%l: error:` would match inside a Maven line and lose the `[ERROR]` tag
--- that carries the severity.
local COMPILERS = {
  gradle = { "javac" },
  maven = { "maven" },
  npm = { "tsc" },
  pnpm = { "tsc" },
  yarn = { "tsc" },
  bun = { "tsc" },
  npx = { "tsc" },
}

-- name -> errorformat string. Populated on first use; a compiler file is a
-- sourced vim script, which is not something to repeat per build.
local efm_cache = {}

--- The errorformat $VIMRUNTIME/compiler/<name>.vim sets, or nil if there is none.
---
--- Read inside a scratch buffer because `:compiler` (without the bang) issues
--- `setlocal` for both 'errorformat' and 'makeprg' — in any other buffer this
--- would quietly repoint `:make` for whatever the user was editing. `:compiler`
--- also unlets `current_compiler` itself before sourcing, so the guard at the top
--- of every compiler file does not make this a once-per-session read.
local function compiler_efm(name)
  if efm_cache[name] ~= nil then
    return efm_cache[name] or nil
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local efm
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("compiler " .. name)
    efm = vim.bo.errorformat
  end)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  efm_cache[name] = efm or false
  return efm
end

--- The full errorformat for `compilers` (a list of $VIMRUNTIME compiler names),
--- directory entry first.
---
--- Order matters: 'errorformat' is tried entry by entry and most of these
--- definitions end in a `%-G%.%#` catch-all that swallows every unmatched line,
--- so anything placed after one is dead.
function M.errorformat(compilers)
  local parts = { DIR_ENTRY }
  for _, name in ipairs(compilers) do
    if name == "tsc" then
      vim.list_extend(parts, EXTRA_TSC)
    end
    local efm = compiler_efm(name)
    if efm then table.insert(parts, efm) end
  end
  return table.concat(parts, ",")
end

--- Which compilers to parse a target's output with, or nil when there is nothing
--- to parse it with.
---
--- nil rather than an empty list so callers can skip the whole parse: a `java`
--- target has no build tool (its main class is launched through jdtls's debug
--- adapter, which reports failures through DAP, not as compiler text).
function M.compilers_for(target)
  local names = target and target.tool and COMPILERS[target.tool]
  return names and vim.deepcopy(names) or nil
end

--- Parse `lines` and return the quickfix items that matched.
---
--- Only `valid == 1` items: everything else is either the synthetic directory
--- line or a `%-G`-less leftover, and an invalid item in a quickfix list is a row
--- that cannot be jumped to.
---
--- Deduplicated, which an end-to-end run against a real Gradle build is what
--- turned up: Gradle prints each javac diagnostic *twice* — once as the task's
--- own output, and again indented two spaces under `* What went wrong:` /
--- `> Compilation failed; see the compiler output below.` — and vim's
--- errorformat skips leading whitespace, so both copies match. One error read as
--- "2 problems (2 errors)", both rows jumping to the same place.
---
--- The key leaves `col` out on purpose, and that is the one judgement call here.
--- The echoed copy's caret line is indented along with the message, so `%p^`
--- gives it a column two further right (34 and 36 for the same error) — keyed on
--- col, the duplicate survives. The cost is that two genuinely distinct errors
--- with the same message on the same line of the same file collapse into one;
--- keeping the *first* occurrence is what makes that cheap, since the task-output
--- copy is the one with the untouched column.
---
--- The three other dedupes in this config (config/tasks.lua's task names,
--- config/jdk.lua's version majors) are all `seen[string]` over a scalar and have
--- no helper between them, so there was nothing to reuse for a composite key.
function M.parse(lines, opts)
  opts = opts or {}
  local compilers = opts.compilers or {}
  if #compilers == 0 then return {} end

  local input = lines
  if opts.dir and vim.fn.isdirectory(opts.dir) == 1 then
    -- Prepended, not appended: the directory stack has to be set before the
    -- first path is resolved. vim also ignores the entry for a directory that
    -- does not exist, hence the isdirectory guard — a stale target.dir would
    -- otherwise silently fall back to resolving against the cwd.
    input = { "Entering directory '" .. opts.dir .. "'" }
    vim.list_extend(input, lines)
  end

  local ok, parsed = pcall(vim.fn.getqflist, {
    lines = input,
    efm = M.errorformat(compilers),
  })
  if not ok or type(parsed) ~= "table" then return {} end

  local items, seen = {}, {}
  for _, item in ipairs(parsed.items or {}) do
    if item.valid == 1 then
      local key = table.concat({
        tostring(item.bufnr or item.filename or ""),
        tostring(item.lnum or 0),
        tostring(item.type or ""),
        item.text or "",
      }, "\0")
      if not seen[key] then
        seen[key] = true
        table.insert(items, item)
      end
    end
  end
  return items
end

--- A terminal buffer's output as plain lines, trailing blanks removed.
---
--- A terminal buffer is a fixed grid, so every row below the last line of output
--- is present and empty; passing those through the parse is harmless but passing
--- them to #lines is not, and "the build produced no output" is a case the caller
--- distinguishes.
function M.terminal_lines(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return {} end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

--- The marker that makes a quickfix list recognisably ours. See M.publish.
local TITLE_PREFIX = "Build: "

--- Replace the quickfix list with `items` and say what happened.
---
--- Deliberately does not open the quickfix window. The build's terminal is on
--- screen and usually focused (Run moves there), and stealing focus out of a
--- terminal mid-keystroke is worse than one notification naming the key that
--- opens the list. `]q` / `[q` are Neovim 0.11 defaults, so there is nothing to
--- bind for the walk itself.
---
--- A clean build clears the list, but *only* if the list it would clear is one of
--- ours. The quickfix list is shared: `grug-far`, `Telescope quickfix` and
--- `:Trouble qflist` all write to it, and a background `ng serve` rebuilding on
--- every save would otherwise wipe a search result the user is working through.
--- Matching on the title prefix is what distinguishes "my own stale errors" from
--- "someone else's list".
function M.publish(items, opts)
  opts = opts or {}
  local title = TITLE_PREFIX .. (opts.title or "build")
  if #items == 0 then
    local current = vim.fn.getqflist({ title = 0 }).title or ""
    if vim.startswith(current, TITLE_PREFIX) then
      vim.fn.setqflist({}, "r", { title = title, items = {} })
    end
    return 0
  end
  vim.fn.setqflist({}, "r", { title = title, items = items })

  local errors = 0
  for _, item in ipairs(items) do
    if (item.type or ""):lower() ~= "w" then errors = errors + 1 end
  end
  vim.notify(
    ("%s: %d problem%s (%d error%s) — :copen, or ]q to walk them"):format(
      title,
      #items,
      #items == 1 and "" or "s",
      errors,
      errors == 1 and "" or "s"
    ),
    errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO
  )
  return #items
end

--- Read `bufnr`'s output, parse it for `target`, and publish the result.
---
--- Returns the number of items published, or nil when the target has no compiler
--- to parse with — which the caller uses to tell "nothing to parse" apart from
--- "parsed, and the build was clean".
function M.capture(bufnr, target, opts)
  local compilers = M.compilers_for(target)
  if not compilers then return nil end
  opts = opts or {}
  local items = M.parse(M.terminal_lines(bufnr), {
    compilers = compilers,
    dir = opts.dir or (target and target.dir),
  })
  return M.publish(items, { title = opts.title or (target and target.label) or "Build" })
end

return M
