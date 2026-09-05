-- config.options — the editor settings other parts of this config assume.
--
-- Every assertion here is on a value that something else reads: nvim-cmp and
-- vim.lsp read completeopt/pumheight/updatetime/winborder, the formatters
-- assume expandtab+shiftwidth, and the test init itself has to be worked around
-- for the file-safety options. Options that only express taste (cursorline,
-- mouse) are asserted too, but the comments only justify the load-bearing ones.

local H = require("helpers")

-- config.options is a script, not a table-returning module: its whole effect is
-- the assignments it performs, so `require` returns nothing useful and a second
-- require would be a no-op against the cache. Dropping the cache entry first is
-- what makes each spec observe a genuine fresh execution rather than whatever
-- an earlier spec (or the test init) left behind.
local function load_options()
  package.loaded["config.options"] = nil
  require("config.options")
end

-- minimal_init.lua turns swapfile/backup/writebackup/undofile off so a test run
-- cannot litter the real ~/.local/share/nvim. config.options turns undofile
-- back on, so every spec that loads it has to put that back or the rest of this
-- file runs with undo-file writing enabled.
local function restore_no_litter()
  vim.opt.undofile = false
  vim.opt.swapfile = false
  vim.opt.backup = false
  vim.opt.writebackup = false
end

describe("config.options", function()
  before_each(function()
    load_options()
  end)

  after_each(function()
    restore_no_litter()
    package.loaded["config.options"] = nil
    H.cleanup()
  end)

  describe("completion", function()
    it("keeps noinsert and noselect in completeopt", function()
      local co = vim.opt.completeopt:get()
      -- menuone: the popup has to appear for a single match too, otherwise the
      -- one-candidate case silently completes with no chance to inspect it.
      assert.is_true(vim.tbl_contains(co, "menuone"))
      -- noinsert + noselect together are what stop native completion from
      -- mutating the buffer before an explicit choice. Dropping either turns
      -- every popup into a speculative edit that <C-e> then has to undo.
      assert.is_true(vim.tbl_contains(co, "noinsert"))
      assert.is_true(vim.tbl_contains(co, "noselect"))
    end)

    it("does not enable preview or longest in completeopt", function()
      local co = vim.opt.completeopt:get()
      -- "preview" opens a scratch preview window instead of the floating doc
      -- window this config's cmp setup draws, and "longest" inserts the common
      -- prefix, which contradicts noinsert.
      assert.is_false(vim.tbl_contains(co, "preview"))
      assert.is_false(vim.tbl_contains(co, "longest"))
    end)

    it("caps the completion popup at 10 rows", function()
      -- pumheight is the only thing bounding the cmp popup's height; at 0 a
      -- large candidate list fills the window and hides the code being edited.
      assert.equals(10, vim.o.pumheight)
    end)
  end)

  describe("performance", function()
    it("sets updatetime low enough for CursorHold to fire while reading", function()
      -- CursorHold drives diagnostic floats and LSP document highlight. The
      -- 4000ms default makes both feel broken rather than slow.
      assert.equals(250, vim.o.updatetime)
    end)

    it("shortens timeoutlen so leader sequences resolve quickly", function()
      -- which-key's popup delay and every <leader> mapping's feel come from
      -- this; 1000 (the default) reads as a hang after pressing Space.
      assert.equals(300, vim.o.timeoutlen)
    end)
  end)

  describe("ui", function()
    it("sets winborder to rounded", function()
      -- The single most load-bearing option in this file. Three separate
      -- consumers fall back to it instead of taking a per-call border:
      -- vim.lsp.util.open_floating_preview (hover, signature help),
      -- cmp.config.window.bordered() — which returns "none" when winborder is
      -- empty — and nvim_open_win's border default. An empty value here shows
      -- up as borderless hover and completion popups, not as an error.
      assert.equals("rounded", vim.o.winborder)
    end)

    it("enables termguicolors", function()
      -- Every colorscheme in this config defines only 24-bit highlights; with
      -- termguicolors off they degrade to the terminal's 16 colours.
      assert.is_true(vim.o.termguicolors)
    end)

    it("keeps signcolumn always visible", function()
      -- "yes", not "auto": gitsigns and diagnostics both draw here, and "auto"
      -- makes the whole buffer shift horizontally the moment the first sign
      -- appears.
      assert.equals("yes", vim.o.signcolumn)
    end)

    it("uses a global statusline", function()
      -- laststatus=3 is what lets lualine render one bar for the whole window
      -- layout; at 2 each split draws its own and the winbar spacing is wrong.
      assert.equals(3, vim.o.laststatus)
    end)

    it("hides the built-in mode message", function()
      -- lualine already shows the mode; showmode would print a second one over
      -- the command line and fight with notifications.
      assert.is_false(vim.o.showmode)
    end)

    it("shows absolute line numbers only", function()
      assert.is_true(vim.o.number)
      -- relativenumber off is deliberate: this config is keyed to VS Code-style
      -- navigation, where a jump is chosen by absolute line.
      assert.is_false(vim.o.relativenumber)
    end)

    it("highlights the cursor line and enables the mouse everywhere", function()
      assert.is_true(vim.o.cursorline)
      assert.equals("a", vim.o.mouse)
    end)

    it("keeps 8 lines and columns of context around the cursor", function()
      -- scrolloff is why the cursor never sits on the last visible row; a 0 here
      -- means every `j` at the bottom edge scrolls, which is what the centring
      -- <C-d>/<C-u>/n/N mappings in keymaps.lua exist to avoid.
      assert.equals(8, vim.o.scrolloff)
      assert.equals(8, vim.o.sidescrolloff)
    end)

    it("does not soft-wrap long lines", function()
      -- wrap off keeps a screen line equal to a buffer line, which the
      -- line-move mappings and diagnostic virtual text both assume.
      assert.is_false(vim.o.wrap)
    end)
  end)

  describe("whitespace visibility", function()
    it("turns list on", function()
      -- listchars only has an effect while list is set; setting one without the
      -- other is the usual way this pair breaks.
      assert.is_true(vim.o.list)
    end)

    it("renders tabs, trailing spaces and non-breaking spaces distinctly", function()
      -- Asserted as a table, not as the raw string: listchars is a dictionary
      -- option, so its serialised order is not meaningful, but the *set* of
      -- keys is — a missing `trail` is how invisible trailing whitespace gets
      -- committed in a repo whose formatters strip it.
      assert.same({ tab = "» ", trail = "·", nbsp = "␣" }, vim.opt.listchars:get())
    end)
  end)

  describe("indentation", function()
    it("expands tabs to two spaces consistently", function()
      -- tabstop and shiftwidth have to agree: if they differ, `>>` and a
      -- literal Tab produce different widths in the same file and every
      -- formatter run reflows lines the editor just indented.
      assert.equals(2, vim.o.tabstop)
      assert.equals(2, vim.o.shiftwidth)
      assert.equals(vim.o.tabstop, vim.o.shiftwidth)
      assert.is_true(vim.o.expandtab)
    end)

    it("applies the same indentation to buffers opened later", function()
      -- tabstop/shiftwidth/expandtab are buffer-scoped. Using `vim.opt` (rather
      -- than `vim.bo`) sets the global default as well, so buffers created
      -- after startup inherit it — this is the assertion that would catch a
      -- change to `vim.bo`, which would only ever configure buffer 1.
      local buf = H.scratch()
      assert.equals(2, vim.bo[buf].tabstop)
      assert.equals(2, vim.bo[buf].shiftwidth)
      assert.is_true(vim.bo[buf].expandtab)
    end)

    it("enables smartindent", function()
      assert.is_true(vim.o.smartindent)
    end)
  end)

  describe("search", function()
    it("pairs ignorecase with smartcase", function()
      -- The pair is the point: ignorecase alone makes an uppercase pattern
      -- unable to express "case-sensitive", and smartcase alone does nothing.
      assert.is_true(vim.o.ignorecase)
      assert.is_true(vim.o.smartcase)
    end)

    it("uses incremental search without persistent highlight", function()
      -- hlsearch off is why the <Esc> -> :nohlsearch mapping in keymaps.lua is
      -- only a safety net; if this flipped to true the highlight would linger
      -- after every search instead of clearing on its own.
      assert.is_true(vim.o.incsearch)
      assert.is_false(vim.o.hlsearch)
    end)
  end)

  describe("files", function()
    it("enables persistent undo pointed at the data dir", function()
      -- undofile is what makes undo survive closing a buffer. Asserted right
      -- after a fresh load because the test init deliberately turns it off
      -- again (see restore_no_litter) to keep the suite from writing undo files.
      assert.is_true(vim.o.undofile)
      -- Under stdpath("data"), not the file's own directory, so undo history is
      -- never left behind inside a project tree.
      assert.equals(vim.fn.stdpath("data") .. "/undo", vim.o.undodir)
    end)

    it("disables swapfiles and backups", function()
      -- With undofile on, swap and backup files are redundant noise that also
      -- produce the "swap file already exists" prompt when nvim is killed.
      assert.is_false(vim.o.swapfile)
      assert.is_false(vim.o.backup)
    end)

    it("enables autoread so external changes are picked up", function()
      -- Format-on-save tooling and git operations rewrite files under the
      -- editor; without autoread the buffer silently keeps the stale content.
      assert.is_true(vim.o.autoread)
    end)

    it("defaults new files to utf-8", function()
      -- fileencoding is buffer-scoped, so this only holds for later buffers
      -- because `vim.opt` also writes the global default.
      assert.equals("utf-8", vim.o.fileencoding)
      local buf = H.scratch()
      assert.equals("utf-8", vim.bo[buf].fileencoding)
    end)
  end)

  describe("splits and clipboard", function()
    it("opens new splits right and below", function()
      -- The <C-S-v>/<C-S-x> split mappings and every plugin that opens a split
      -- inherit this; the vim defaults put new windows left/above, which
      -- reverses the layout those mappings are documented to produce.
      assert.is_true(vim.o.splitright)
      assert.is_true(vim.o.splitbelow)
    end)

    it("shares the unnamed register with the system clipboard", function()
      -- The explicit <C-y> ("+y) mappings in keymaps.lua still work without
      -- this, but plain y/p depend on it entirely.
      assert.is_true(vim.tbl_contains(vim.opt.clipboard:get(), "unnamedplus"))
    end)
  end)

  describe("module", function()
    it("is idempotent: a second load changes nothing", function()
      -- init.lua requires this once, but a :source of the config or a plugin
      -- that re-requires it must not flip anything. This also proves no
      -- assignment here is a toggle or an append to a previous value — the
      -- classic failure being `opt.listchars:append(...)` style code, which
      -- would grow the value on every load.
      local names = {
        "completeopt", "pumheight", "updatetime", "timeoutlen", "winborder",
        "termguicolors", "signcolumn", "laststatus", "showmode", "number",
        "relativenumber", "cursorline", "mouse", "scrolloff", "sidescrolloff",
        "wrap", "list", "listchars", "tabstop", "shiftwidth", "expandtab",
        "smartindent", "ignorecase", "smartcase", "incsearch", "hlsearch",
        "undofile", "undodir", "swapfile", "backup", "autoread", "fileencoding",
        "splitright", "splitbelow", "clipboard",
      }
      local before = {}
      for _, name in ipairs(names) do before[name] = vim.o[name] end

      load_options()

      local after = {}
      for _, name in ipairs(names) do after[name] = vim.o[name] end
      assert.same(before, after)
    end)
  end)
end)
