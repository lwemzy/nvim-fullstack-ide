-- End-to-end editing behaviour of the booted config: the autocmds in
-- lua/config/autocmds.lua driven with real files, real writes and real buffer
-- switches.
--
-- These are the autocmds that touch the user's data. A unit spec can prove the
-- callbacks make the right decisions with stubs; only a real file can prove the
-- bytes on disk end up right, and every failure mode here is silent — a lost
-- edit, a clobbered external change, a cursor left out of range. So every case
-- below asserts on the file system or on the buffer nvim actually produced.
--
-- Everything happens under H.tmpdir(): the config auto-saves on BufLeave, so a
-- spec that opened a file in this repo would rewrite it.

local H = require("helpers")

--- Set `path`'s mtime `seconds` into the future.
---
-- Shared: getftime's one-second resolution is what makes an explicit mtime bump
-- necessary (see H.touch), and "nil when the file is absent" is what lets the
-- was-not-written assertions read as plainly as the was-written ones.
local set_future_mtime, external_write, disk = H.touch, H.external_write, H.read

--- Switch away from the current buffer for real, which is what fires BufLeave.
---
--- nvim_exec_autocmds("BufLeave") would run the same callback, but then the
--- assertion would only cover the callback and not that the config subscribed
--- to an event that fires when a user presses <C-^>. Auto-save writing at the
--- wrong time (or never) is exactly a wiring bug, so the wiring is under test.
local function leave_buffer()
  return H.scratch()
end

describe("auto-save", function()
  local dir

  before_each(function()
    dir = H.tmpdir("autosave")
  end)

  after_each(function()
    H.cleanup()
  end)

  it("writes a modified buffer to disk when you switch away from it", function()
    local path = H.write(dir .. "/note.txt", { "original" })
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited in the buffer" })

    leave_buffer()

    -- The single most load-bearing behaviour in this config: there is no
    -- :w in the user's muscle memory any more, so a regression here loses work.
    assert.same({ "edited in the buffer" }, disk(path))
    -- 'modified' being cleared is what proves the buffer itself was written,
    -- rather than the same text arriving on disk by some other route.
    assert.is_false(vim.bo[buf].modified)
  end)

  it("says nothing on a successful save", function()
    local path = H.write(dir .. "/quiet.txt", { "original" })
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "quietly edited" })

    local notes = H.capture_notifications(leave_buffer)

    -- Auto-save happens on every buffer switch. One notification per switch
    -- would be a permanent stream of noise, which is why the write is `silent!`
    -- and why the only notify in this augroup is the skip warning below.
    assert.same({}, notes)
    assert.same({ "quietly edited" }, disk(path))
  end)

  it("refuses to overwrite a file that changed on disk after it was read", function()
    local path = H.write(dir .. "/shared.txt", { "original" })
    local buf = H.edit(path)
    -- BufReadPost stamped the mtime; the guard compares against this.
    assert.is_number(vim.b[buf].autosave_mtime)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my edit" })
    external_write(path, { "someone else's edit" })

    local notes = H.capture_notifications(leave_buffer)

    -- Without this guard `silent! write` still stops on the "file has changed
    -- since reading it, really write (y/n)?" prompt — invisible in a real
    -- session, answered by whatever you typed next. Skipping is the safe
    -- outcome: the external change survives and the buffer keeps its edits.
    assert.same({ "someone else's edit" }, disk(path))
    assert.is_true(vim.bo[buf].modified)
    assert.equals(1, #notes)
    assert.is_truthy(notes[1].msg:find("auto%-save skipped"))
    -- The message has to name the file and the way out (:w), because the user
    -- is about to switch buffers again and needs to know their edit is unsaved.
    assert.is_truthy(notes[1].msg:find("shared.txt", 1, true))
    assert.is_truthy(notes[1].msg:find(":w", 1, true))
    assert.equals(vim.log.levels.WARN, notes[1].level)
  end)

  it("saves again once the stamp is refreshed by an explicit write", function()
    local path = H.write(dir .. "/recovered.txt", { "original" })
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my edit" })
    external_write(path, { "someone else's edit" })
    leave_buffer()
    assert.is_true(vim.bo[buf].modified)

    -- The documented recovery path. BufWritePost re-stamps, so auto-save has to
    -- resume afterwards — a guard that latched would silently stop saving this
    -- buffer for the rest of the session.
    --
    -- `write!`, not `write`: a plain :w on a file that changed on disk stops on
    -- nvim's own "Do you really want to write to it (y/n)?" prompt, which a
    -- headless spec can never answer. (The skip message says ":w to overwrite",
    -- which is a keystroke short of the truth — see the report.)
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("write!")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my second edit" })
    leave_buffer()

    assert.same({ "my second edit" }, disk(path))
    assert.is_false(vim.bo[buf].modified)
  end)

  -- The callback's exclusions are exactly: 'modified', buftype == "" and a
  -- non-empty name. The cases below pin each one, because each is the only
  -- thing standing between auto-save and a write that cannot succeed.

  it("does not try to write an unnamed buffer", function()
    -- `enew`, not H.scratch(): a scratch buffer is buftype=nofile and would be
    -- excluded by the buftype check instead, so it could not prove anything
    -- about the name check.
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("", vim.api.nvim_buf_get_name(buf))
    assert.equals("", vim.bo[buf].buftype)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "typed into a new buffer" })

    -- E32 (no file name) is what a write would raise; `silent!` would hide it,
    -- leaving no way to notice except that nothing is ever saved.
    local notes = H.capture_notifications(leave_buffer)
    assert.same({}, notes)
    assert.is_true(vim.bo[buf].modified)
    -- Nothing may be invented on disk from a nameless buffer.
    assert.same({}, vim.fn.readdir(dir))
  end)

  it("does not write buffers whose buftype marks them as not a file", function()
    for _, buftype in ipairs({ "nofile", "nowrite" }) do
      local path = dir .. "/" .. buftype .. ".txt"
      local buf = H.scratch({ name = path, lines = { "plugin-owned content" } })
      vim.bo[buf].buftype = buftype
      vim.bo[buf].modified = true

      leave_buffer()

      -- Pickers, dashboards and preview windows all have real-looking names.
      -- Writing one would create a file the user never asked for, on a path a
      -- plugin chose.
      assert.is_nil(disk(path), buftype .. " buffer was written to disk")
    end
  end)

  it("still writes a nomodifiable buffer, but leaves a readonly one alone", function()
    -- 'modifiable' is NOT in the guard, and that is deliberate: you can turn it
    -- off on a buffer you have already edited, and those edits still have to be
    -- saved. Documented here so a "skip nomodifiable" change has to be an
    -- explicit decision rather than a silent way to lose an edit.
    local nomod = dir .. "/nomodifiable.txt"
    local buf = H.edit(H.write(nomod, { "original" }))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited then locked" })
    vim.bo[buf].modifiable = false
    leave_buffer()
    assert.same({ "edited then locked" }, disk(nomod))

    -- 'readonly' is different: the write fails (E45) and `silent!` swallows it,
    -- so the file must be untouched and the buffer must still be marked
    -- modified — that flag is the only remaining trace that the edit exists.
    local ro = dir .. "/readonly.txt"
    local ro_buf = H.edit(H.write(ro, { "original" }))
    vim.api.nvim_buf_set_lines(ro_buf, 0, -1, false, { "edit to a readonly buffer" })
    vim.bo[ro_buf].readonly = true

    local notes = H.capture_notifications(leave_buffer)
    assert.same({ "original" }, disk(ro))
    assert.is_true(vim.bo[ro_buf].modified)
    assert.same({}, notes)
  end)
end)

describe("auto-create-dir", function()
  local dir

  before_each(function()
    dir = H.tmpdir("mkdir")
    H.disable_autosave()
  end)

  after_each(function()
    H.cleanup()
  end)

  it("creates missing parent directories when a new file is written", function()
    local path = dir .. "/deep/deeper/new.txt"
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line" })

    -- Two levels missing at once: mkdir needs "p", and a single-level test
    -- would pass even without it.
    vim.cmd("write")

    assert.equals(1, vim.fn.isdirectory(dir .. "/deep"))
    assert.equals(1, vim.fn.isdirectory(dir .. "/deep/deeper"))
    assert.same({ "first line" }, disk(path))
  end)

  it("creates the directory for a path written from a different cwd", function()
    -- ev.match is absolute for a real buffer, and the callback resolves it with
    -- fs_realpath before taking :p:h. Writing while cwd is elsewhere is what
    -- catches a relative-path bug: mkdir would land next to the cwd instead.
    local cwd = vim.fn.getcwd()
    local path = dir .. "/from-elsewhere/file.txt"
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
    local other = H.tmpdir("cwd")
    vim.cmd.lcd(other)
    local ok, err = pcall(vim.cmd.write)
    vim.cmd.lcd(cwd)

    assert.is_true(ok, tostring(err))
    assert.equals(1, vim.fn.isdirectory(dir .. "/from-elsewhere"))
    assert.same({ "x" }, disk(path))
    -- Nothing may appear under the unrelated cwd.
    assert.same({}, vim.fn.readdir(other))
  end)

  -- KNOWN GAP, reported rather than fixed (this spec may not edit lua/):
  -- auto_create_dir runs for *every* BufWritePre, including buffers whose name
  -- is a URL a plugin owns (oil://, fugitive://, octo://). fnamemodify(":p:h")
  -- leaves a URL alone, and vim.fn.mkdir() then happily creates a directory
  -- literally called "oil:" under the cwd — i.e. writing an oil.nvim buffer
  -- litters the project root. Left pending so the intended behaviour is
  -- recorded without asserting the current one.
  pending("does not create a directory for a URL-ish buffer name", function()
    local sandbox = H.tmpdir("urlish")
    local cwd = vim.fn.getcwd()
    vim.cmd.lcd(sandbox)
    vim.api.nvim_exec_autocmds("BufWritePre", {
      group = "auto_create_dir",
      pattern = "oil:///" .. sandbox .. "/tree/leaf.txt",
    })
    vim.cmd.lcd(cwd)
    assert.same({}, vim.fn.readdir(sandbox))
  end)
end)

describe("auto-reload", function()
  local dir

  --- Run the auto_reload callback registered for `event`.
  ---
  --- Deliberately not nvim_exec_autocmds: ":checktime" issued from inside an
  --- autocmd is *postponed* by nvim until the main loop reaches a safe state
  --- (:help :checktime), which a headless spec running inside one -c command
  --- never reaches — the buffer then reloads after the assertions, or never.
  --- Calling the registered callback runs the identical code, including the
  --- mode guard, with the reload happening synchronously. The wiring (that the
  --- config really subscribed to these events) is asserted separately below.
  local function reload_check(event)
    local aus = H.autocmds({ group = "auto_reload", event = event })
    assert.equals(1, #aus, "no auto_reload autocmd for " .. event)
    aus[1].callback({})
  end

  before_each(function()
    dir = H.tmpdir("reload")
    H.disable_autosave()
  end)

  after_each(function()
    H.cleanup()
  end)

  it("picks up an external change in normal mode", function()
    local path = H.write(dir .. "/watched.txt", { "before" })
    local buf = H.edit(path)
    external_write(path, { "after" })

    reload_check("FocusGained")

    -- The whole point of the augroup: Claude/git/tsc change a file while you
    -- are looking at it and the buffer must not keep showing stale text you
    -- might then save over.
    assert.same({ "after" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("subscribes to the events that mean 'you may have missed a change'", function()
    -- Wiring check for the callback-level cases above. FocusGained (came back
    -- to the terminal), BufEnter (switched to the buffer), CursorHold (idle),
    -- TermLeave (left the Claude terminal) are each a moment where the file may
    -- have changed while nvim was not looking.
    for _, event in ipairs({ "FocusGained", "BufEnter", "CursorHold", "TermLeave" }) do
      assert.equals(1, H.count_autocmds(event, "auto_reload"), "missing " .. event)
    end
  end)

  it("does not reload while the user is mid-keystroke", function()
    -- The guard is mode():find("^[icRrt!]"). Insert is the case that cost real
    -- text: reloading under the cursor discarded uncommitted input, destroyed
    -- the completion context and moved the cursor into foreign text, so the
    -- next keystrokes edited the wrong place. Cmdline and terminal are the same
    -- hazard for a half-typed command / a running program.
    for _, mode in ipairs({ "i", "c", "t", "R", "!" }) do
      local path = H.write(dir .. "/mode-" .. mode .. ".txt", { "before" })
      local buf = H.edit(path)
      external_write(path, { "after" })

      local restore = H.stub(vim.fn, "mode", function() return mode end)
      reload_check("FocusGained")
      vim.fn.mode = restore

      assert.same(
        { "before" },
        vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        "buffer was reloaded in mode " .. mode
      )
    end
  end)

  it("reloads once the user is back in normal mode", function()
    -- The skip must be a deferral, not a drop: the change still has to arrive,
    -- otherwise the buffer stays stale until the next unrelated event.
    local path = H.write(dir .. "/deferred.txt", { "before" })
    local buf = H.edit(path)
    external_write(path, { "after" })

    local restore = H.stub(vim.fn, "mode", function() return "i" end)
    reload_check("CursorHold")
    vim.fn.mode = restore
    assert.same({ "before" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

    reload_check("CursorHold")
    assert.same({ "after" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("does not reload a modified buffer out from under the user", function()
    -- checktime never reloads a modified buffer; it warns instead. Asserted
    -- here because it is the other half of the auto-save mtime guard: between
    -- the two, an external change to a file you have unsaved edits in can
    -- neither overwrite your buffer nor be overwritten by it without a :w.
    local path = H.write(dir .. "/conflict.txt", { "before" })
    local buf = H.edit(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my unsaved edit" })
    external_write(path, { "external" })

    reload_check("FocusGained")

    assert.same({ "my unsaved edit" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same({ "external" }, disk(path))
  end)
end)

describe("restore-cursor", function()
  local dir

  local function numbered_lines(n)
    local out = {}
    for i = 1, n do
      out[i] = ("line %d"):format(i)
    end
    return out
  end

  before_each(function()
    dir = H.tmpdir("cursor")
    H.disable_autosave()
  end)

  after_each(function()
    H.cleanup()
  end)

  it("puts the cursor back where you left the file", function()
    local path = H.write(dir .. "/long.txt", numbered_lines(40))
    H.edit(path)
    vim.api.nvim_win_set_cursor(0, { 23, 0 })

    -- Leaving sets the '" mark; reopening re-reads the file and fires
    -- BufReadPost. This is the user-visible contract, whichever mechanism gets
    -- there — the next case pins the autocmd itself.
    leave_buffer()
    local buf = H.edit(path)

    assert.equals(23, vim.api.nvim_win_get_cursor(0)[1])
    assert.same({ 23, 0 }, vim.api.nvim_buf_get_mark(buf, '"'))
  end)

  it("jumps to the '\" mark on BufReadPost", function()
    -- A freshly opened buffer with no window history: nvim has nothing of its
    -- own to restore from here, so a cursor that moves can only be this
    -- autocmd. BufReadPost is triggered directly because the mark has to be
    -- planted between the read and the restore, which a real :edit does not
    -- leave room for.
    local buf = H.edit(H.write(dir .. "/marked.txt", numbered_lines(30)))
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    vim.api.nvim_buf_set_mark(buf, '"', 17, 0, {})

    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

    assert.equals(17, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("stays on line 1 when the mark is line 1", function()
    -- mark[1] > 1 exists so a file you left at the top is not "restored" with a
    -- jump that clears the jumplist and scrolls for no reason.
    local buf = H.edit(H.write(dir .. "/top.txt", numbered_lines(10)))
    vim.api.nvim_buf_set_mark(buf, '"', 1, 0, {})
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("does not leave the cursor out of range after the file was truncated", function()
    local path = H.write(dir .. "/shrinking.txt", numbered_lines(40))
    H.edit(path)
    vim.api.nvim_win_set_cursor(0, { 35, 0 })
    leave_buffer()

    -- git checkout of a shorter revision, or a formatter that deletes lines.
    vim.fn.writefile(numbered_lines(5), path)
    local buf = H.edit(path)
    local mark = vim.api.nvim_buf_get_mark(buf, '"')

    -- The stale mark survives the re-read, so the guard is doing real work
    -- here: nvim_win_set_cursor() with it raises "Invalid 'line': out of
    -- range", and an error thrown from BufReadPost aborts the rest of the
    -- BufReadPost chain for every file opened this way.
    assert.is_true(mark[1] > vim.api.nvim_buf_line_count(buf))
    assert.has_error(function()
      vim.api.nvim_win_set_cursor(0, mark)
    end)

    local row = vim.api.nvim_win_get_cursor(0)[1]
    assert.is_true(row >= 1 and row <= vim.api.nvim_buf_line_count(buf))
  end)
end)

describe("close-with-q", function()
  -- Every filetype the config lists. These are all throwaway windows you open
  -- to read one thing, so `q` is the mapping; anything missing from this list
  -- is a window you have to :close by hand.
  local FILETYPES = { "help", "lspinfo", "man", "qf", "checkhealth" }

  before_each(function()
    H.disable_autosave()
  end)

  after_each(function()
    H.cleanup()
  end)

  it("maps buffer-local q for each throwaway filetype", function()
    for _, ft in ipairs(FILETYPES) do
      local buf = H.scratch({ ft = ft })
      local map = H.keymap("n", "q", buf)
      assert.is_not_nil(map, "no q mapping for filetype " .. ft)
      -- buffer-local: a global `q` would break macro recording everywhere.
      assert.equals(1, map.buffer)
      assert.equals(1, map.silent)
      -- Also unlisted, so these windows do not clutter :bnext / the bufferline.
      assert.is_false(vim.bo[buf].buflisted)
    end
  end)

  it("closes the window when q is pressed", function()
    for _, ft in ipairs(FILETYPES) do
      local before = #vim.api.nvim_list_wins()
      vim.cmd("new")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].filetype = ft
      assert.equals(before + 1, #vim.api.nvim_list_wins())

      H.run_keymap("n", "q", buf)

      -- The mapping existing is not the same as it working: `<cmd>close<CR>`
      -- is what makes q usable, and a wrong rhs (:bdelete, :quit) would either
      -- fail here or take the whole session down.
      assert.equals(before, #vim.api.nvim_list_wins(), "q did not close the " .. ft .. " window")
    end
  end)

  it("leaves q alone in an ordinary file buffer", function()
    local path = H.write(H.tmpdir("q") .. "/plain.txt", { "text" })
    local buf = H.edit(path)

    -- q is the most common normal-mode prefix there is (q<reg> records a
    -- macro). A stray non-buffer-local mapping from this augroup would make
    -- every recording attempt close the window instead.
    assert.is_false(H.has_keymap("n", "q", buf))
    assert.is_true(vim.bo[buf].buflisted)
  end)
end)
