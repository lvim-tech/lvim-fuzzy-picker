-- lvim-picker.source: the directory listing a preview shows, sync (fzf backend) and async (tint list).

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

describe("lvim-picker.source: directory previews")

it("list_dir lists like `ls -A`: hidden entries in, `.` and `..` out, by name", function()
    eq({ ".hidden", "a.txt", "b.lua", "sub" }, source.list_dir(tree()))
end)

it("list_dir caps the entries and answers {} for a missing directory", function()
    eq({ ".hidden", "a.txt" }, source.list_dir(tree(), 2))
    eq({}, source.list_dir(vim.fn.tempname()))
end)

it("the async preview of a directory is its listing", function()
    local got
    source.read_preview_async(tree(), 100, function(lines, ft)
        got = { lines = lines, ft = ft }
    end)
    vim.wait(2000, function()
        return got ~= nil
    end, 10)
    eq({ lines = { ".hidden", "a.txt", "b.lua", "sub" }, ft = "" }, got)
end)

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
