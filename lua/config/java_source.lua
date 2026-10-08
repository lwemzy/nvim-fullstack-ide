-- jdtls's "source action" generators, on keys instead of buried in a menu.
--
-- jdtls implements everything IntelliJ's Alt+Insert does — getters and setters,
-- a constructor from selected fields, equals/hashCode, toString, delegate
-- methods, override/implement, sort members — but all of it arrives as code
-- actions, and this config only had one way to reach a code action: <F4>, which
-- lists every quickfix and refactoring for the cursor position together. Finding
-- "Generate toString()" in that list is slower than typing the method.
--
-- Each generator here is a code action request filtered to one kind, so the key
-- goes straight to the prompt. The kind strings are not guesses: they were read
-- out of the installed org.eclipse.jdt.ls.core_1.60.0 jar
-- (SourceAssistProcessor), which is also where the one real complication below
-- came from.
--
-- ── The accessors gap ──
--
-- nvim-jdtls registers client-side handlers for the commands these actions
-- resolve to (jdtls.lua's M.commands -> vim.lsp.commands): toString,
-- hashCodeEquals, constructors, delegateMethods, overrideMethods, organizeImports
-- and the refactoring dispatcher. It does NOT register one for
-- `java.action.generateAccessorsPrompt` — grep the whole plugin for "accessor"
-- and the only hit is an unrelated stack-trace pattern in jdtls/junit.lua.
--
-- Without a handler, Neovim falls back to sending the command to the server as
-- workspace/executeCommand, which jdtls does not implement for the *Prompt
-- commands — they exist precisely to hand control back to the client so it can
-- ask which fields to generate for. So the single most-wanted generator was the
-- one that silently did nothing. M.setup registers the missing handler, built
-- from the same two requests vscode-java uses:
--
--   java/resolveUnimplementedAccessors  AccessorCodeActionParams
--                                       -> AccessorField[]
--                                          { fieldName, isStatic, typeName,
--                                            generateGetter, generateSetter }
--   java/generateAccessors              { context, accessors }
--                                       -> WorkspaceEdit
--
-- Verified against the jar rather than copied from vscode-java's TypeScript:
-- JDTLanguageServer.resolveUnimplementedAccessors / .generateAccessors for the
-- method names, GenerateAccessorsHandler$GenerateAccessorsParams for the request
-- shape, and GenerateGetterSetterOperation$AccessorField for the field names.
--
-- The command's own argument already carries the `kind` (GETTER / SETTER / BOTH)
-- that the chosen action meant, so it is passed through untouched rather than
-- rebuilt — which also means the three separate "Generate Getters", "Generate
-- Setters" and "Generate Getters and Setters" actions all work through one
-- handler.

local M = {}

--- The command jdtls resolves its accessors source action to.
local ACCESSORS_COMMAND = "java.action.generateAccessorsPrompt"

--- The code action kinds each generator is filtered to.
---
--- Hierarchical, so `source.generate` is a superset of the five below it — LSP
--- kind matching is prefix-based on `.` boundaries, which is also how jdtls
--- itself decides whether the client supports a kind
--- (ClientPreferences.isSupportedCodeActionKind does `kind.startsWith(entry)`).
--- That is why no capability change is needed for any of these: the valueSet
--- `vim.lsp.protocol.make_client_capabilities()` sends already contains
--- "source".
---
--- `source.overrideMethods` and `source.sortMembers` are deliberately not under
--- `source.generate` — that is jdtls's own naming, not a typo here.
---
--- All nine were then checked against a running jdtls 1.60.0 rather than only
--- against the jar, and two of them look broken until you know why, so:
--- `final_modifiers` and `sort_members` answer with **no action at all** in a
--- class where there is nothing for them to do, at every cursor position and
--- selection. That is correct, not a dead key —
--- SourceAssistProcessor.getSortMembersProposal returns Optional.empty() when
--- CompilationUnitSorter.sort returns null, i.e. when the sort would change
--- nothing, and Eclipse's DefaultJavaElementComparator orders by *category*
--- (fields, then constructors, then methods) and not alphabetically, so
--- `void b()` before `void a()` is already sorted.
--- addFinalModifierWherePossibleAction bails the same way when no local,
--- parameter or field can take `final`. Both appear as soon as the file actually
--- needs them (a method declared above a field; an effectively-final local).
---
--- Nothing here reports the empty case, because Neovim already does:
--- vim.lsp.buf.code_action notifies "No code actions available" after applying
--- the `only` filter (runtime/lua/vim/lsp/buf.lua), so the press says so itself.
M.KINDS = {
  all = "source.generate",
  accessors = "source.generate.accessors",
  constructors = "source.generate.constructors",
  delegates = "source.generate.delegateMethods",
  hash_code_equals = "source.generate.hashCodeEquals",
  to_string = "source.generate.toString",
  final_modifiers = "source.generate.finalModifiers",
  override = "source.overrideMethods",
  sort_members = "source.sortMembers",
}

--- The jdtls client attached to `bufnr`, or nil with a warning.
---
--- Named rather than taken from the first attached client: a .java buffer can
--- also have the Spring Boot language server attached (lua/plugins/java.lua),
--- and it answers textDocument/codeAction with its own, unrelated actions.
local function jdtls_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })
  if #clients == 0 then
    vim.notify("jdtls is not attached to this buffer", vim.log.levels.WARN)
    return nil
  end
  return clients[1]
end

--- Ask for one kind of source action and apply it.
---
--- apply = true means a single result is applied without a menu, which is the
--- point of a dedicated key. Several results still show a picker, and that is
--- correct rather than a leak: filtering to `source.generate.accessors` returns
--- three actions (getters, setters, both), and choosing between them is the
--- question the key cannot answer on its own.
---
--- diagnostics = {} because this is a `source` action, not a fix. jdtls's
--- CodeActionHandler runs the quick-fix processors over whatever diagnostics the
--- context carries, so passing the buffer's real diagnostics would make it
--- compute a set of fixes that are then filtered away — work paid for on every
--- press and never used.
function M.generate(kind)
  return function()
    local bufnr = vim.api.nvim_get_current_buf()
    if not jdtls_client(bufnr) then return end
    vim.lsp.buf.code_action({
      context = { only = { kind }, diagnostics = {} },
      apply = true,
    })
  end
end

--- `generateGetter`/`generateSetter` are both booleans on the same field, so one
--- entry in the prompt can mean "a getter", "a setter" or both. Spelling that out
--- matters: the list is the only place it is visible, and a field that already
--- has a getter is offered here with generateGetter = false.
local function accessor_label(field)
  local parts = {}
  if field.generateGetter then table.insert(parts, "get") end
  if field.generateSetter then table.insert(parts, "set") end
  return ("%s: %s  (%s)"):format(
    field.fieldName,
    field.typeName or "?",
    #parts > 0 and table.concat(parts, "/") or "none"
  )
end

--- Apply a WorkspaceEdit that came back from `client`.
local function apply(client, edit)
  if not edit then return end
  vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
end

--- The handler nvim-jdtls is missing. See the header.
---
--- Nested callbacks rather than nvim-jdtls's coroutine style (jdtls.async.run
--- plus a yielding `request`): there are exactly two requests, and the prompt in
--- between is `vim.fn.input`, which has to run on the main loop. vim.schedule
--- states that requirement where it applies instead of making the whole flow a
--- coroutine to hide it.
local function generate_accessors(command, ctx)
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_client_by_id(ctx.client_id) or jdtls_client(bufnr)
  if not client then return end

  -- Passed straight back to the server. It is an AccessorCodeActionParams —
  -- a CodeActionParams plus the `kind` enum naming which of getters, setters or
  -- both the chosen action was — and reconstructing it here would mean guessing
  -- that kind from the action's title.
  local params = command.arguments and command.arguments[1]
  if not params then
    return vim.notify("jdtls sent no arguments for " .. ACCESSORS_COMMAND, vim.log.levels.ERROR)
  end

  client:request("java/resolveUnimplementedAccessors", params, function(err, fields)
    if err then
      return vim.notify("Could not resolve accessors: " .. err.message, vim.log.levels.ERROR)
    end
    if not fields or #fields == 0 then
      -- Not an error: every field already has the accessors that were asked for,
      -- which is a perfectly ordinary answer and the one Lombok's @Data gives.
      return vim.notify("No fields need accessors here", vim.log.levels.INFO)
    end

    vim.schedule(function()
      -- The same prompt nvim-jdtls uses for constructors and override-methods,
      -- so the interaction is identical across all of them: numbered list, type
      -- a number to toggle, Esc to confirm. Reused rather than reimplemented
      -- with vim.ui.select, which cannot multi-select.
      local selected = require("jdtls.ui").pick_many(
        fields,
        "Generate accessors for: ",
        accessor_label,
        { is_selected = function() return true end }
      )
      if not selected or #selected == 0 then return end

      client:request("java/generateAccessors", {
        context = params,
        accessors = selected,
      }, function(err2, edit)
        if err2 then
          return vim.notify("Could not generate accessors: " .. err2.message, vim.log.levels.ERROR)
        end
        apply(client, edit)
      end, bufnr)
    end)
  end, bufnr)
end

--- Register the accessors command handler.
---
--- Idempotent, and it does not overwrite an existing entry: if a future
--- nvim-jdtls ships its own `java.action.generateAccessorsPrompt`, theirs is the
--- one that should win — it will be maintained against the server, and this is a
--- stand-in for its absence.
---
--- Called from ftplugin/java.lua, i.e. only once a Java file is opened, so a
--- session that never touches Java never loads this module.
--- Nothing creates `vim.lsp.commands` here: core owns it (runtime/lua/vim/lsp.lua)
--- and guards it with a `__newindex` that rejects any value which is not a
--- function, so re-binding it would be both pointless and a way to lose that
--- check.
function M.setup()
  if vim.lsp.commands[ACCESSORS_COMMAND] then return false end
  vim.lsp.commands[ACCESSORS_COMMAND] = generate_accessors
  return true
end

return M
