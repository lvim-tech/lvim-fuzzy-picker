-- lvim-picker.media: the picker asks the shared preview engine (`lvim-fuzzy-cli preview`) about media and binary
-- files; without the engine it previews as it always did. The engine here is a stand-in program that answers
-- what the real one answers, so the test needs no build.

local source = require("lvim-picker.source")

--- A directory holding a fake `lvim-fuzzy`, put first on PATH; returns the old PATH to restore.
local function fake_engine()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    local script = [==[#!/bin/sh
# the preview plugins' answer (`preview --plugin`): the plugins pick the engine by file type
if [ "$2" = "--plugin" ]; then
  case "$*" in
    *pic.png*) echo '[{"op":"preview","facts":[["dimensions","10 × 20"],["format","PNG"]],"positions":1,"picture":{"path":"/tmp/x.png","width":10,"height":20}}]' ;;
    *blob.bin*) echo '[{"op":"preview","facts":[["type","binary file"],["file size","3 B"]]}]' ;;
    *dirx*) echo '[{"op":"preview","body":{"type":"entries","rows":[{"name":"sub","dir":true,"size":0},{"name":"a.txt","dir":false,"size":2048}]}}]' ;;
    *tbl.csv*) echo '[{"op":"preview","body":{"type":"table","rows":[["name","age"],["ann","30"]]}}]' ;;
    *nvim.txt*) echo '[{"op":"preview","renderer":"nvim"}]' ;;
    *bat.rs*) echo '[{"op":"preview","missing":["bat is not installed"],"body":{"type":"text","ansi":true,"lines":["\u001b[31mfn\u001b[0m main"]}}]' ;;
    *) echo '[{"op":"pass"}]' ;;
  esac
  exit 0
fi
]==]
    vim.fn.writefile(vim.split(script, "\n"), d .. "/lvim-fuzzy-cli")
    vim.fn.setfperm(d .. "/lvim-fuzzy-cli", "rwxr-xr-x")
    local old = vim.env.PATH
    vim.env.PATH = d .. ":" .. old
    return old, d
end

local function read(path)
    local got
    source.read_preview_async(path, 100, function(lines, ft, picture)
        got = { lines = lines, ft = ft, picture = picture }
    end)
    vim.wait(3000, function()
        return got ~= nil
    end, 10)
    return got
end

describe("lvim-picker.media: what the shared engine says")

it("a picture is a table of facts and a picture file, not its bytes", function()
    local old = fake_engine()
        local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    vim.fn.writefile({ "\137PNG" }, d .. "/pic.png")
    local got = read(d .. "/pic.png")
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
    eq({ " dimensions  10 × 20", "     format  PNG" }, got.lines)
    eq("/tmp/x.png", got.picture)
end)

it("a binary file is a note, not bytes as text", function()
    local old = fake_engine()
    package.loaded["lvim-picker.media"] = nil
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    local f = io.open(d .. "/blob.bin", "wb")
    f:write("ab\0cd\0\1\2\3")
    f:close()
    local got = read(d .. "/blob.bin")
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
    eq({ "      type  binary file", " file size  3 B" }, got.lines)
    eq(nil, got.picture)
end)

it("a directory, a table and coloured text come from the plugin's answer", function()
    local old = fake_engine()
    package.loaded["lvim-picker.media"] = nil
    local d = vim.fn.tempname() .. "/dirx"
    vim.fn.mkdir(d, "p")
    eq({ " sub/", " a.txt  2.0 K" }, read(d).lines)
    local t = vim.fn.tempname() .. "/tbl.csv"
    vim.fn.mkdir(vim.fn.fnamemodify(t, ":h"), "p")
    vim.fn.writefile({ "name,age", "ann,30" }, t)
    eq({ " name │ age", " ─────┼────", " ann  │ 30 " }, read(t).lines)
    -- coloured text: the colour codes dropped, the missing program said first (red, from M.paint)
    local r = vim.fn.tempname() .. "/bat.rs"
    vim.fn.mkdir(vim.fn.fnamemodify(r, ":h"), "p")
    vim.fn.writefile({ "fn main" }, r)
    eq({ " ✗ bat is not installed", "fn main" }, read(r).lines)
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
end)

it("a plugin that says Neovim leaves the file to the picker's own buffer", function()
    local old = fake_engine()
    package.loaded["lvim-picker.media"] = nil
    local f = vim.fn.tempname() .. "/nvim.txt"
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ "one", "two" }, f)
    eq({ "one", "two" }, read(f).lines)
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
end)

it("without the plugins a directory has no preview of its own", function()
    local old = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    package.loaded["lvim-picker.media"] = nil
    local d = vim.fn.tempname() .. "/dirx"
    vim.fn.mkdir(d, "p")
    eq({ "[unreadable]" }, read(d).lines)
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
end)

it("plain text is read as before", function()
    local old = fake_engine()
    package.loaded["lvim-picker.media"] = nil
    local f = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "one", "two" }, f)
    local got = read(f)
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
    eq({ "one", "two" }, got.lines)
end)

it("without the engine a media file is read as text, as before", function()
    local old = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    package.loaded["lvim-picker.media"] = nil
    local f = vim.fn.tempname() .. ".png"
    vim.fn.writefile({ "not really a png" }, f)
    local got = read(f)
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
    eq({ "not really a png" }, got.lines)
end)

describe("lvim-picker.media: opening a file by the shared rule")

it("a program is started for a picture, not for text, and nothing without the engine", function()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    local flag = d .. "/started"
    local script = ([==[#!/bin/sh
case "$*" in
  *pic.png*) echo '{"action":"exec","cmd":"touch %s"}' ;;
  *) echo '{"action":"editor"}' ;;
esac
]==]):format(flag)
    vim.fn.writefile(vim.split(script, "\n"), d .. "/lvim-fuzzy-cli")
    vim.fn.setfperm(d .. "/lvim-fuzzy-cli", "rwxr-xr-x")
    local old = vim.env.PATH
    vim.env.PATH = d .. ":" .. old
    local media = require("lvim-picker.media")
    vim.fn.writefile({ "x" }, d .. "/pic.png")
    vim.fn.writefile({ "x" }, d .. "/note.txt")
    eq(false, media.open_external(d .. "/note.txt"))
    eq(false, media.open_external(d)) -- a directory is the editor's
    eq(true, media.open_external(d .. "/pic.png"))
    vim.wait(3000, function()
        return vim.uv.fs_stat(flag) ~= nil
    end, 20)
    vim.env.PATH = "/nonexistent"
    package.loaded["lvim-picker.media"] = nil
    eq(false, require("lvim-picker.media").open_external(d .. "/pic.png"))
    vim.env.PATH = old
    package.loaded["lvim-picker.media"] = nil
    eq(true, vim.uv.fs_stat(flag) ~= nil)
end)
