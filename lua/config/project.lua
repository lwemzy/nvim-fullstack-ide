-- Bounded upward file search.
--
-- vim.fs.find({ upward = true }) walks to `/` unless given a `stop`, which makes
-- "does this project have X?" answerable by a file that has nothing to do with
-- the project. A stray ~/.prettierrc marked every JS/TS project on the machine as
-- having its own formatting opinion; a stray ~/pom.xml made every loose .java
-- file look like a Spring Boot project. Both are single-file, whole-machine
-- behaviour changes with no visible cause, which is the worst kind.
--
-- Shared rather than inlined at each call site because the ceiling is a judgement
-- call (below), and two copies of a judgement call drift.

local M = {}

--- The directory to stop at, exclusive: `stop` is never itself searched.
---
--- The parent of the VCS root, so the search covers the whole project and nothing
--- above it. The VCS root rather than the nearest package.json / pom.xml: in a
--- monorepo or a multi-module Maven build those stop at the package, hiding the
--- shared config at the repository root that the package actually inherits.
---
--- With no VCS root, $HOME. Not the parent of $HOME: the dotfiles that caused the
--- original bug live directly in $HOME, so $HOME itself must be excluded.
--- A buffer outside $HOME with no VCS root still walks to `/`; that is a handful
--- of stat calls in a directory tree nobody keeps config in.
function M.ceiling(bufnr)
  local root = vim.fs.root(bufnr or 0, { ".git", ".hg", ".svn" })
  if root then return vim.fs.dirname(root) end
  return vim.uv.os_homedir()
end

--- vim.fs.find upward from the buffer's own directory, bounded by M.ceiling.
--- `opts` is passed through to vim.fs.find (e.g. `limit`).
function M.find_upward(bufnr, names, opts)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then return {} end
  return vim.fs.find(
    names,
    vim.tbl_extend("keep", opts or {}, {
      path = vim.fs.dirname(name),
      upward = true,
      stop = M.ceiling(bufnr),
    })
  )
end

return M
