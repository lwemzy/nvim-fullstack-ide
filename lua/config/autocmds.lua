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

-- Java: use 4-space indent (convention)
autocmd("FileType", {
  group = augroup("java_settings", { clear = true }),
  pattern = "java",
  callback = function()
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
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

-- Enable treesitter highlighting for every buffer that has a parser
autocmd("FileType", {
  group = augroup("treesitter_highlight", { clear = true }),
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)
  end,
})

-- Save when focus is lost or when switching away from a buffer
autocmd({ "FocusLost", "BufLeave", "InsertLeave" }, {
  group = augroup("auto_save", { clear = true }),
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.fn.expand("%") ~= "" then
      vim.cmd("silent! write")
    end
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
autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermLeave" }, {
  group = augroup("auto_reload", { clear = true }),
  callback = function()
    if vim.fn.mode() ~= "c" then
      vim.cmd("silent! checktime")
    end
  end,
})

-- Auto-create parent directories when saving a new file
autocmd("BufWritePre", {
  group = augroup("auto_create_dir", { clear = true }),
  callback = function(ev)
    local file = vim.uv.fs_realpath(ev.match) or ev.match
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":p:h"), "p")
  end,
})
