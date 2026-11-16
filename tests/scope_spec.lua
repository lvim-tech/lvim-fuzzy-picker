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

describe("lvim-picker.scope: the scopes the engine searches")

it("reads the literal terms a file scope highlights, smart-case in any script", function()
    eq({ { text = "x", ci = true } }, scope.terms("!neg | 'x$"))
    eq(false, scope.terms("Пи")[1].ci)
    eq(true, scope.terms("пи")[1].ci)
end)

it("filters a grep blob by line, path and file", function()
    local engine = require("lvim-fuzzy")
    if not engine.native_loaded() then
        skip("filters a grep blob by scope", "the native lvim-fuzzy library is not built")
        return
    end
    local fuzzy = require("lvim-picker.fuzzy")
    local a, b = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.writefile({ "health here" }, a)
    vim.fn.writefile({ "nothing" }, b)
    local blob = engine.blob_new()
    engine.blob_append(blob, ("%s:1:x\n%s:1:y\n%s:1:health()\n"):format(b, a, b))
    engine.blob_flush(blob)
    local function run(sc)
        local got
        fuzzy.blob_filter(blob, "health", function(list, total)
            got = { idx = vim.tbl_map(function(r)
                return r.idx
            end, list), total = total }
        end, { scope = sc })
        vim.wait(1000, function()
            return got ~= nil
        end)
        return got
    end
    eq({ idx = { 3 }, total = 1 }, run("line"))
    eq({ idx = { 2 }, total = 1 }, run("file"))
    eq(0, run("path").total, "the temp paths do not say health")
    engine.blob_free(blob)
end)
