-- lua/config/problems.lua — build output -> quickfix.
--
-- Everything here is checked against the error formats Neovim actually ships in
-- $VIMRUNTIME/compiler, not against patterns written in the spec: the module's
-- central claim is that javac/maven/tsc output parses without this config owning
-- any of those patterns, and a spec with its own copy of them would pass while
-- the real thing parsed nothing.
--
-- The output samples below are real shapes — javac with and without a column,
-- Maven's [ERROR] form, and the `src/x.ts:4:9 - error TS2322:` line that
-- $VIMRUNTIME/compiler/tsc.vim predates and EXTRA_TSC exists for.
--
-- Unit tier: this is string parsing plus getqflist, with no process and no
-- language server anywhere in it.

local H = require("helpers")

local function problems()
  package.loaded["config.problems"] = nil
  return require("config.problems")
end

--- The quickfix list's title, which is how M.publish marks a list as its own.
local function qf_title()
  return vim.fn.getqflist({ title = 0 }).title or ""
end

describe("config.problems", function()
  local P

  before_each(function()
    P = problems()
    vim.fn.setqflist({}, "f") -- free every list, so no case inherits a title
  end)

  after_each(function()
    package.loaded["config.problems"] = nil
    vim.fn.setqflist({}, "f")
    H.cleanup()
  end)

  describe("errorformat", function()
    it("starts with the directory entry, because the stack must precede the paths", function()
      local efm = P.errorformat({ "javac" })
      assert.is_true(vim.startswith(efm, [[%DEntering\ directory\ '%f']]), efm)
    end)

    it("picks up javac's patterns from $VIMRUNTIME rather than carrying its own", function()
      local efm = P.errorformat({ "javac" })
      -- The exact entries $VIMRUNTIME/compiler/javac.vim sets. If Neovim changes
      -- them the assertion should be re-read, not reworded: that file *is* the
      -- source of truth this module chose.
      assert.is_true(efm:find("%E%f:%l: error: %m", 1, true) ~= nil, efm)
      assert.is_true(efm:find("%W%f:%l: warning: %m", 1, true) ~= nil, efm)
    end)

    it("adds the modern tsc diagnostic shape ahead of the bundled definition", function()
      local efm = P.errorformat({ "tsc" })
      local extra = efm:find([[%f:%l:%c\ -\ %trror\ %m]], 1, true)
      local bundled = efm:find([[%f\ (%l\,%c):\ %trror\ TS%n:\ %m]], 1, true)
      assert.is_not_nil(extra, efm)
      -- Order is the whole point: these definitions end in a %-G catch-all, so
      -- an entry placed after one never runs.
      if bundled then assert.is_true(extra < bundled, efm) end
    end)

    it("puts the one-liners before the multiline esbuild entries", function()
      -- Not cosmetic: `%C%.%#` (the last entry, and not removable — see below)
      -- swallows ANY line while a multiline message is open. With the one-liners
      -- after it, a tsc error printed anywhere downstream of an esbuild error was
      -- absorbed as a continuation line and vanished from the list. Measured both
      -- ways before fixing the order.
      local efm = P.errorformat({ "tsc" })
      local one_liner = efm:find([[%f:%l:%c\ -\ %trror\ %m]], 1, true)
      local multiline = efm:find("%E\xe2\x9c\x98\\ [ERROR]\\ %m", 1, true)
      local continuation = efm:find("%C%.%#", 1, true)
      assert.is_not_nil(multiline, efm)
      assert.is_not_nil(continuation, efm)
      assert.is_true(one_liner < multiline, efm)
      assert.is_true(multiline < continuation, efm)
    end)

    it("returns only the directory entry for a compiler that does not exist", function()
      assert.equals([[%DEntering\ directory\ '%f']], P.errorformat({ "no-such-compiler" }))
    end)
  end)

  describe("compilers_for", function()
    it("maps each build tool to the compilers that produce its output", function()
      assert.same({ "javac" }, P.compilers_for({ tool = "gradle" }))
      assert.same({ "maven" }, P.compilers_for({ tool = "maven" }))
      assert.same({ "tsc" }, P.compilers_for({ tool = "npm" }))
      assert.same({ "tsc" }, P.compilers_for({ tool = "pnpm" }))
    end)

    it("has nothing for a jdtls-launched target, so the caller can skip the parse", function()
      -- A loose .java file: the main class runs through jdtls's debug adapter and
      -- reports failures over DAP, never as compiler text.
      assert.is_nil(P.compilers_for({ tool = "jdtls" }))
      assert.is_nil(P.compilers_for({}))
      assert.is_nil(P.compilers_for(nil))
    end)

    it("hands out a copy, so a caller cannot edit the table every build shares", function()
      local first = P.compilers_for({ tool = "gradle" })
      table.insert(first, "tsc")
      assert.same({ "javac" }, P.compilers_for({ tool = "gradle" }))
    end)
  end)

  describe("parse", function()
    it("reads a javac error, with its line and column", function()
      local items = P.parse({
        "> Task :compileJava FAILED",
        "/src/App.java:12: error: ';' expected",
        "        int x = 1",
        "                 ^",
        "1 error",
      }, { compilers = { "javac" } })

      assert.equals(1, #items)
      assert.equals(12, items[1].lnum)
      assert.is_true(items[1].text:find("';' expected", 1, true) ~= nil, items[1].text)
    end)

    it("reads Maven's bracketed form and keeps its severity", function()
      local items = P.parse({
        "[INFO] Scanning for projects...",
        "[INFO] Compiling 3 source files",
        "[ERROR] /src/App.java:[14,9] cannot find symbol",
        "[INFO] BUILD FAILURE",
      }, { compilers = { "maven" } })

      assert.equals(1, #items)
      assert.equals(14, items[1].lnum)
      assert.equals(9, items[1].col)
      -- maven.vim's own %-G[INFO] %.%# is what drops the lifecycle noise; if the
      -- [INFO] lines came through as items the list would be unnavigable.
      assert.equals("E", items[1].type)
    end)

    it("reads the dash-separated tsc diagnostic the bundled pattern misses", function()
      local items = P.parse({
        "src/app/money.ts:4:9 - error TS2322: Type 'string' is not assignable to type 'number'.",
      }, { compilers = { "tsc" } })

      assert.equals(1, #items)
      assert.equals(4, items[1].lnum)
      assert.equals(9, items[1].col)
      -- Lower-cased: `%trror` captures the literal `e`, where the esbuild
      -- entries' `%E` yields `E`. Vim renders both as "error" and M.publish
      -- lower-cases before counting, so the difference is cosmetic — asserting
      -- it case-insensitively is what keeps that true of the test too.
      assert.equals("e", items[1].type:lower())
      -- The code stays in the message rather than being captured with `TS%n`.
      -- Capturing it required the literal "TS", which silently dropped every
      -- Angular template diagnostic (NG8001) and i18n one (NG-…) — exactly the
      -- errors an Angular build produces most. In the list it reads as part of
      -- the text, which is where it is useful anyway.
      assert.is_true(items[1].text:find("TS2322", 1, true) ~= nil, items[1].text)
    end)

    it("reads an Angular template diagnostic, whose code is not a TS number", function()
      local items = P.parse({
        "src/app/app.component.html:2:5 - error NG8001: 'app-foo' is not a known element.",
      }, { compilers = { "tsc" } })

      assert.equals(1, #items)
      assert.equals(2, items[1].lnum)
      assert.equals(5, items[1].col)
      assert.is_true(items[1].text:find("NG8001", 1, true) ~= nil, items[1].text)
    end)

    it("strips the Error: prefix the Angular webpack builder adds", function()
      -- An errorformat entry is NOT anchored to the start of the line, so with
      -- only the bare form `%f` matched from column 1 and the prefix became part
      -- of the filename: every item pointed at a path like
      -- "<cwd>/Error: src/app/x.ts", a row that looks parsed and cannot be
      -- jumped to. Proved by the differing bufnrs this asserts on.
      local dir = H.tmpdir("ngbuild")
      H.write(dir .. "/src/app/x.ts", { "const x: number = 'a';" })

      local items = P.parse({
        "Error: src/app/x.ts:1:7 - error TS2322: not assignable",
      }, { compilers = { "tsc" }, dir = dir })

      assert.equals(1, #items)
      assert.equals(
        vim.uv.fs_realpath(dir .. "/src/app/x.ts"),
        vim.uv.fs_realpath(vim.api.nvim_buf_get_name(items[1].bufnr))
      )
      assert.equals(1, items[1].lnum)
    end)

    it("reads an esbuild diagnostic, whose location is on a later line", function()
      -- Angular 17+ — the default builder for every new project since — splits
      -- one diagnostic over a header, a blank line and an indented location
      -- line, which no single-line pattern can express. Before this the whole
      -- web half of the module looked broken: a failed `ng build` produced an
      -- empty quickfix list.
      local dir = H.tmpdir("esbuild")
      H.write(dir .. "/src/app/app.component.ts", { "x", "y", "z" })

      local items = P.parse({
        "Application bundle generation failed. [2.253 seconds]",
        "",
        "\xe2\x9c\x98 [ERROR] TS2322: Type 'string' is not assignable to type 'number'. [plugin angular-compiler]",
        "",
        "    src/app/app.component.ts:2:2:",
        "      2 \xe2\x94\x82   count: number = 'nope';",
        "",
      }, { compilers = { "tsc" }, dir = dir })

      assert.equals(1, #items)
      assert.equals(
        vim.uv.fs_realpath(dir .. "/src/app/app.component.ts"),
        vim.uv.fs_realpath(vim.api.nvim_buf_get_name(items[1].bufnr))
      )
      assert.equals(2, items[1].lnum)
      assert.equals("E", items[1].type)
      assert.is_true(items[1].text:find("not assignable", 1, true) ~= nil, items[1].text)
    end)

    it("separates two consecutive esbuild diagnostics", function()
      local items = P.parse({
        "\xe2\x9c\x98 [ERROR] TS2322: bad one [plugin angular-compiler]",
        "",
        "    src/a.ts:1:2:",
        "      1 \xe2\x94\x82 x",
        "",
        "\xe2\x9c\x98 [ERROR] TS2554: bad two [plugin angular-compiler]",
        "",
        "    src/b.ts:3:4:",
        "      3 \xe2\x94\x82 y",
        "",
      }, { compilers = { "tsc" } })

      assert.equals(2, #items)
      assert.equals(1, items[1].lnum)
      assert.equals(3, items[2].lnum)
      assert.is_true(items[1].text:find("bad one", 1, true) ~= nil, items[1].text)
      assert.is_true(items[2].text:find("bad two", 1, true) ~= nil, items[2].text)
    end)

    it("marks an esbuild warning as a warning", function()
      local items = P.parse({
        "\xe2\x96\xb2 [WARNING] TS6385: 'foo' is deprecated. [plugin angular-compiler]",
        "",
        "    src/app/other.ts:4:9:",
        "      4 \xe2\x94\x82   foo();",
        "",
      }, { compilers = { "tsc" } })

      assert.equals(1, #items)
      assert.equals(4, items[1].lnum)
      assert.equals("W", items[1].type)
    end)

    it("keeps a location-less esbuild error as a message-only row", function()
      -- `Could not resolve "./x"` has no location line at all. Deliberately kept
      -- with no file and lnum 0: it is a real failure and the message is the
      -- whole content, and one unjumpable row beats a build that fails with an
      -- empty list.
      local items = P.parse({
        "\xe2\x9c\x98 [ERROR] Could not resolve \"./missing\" [plugin angular-compiler]",
        "",
      }, { compilers = { "tsc" } })

      assert.equals(1, #items)
      assert.equals(0, items[1].lnum)
      assert.is_true(items[1].text:find("Could not resolve", 1, true) ~= nil, items[1].text)
    end)

    it("still finds a tsc one-liner printed after an esbuild diagnostic", function()
      -- The regression the entry order exists for: `%C%.%#` absorbs any line
      -- while a multiline message is open, so with the one-liners placed after
      -- the %E/%W/%Z set this error was swallowed and only the esbuild one
      -- survived.
      local items = P.parse({
        "\xe2\x9c\x98 [ERROR] TS2322: esbuild one [plugin angular-compiler]",
        "",
        "    src/a.ts:1:2:",
        "      1 \xe2\x94\x82 x",
        "",
        "src/b.ts:7:3 - error TS2554: tsc one",
      }, { compilers = { "tsc" } })

      assert.equals(2, #items)
      assert.equals(7, items[2].lnum)
      assert.is_true(items[2].text:find("tsc one", 1, true) ~= nil, items[2].text)
    end)

    it("produces nothing for a clean esbuild build", function()
      local items = P.parse({
        "Application bundle generation complete. [1.2 seconds]",
        "",
      }, { compilers = { "tsc" } })
      assert.same({}, items)
    end)

    it("resolves a relative path against the build directory, not nvim's cwd", function()
      local dir = H.tmpdir("build")
      H.write(dir .. "/src/app/money.ts", { "const x: number = 'a';" })

      local items = P.parse({
        "src/app/money.ts:1:7 - error TS2322: not assignable",
      }, { compilers = { "tsc" }, dir = dir })

      assert.equals(1, #items)
      -- The point of the synthetic "Entering directory" line: without it this
      -- buffer would be a src/app/money.ts under wherever nvim was started.
      assert.equals(
        vim.uv.fs_realpath(dir .. "/src/app/money.ts"),
        vim.uv.fs_realpath(vim.api.nvim_buf_get_name(items[1].bufnr))
      )
    end)

    it("ignores a build directory that no longer exists instead of silently rebasing", function()
      -- vim drops a %D entry for a directory it cannot enter, so this has to not
      -- throw; what it must not do is pretend the paths resolved.
      local items = P.parse({
        "/src/App.java:3: error: bad",
      }, { compilers = { "javac" }, dir = "/definitely/not/here" })
      assert.equals(1, #items)
    end)

    it("has nothing to say when there is no compiler to say it with", function()
      assert.same({}, P.parse({ "/src/App.java:3: error: bad" }, { compilers = {} }))
      assert.same({}, P.parse({ "/src/App.java:3: error: bad" }, nil))
    end)

    it("reports a Gradle error once, though Gradle prints it twice", function()
      -- Verbatim shape of `./gradlew compileJava` on a real failing Spring Boot
      -- build (Gradle 9.7.1, javac 25): the diagnostic appears as the task's own
      -- output and again indented two spaces under "What went wrong". vim's
      -- errorformat skips leading whitespace, so both copies match and the list
      -- used to hold the same error twice — the second with its column shifted
      -- two right, because the `%p^` caret line is indented along with it.
      local items = P.parse({
        "> Task :compileJava FAILED",
        "/p/src/main/java/com/example/demo/Broken.java:4: error: ';' expected",
        '  int bad() { return "not an int" }',
        "                                 ^",
        "1 error",
        "",
        "FAILURE: Build failed with an exception.",
        "",
        "* What went wrong:",
        "Execution failed for task ':compileJava'.",
        "> Compilation failed; see the compiler output below.",
        "  /p/src/main/java/com/example/demo/Broken.java:4: error: ';' expected",
        '    int bad() { return "not an int" }',
        "                                   ^",
        "  1 error",
        "",
        "BUILD FAILED in 1s",
      }, { compilers = { "javac" } })

      assert.equals(1, #items)
      assert.equals(4, items[1].lnum)
      assert.equals("';' expected", items[1].text)
      -- The first occurrence is kept, so the column is the one from the
      -- unindented task output rather than the echo's shifted 36.
      assert.equals(34, items[1].col)
    end)

    it("keeps two distinct errors that share a line and a message", function()
      -- The cost of leaving `col` out of the dedup key is bounded by this: the
      -- key is file+line+severity+text, so same-message errors on *different*
      -- lines both survive, which is the case that actually occurs (an undefined
      -- symbol used twice reads as "cannot find symbol" at each use).
      local items = P.parse({
        "/p/A.java:4: error: cannot find symbol",
        "    int a = missing;",
        "            ^",
        "/p/A.java:9: error: cannot find symbol",
        "    int b = missing;",
        "            ^",
        "2 errors",
      }, { compilers = { "javac" } })
      assert.equals(2, #items)
      assert.equals(4, items[1].lnum)
      assert.equals(9, items[2].lnum)
    end)

    it("drops the lines that matched nothing, since an invalid item cannot be jumped to", function()
      local items = P.parse({
        "Welcome to Gradle 8.14!",
        "BUILD SUCCESSFUL in 3s",
        "4 actionable tasks: 4 executed",
      }, { compilers = { "javac" } })
      assert.same({}, items)
    end)
  end)

  describe("terminal_lines", function()
    it("drops the blank rows a terminal grid always has below the output", function()
      local buf = H.scratch({ lines = { "> Task :compileJava", "BUILD FAILED", "", "", "   " } })
      assert.same({ "> Task :compileJava", "BUILD FAILED" }, P.terminal_lines(buf))
    end)

    it("returns an empty list for a buffer that is gone, rather than throwing", function()
      local buf = H.scratch({ lines = { "x" } })
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.same({}, P.terminal_lines(buf))
      assert.same({}, P.terminal_lines(nil))
    end)
  end)

  describe("publish", function()
    local function one_item()
      return { { filename = "/src/App.java", lnum = 1, col = 1, text = "boom", type = "E", valid = 1 } }
    end

    it("titles the list so it can recognise its own later", function()
      local items = P.parse({ "/src/App.java:7: error: nope" }, { compilers = { "javac" } })
      -- Captured only to keep the report out of the test output; what this case
      -- is about is the title.
      H.capture_notifications(function() P.publish(items, { title = "demo" }) end)
      assert.equals("Build: demo", qf_title())
      assert.equals(1, #vim.fn.getqflist())
    end)

    it("counts errors apart from warnings in what it reports", function()
      local items = P.parse({
        "/src/App.java:7: error: nope",
        "/src/App.java:9: warning: deprecated",
      }, { compilers = { "javac" } })

      local notes = H.capture_notifications(function() P.publish(items, { title = "demo" }) end)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("2 problems", 1, true) ~= nil, notes[1].msg)
      assert.is_true(notes[1].msg:find("1 error", 1, true) ~= nil, notes[1].msg)
    end)

    it("clears its own stale list when the build comes back clean", function()
      vim.fn.setqflist({}, "r", { title = "Build: demo", items = one_item() })
      assert.equals(0, P.publish({}, { title = "demo" }))
      assert.same({}, vim.fn.getqflist())
      assert.equals("Build: demo", qf_title())
    end)

    it("leaves someone else's list alone, so a background rebuild cannot wipe a search", function()
      -- grug-far, :Telescope quickfix and :Trouble qflist all write here. An
      -- `ng serve` recompiling on every save would otherwise clear the results
      -- the user is working through.
      vim.fn.setqflist({}, "r", { title = "Search: TODO", items = one_item() })
      assert.equals(0, P.publish({}, { title = "demo" }))
      assert.equals("Search: TODO", qf_title())
      assert.equals(1, #vim.fn.getqflist())
    end)

    it("says nothing at all for a clean build", function()
      local notes = H.capture_notifications(function() P.publish({}, { title = "demo" }) end)
      assert.same({}, notes)
    end)
  end)

  describe("capture", function()
    it("goes from terminal buffer to a published list in one call", function()
      local dir = H.tmpdir("capture")
      H.write(dir .. "/src/App.java", { "class App {}" })
      local buf = H.scratch({ lines = {
        "> Task :compileJava FAILED",
        "src/App.java:1: error: ';' expected",
        "",
        "",
      } })

      local count = H.capture_notifications(function()
        assert.equals(1, P.capture(buf, { tool = "gradle", dir = dir, label = "demo (gradle)" }))
      end)

      assert.equals("Build: demo (gradle)", qf_title())
      assert.equals(1, #count)
    end)

    it("returns nil for a target with no compiler, which is not the same as a clean build", function()
      local buf = H.scratch({ lines = { "Exception in thread \"main\"" } })
      assert.is_nil(P.capture(buf, { tool = "jdtls", dir = H.tmpdir("nc"), label = "App" }))
    end)
  end)
end)
