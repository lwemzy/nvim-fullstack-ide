-- config.autocmds — the always-on editor behaviour layer.
--
-- Everything here is asserted against the *observable* effect of the callback
-- (a file on disk, a buffer-local mapping, an ex-command that ran) rather than
-- against the callback object, because the value of this module is entirely in
-- what it does to buffers you did not ask it to touch. The auto-save block is
-- the reason this spec exists: those callbacks write user files unprompted, so
-- the guards that stop them writing are the load-bearing part.
--
-- Real actions (:write, a buffer switch, setting 'filetype') are preferred over
-- nvim_exec_autocmds; every fall back to exec_autocmds is justified inline,
-- and always with `group = ...` so the assertion cannot be satisfied by some
-- other listener on the same event.

local H = require("helpers")

local function load_autocmds()
  -- The module returns nothing, so require() caches `true` and a second
  -- require is a no-op — the cache has to be dropped to re-run the file.
  package.loaded["config.autocmds"] = nil
  require("config.autocmds")
end

-- group -> event -> how many autocmds that group registers for that event.
-- One entry per (event, pattern) pair is what nvim_get_autocmds reports, so the
-- multi-pattern groups count higher than their single autocmd() call suggests.
local EXPECTED = {
  highlight_yank         = { TextYankPost = 1 },
  restore_cursor         = { BufReadPost = 1 },
  java_settings          = { FileType = 1 },
  close_with_q           = { FileType = 5 },
  treesitter_highlight   = { FileType = 1 },
  auto_save_stamp        = { BufReadPost = 1, BufWritePost = 1 },
  auto_save              = { FocusLost = 1, BufLeave = 1 },
  java_new_file_track    = { BufNewFile = 1 },
  java_new_file_reindex  = { BufWritePost = 1 },
  gradle_refresh         = { BufWritePost = 5 },
  auto_reload            = { FocusGained = 1, BufEnter = 1, CursorHold = 1, TermLeave = 1 },
  auto_create_dir        = { BufWritePre = 1 },
}

--- A listed, normal (buftype "") buffer, named or not.
---
--- `scratch = false` is the load-bearing part: unnamed-but-normal and
--- unnamed-nofile are two *different* auto_save exclusions, and the default
--- would silently give the second one.
local function plain_buf(name, lines)
  return H.scratch({ scratch = false, name = name, lines = lines })
end

local ex_commands, ran = H.capture_ex, H.ran_ex

describe("config.autocmds", function()
  after_each(function() H.cleanup() end)

  describe("registration", function()
    before_each(load_autocmds)

    for group, events in pairs(EXPECTED) do
      it("creates the " .. group .. " group with its autocmds", function()
        -- nvim_get_autocmds errors on an unknown group and H.autocmds turns
        -- that into {}, so a non-empty result is also proof the group exists.
        assert.is_true(#H.autocmds({ group = group }) > 0)
        for event, count in pairs(events) do
          assert.equals(count, H.count_autocmds(event, group))
        end
      end)
    end

    it("does not duplicate autocmds when the module is loaded twice", function()
      local before = {}
      for group, events in pairs(EXPECTED) do
        for event in pairs(events) do
          before[group .. "/" .. event] = H.count_autocmds(event, group)
        end
      end

      load_autocmds()

      for group, events in pairs(EXPECTED) do
        for event in pairs(events) do
          local key = group .. "/" .. event
          -- Every group is created with clear = true. If one were not, a
          -- second load (a :source of the config, a reload plugin) would
          -- stack a second auto-save callback and every BufLeave would write
          -- the file twice — the second write racing conform's format-on-save.
          assert.equals(before[key], H.count_autocmds(event, group))
        end
      end
    end)

    it("registers java_settings only for the java filetype", function()
      assert.same({ "java" }, vim.tbl_map(function(a) return a.pattern end,
        H.autocmds({ group = "java_settings" })))
    end)

    it("registers close_with_q for exactly the read-only filetypes", function()
      local patterns = vim.tbl_map(function(a) return a.pattern end,
        H.autocmds({ group = "close_with_q" }))
      table.sort(patterns)
      assert.same({ "checkhealth", "help", "lspinfo", "man", "qf" }, patterns)
    end)

    it("registers treesitter_highlight for every filetype", function()
      -- Pattern "*": highlighting is opted *out* of by size, not opted in by
      -- filetype, so a missing pattern here is the correct shape.
      assert.same({ "*" }, vim.tbl_map(function(a) return a.pattern end,
        H.autocmds({ group = "treesitter_highlight" })))
    end)

    it("watches only *.java for the new-file reindex", function()
      assert.same({ "*.java" }, vim.tbl_map(function(a) return a.pattern end,
        H.autocmds({ group = "java_new_file_track" })))
      assert.same({ "*.java" }, vim.tbl_map(function(a) return a.pattern end,
        H.autocmds({ group = "java_new_file_reindex" })))
    end)

    it("watches every gradle build file for a project refresh", function()
      local patterns = vim.tbl_map(function(a) return a.pattern end,
        H.autocmds({ group = "gradle_refresh" }))
      table.sort(patterns)
      -- Both the Groovy and Kotlin DSL spellings, plus gradle.properties:
      -- missing one means dependency changes in that file never reach jdtls
      -- and completion silently keeps the stale classpath.
      assert.same({
        "build.gradle", "build.gradle.kts", "gradle.properties",
        "settings.gradle", "settings.gradle.kts",
      }, patterns)
    end)
  end)

  describe("highlight_yank", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    it("highlights on TextYankPost without erroring", function()
      local buf = H.scratch({ lines = { "yank me" } })
      -- A real `yy` would do, but the callback reads vim.v.event and an error
      -- inside it surfaces only as an :messages entry during a normal yank —
      -- calling it directly is what makes a regression fail the spec.
      local cmds = H.autocmds({ group = "highlight_yank", event = "TextYankPost" })
      assert.equals(1, #cmds)
      local ok, err = pcall(cmds[1].callback, { buf = buf })
      assert.is_true(ok, tostring(err))
    end)
  end)

  describe("restore_cursor", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    it("moves the cursor to the saved '\"' mark", function()
      local path = H.write(H.tmpdir("cursor") .. "/file.txt",
        { "one", "two", "three", "four", "five" })
      local buf = H.edit(path)
      vim.api.nvim_buf_set_mark(buf, '"', 4, 0, {})
      -- exec_autocmds, not a second :edit: '"' is restored from shada at read
      -- time and a spec cannot control this machine's shada, so setting the
      -- mark and firing the event is the only way to exercise the callback
      -- with a known mark.
      vim.api.nvim_exec_autocmds("BufReadPost", { group = "restore_cursor", buffer = buf })
      assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("leaves the cursor alone when the mark is on line 1", function()
      local path = H.write(H.tmpdir("cursor") .. "/file.txt", { "one", "two", "three" })
      local buf = H.edit(path)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.api.nvim_buf_set_mark(buf, '"', 1, 0, {})
      vim.api.nvim_exec_autocmds("BufReadPost", { group = "restore_cursor", buffer = buf })
      -- `mark[1] > 1` exists so an absent/line-1 mark is not treated as a
      -- position to jump to.
      assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("does not jump past the last line when the mark is stale", function()
      local path = H.write(H.tmpdir("cursor") .. "/file.txt", { "one", "two" })
      local buf = H.edit(path)
      -- The mark has to be faked: nvim_buf_set_mark rejects an out-of-range
      -- line, and truncating the buffer resets the mark to {0,0}. A shada
      -- mark from before the file shrank is exactly this state, and it is the
      -- important case — nvim_win_set_cursor on a line that no longer exists
      -- throws, which would make every :edit of a shrunken file error.
      H.stub(vim.api, "nvim_buf_get_mark", function() return { 99, 0 } end)
      local ok, err = pcall(vim.api.nvim_exec_autocmds, "BufReadPost",
        { group = "restore_cursor", buffer = buf })
      assert.is_true(ok, tostring(err))
      assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    end)
  end)

  describe("java_settings", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    -- Setting 'filetype' to java is safe *because this is a unit spec*: no
    -- language server is configured under minimal_init and ftplugin/java.lua
    -- returns on its first line when require("jdtls") fails, so nothing spawns
    -- and nothing waits. The same assertion in an integration spec would start
    -- a real jdtls.
    it("applies Google Java Style indent and column marker on FileType java", function()
      -- The callback uses vim.opt_local, which resolves against the *current*
      -- buffer/window — so the buffer must already be current when FileType
      -- fires, exactly as it is in real use.
      local buf = H.scratch({ name = H.tmpdir("java") .. "/Foo.java" })
      H.stub(vim.wo, "colorcolumn", vim.wo.colorcolumn)
      vim.bo[buf].filetype = "java"

      assert.equals(2, vim.bo[buf].tabstop)
      assert.equals(2, vim.bo[buf].shiftwidth)
      -- 100, not 80: the checked-in java-google-style.xml wraps at 100, so a
      -- different column here would draw the guide in the wrong place
      -- relative to what format-on-save actually produces.
      assert.equals("100", vim.wo.colorcolumn)
    end)
  end)

  describe("close_with_q", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    for _, ft in ipairs({ "help", "lspinfo", "man", "qf", "checkhealth" }) do
      it("maps q buffer-locally for " .. ft, function()
        local buf = H.scratch({ ft = ft })
        local map = H.keymap("n", "q", buf)
        assert.is_not_nil(map)
        -- buffer = 1: a global `q` would shadow the recording prefix in every
        -- buffer, which is why this is asserted per filetype rather than once.
        assert.equals(1, map.buffer)
        assert.is_true(map.rhs:lower():find("close") ~= nil)
        -- Unlisted too, so :bnext never lands on a help window.
        assert.is_false(vim.bo[buf].buflisted)
      end)
    end

    it("does not map q in an ordinary file buffer", function()
      local buf = H.scratch({ name = H.tmpdir("q") .. "/notes.txt", ft = "text" })
      -- Catastrophic if wrong: `q` would stop being the record/macro prefix
      -- and would start closing the window you are editing in.
      assert.is_nil(H.keymap("n", "q", buf))
    end)
  end)

  describe("treesitter_highlight", function()
    local starts

    before_each(function()
      load_autocmds()
      H.disable_autosave()
      -- The config's only observable is `pcall(vim.treesitter.start, buf)`:
      -- nvim-treesitter is not loaded in unit mode, so the parser for a given
      -- filetype may or may not exist on this machine and the real call's
      -- success is not what is under test — the size guards are.
      starts = H.spy(vim.treesitter, "start")
    end)

    it("starts highlighting for an ordinary small buffer", function()
      local buf = H.scratch({ name = H.tmpdir("ts") .. "/small.txt", lines = { "a", "b" } })
      vim.bo[buf].filetype = "text"
      assert.equals(1, starts.count)
      assert.equals(buf, starts[1][1])
    end)

    it("opts out of a buffer over the 10000-line limit", function()
      local lines = {}
      for i = 1, 10001 do lines[i] = "line " .. i end
      local buf = H.scratch({ name = H.tmpdir("ts") .. "/long.txt", lines = lines })
      vim.bo[buf].filetype = "text"
      -- Over TS_MAX_LINES: treesitter's reparse cost is paid on every
      -- keystroke, so a big file must fall back to regex syntax or typing
      -- visibly lags.
      assert.equals(0, starts.count)
    end)

    it("opts out of a file over the 512KB limit even when it is short", function()
      local path = H.write(H.tmpdir("ts") .. "/wide.txt", { string.rep("x", 600 * 1024) })
      -- Two lines in the buffer, ~600KB on disk: the byte check has to be
      -- independent of the line check or a minified bundle (one enormous line)
      -- slips past both.
      local buf = H.scratch({ name = path, lines = { "x", "y" } })
      vim.bo[buf].filetype = "text"
      assert.equals(0, starts.count)
    end)

    it("opts out of a special buftype", function()
      -- Quickfix/terminal/plugin buffers get their own highlighting and are
      -- rewritten wholesale, so parsing them is pure cost.
      local buf = H.scratch({ lines = { "a" } })
      assert.equals("nofile", vim.bo[buf].buftype)
      vim.bo[buf].filetype = "text"
      assert.equals(0, starts.count)
    end)
  end)

  describe("auto_save", function()
    local dir, path

    before_each(function()
      -- No H.disable_autosave() here: this is the group under test. A fresh
      -- load also resets the auto_save_stamp bookkeeping the guard reads.
      load_autocmds()
      dir = H.tmpdir("autosave")
      path = H.write(dir .. "/note.txt", { "original" })
    end)

    it("writes a modified file-backed buffer on BufLeave", function()
      local buf = H.edit(path) -- BufReadPost stamps the on-disk mtime
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })

      -- Real action: switching the current buffer is what fires BufLeave in
      -- normal use, and it also proves the callback reads the *leaving*
      -- buffer rather than the one being entered.
      H.scratch()

      assert.same({ "edited" }, vim.fn.readfile(path))
      assert.is_false(vim.bo[buf].modified)
    end)

    it("stays silent on a successful auto-save", function()
      local buf = H.edit(path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
      local notes = H.capture_notifications(function() H.scratch() end)
      -- Auto-save fires on every buffer switch; a notification per switch
      -- would make the message area useless.
      assert.same({}, notes)
    end)

    it("skips the write when the file changed on disk after the last stamp", function()
      local buf = H.edit(path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
      -- Backdating the stamp is equivalent to the file having been rewritten
      -- since it was read, without depending on getftime's one-second
      -- resolution (a real rewrite inside the same second is invisible).
      vim.b[buf].autosave_mtime = vim.fn.getftime(path) - 10

      local notes = H.capture_notifications(function() H.scratch() end)

      -- Losing this guard loses user data: `silent! write` does not suppress
      -- the "changed since reading it, really write?" prompt, so the old
      -- behaviour was an invisible prompt the next keystroke answered — often
      -- with yes, clobbering an external edit (git pull, an agent writing
      -- files).
      assert.same({ "original" }, vim.fn.readfile(path))
      assert.is_true(vim.bo[buf].modified)
      assert.equals(1, #notes)
      assert.is_true(notes[1].msg:find("auto%-save skipped") ~= nil)
      assert.is_true(notes[1].msg:find("note.txt", 1, true) ~= nil)
      -- WARN, because the user has to resolve it with an explicit :w.
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)

    it("re-stamps after a write, so the next auto-save is not blocked", function()
      local buf = H.edit(path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first" })
      vim.cmd("silent write") -- BufWritePost re-stamps
      assert.equals(vim.fn.getftime(path), vim.b[buf].autosave_mtime)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "second" })
      H.scratch()
      -- Without the BufWritePost half of auto_save_stamp the stamp would
      -- still describe the pre-write file and every later auto-save would be
      -- refused as an "external change".
      assert.same({ "second" }, vim.fn.readfile(path))
    end)

    it("does nothing for an unmodified buffer", function()
      H.edit(path)
      local cmds = ex_commands(function()
        vim.api.nvim_exec_autocmds("BufLeave", { group = "auto_save" })
      end)
      assert.is_false(ran(cmds, "write"))
    end)

    it("does nothing for a buffer with no name", function()
      plain_buf(nil, { "unsaved scratch work" })
      -- exec_autocmds rather than a buffer switch: the callback reads the
      -- *current* buffer, so it must still be current when the event fires,
      -- and firing it directly keeps the other BufLeave/BufEnter groups out
      -- of the command log.
      local cmds = ex_commands(function()
        vim.api.nvim_exec_autocmds("BufLeave", { group = "auto_save" })
      end)
      -- :write with no file name errors; reaching it at all would mean an
      -- E32 in the message area on every switch away from a scratch buffer.
      assert.is_false(ran(cmds, "write"))
    end)

    for _, buftype in ipairs({ "nofile", "help", "acwrite" }) do
      it("does nothing for a " .. buftype .. " buffer", function()
        local buf = plain_buf(path)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
        vim.bo[buf].buftype = buftype
        local cmds = ex_commands(function()
          vim.api.nvim_exec_autocmds("BufLeave", { group = "auto_save" })
        end)
        -- Plugin-owned buffers (oil, fugitive, dbui, terminals) are not files
        -- the user asked to save, and acwrite in particular routes :write
        -- into a plugin's BufWriteCmd — writing one behind the user's back
        -- can trigger arbitrary plugin side effects.
        assert.is_false(ran(cmds, "write"))
        assert.same({ "original" }, vim.fn.readfile(path))
      end)
    end
  end)

  describe("auto_reload", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    for _, mode in ipairs({ "i", "ic", "R", "Rv", "r", "t", "!", "c", "cv" }) do
      it(("does not checktime in mode %q"):format(mode), function()
        H.scratch({ lines = { "a" } })
        H.stub(vim.fn, "mode", function() return mode end)
        local cmds = ex_commands(function()
          vim.api.nvim_exec_autocmds("CursorHold", { group = "auto_reload" })
        end)
        -- A checktime here reloads the buffer *while the user is typing*:
        -- uncommitted insert-mode text disappears, the completion context is
        -- destroyed and the cursor is relocated into foreign text, so the
        -- next keystrokes edit the wrong place.
        assert.is_false(ran(cmds, "checktime"))
      end)
    end

    it("checktimes in normal mode", function()
      H.scratch({ lines = { "a" } })
      H.stub(vim.fn, "mode", function() return "n" end)
      local cmds = ex_commands(function()
        vim.api.nvim_exec_autocmds("CursorHold", { group = "auto_reload" })
      end)
      assert.is_true(ran(cmds, "checktime"))
    end)

    for _, event in ipairs({ "FocusGained", "BufEnter", "CursorHold", "TermLeave" }) do
      it("checktimes on " .. event, function()
        H.scratch({ lines = { "a" } })
        H.stub(vim.fn, "mode", function() return "n" end)
        local cmds = ex_commands(function()
          vim.api.nvim_exec_autocmds(event, { group = "auto_reload" })
        end)
        -- TermLeave is the one that matters for the Claude panel: files an
        -- agent wrote while you were in the terminal are picked up on exit.
        assert.is_true(ran(cmds, "checktime"))
      end)
    end
  end)

  describe("auto_create_dir", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    it("creates missing parent directories on write", function()
      local dir = H.tmpdir("mkdir")
      local path = dir .. "/one/two/new.txt"
      local buf = H.scratch({ name = path, lines = { "hello" } })
      -- Real :write inside a temp dir: the whole point of the autocmd is that
      -- this does not fail with E212, so anything short of a real write would
      -- be testing the wrong thing.
      vim.cmd("silent write")
      assert.equals(1, vim.fn.isdirectory(dir .. "/one/two"))
      assert.same({ "hello" }, vim.fn.readfile(path))
      assert.is_false(vim.bo[buf].modified)
    end)

    it("is a no-op when the directory already exists", function()
      local dir = H.tmpdir("mkdir")
      local buf = H.scratch({ name = dir .. "/flat.txt", lines = { "hi" } })
      local mkdirs = H.spy(vim.fn, "mkdir")
      vim.api.nvim_exec_autocmds("BufWritePre", { group = "auto_create_dir", buffer = buf })
      -- mkdir with "p" is idempotent, so this only documents that the
      -- callback does not try to be clever about it.
      assert.equals(1, mkdirs.count)
      -- fs_realpath, because nvim stores a buffer's name fully resolved and on
      -- macOS the temp dir lives behind the /var -> /private/var symlink; the
      -- raw H.tmpdir string would compare unequal for that reason alone.
      assert.equals(vim.uv.fs_realpath(dir), mkdirs[1][1])
      assert.equals("p", mkdirs[1][2])
    end)

    it("feeds a URL-style buffer name straight to mkdir (known bug)", function()
      -- KNOWN BUG, reported rather than fixed here: the callback has no URL
      -- guard, so a plugin buffer named like a URL (oil://, fugitive://,
      -- term://) makes it mkdir a *cwd-relative* junk tree — `./oil:/tmp/foo`
      -- under wherever nvim was started, i.e. inside whatever project you are
      -- editing.
      --
      -- vim.fn.mkdir is spied, not called, precisely so running this spec does
      -- not litter the repo the spec lives in. The assertion records today's
      -- behaviour; if a guard is added it should flip to mkdirs.count == 0.
      -- Deliberately not made current (H.scratch would): entering a buffer runs
      -- auto_reload's BufEnter, and this spec is about one BufWritePre callback.
      local buf = H.track_buf(vim.api.nvim_create_buf(true, true))
      vim.api.nvim_buf_set_name(buf, "oil:///tmp/nvim-ide-tests-oil/sub")
      local mkdirs = H.spy(vim.fn, "mkdir")
      vim.api.nvim_exec_autocmds("BufWritePre", { group = "auto_create_dir", buffer = buf })
      assert.equals(1, mkdirs.count)
      assert.equals("oil:///tmp/nvim-ide-tests-oil", mkdirs[1][1])
      assert.is_false(vim.startswith(mkdirs[1][1], "/"))
    end)
  end)

  describe("java_new_file_track / java_new_file_reindex", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    it("does not reindex a saved .java file that was not newly created", function()
      -- The file exists first, so :edit takes the BufReadPost path and
      -- BufNewFile never fires — the real distinction the gate is drawing.
      local path = H.write(H.tmpdir("java") .. "/Existing.java", { "class Existing {}" })
      local buf = H.edit(path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "class Existing { }" })
      local clients = H.spy(vim.lsp, "get_clients", function() return {} end)
      vim.cmd("silent write")
      -- The new_java_bufs gate returns before anything is scheduled, so a
      -- plain :w of an existing file never costs a project reimport — the
      -- reindex is a multi-second Gradle round trip.
      assert.equals(0, clients.count)
    end)

    it("marks a new .java buffer for reindexing and clears the mark after one save", function()
      -- :edit of a path that does not exist yet is what fires BufNewFile, so
      -- this drives the tracking autocmd for real instead of announcing it.
      local path = H.tmpdir("java") .. "/Brand.java"
      local buf = H.edit(path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "class Brand {}" })

      -- get_clients is stubbed because the reindex path calls into vim.lsp and
      -- unit mode has no client; the observable is that the deferred branch is
      -- entered at all, which only happens for a tracked buffer. defer_fn is
      -- run inline so the assertion does not depend on a 1s wall-clock wait.
      local clients = H.spy(vim.lsp, "get_clients", function() return {} end)
      local defers = H.spy(vim, "defer_fn", function(fn) fn() end)
      vim.cmd("silent write")
      assert.equals(1, defers.count)
      assert.equals(1000, defers[1][2])
      assert.equals(1, clients.count)
      assert.same({ name = "jdtls" }, clients[1][1])

      -- Second save: the buffer is no longer new, so it must not reindex
      -- again. Without the clear, every save of that file for the rest of the
      -- session would trigger a project reimport.
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "class Brand { }" })
      vim.cmd("silent write")
      assert.equals(1, defers.count)
    end)
  end)

  describe("gradle_refresh", function()
    before_each(function()
      load_autocmds()
      H.disable_autosave()
    end)

    it("asks jdtls to update the project when a build file is saved", function()
      local path = H.write(H.tmpdir("gradle") .. "/build.gradle", { "plugins {}" })
      local buf = H.edit(path)
      local fake = { name = "jdtls" }
      H.stub(vim.lsp, "get_clients", function() return { fake } end)
      local commands = H.spy(vim.lsp.buf, "execute_command")

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plugins { }" })
      -- Real :write: BufWritePost is the event, and a real save also proves the
      -- pattern list actually matches a file named build.gradle.
      local notes = H.capture_notifications(function() vim.cmd("silent write") end)

      assert.equals(1, commands.count)
      -- The exact command id and a file:// URI argument: jdtls silently
      -- ignores anything else, so a typo here looks like "refresh does
      -- nothing" while still printing the reassuring notification below.
      assert.equals("java.projectConfiguration.update", commands[1][1].command)
      assert.same({ vim.uri_from_fname(vim.uv.fs_realpath(path)) }, commands[1][1].arguments)
      assert.equals(1, #notes)
      assert.equals(vim.log.levels.INFO, notes[1].level)
    end)

    it("does nothing when no jdtls client is attached", function()
      local path = H.write(H.tmpdir("gradle") .. "/build.gradle.kts", { "plugins {}" })
      local buf = H.edit(path)
      H.stub(vim.lsp, "get_clients", function() return {} end)
      local commands = H.spy(vim.lsp.buf, "execute_command")

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plugins { }" })
      local notes = H.capture_notifications(function() vim.cmd("silent write") end)

      -- Saving a build file in a non-Java session (or before jdtls starts)
      -- must not error or claim it refreshed anything.
      assert.equals(0, commands.count)
      assert.same({}, notes)
    end)
  end)
end)
