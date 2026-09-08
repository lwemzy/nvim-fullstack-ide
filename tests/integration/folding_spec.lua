-- Code folding (nvim-ufo, configured in lua/plugins/tools.lua).
--
-- One decision in that config is worth a spec of its own: Java folding must not
-- go through ufo's LSP provider. jdtls's FoldingRangeHandler hits a long-standing
-- JDT-core Scanner bug (source index -1 out of bounds) on some documents
-- (eclipse.jdt.ls #990, #1419, #1815), and ufo cannot survive it: its LSP client
-- turns only RequestCancelled/ContentModified/RequestFailed into the internal
-- UfoFallbackException, so an InternalError — which is what a JDT exception
-- arrives as — is re-raised as-is, and nothing in ufo's fold chain catches it
-- (provider/lsp/nvim.lua, provider/init.lua's needFallback, fold/init.lua's
-- rejection handler). The user sees a "Press ENTER to continue" error dump while
-- editing, and folding never recovers for that buffer.
--
-- So the pin is behavioural, in both directions: Java's chain must not contain
-- "lsp", and the treesitter provider that replaced it must actually return folds
-- for a real Java buffer — a chain pointing at a provider that yields nothing
-- would silently mean no folding at all, which is not what was traded for.

local H = require("helpers")

local MASON_JDTLS = vim.fn.stdpath("data") .. "/mason/bin/jdtls"

describe("fold providers", function()
  local ufo

  before_each(function()
    H.load_plugin("nvim-ufo", "nvim-treesitter")
    H.disable_autosave()
    ufo = require("ufo.config")
  end)

  after_each(function()
    H.cleanup()
  end)

  --- The provider chain lua/plugins/tools.lua hands ufo for a filetype.
  local function chain(ft)
    assert.is_function(ufo.provider_selector, "ufo was set up without a provider_selector")
    return ufo.provider_selector(0, ft, ft) or {}
  end

  --- A real Java buffer with no jdtls behind it: filetype detection runs (the
  --- treesitter provider needs the parser that comes with it), but the launch is
  --- intercepted the way tests/integration/java_ftplugin_spec.lua does it, since
  --- a real Eclipse JDT LS start costs ~30s and is irrelevant here.
  local function java_buffer()
    if vim.fn.executable(MASON_JDTLS) == 0 then return nil end
    H.load_plugin("nvim-jdtls")
    H.spy(require("jdtls"), "start_or_attach")
    H.spy(require("jdtls"), "setup_dap")
    local dir = H.tmpdir("folding")
    local path = H.write(dir .. "/App.java", {
      "package com.example;",
      "",
      "public class App {",
      "  public String greeting() {",
      "    if (true) {",
      "      return \"hello\";",
      "    }",
      "    return \"\";",
      "  }",
      "}",
    })
    return H.edit(path)
  end

  --- Settle one of ufo's providers. They return promise-async promises, so the
  --- value is only reachable through thenCall.
  local function folds(provider, bufnr)
    local promise = require("promise")
    local settled, ranges, failure = false, nil, nil
    promise(function(resolve)
      resolve(require("ufo.provider." .. provider).getFolds(bufnr))
    end):thenCall(
      function(value) ranges, settled = value, true end,
      function(err) failure, settled = err, true end
    )
    H.wait_for("the " .. provider .. " fold provider to answer", function() return settled end)
    assert.is_nil(failure, "the " .. provider .. " provider rejected: " .. vim.inspect(failure))
    return ranges or {}
  end

  it("never asks jdtls for Java folding ranges", function()
    local providers = chain("java")
    assert.is_false(vim.tbl_contains(providers, "lsp"),
      "Java folding is back on the LSP provider: " .. vim.inspect(providers))
    -- treesitter first, indent as the fallback for a file whose parser is
    -- missing — indent alone loses every fold that is not indentation-shaped.
    assert.equals("treesitter", providers[1])
    assert.equals("indent", providers[2])
  end)

  it("keeps the LSP provider for the filetypes whose servers answer correctly", function()
    -- Scoped to Java on purpose. ts_ls/angularls fold correctly and their ranges
    -- are better than treesitter's, so a future blanket "just use treesitter"
    -- would be a silent downgrade for the whole TS/Angular half of this config.
    for _, ft in ipairs({ "typescript", "javascript" }) do
      assert.is_true(vim.tbl_contains(chain(ft), "lsp"), ft .. " lost its LSP fold provider")
    end
  end)

  it("really folds a Java buffer through treesitter", function()
    local bufnr = java_buffer()
    if not bufnr then return H.skip("mason jdtls is not installed; run :MasonInstall jdtls") end
    if not pcall(vim.treesitter.get_parser, bufnr, "java") then
      return H.skip("the java treesitter parser is not installed")
    end

    local ranges = folds("treesitter", bufnr)
    assert.is_true(#ranges >= 3, "expected class/method/if folds, got " .. vim.inspect(ranges))

    -- The class body, the method body and the if block, by their 0-based start
    -- lines. Asserting on which lines fold (not just how many) is what would
    -- catch the folds query silently matching nothing after a parser update.
    local starts = {}
    for _, r in ipairs(ranges) do starts[r.startLine] = r.endLine end
    assert.is_not_nil(starts[2], "the class body does not fold: " .. vim.inspect(ranges))
    assert.is_not_nil(starts[3], "the method body does not fold: " .. vim.inspect(ranges))
    assert.is_not_nil(starts[4], "the if block does not fold: " .. vim.inspect(ranges))
  end)
end)
