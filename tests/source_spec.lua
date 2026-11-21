-- lvim-picker.source: what the async preview reads — a file's lines, or a directory's listing.

local source = require("lvim-picker.source")

--- A temp directory with a few entries, one of them hidden.
---@return string
local function tree()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. "/sub", "p")
    vim.fn.writefile({ "x" }, d .. "/b.lua")
    vim.fn.writefile({ "x" }, d .. "/a.txt")
    vim.fn.writefile({ "x" }, d .. "/.hidden")
    return d
end

describe("lvim-picker.source: file previews")

it("the async preview of a file is still its lines", function()
    local f = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local a = 1", "return a" }, f)
    local got
    source.read_preview_async(f, 100, function(lines, ft)
        got = { lines = lines, ft = ft }
    end)
    vim.wait(2000, function()
        return got ~= nil
    end, 10)
    eq({ lines = { "local a = 1", "return a" }, ft = "lua" }, got)
end)
