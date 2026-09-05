local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Highlight yanked text briefly
autocmd("TextYankPost", {
  group = augroup("highlight_yank", { clear = true }),
  callback = function() vim.highlight.on_yank() end,
})

-- Restore cursor position on file open
autocmd("BufReadPost", {
  group = augroup("restore_cursor", { clear = true }),
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    if mark[1] > 1 and mark[1] <= vim.api.nvim_buf_line_count(0) then
      vim.api.nvim_win_set_cursor(0, mark)
    end
  end,
})

-- Java: 2-space indent (Google Java Style Guide §4.2) — matches
-- java-google-style.xml's actual formatter output (ftplugin/java.lua),
-- so what you type before format-on-save already looks like the result.
autocmd("FileType", {
  group = augroup("java_settings", { clear = true }),
  pattern = "java",
  callback = function()
    vim.opt_local.tabstop = 2
    vim.opt_local.shiftwidth = 2
    -- Google style §4.4: line length is 100 columns
    vim.opt_local.colorcolumn = "100"
  end,
})

-- Close certain filetypes with just 'q'
autocmd("FileType", {
  group = augroup("close_with_q", { clear = true }),
  pattern = { "help", "lspinfo", "man", "qf", "checkhealth" },
  callback = function(ev)
    vim.bo[ev.buf].buflisted = false
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = ev.buf, silent = true })
  end,
})

-- Enable treesitter highlighting for every buffer that has a parser.
-- Load-bearing: nvim-treesitter `main` no longer starts highlighting itself.
-- Guarded on size and buftype because treesitter's incremental reparse is paid
-- on every edit *before* nvim-cmp even debounces — a 3MB/20k-line JSON costs
-- ~120ms to parse and ~24ms per keystroke to reparse, which reads as the
-- completion menu lagging. Big files fall back to regex syntax instead.
local TS_MAX_LINES = 10000
local TS_MAX_BYTES = 512 * 1024
autocmd("FileType", {
  group = augroup("treesitter_highlight", { clear = true }),
  callback = function(args)
    if vim.bo[args.buf].buftype ~= "" then return end
    if vim.api.nvim_buf_line_count(args.buf) > TS_MAX_LINES then return end
    local name = vim.api.nvim_buf_get_name(args.buf)
    if name ~= "" and (vim.fn.getfsize(name) or 0) > TS_MAX_BYTES then return end
    pcall(vim.treesitter.start, args.buf)
  end,
})

-- Track the on-disk mtime we last synced with, so auto-save can tell whether
-- the file changed underneath us.
local function stamp(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" then vim.b[buf].autosave_mtime = vim.fn.getftime(name) end
end
autocmd({ "BufReadPost", "BufWritePost" }, {
  group = augroup("auto_save_stamp", { clear = true }),
  callback = function(ev) stamp(ev.buf) end,
})

-- Save when focus is lost or when switching away from a buffer.
--
-- InsertLeave was deliberately REMOVED from this list. It made every single
-- exit from insert mode write the file, which then fired conform.nvim's
-- format_after_save (BufWritePost) — an async prettier run that rewrote the
-- buffer ~130ms later, i.e. after you had already started typing again, moving
-- the cursor mid-expression. It also meant two writes per InsertLeave and made
-- format-on-save nondeterministic (conform drops its result with
-- CONCURRENT_MODIFICATION, silently, if you type during the run).
autocmd({ "FocusLost", "BufLeave" }, {
  group = augroup("auto_save", { clear = true }),
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if not (vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.fn.expand("%") ~= "") then
      return
    end
    -- `silent! write` does NOT suppress the "file has changed since reading it,
    -- really write (y/n)?" prompt, and a modified buffer is never auto-reloaded
    -- by checktime — so without this guard an external edit (git pull, Claude
    -- writing files) made Esc/buffer-switch freeze on an invisible prompt that
    -- your next keystroke then answered. Skip the auto-save instead and let the
    -- user resolve it with an explicit :w.
    local name = vim.api.nvim_buf_get_name(buf)
    local known = vim.b[buf].autosave_mtime
    if known and vim.fn.getftime(name) > known then
      vim.notify(
        "auto-save skipped: " .. vim.fn.fnamemodify(name, ":t") .. " changed on disk (:w to overwrite)",
        vim.log.levels.WARN
      )
      return
    end
    vim.cmd("silent! write")
  end,
})

-- Java: reindex project when a new .java file is first saved
local new_java_bufs = {}
autocmd("BufNewFile", {
  group = augroup("java_new_file_track", { clear = true }),
  pattern = "*.java",
  callback = function(ev)
    new_java_bufs[ev.buf] = true
  end,
})
autocmd("BufWritePost", {
  group = augroup("java_new_file_reindex", { clear = true }),
  pattern = "*.java",
  callback = function(ev)
    if not new_java_bufs[ev.buf] then return end
    new_java_bufs[ev.buf] = nil
    local bufname = vim.api.nvim_buf_get_name(ev.buf)
    vim.defer_fn(function()
      local clients = vim.lsp.get_clients({ name = "jdtls" })
      if #clients == 0 then return end
      vim.lsp.buf.execute_command({
        command = "java.projectConfiguration.update",
        arguments = { vim.uri_from_fname(bufname) },
      })
      vim.notify("Java: reindexing project for new file…", vim.log.levels.INFO)
    end, 1000)
  end,
})

-- Gradle: refresh jdtls project config when build files are saved
autocmd("BufWritePost", {
  group = augroup("gradle_refresh", { clear = true }),
  pattern = { "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties" },
  callback = function()
    local clients = vim.lsp.get_clients({ name = "jdtls" })
    if #clients == 0 then return end
    local uri = vim.uri_from_fname(vim.api.nvim_buf_get_name(0))
    vim.lsp.buf.execute_command({
      command = "java.projectConfiguration.update",
      arguments = { uri },
    })
    vim.notify("Gradle: refreshing project dependencies…", vim.log.levels.INFO)
  end,
})

-- Auto-reload files changed outside Neovim
-- TermLeave fires when exiting a terminal (e.g. Claude panel) — ideal for
-- picking up file changes Claude made while you were in the terminal.
--
-- CursorHoldI was REMOVED. It ran :checktime from the insert-mode idle timer, so
-- if a file changed on disk while you paused typing (Claude writing files, git
-- pull, tsc/jest --watch) nvim reloaded the buffer *while you were still in
-- insert mode*: your uncommitted text vanished, the completion context was
-- destroyed, and the cursor was relocated into foreign text, so the next
-- keystrokes edited the wrong place. The mode guard below is defence in depth
-- for the remaining events (BufEnter can fire in insert mode).
autocmd({ "FocusGained", "BufEnter", "CursorHold", "TermLeave" }, {
  group = augroup("auto_reload", { clear = true }),
  callback = function()
    -- skip insert, replace, cmdline, terminal and operator-pending
    if vim.fn.mode():find("^[icRrt!]") then return end
    vim.cmd("silent! checktime")
  end,
})

-- Auto-create parent directories when saving a new file
autocmd("BufWritePre", {
  group = augroup("auto_create_dir", { clear = true }),
  callback = function(ev)
    -- Only real files. A plugin buffer (oil://, fugitive://, term://) is written
    -- through a BufWriteCmd and its name is a URL, not a path: fs_realpath
    -- returns nil, fnamemodify(":p:h") leaves the scheme alone, and mkdir then
    -- creates a *cwd-relative* junk tree — writing an oil:// buffer left
    -- ./oil:/tmp/... inside whatever project you were editing. Every such buffer
    -- has a non-empty buftype ("acwrite"/"nofile"/"terminal"); a real file's is "".
    if vim.bo[ev.buf].buftype ~= "" then return end
    local file = vim.uv.fs_realpath(ev.match) or ev.match
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":p:h"), "p")
  end,
})
