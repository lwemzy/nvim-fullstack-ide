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
      local extra = efm:find([[%f:%l:%c\ -\ %trror\ TS%n:\ %m]], 1, true)
      local bundled = efm:find([[%f\ (%l\,%c):\ %trror\ TS%n:\ %m]], 1, true)
      assert.is_not_nil(extra, efm)
      -- Order is the whole point: these definitions end in a %-G catch-all, so
      -- an entry placed after one never runs.
      if bundled then assert.is_true(extra < bundled, efm) end
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
      assert.equals(2322, items[1].nr)
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
