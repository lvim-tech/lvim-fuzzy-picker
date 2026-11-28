-- lvim-picker.modes: the modes come from the modes plugin through the plugin host, and the command templates are filled by it. The host here is
-- a stand-in program (JSON lines) that answers what the real plugin host does, so the test needs no build.

local function fake_host()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    local script = [==[#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
  case "$line" in
    *'"method":"quit"'*) exit 0 ;;
    *'"method":"list"'*) ans='[{"name":"lvim-fuzzy-plugin-modes","tables":{"modes":true}},{"name":"other","tables":{}}]' ;;
    *'"call":"modes"'*) ans='[{"op":"modes","modes":[{"name":"git-log","title":"Git log","command":"echo a","requires":["definitely-not-a-program-xyz"]},{"name":"grep","live":true,"command":"x"},{"name":"files","command":"x"},{"name":"procs","description":"d","command":"ps","options":["--delimiter=:"]}]}]' ;;
    *'"call":"expand"'*) ans='[{"op":"text","text":"expanded"}]' ;;
    *) ans='[{"op":"pass"}]' ;;
  esac
  case "$line" in *'"method":"list"'*) printf '{"id":%s,"result":%s}\n' "$id" "$ans" ;; *) printf '{"id":%s,"result":%s}\n' "$id" "$ans" ;; esac
done
]==]
    vim.fn.writefile(vim.split(script, "\n"), d .. "/lvim-plugin")
    vim.fn.setfperm(d .. "/lvim-plugin", "rwxr-xr-x")
    local old = vim.env.PATH
    vim.env.PATH = d .. ":" .. old
    return old
end

local function fresh()
    for _, m in ipairs({ "lvim-picker.modes", "lvim-picker.media" }) do
        package.loaded[m] = nil
    end
    return require("lvim-picker.modes")
end

describe("lvim-picker.modes: asked of the modes plugin")

it("lists the modes without the live, pattern and native ones, and says which programs are missing", function()
    local old = fake_host()
    local modes = fresh()
    local got
    modes.list(function(m)
        got = m
    end)
    vim.wait(3000, function()
        return got ~= nil
    end, 10)
    vim.env.PATH = old
    truthy(got ~= nil, "the plugin answered")
    local names = vim.tbl_map(function(m)
        return m.name
    end, got)
    eq({ "git-log", "procs" }, names)
    eq({ "definitely-not-a-program-xyz" }, got[1].missing)
    eq("Git log", got[1].title)
    eq("procs", got[2].title, "a mode with no title is its name")
    eq({ "git-log", "procs" }, modes.names())
end)

it("finds a mode by name, and says when there is none", function()
    local old = fake_host()
    local modes = fresh()
    local found, none, done1, done2
    modes.find("procs", function(m)
        found, done1 = m, true
    end)
    modes.find("nothing", function(m)
        none, done2 = m, true
    end)
    vim.wait(3000, function()
        return done1 and done2
    end, 10)
    vim.env.PATH = old
    eq("procs", found and found.name)
    eq(nil, none)
end)

it("has no modes without the plugin host, and does not hang", function()
    local old = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    package.loaded["lvim-utils.pluginhost"] = nil
    local modes = fresh()
    local got
    modes.list(function(m)
        got = m
    end)
    vim.wait(3000, function()
        return got ~= nil
    end, 10)
    vim.env.PATH = old
    package.loaded["lvim-utils.pluginhost"] = nil
    eq({}, got)
end)

it("does not keep an empty answer: a modes plugin installed later is seen", function()
    local old = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    package.loaded["lvim-utils.pluginhost"] = nil
    local modes = fresh()
    local first
    modes.list(function(m)
        first = m
    end)
    vim.wait(3000, function()
        return first ~= nil
    end, 10)
    eq({}, first)
    vim.env.PATH = old
    package.loaded["lvim-utils.pluginhost"] = nil
    local o2 = fake_host()
    package.loaded["lvim-picker.media"] = nil
    local second
    modes.list(function(m)
        second = m
    end)
    vim.wait(3000, function()
        return second ~= nil
    end, 10)
    vim.env.PATH = o2
    truthy(second and #second == 2, "the second ask found the plugin")
end)
