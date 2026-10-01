-- One size threshold for every per-keystroke cost in this config.
--
-- The cost that matters is the edit-loop one. Treesitter's incremental reparse is
-- paid on every edit *before* nvim-cmp even debounces — measured on a generated
-- 20k-line Lua file it is 68ms median per edit, and 74ms (122ms p95) on a
-- comparable Markdown one, which reads as the completion menu lagging rather than
-- as the file being big. Indent guides, colour swatches, reference highlighting
-- and fold providers all recompute on the same change events, and a language
-- server re-analysing the buffer on didChange is the same story an order of
-- magnitude louder.
--
-- This module owns the numbers and the actions only; the autocmds that decide
-- when to apply them are registered in lua/config/autocmds.lua, with the rest.

local M = {}

-- Both a line count and a byte count, because neither alone catches both shapes
-- of big file: a generated 20k-line config is cheap per line and expensive in
-- total, while a minified 3MB bundle is a handful of lines that are each
-- individually pathological for a regex engine.
M.MAX_LINES = 10000
M.MAX_BYTES = 512 * 1024

-- A second, much higher tier, for the LSP features that scale with document size
-- rather than with the edit. Deliberately not the same number: losing treesitter
-- highlighting on a 600KB file is cosmetic, but a 10k-line Java class is an
-- ordinary thing to find in a real project and must keep completion, diagnostics
-- and go-to-definition. 40k lines is also gitsigns' own built-in max_file_length
-- default, i.e. the same line the ecosystem already draws.
M.LSP_MAX_LINES = 40000
M.LSP_MAX_BYTES = 4 * 1024 * 1024

-- getfsize returns -1 for a file that isn't there (an unwritten buffer), which
-- compares below every threshold — the line count is the only usable signal
-- then, and it is checked first.
local function over(buf, max_lines, max_bytes)
  if vim.api.nvim_buf_line_count(buf) > max_lines then return true end
  return M.file_over(vim.api.nvim_buf_get_name(buf), max_bytes)
end

---Is the file at `path` alone over `max_bytes`?
---
---Split out because at BufReadPre the buffer still holds the *outgoing* file (on
---a reload it holds the previous contents of this one), so the line count is
---meaningless there and the on-disk size is the only honest signal.
---@param path string
---@param max_bytes integer
---@return boolean
function M.file_over(path, max_bytes)
  return path ~= "" and vim.fn.getfsize(path) > max_bytes
end

---Big enough to turn off per-keystroke decoration (treesitter, indent guides,
---colour swatches, folds).
---@param buf integer
---@return boolean
function M.is_big(buf)
  return over(buf, M.MAX_LINES, M.MAX_BYTES)
end

---Big enough that a language server's whole-document features should be off.
---@param buf integer
---@return boolean
function M.is_heavy_for_lsp(buf)
  return over(buf, M.LSP_MAX_LINES, M.LSP_MAX_BYTES)
end

---Turn off the machinery that costs something on every edit, for one buffer.
---Everything here is buffer-scoped: no global option is touched, so the next
---file opened is unaffected. Safe to call more than once on the same buffer.
---@param buf integer
function M.limit(buf)
  -- Regex syntax is what keeps a merely-large file readable, and unlike
  -- treesitter it is not re-run over the whole buffer on every keystroke.
  -- synmaxcol is the part that actually hangs — Vim's regex engine on a single
  -- 3MB minified line — and 200 columns is past the right edge of any window
  -- this config opens, so nothing visible loses its colour.
  vim.bo[buf].synmaxcol = 200

  -- Per-write rather than per-keystroke, but it is a full serialization of the
  -- undo tree of a file this size on every single save.
  vim.bo[buf].undofile = false

  -- Everything below is scheduled, and that is load-bearing rather than tidiness.
  -- This function is called from autocmds registered in lua/config/autocmds.lua,
  -- which init.lua requires *before* lazy.setup — so our FileType callback runs
  -- ahead of every other FileType handler in the session, including Neovim's own
  -- runtime ftplugins (their `filetypeplugin` group is created while the runtime
  -- is sourced, i.e. after the user config). Anything attached from a FileType
  -- handler therefore cannot be detached inline: the detach finds nothing, and the
  -- attach happens a moment later. Measured both ways — colorizer stayed attached
  -- to a 12000-line CSS file, and a 20002-line .lua file came out of the guard
  -- with the treesitter highlighter active, because Neovim's lua ftplugin calls
  -- vim.treesitter.start() after we had already decided not to.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end

    -- Neovim's own ftplugins for lua, markdown, help and query start treesitter
    -- themselves, so on those filetypes not calling start() achieves nothing and
    -- it has to be stopped.
    --
    -- Restoring `syntax` is the other half, and it is not optional: start()
    -- clears it ("By default, disables regex syntax highlighting", runtime
    -- lua/vim/treesitter.lua) and stop() does not put it back, so stopping alone
    -- leaves a big Lua or Markdown file with no highlighting at all.
    if vim.treesitter.highlighter.active[buf] then
      pcall(vim.treesitter.stop, buf)
      local ft = vim.bo[buf].filetype
      if ft ~= "" and vim.bo[buf].syntax == "" then
        vim.bo[buf].syntax = ft
      end
    end

    -- package.loaded, not pcall(require, …): every plugin below is lazy-loaded,
    -- and require() is itself one of lazy.nvim's load triggers — so requiring one
    -- here to ask it to do less would drag it into the session to do nothing, on
    -- the exact buffer where the goal is less work. If it isn't loaded there is
    -- nothing to switch off. The require itself is inside the pcall because a
    -- loaded-but-broken module would otherwise throw past it.

    -- ufo computes folds from the LSP or treesitter provider — both gone on a
    -- buffer this size — and its indent fallback walks the whole buffer.
    if package.loaded["ufo"] then
      pcall(function() require("ufo").detach(buf) end)
    end

    -- indent-blankline recomputes its virtual text for the window on every
    -- change; setup_buffer is its own documented per-buffer switch.
    if package.loaded["ibl"] then
      pcall(function() require("ibl").setup_buffer(buf, { enabled = false }) end)
    end

    -- colorizer re-scans changed lines for colour literals on every edit.
    if package.loaded["colorizer"] then
      pcall(function() require("colorizer").detach_from_buffer(buf) end)
    end

    -- rainbow-delimiters runs a treesitter query over the buffer and places an
    -- extmark per delimiter — 40,000 of them on a 20k-line file, and it has no
    -- size condition of its own.
    --
    -- Gated on "rainbow-delimiters.lib", not on "rainbow-delimiters": the plugin
    -- attaches from a FileType autocmd in its own plugin/ directory that requires
    -- only `rainbow-delimiters.config` and `rainbow-delimiters.lib`, so the
    -- top-level module is never in package.loaded even while the plugin is loaded
    -- and attached. Measured: the top-level key was nil on a 20002-line Lua file
    -- with rainbow-delimiters active, so this opt-out had never once run. The call
    -- itself still goes through the public module, which `lib` being loaded makes
    -- a plain require rather than a lazy.nvim load trigger.
    if package.loaded["rainbow-delimiters.lib"] then
      pcall(function() require("rainbow-delimiters").disable(buf) end)
    end

    -- illuminate has its own line-based cutoff (set from MAX_LINES in
    -- lua/plugins/editor.lua), but it only ever compares line('$') — so the
    -- minified-bundle shape, few lines and megabytes of them, slips past it and
    -- has to be stopped here. engine.stop_buf rather than the top-level
    -- illuminate.stop_buf because only the engine's version takes a bufnr; the
    -- public wrapper drops the argument and acts on the current buffer.
    if package.loaded["illuminate"] then
      pcall(function() require("illuminate.engine").stop_buf(buf) end)
    end
  end)
end

---Turn off the LSP features whose cost scales with the size of the document
---rather than with the edit, for one buffer. The client stays attached.
---
---Detaching the client instead was the obvious move and it is the wrong one.
---Three separate things break:
---
---  * lua/config/lsp_reap.lua derives idleness from client.attached_buffers, so
---    detaching the only Java buffer empties it and the reaper stops the JVM five
---    minutes later — a second notification saying "no open buffers" about a file
---    still on screen, and a ~30s project import to get it back.
---  * the LspAttach handler in lua/plugins/lsp.lua binds gd/gr/K/rename/code
---    action synchronously, and barbecue attaches navic, so a detach one tick
---    later leaves those bound to a client that is gone: "the LSP is half broken"
---    rather than "the LSP is off here".
---  * Client:on_attach queues its own capability init *after* firing LspAttach
---    (runtime lua/vim/lsp/client.lua), so a scheduled detach runs first (FIFO)
---    and the capability is created after the teardown that would have removed
---    it — leaking its augroup, with inlay hints live inside it.
---
---Turning the expensive features off keeps completion, diagnostics and go-to
---working, which is what makes a 40k-line file feel big rather than broken.
---@param buf integer
---@param client vim.lsp.Client
function M.limit_lsp(buf, client)
  -- Inlay hints re-request on every viewport change and every didChange, and
  -- resolve to one extmark per hint; this config's own inlay-hint column errors
  -- on generated files were what first made the cost visible.
  pcall(vim.lsp.inlay_hint.enable, false, { bufnr = buf })

  -- Semantic tokens are a full-document re-tokenization per edit unless the
  -- server supports deltas, and the response is one highlight per token.
  if client.server_capabilities and client.server_capabilities.semanticTokensProvider then
    pcall(vim.lsp.semantic_tokens.stop, buf, client.id)
  end

  -- documentHighlight, the request illuminate's LSP provider makes on every
  -- CursorMoved. stop_buf covers the other two providers at the same time.
  if package.loaded["illuminate"] then
    pcall(function() require("illuminate.engine").stop_buf(buf) end)
  end
end

return M
