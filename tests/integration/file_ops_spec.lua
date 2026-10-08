-- lua/config/file_ops.lua — LSP-aware renames from the file explorer.
--
-- Integration tier because the subject is an interaction between three things
-- that each have their own ordering rules: nvim-tree's rename action (which
-- dispatches WillRenameNode before uv.fs_rename and NodeRenamed after it),
-- nvim-lsp-file-operations (which answers the first by sending a synchronous
-- workspace/willRenameFiles and applying the reply), and this config (which has
-- to write the result, because vim.lsp.util never does). A unit test of any one
-- of them would prove nothing about the ordering, which is where all the
-- failure modes are.
--
-- The rename goes through nvim-tree's real action rather than through
-- events._dispatch_* : those dispatches are the thing whose order is in
-- question, so faking them would assume the answer.
--
-- The server is fake (helpers.fake_lsp), which makes it a real vim.lsp.Client
-- over an in-process transport — real capability negotiation, real request_sync,
-- real apply_workspace_edit. Using jdtls here would mean a Gradle project and
-- tens of seconds of indexing to assert something about this config's plumbing.

local H = require("helpers")
local fake_lsp = require("helpers.fake_lsp")

--- What jdtls advertises for willRename, per its InitHandler: a `**/*.java`
--- pattern plus a folder pattern for package moves.
local JAVA_FILTERS = {
  { pattern = { glob = "**/*.java", matches = "file" } },
  { pattern = { glob = "**", matches = "folder" } },
}

describe("config.file_ops", function()
  local dir, srv

  --- A loaded buffer for `path` that was never entered — the shape
  --- apply_text_edits leaves behind for a file that merely referenced the
  --- renamed one.
  local function hidden(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf) -- fires BufReadPost, so auto_save_stamp stamps it
    H.track_buf(buf)
    return buf
  end

  --- Start a fake server on `bufnr` that answers willRenameFiles by replacing
  --- the whole first line of `target` with `line`.
  local function serve(bufnr, target, line, filters)
    local started = fake_lsp.start({
      name = "fake_jdtls",
      bufnr = bufnr,
      root_dir = dir,
      capabilities = {
        workspace = { fileOperations = { willRename = { filters = filters or JAVA_FILTERS } } },
      },
      responses = {
        ["workspace/willRenameFiles"] = function()
          return {
            changes = {
              [vim.uri_from_fname(target)] = {
                {
                  range = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 1, character = 0 },
                  },
                  newText = line .. "\n",
                },
              },
            },
          }
        end,
      },
    })
    H.track_client(started.id)
    return started
  end

  local function rename(from, to)
    -- Swallows nvim-tree's own "from -> to" info toast.
    H.capture_notifications(function()
      require("nvim-tree.actions.fs.rename-file").rename({ absolute_path = from }, to)
    end)
  end

  before_each(function()
    -- The group under test writes buffers, so the BufLeave auto-save must not
    -- be able to write anything too — otherwise a pass could come from either.
    H.disable_autosave()
    -- Loads nvim-tree (cmd-triggered, so not loaded at startup) and with it the
    -- tail of its config, which is what calls config.file_ops.setup().
    H.load_plugin("nvim-tree.lua")
    dir = H.tmpdir("file-ops")
  end)

  after_each(H.cleanup)

  it("loads nvim-lsp-file-operations with nvim-tree, not at startup", function()
    -- The capability require in config.capabilities must not have been a load
    -- trigger: that would drag nvim-tree in at client-start time and undo its
    -- cmd-only trigger, which is ~30ms of startup.
    local plugin = require("lazy.core.config").plugins["nvim-lsp-file-operations"]
    assert.is_truthy(plugin, "plugin is not declared")
    assert.is_truthy(plugin._.loaded, "nvim-tree's config should have loaded it")
  end)

  it("asks the server before the file moves, with both URIs", function()
    local moved = H.write(dir .. "/Moved.java", { "package old;" })
    local user = H.write(dir .. "/User.java", { "import old.Moved;" })
    srv = serve(hidden(user), user, "import new.Moved;")
    local to = dir .. "/sub/Moved.java"

    rename(moved, to)

    local sent = srv.requests_for("workspace/willRenameFiles")
    assert.equals(1, #sent)
    -- oldUri has to be the pre-rename path: the request is what produces the
    -- edit, so sending it after uv.fs_rename would ask the server about a file
    -- that no longer exists and get nothing back.
    assert.same({
      { oldUri = vim.uri_from_fname(moved), newUri = vim.uri_from_fname(to) },
    }, sent[1].params.files)
  end)

  it("gets the server's edits onto disk, not just into a buffer", function()
    -- The one assertion the plugin alone does not satisfy, and the reason this
    -- module exists. vim.lsp.util.apply_text_edits bufloads each referencing
    -- file and edits it in memory; nothing writes it. The symptom of getting
    -- this wrong is the worst available: imports look fixed in the editor while
    -- gradle and :Run compile the stale file.
    local moved = H.write(dir .. "/Moved.java", { "package old;" })
    local user = H.write(dir .. "/User.java", { "import old.Moved;" })
    local buf = hidden(user)
    srv = serve(buf, user, "import new.Moved;")

    rename(moved, dir .. "/sub/Moved.java")

    assert.same({ "import new.Moved;" }, vim.fn.readfile(user))
    assert.is_false(vim.bo[buf].modified)
  end)

  it("leaves a buffer that was already dirty before the rename alone", function()
    -- A rename is not a :wall. Work in progress in an unrelated file is the
    -- user's to save, and writing it here would be an edit they never asked
    -- for — the snapshot taken on WillRenameNode is what draws that line.
    local moved = H.write(dir .. "/Moved.java", { "package old;" })
    local user = H.write(dir .. "/User.java", { "import old.Moved;" })
    local other = H.write(dir .. "/Other.java", { "class Other {}" })
    local other_buf = hidden(other)
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "class Other { int wip; }" })
    srv = serve(hidden(user), user, "import new.Moved;")

    rename(moved, dir .. "/sub/Moved.java")

    assert.same({ "class Other {}" }, vim.fn.readfile(other))
    assert.is_true(vim.bo[other_buf].modified)
    -- …while the file the refactor did touch was still written.
    assert.same({ "import new.Moved;" }, vim.fn.readfile(user))
  end)

  it("does nothing when the server does not claim the path", function()
    -- The filters are the server's, and a .java-only server must not be asked
    -- about a .txt move. Asserting the request was never sent rather than that
    -- nothing changed: a server that answers anyway would still edit nothing,
    -- so only the absent request catches the filter breaking.
    local moved = H.write(dir .. "/notes.txt", { "hello" })
    local user = H.write(dir .. "/User.java", { "import old.Moved;" })
    srv = serve(hidden(user), user, "import new.Moved;")

    rename(moved, dir .. "/sub/notes.txt")

    assert.same({}, srv.requests_for("workspace/willRenameFiles"))
    assert.same({ "import old.Moved;" }, vim.fn.readfile(user))
  end)

  it("does nothing when the server never advertised willRename", function()
    -- The silent failure mode in full: the rename still happens, the project
    -- still breaks, and nothing is reported anywhere. It is why
    -- lua/nvim-ide/health.lua reports the negotiated capability per client.
    local moved = H.write(dir .. "/Moved.java", { "package old;" })
    local user = H.write(dir .. "/User.java", { "import old.Moved;" })
    srv = fake_lsp.start({
      name = "fake_nocaps",
      bufnr = hidden(user),
      root_dir = dir,
      capabilities = {},
    })
    H.track_client(srv.id)

    rename(moved, dir .. "/sub/Moved.java")

    assert.same({}, srv.requests_for("workspace/willRenameFiles"))
    assert.same({ "import old.Moved;" }, vim.fn.readfile(user))
    -- The move itself is nvim-tree's, and it still has to work.
    assert.equals(1, vim.fn.filereadable(dir .. "/sub/Moved.java"))
  end)

  it("sends a folder move, so a package rename reaches the server", function()
    -- jdtls's computePackageRenameEdit is the folder half, and it is gated on a
    -- separate `matches = "folder"` filter — so a file-only check here would
    -- pass while moving a whole package silently did nothing.
    local pkg = dir .. "/old"
    vim.fn.mkdir(pkg, "p")
    H.write(pkg .. "/Moved.java", { "package old;" })
    local user = H.write(dir .. "/User.java", { "import old.Moved;" })
    srv = serve(hidden(user), user, "import new.Moved;")
    local to = dir .. "/new"

    rename(pkg, to)

    local sent = srv.requests_for("workspace/willRenameFiles")
    assert.equals(1, #sent)
    assert.equals(vim.uri_from_fname(pkg), sent[1].params.files[1].oldUri)
    assert.same({ "import new.Moved;" }, vim.fn.readfile(user))
  end)

  it("advertises the capability on every server this config starts", function()
    -- config.capabilities.make() is shared by lua/plugins/lsp.lua and
    -- ftplugin/java.lua, and jdtls — the one server this feature is for — is
    -- reached only by the second. Asserting the real plugin's table rather
    -- than a stand-in, because its shape is what the server negotiates against.
    local caps = require("config.capabilities").make()
    assert.is_true(caps.workspace.fileOperations.willRename)
    assert.is_true(caps.workspace.fileOperations.didRename)
    -- Still the completion capabilities that were here first.
    assert.is_true(caps.textDocument.completion.completionItem.snippetSupport)
  end)
end)
