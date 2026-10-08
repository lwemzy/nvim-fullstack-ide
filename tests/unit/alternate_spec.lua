-- lua/config/alternate.lua — the class <-> test / component <-> template jump.
--
-- Unit tier: the module is a pure path transform plus one disk check, so the
-- only thing it needs is real files, which H.tmpdir gives. Nothing here touches
-- a language server or a plugin.
--
-- The assertions worth having are the ones about what must NOT happen: a
-- production class called RetryTest must not be treated as a test, index.html
-- must not be offered a spec, and a counterpart that appeared on disk between
-- the check and the edit must not be overwritten with a scaffold.

local H = require("helpers")

local function alternate()
  package.loaded["config.alternate"] = nil
  return require("config.alternate")
end

--- Create `rel` under `root`, with its own path as its contents.
---
--- H.write already makes the parent directories and returns the path, so this is
--- only here to keep `root .. "/" .. rel` out of every case and to give each file
--- a body that identifies it — which is what lets the scaffold-race case below
--- tell "the file that was already there" from "the scaffold".
local function touch(root, rel)
  return H.write(root .. "/" .. rel, { "// " .. rel })
end

describe("config.alternate", function()
  local A, root

  before_each(function()
    A = alternate()
    -- Resolved, not as H.tmpdir returns it: on macOS the temp dir is under
    -- /var, which is a symlink to /private/var, and nvim stores a buffer's name
    -- fully resolved. Without this the toggle cases compare two spellings of the
    -- same path. (tests/README.md records the same trap.)
    root = vim.uv.fs_realpath(H.tmpdir())
    H.disable_autosave()
  end)

  after_each(function()
    package.loaded["config.alternate"] = nil
    H.cleanup()
  end)

  describe("java", function()
    it("offers the Test-suffixed test for a main class, nearest spelling first", function()
      local main = root .. "/src/main/java/com/example/OrderService.java"
      local set = A.resolve(main)
      assert.is_not_nil(set)
      assert.equals(root .. "/src/test/java/com/example/OrderServiceTest.java", set.candidates[1])
      -- Tests and IT are reachable, so a project using either is still found.
      assert.is_true(vim.tbl_contains(set.candidates, root .. "/src/test/java/com/example/OrderServiceTests.java"))
      assert.is_true(vim.tbl_contains(set.candidates, root .. "/src/test/java/com/example/OrderServiceIT.java"))
    end)

    it("sends a test back to its production class", function()
      local test = root .. "/src/test/java/com/example/OrderServiceTest.java"
      local main = touch(root, "src/main/java/com/example/OrderService.java")
      assert.equals(main, A.find(test))
    end)

    it("finds the Tests spelling when that is what the project uses", function()
      local main = root .. "/src/main/java/com/example/OrderService.java"
      local tests = touch(root, "src/test/java/com/example/OrderServiceTests.java")
      assert.equals(tests, A.find(main))
    end)

    it("keeps the package directory, so a nested package maps to its mirror", function()
      local main = root .. "/src/main/java/com/example/web/api/OrderController.java"
      local set = A.resolve(main)
      assert.equals(
        root .. "/src/test/java/com/example/web/api/OrderControllerTest.java",
        set.candidates[1]
      )
    end)

    it("does not strip a test-looking suffix from a class in src/main", function()
      -- RetryTest is production code, not the test of a class called `Retry`.
      -- Stripping here would send it at src/main/java/com/example/Retry.java and
      -- then offer to create it.
      local main = root .. "/src/main/java/com/example/RetryTest.java"
      local set = A.resolve(main)
      assert.equals(root .. "/src/test/java/com/example/RetryTestTest.java", set.create)
    end)

    it("has no opinion about a .java file outside src/<set>/java", function()
      assert.is_nil(A.resolve(root .. "/Scratch.java"))
      assert.is_nil(A.resolve(root .. "/src/other/java/com/example/Thing.java"))
    end)

    it("creates the test, not another test spelling, when nothing exists", function()
      local test = root .. "/src/test/java/com/example/OrderServiceTest.java"
      -- From the test side the thing to create is the production class, not
      -- OrderServiceTests.java — which is the first *candidate* but never the
      -- right thing to write.
      assert.equals(root .. "/src/main/java/com/example/OrderService.java", A.resolve(test).create)
    end)
  end)

  describe("java scaffold", function()
    it("declares the package the directory implies and the type the file name does", function()
      local lines = A.scaffold(root .. "/src/test/java/com/example/OrderServiceTest.java")
      assert.same({
        "package com.example;",
        "",
        "class OrderServiceTest {",
        "",
        "}",
      }, lines)
    end)

    it("makes a production class public and a test package-private", function()
      local main = A.scaffold(root .. "/src/main/java/com/example/OrderService.java")
      assert.is_true(vim.tbl_contains(main, "public class OrderService {"))
    end)

    it("omits the package line in the default package", function()
      local lines = A.scaffold(root .. "/src/test/java/AppTest.java")
      assert.equals("class AppTest {", lines[1])
    end)

    it("has nothing to say about a .ts file", function()
      assert.is_nil(A.scaffold(root .. "/src/app/app.service.ts"))
    end)
  end)

  describe("typescript", function()
    it("pairs a plain module with its spec", function()
      -- Both on disk, because find() only returns a counterpart that exists and
      -- this case is about the pairing being symmetric.
      local mod = touch(root, "src/lib/money.ts")
      local spec = touch(root, "src/lib/money.spec.ts")
      assert.equals(spec, A.find(mod))
      assert.equals(mod, A.find(spec))
    end)

    it("accepts the .test. spelling too", function()
      local mod = root .. "/src/lib/money.ts"
      local test = touch(root, "src/lib/money.test.ts")
      assert.equals(test, A.find(mod))
    end)

    it("creates .spec, not .test, when neither exists", function()
      assert.equals(root .. "/src/lib/money.spec.ts", A.resolve(root .. "/src/lib/money.ts").create)
    end)

    it("keeps the extension it was given, so a .tsx spec is a .tsx", function()
      assert.equals(
        root .. "/src/ui/Button.spec.tsx",
        A.resolve(root .. "/src/ui/Button.tsx").create
      )
    end)

    it("walks an Angular component .ts -> .html -> .scss -> .spec -> .ts", function()
      local ts = touch(root, "src/app/home/home.component.ts")
      local html = touch(root, "src/app/home/home.component.html")
      local scss = touch(root, "src/app/home/home.component.scss")
      local spec = touch(root, "src/app/home/home.component.spec.ts")

      assert.equals(html, A.find(ts))
      assert.equals(scss, A.find(html))
      assert.equals(spec, A.find(scss))
      assert.equals(ts, A.find(spec))
    end)

    it("skips a stylesheet extension the project does not use", function()
      local ts = touch(root, "src/app/home/home.component.ts")
      local html = touch(root, "src/app/home/home.component.html")
      -- .css rather than .scss, and no spec: the walk from the template has to
      -- land on the stylesheet that exists.
      local css = touch(root, "src/app/home/home.component.css")
      assert.equals(html, A.find(ts))
      assert.equals(css, A.find(html))
    end)

    it("offers a service only its spec, never a template", function()
      local set = A.resolve(root .. "/src/app/order.service.ts")
      for _, candidate in ipairs(set.candidates) do
        assert.is_nil(candidate:match("%.html$"), candidate .. " should not be offered")
        assert.is_nil(candidate:match("%.scss$"), candidate .. " should not be offered")
      end
      assert.equals(root .. "/src/app/order.service.spec.ts", set.create)
    end)

    it("has no opinion about a template or stylesheet that is not a component's", function()
      assert.is_nil(A.resolve(root .. "/src/index.html"))
      assert.is_nil(A.resolve(root .. "/src/styles.scss"))
    end)
  end)

  describe("toggle", function()
    it("opens the counterpart that exists", function()
      local main = touch(root, "src/main/java/com/example/OrderService.java")
      local test = touch(root, "src/test/java/com/example/OrderServiceTest.java")
      H.edit(main)
      A.toggle()
      assert.equals(test, vim.api.nvim_buf_get_name(0))
    end)

    it("declines to create anything when the prompt is answered no", function()
      local main = touch(root, "src/main/java/com/example/OrderService.java")
      H.edit(main)
      local restore = vim.fn.confirm
      vim.fn.confirm = function() return 2 end
      local ok = pcall(A.toggle)
      vim.fn.confirm = restore
      assert.is_true(ok)
      assert.equals(main, vim.api.nvim_buf_get_name(0))
    end)

    it("opens a scaffolded, unwritten buffer when the counterpart is missing", function()
      local main = touch(root, "src/main/java/com/example/OrderService.java")
      H.edit(main)
      local restore = vim.fn.confirm
      vim.fn.confirm = function() return 1 end
      A.toggle()
      vim.fn.confirm = restore

      local test = root .. "/src/test/java/com/example/OrderServiceTest.java"
      assert.equals(test, vim.api.nvim_buf_get_name(0))
      -- Nothing on disk yet: the scaffold is a buffer to accept or abandon.
      assert.equals(0, vim.fn.filereadable(test))
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.equals("package com.example;", lines[1])
      assert.equals("class OrderServiceTest {", lines[3])
    end)

    it("does not scaffold over a file that appeared after the check", function()
      local main = touch(root, "src/main/java/com/example/OrderService.java")
      H.edit(main)
      local restore = vim.fn.confirm
      vim.fn.confirm = function()
        -- The race this guards: a generator, a git checkout or the other half of
        -- a rename creating the file between the existence check and the :edit.
        touch(root, "src/test/java/com/example/OrderServiceTest.java")
        return 1
      end
      A.toggle()
      vim.fn.confirm = restore

      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.equals("// src/test/java/com/example/OrderServiceTest.java", lines[1])
      assert.is_false(vim.bo.modified)
    end)

    it("says so rather than guessing for a file with no convention", function()
      local other = touch(root, "notes.md")
      H.edit(other)
      local notes = H.capture_notifications(function() A.toggle() end)
      assert.equals(other, vim.api.nvim_buf_get_name(0))
      assert.is_true(#notes > 0)
    end)
  end)
end)
