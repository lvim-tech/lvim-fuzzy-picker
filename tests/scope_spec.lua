-- lvim-picker.scope: what a grep FILTER reads in each `path:lnum[:col]:text` result.

local scope = require("lvim-picker.scope")

describe("lvim-picker.scope: splitting a result")

it("separates the path, the locator and the line's text", function()
    local path, loc, body = scope.split("lua/x/health.lua:21:5:  h.start('x')")
    eq("lua/x/health.lua", path)
    eq("lua/x/health.lua:21:5:", loc)
    eq("  h.start('x')", body)
    path, loc, body = scope.split("a.lua:7:text")
    eq({ "a.lua", "a.lua:7:", "text" }, { path, loc, body })
    eq(nil, (scope.split("no locator here")))
end)

it("reads the part a scope names", function()
    eq("text here", scope.part("p/f.lua:3:1:text here", "line"))
    eq("p/f.lua", scope.part("p/f.lua:3:1:text here", "path"))
    eq("plain", scope.part("plain", "line"))
end)

it("cycles line → path → file → line", function()
    eq("path", scope.next("line"))
    eq("file", scope.next("path"))
    eq("line", scope.next("file"))
end)

describe("lvim-picker.scope: the file scope")

it("keeps a row when its FILE holds every term (exact, smart-case)", function()
    local f = vim.fn.tempname()
    vim.fn.writefile({ "local h = vim.health", "return 1" }, f)
    eq(true, scope.file_has(f, scope.terms("health")))
    eq(true, scope.file_has(f, scope.terms("vim health")))
    eq(false, scope.file_has(f, scope.terms("hrt"))) -- scattered letters do not count
    eq(false, scope.file_has(f, scope.terms("Health"))) -- an uppercase letter = case-sensitive
    eq({ { text = "x", ci = true } }, scope.terms("!neg | 'x$"))
end)

it("filters a blob by file content, in source order", function()
    local engine = require("lvim-fuzzy")
    if not (engine.has_blob and engine.has_blob()) then
        skip("filters a blob by file content", "the native lvim-fuzzy library (blob ABI) is not built")
        return
    end
    scope.reset()
    local a, b = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.writefile({ "health here" }, a)
    vim.fn.writefile({ "nothing" }, b)
    local blob = engine.blob_new()
    engine.blob_append(blob, ("%s:1:x\n%s:1:y\n%s:1:z\n"):format(b, a, a))
    engine.blob_flush(blob)
    local list, total = scope.file_filter(blob, "health", 10)
    eq(2, total)
    eq({ 2, 3 }, { list[1].idx, list[2].idx })
    local d = scope.derive(blob, "line")
    eq({ "x", "y", "z" }, { engine.blob_text(d, 1), engine.blob_text(d, 2), engine.blob_text(d, 3) })
    engine.blob_free(d)
    engine.blob_free(blob)
end)
