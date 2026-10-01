-- One size threshold for every per-keystroke cost in this config.
--
-- The cost that matters is the edit-loop one. Treesitter's incremental reparse is
-- paid on every edit *before* nvim-cmp even debounces — a 3MB/20k-line JSON is
-- ~120ms to parse and ~24ms per keystroke to reparse, which reads as the
-- completion menu lagging rather than as the file being big. Indent guides,
-- colour swatches, reference highlighting and fold providers all recompute on
-- the same change events, and a language server re-analysing the buffer on
-- didChange is the same story an order of magnitude louder.
--
-- This module owns the numbers and the predicates only; the autocmds that act on
-- them are registered in lua/config/autocmds.lua, with the rest of them.

local M = {}

-- Both a line count and a byte count, because neither alone catches both shapes
-- of big file: a generated 20k-line config is cheap per line and expensive in
-- total, while a minified 3MB bundle is a handful of lines that are each
-- individually pathological for a regex engine.
M.MAX_LINES = 10000
M.MAX_BYTES = 512 * 1024

-- A second, much higher tier, used only to decide whether to let a language
-- server have the buffer. Deliberately not the same number: losing treesitter
-- highlighting on a 600KB file is cosmetic, but losing the LSP there would lose
-- completion, diagnostics and go-to-definition — and a 10k-line Java class is an
-- ordinary thing to find in a real project. So the LSP is only given up when the
-- file is one nobody edits by hand. 40k lines is also gitsigns' own built-in
-- max_file_length default, i.e. the same line the ecosystem already draws.
--
-- Crossing this tier is the one case here that notifies, because it is the only
-- one a user would otherwise experience as "autocomplete is broken in this file".
M.LSP_MAX_LINES = 40000
M.LSP_MAX_BYTES = 4 * 1024 * 1024

-- getfsize returns -1 for a file that isn't there (an unwritten buffer), which
-- compares below every threshold — the line count is the only usable signal
-- then, and it is checked first.
local function over(buf, max_lines, max_bytes)
  if vim.api.nvim_buf_line_count(buf) > max_lines then return true end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and (vim.fn.getfsize(name) or 0) > max_bytes
end

---Big enough to turn off per-keystroke decoration (treesitter, indent guides,
---colour swatches, folds).
---@param buf integer
---@return boolean
function M.is_big(buf)
  return over(buf, M.MAX_LINES, M.MAX_BYTES)
end

---Big enough that a language server should not be analysing it at all.
---@param buf integer
---@return boolean
function M.is_too_big_for_lsp(buf)
  return over(buf, M.LSP_MAX_LINES, M.LSP_MAX_BYTES)
end

---Turn off the machinery that costs something on every edit, for one buffer.
---Everything here is buffer-scoped: no global option is touched, so the next
---file opened is unaffected.
---@param buf integer
function M.limit(buf)
  -- Regex syntax stays ON. It is what keeps a merely-large file readable, and
  -- unlike treesitter it is not re-run over the whole buffer on every keystroke.
  -- synmaxcol is the part that actually hangs — Vim's regex engine on a single
  -- 3MB minified line — and 200 columns is past the right edge of any window
  -- this config opens, so nothing visible loses its colour.
  vim.bo[buf].synmaxcol = 200

  -- Per-write rather than per-keystroke, but it is a full serialization of the
  -- undo tree of a file this size on every single save.
  vim.bo[buf].undofile = false

  -- package.loaded, not pcall(require, …): every plugin below is lazy-loaded, and
  -- require() is itself one of lazy.nvim's load triggers — so requiring one here
  -- to ask it to do less would drag it into the session to do nothing, on the
  -- exact buffer where the goal is less work. If it isn't loaded there is
  -- nothing to switch off.

  -- ufo computes folds from the LSP or treesitter provider — both gone on a
  -- buffer this size — and its indent fallback walks the whole buffer.
  if package.loaded["ufo"] then
    pcall(require("ufo").detach, buf)
  end

  -- indent-blankline recomputes its virtual text for the window on every change;
  -- setup_buffer is its own documented per-buffer switch.
  if package.loaded["ibl"] then
    pcall(require("ibl").setup_buffer, buf, { enabled = false })
  end

  -- colorizer re-scans changed lines for colour literals on every edit.
  if package.loaded["colorizer"] then
    pcall(require("colorizer").detach_from_buffer, buf)
  end

  -- vim-illuminate is handled by its own large_file_cutoff /
  -- large_file_overrides (lua/plugins/editor.lua), which read these same
  -- thresholds — it keeps the cheap LSP provider and drops the regex and
  -- treesitter ones, which is better than the all-or-nothing switch here.
end

return M
