-- The nvim-cmp setup in lua/plugins/lsp.lua.
--
-- Everything here is asserted against require("cmp").get_config() and
-- require("cmp.config").cmdline — cmp's own resolved state, after its `config`
-- function has run for real. Reading the plugin spec as data (helpers.specs)
-- would only prove what was written down; going through cmp proves it survived
-- cmp's normalisation, and that is where the interesting failures live (a
-- source table that never became a source, a mapping key that normalised to
-- something else, cmp.config.sources() group_index semantics).
--
-- What cannot be tested here: cmp.visible() is false for the whole session in
-- headless mode, because there is no completion menu to show. Every mapping
-- below therefore stubs cmp.visible/cmp.get_selected_entry to put the *decision*
-- under test rather than the popup. That works because the config's mapping
-- closures capture the `cmp` and `luasnip` module tables as upvalues, so
-- replacing a field on those tables is visible from inside the closure — the
-- branch that runs is the real one, only its inputs are dictated.

local H = require("helpers")

--- Invoke one mode's handler of a cmp mapping entry.
---
--- get_config().mapping[lhs] is { i = fn, s = fn, … } (cmp.config.mapping's
--- __call fans a single function out over its modes), and each fn takes the
--- `fallback` cmp would pass at keypress time. Returns the fallback call log so
--- a spec can assert "this key fell through to Neovim's own behaviour".
local function press(lhs, mode)
  local entry = require("cmp").get_config().mapping[lhs]
  assert(entry, "no cmp mapping for " .. lhs)
  local fn = entry[mode or "i"]
  assert(type(fn) == "function", ("%s has no %s-mode handler"):format(lhs, mode or "i"))
  local fallbacks = { count = 0 }
  fn(function()
    fallbacks.count = fallbacks.count + 1
  end)
  return fallbacks
end

describe("nvim-cmp", function()
  local cmp, luasnip

  before_each(function()
    -- nvim-cmp is configured in its lazy `config` function; nothing below exists
    -- until that has run.
    H.load_plugin("nvim-cmp")
    cmp = require("cmp")
    luasnip = require("luasnip")
  end)

  after_each(function()
    H.cleanup()
  end)

  it("pins the tuned performance settings", function()
    -- cmp's defaults are debounce 60 / throttle 30 / fetching_timeout 500 /
    -- max_view_entries 200. These are the difference between a popup that keeps
    -- up with typing and one that lags behind it, and max_view_entries is the
    -- load-bearing one: ts_ls returns ~1000 items for a bare cursor and cmp
    -- sorts and renders the whole set through ten comparators on every
    -- keystroke. Capping the view keeps matching intact and cuts that work ~8x.
    local perf = cmp.get_config().performance
    assert.equals(20, perf.debounce)
    assert.equals(10, perf.throttle)
    assert.equals(200, perf.fetching_timeout)
    assert.equals(25, perf.max_view_entries)
  end)

  it("registers the expected sources at the expected priorities", function()
    local by_name = {}
    for _, src in ipairs(cmp.get_config().sources) do
      by_name[src.name] = src
    end

    -- Set equality, not just presence: an extra source is as much a regression
    -- as a missing one (emmet answering plain .ts buffers with HTML tags is the
    -- documented example of a source that had to be reined in).
    assert.same(
      { "buffer", "lazydev", "luasnip", "nvim_lsp", "path" },
      vim.fn.sort(vim.tbl_keys(by_name))
    )

    -- Priority is what decides the order the menu is read in. lazydev is in the
    -- list at all because cmp only ever queries sources named here — registering
    -- itself as a source (which lazydev's cmp integration does) is not enough.
    assert.equals(1000, by_name.nvim_lsp.priority)
    assert.equals(900, by_name.lazydev.priority)
    assert.equals(750, by_name.luasnip.priority)
    assert.equals(500, by_name.buffer.priority)
    assert.equals(250, by_name.path.priority)

    -- keyword_length 3 on buffer only: without it, every one- and two-character
    -- identifier already in the file crowds the menu on the first keystroke,
    -- above real LSP items that have not arrived yet.
    assert.equals(3, by_name.buffer.keyword_length)
    for name, src in pairs(by_name) do
      if name ~= "buffer" then
        assert.is_nil(src.keyword_length, name .. " should not have a keyword_length")
      end
    end

    -- One group, so all five are queried together and ranked against each other.
    -- Separate groups would make later ones fallbacks that only run when every
    -- earlier group returns nothing — which is what the cmdline `:` config below
    -- deliberately does, and what the main list must not.
    for name, src in pairs(by_name) do
      assert.equals(1, src.group_index, name .. " should be in the first group")
    end
  end)

  it("confirms on <CR> only when an entry is actually selected", function()
    assert.is_not_nil(cmp.get_config().mapping["<CR>"])
    local confirmed = H.spy(cmp, "confirm")

    -- cmp runs with 'noselect', so nothing is ever preselected, and
    -- cmp.confirm()'s own `if not e and option.select then e = get_first_entry()`
    -- means confirm({ select = true }) would accept the top suggestion. That made
    -- it impossible to type Enter for a newline while the menu was open — the
    -- single most user-visible thing cmp does. Hence: menu visible but nothing
    -- highlighted must still fall through to Neovim.
    H.stub(cmp, "visible", function() return true end)
    H.stub(cmp, "get_selected_entry", function() return nil end)
    assert.equals(1, press("<CR>", "i").count)
    assert.equals(0, confirmed.count)

    -- Menu closed: plain Enter, same as above but via the other branch.
    H.stub(cmp, "visible", function() return false end)
    assert.equals(1, press("<CR>", "i").count)
    assert.equals(0, confirmed.count)

    -- And with a real selection it commits, without re-selecting for the user.
    H.stub(cmp, "visible", function() return true end)
    H.stub(cmp, "get_selected_entry", function() return { fake = "entry" } end)
    assert.equals(0, press("<CR>", "i").count)
    assert.equals(1, confirmed.count)
    assert.same({ select = false }, confirmed[1][1])
  end)

  it("binds <CR> in select mode as well as insert", function()
    -- The "s" mode matters while a snippet placeholder is selected: without it
    -- Enter inside a placeholder falls back to whatever the global mapping is.
    local entry = cmp.get_config().mapping["<CR>"]
    assert.is_function(entry.i)
    assert.is_function(entry.s)
  end)

  it("uses luasnip's position-aware jump checks for <Tab>/<S-Tab>", function()
    -- expand_or_jumpable()/jumpable(-1) ask only whether a jump destination
    -- differs from the current node — no in_snippet() check (luasnip/init.lua).
    -- Since region_check_events and delete_check_events are both unset, leaving a
    -- snippet early (Esc, arrows, editing elsewhere) never clears it, so those
    -- variants teleported the cursor back into a stale snippet from anywhere in
    -- the buffer instead of indenting. The locally_* variants add in_snippet(),
    -- which is the entire reason Tab is usable as Tab again.
    local unsafe_expand = H.spy(luasnip, "expand_or_jumpable", function() return true end)
    local unsafe_jump = H.spy(luasnip, "jumpable", function() return true end)
    local local_expand = H.spy(luasnip, "expand_or_locally_jumpable", function() return false end)
    local local_jump = H.spy(luasnip, "locally_jumpable", function() return false end)

    H.stub(cmp, "visible", function() return false end)

    assert.equals(1, press("<Tab>", "i").count)
    assert.equals(1, local_expand.count)
    assert.equals(0, unsafe_expand.count)

    assert.equals(1, press("<S-Tab>", "i").count)
    assert.equals(1, local_jump.count)
    assert.equals(0, unsafe_jump.count)
    -- -1 is the backwards direction; locally_jumpable() with no argument would
    -- test the forward jump and make S-Tab behave like Tab.
    assert.equals(-1, local_jump[1][1])
  end)

  it("jumps the snippet when luasnip says the cursor is still inside one", function()
    H.stub(cmp, "visible", function() return false end)
    H.stub(luasnip, "expand_or_locally_jumpable", function() return true end)
    H.stub(luasnip, "locally_jumpable", function() return true end)
    local expand_or_jump = H.spy(luasnip, "expand_or_jump")
    local jump = H.spy(luasnip, "jump")

    -- Not falling back is the point: Tab must not insert a tab in the middle of
    -- a snippet, and must insert one everywhere else (asserted above).
    assert.equals(0, press("<Tab>", "i").count)
    assert.equals(1, expand_or_jump.count)

    assert.equals(0, press("<S-Tab>", "i").count)
    assert.equals(1, jump.count)
    assert.equals(-1, jump[1][1])
  end)

  it("drives the menu with <Tab> before touching snippets", function()
    -- Menu open wins over any snippet state: Tab is the selection key, which is
    -- what makes <CR>-only-on-selection workable in the first place.
    H.stub(cmp, "visible", function() return true end)
    local next_item = H.spy(cmp, "select_next_item")
    local prev_item = H.spy(cmp, "select_prev_item")
    local expand = H.spy(luasnip, "expand_or_locally_jumpable", function() return true end)

    assert.equals(0, press("<Tab>", "i").count)
    assert.equals(1, next_item.count)
    assert.equals(0, expand.count)

    assert.equals(0, press("<S-Tab>", "i").count)
    assert.equals(1, prev_item.count)
  end)

  it("keeps the navigation and documentation keys the config declares", function()
    -- cmp normalises mapping keys through keymap.normalize, which upper-cases the
    -- modifier argument: "<C-k>" is stored as "<C-K>". Asserting the normalised
    -- form is asserting what cmp will actually look up on keypress.
    local mapping = cmp.get_config().mapping
    for _, lhs in ipairs({ "<C-K>", "<C-J>", "<C-B>", "<C-F>", "<C-Space>", "<C-E>" }) do
      assert.is_not_nil(mapping[lhs], lhs .. " should be mapped")
      assert.is_function(mapping[lhs].i, lhs .. " should map in insert mode")
    end

    -- From cmp.mapping.preset.insert, which the config wraps rather than
    -- replaces — <C-n>/<C-p>/<Up>/<Down> come from there and are what make the
    -- menu navigable with the keys people expect.
    for _, lhs in ipairs({ "<C-N>", "<C-P>", "<Up>", "<Down>" }) do
      assert.is_not_nil(mapping[lhs], lhs .. " should come from preset.insert")
    end
  end)

  it("expands snippets through luasnip", function()
    local expanded = H.spy(luasnip, "lsp_expand")
    -- snippet.expand is what cmp calls for any server item with
    -- insertTextFormat = Snippet. Unwired, every `foo(${1:arg})` from a language
    -- server would be inserted literally, braces and all — and the wildcard
    -- capabilities in lua/plugins/lsp.lua promise servers we can handle them.
    cmp.get_config().snippet.expand({ body = "foo(${1:arg})" })
    assert.equals(1, expanded.count)
    assert.equals("foo(${1:arg})", expanded[1][1])
  end)

  it("draws both popups with a rounded border", function()
    -- cmp.config.window.bordered() with no argument resolves its border from
    -- vim.o.winborder and yields "none" when that is unset, which is how these
    -- popups ended up borderless. Passing the border explicitly is what makes it
    -- correct regardless of option load order.
    local window = cmp.get_config().window
    assert.equals("rounded", window.completion.border)
    assert.equals("rounded", window.documentation.border)
  end)

  it("formats entries with codicon kind icons", function()
    local lspkind = require("lspkind")
    -- preset = "codicons" is applied by lspkind.cmp_format() as a side effect on
    -- lspkind.symbol_map, and nvim-cmp reads that table directly
    -- (cmp/entry.lua) — so this is the observable of the preset actually landing.
    assert.same(lspkind.presets.codicons, lspkind.symbol_map)

    local format = cmp.get_config().formatting.format
    assert.is_function(format)

    -- maxwidth was a bare 50, which lspkind expands to { abbr = 50, menu = 50 }
    -- and applies to BOTH columns, chopping long TS/Java signatures in the detail
    -- column mid-type so they read as a render glitch. The two columns need
    -- different budgets: 50 for the label, 80 for the detail.
    local item = format({ source = { name = "nvim_lsp" } }, {
      abbr = ("a"):rep(60),
      menu = ("m"):rep(60),
      kind = "Function",
    })
    assert.equals(("a"):rep(50) .. "…", item.abbr)
    assert.equals(("m"):rep(60), item.menu, "a 60-char detail must not be truncated")

    local wide = format({ source = { name = "nvim_lsp" } }, {
      abbr = "short",
      menu = ("m"):rep(90),
      kind = "Function",
    })
    assert.equals("short", wide.abbr)
    assert.equals(("m"):rep(80) .. "…", wide.menu)
  end)

  it("configures cmdline completion for both search and command mode", function()
    local cmdline = require("cmp.config").cmdline
    -- Search ("/" and "?") completes from the buffer, which is the only useful
    -- source for a search pattern. Both directions, or `?` searches silently
    -- lose completion.
    for _, cmdtype in ipairs({ "/", "?" }) do
      assert.is_not_nil(cmdline[cmdtype], cmdtype .. " should have a cmdline config")
      assert.same({ "buffer" }, vim.tbl_map(function(s) return s.name end, cmdline[cmdtype].sources))
      assert.is_table(cmdline[cmdtype].mapping)
    end

    -- ":" gets path and cmdline, in SEPARATE groups: cmp.config.sources() called
    -- with two argument tables makes the second a fallback, so command names only
    -- appear when path completion has nothing — which is what keeps `:e src/…`
    -- from being buried under every :command in existence.
    local colon = cmdline[":"]
    assert.is_not_nil(colon)
    assert.same({ "path", "cmdline" }, vim.tbl_map(function(s) return s.name end, colon.sources))
    local groups = {}
    for _, src in ipairs(colon.sources) do
      groups[src.name] = src.group_index
    end
    assert.equals(1, groups.path)
    assert.equals(2, groups.cmdline)

    -- cmp defaults disallow_symbol_nonprefix_matching = true, which blocks
    -- matching any candidate starting with a symbol; cmp-cmdline documents
    -- turning it off as a requirement for completing `:e ~/…` or `:!cmd`.
    assert.is_false(colon.matching.disallow_symbol_nonprefix_matching)
  end)

  it("leaves cmp's prompt-buffer guard in place", function()
    -- The config sets no `enabled`, so cmp's default predicate stands: disabled
    -- in prompt buffers (Telescope's input line, vim.ui.input) and while a macro
    -- is recording or replaying. Asserting the behaviour rather than the absence
    -- of the key, because the failure mode of overriding it is a completion menu
    -- fighting Telescope's prompt for the same keystrokes.
    local enabled = cmp.get_config().enabled
    assert.is_function(enabled)

    local normal = H.scratch({ lines = { "hello" } })
    assert.is_true(enabled(), "cmp should be enabled in an ordinary buffer")
    assert.is_true(vim.api.nvim_buf_is_valid(normal))

    local prompt = H.scratch()
    vim.bo[prompt].buftype = "prompt"
    assert.is_false(enabled(), "cmp must stay out of prompt buffers")
  end)
end)
