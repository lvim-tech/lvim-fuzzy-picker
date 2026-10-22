-- Every module loads on its own, setup() stacks nothing on a second call, and health runs.

local root = PLUGIN_ROOT .. "/lua/lvim-picker"

---@return string[]
local function modules()
    local out = {}
    local function walk(dir, prefix)
        for name, kind in vim.fs.dir(dir) do
            if kind == "directory" then
                walk(dir .. "/" .. name, prefix .. name .. ".")
            elseif name:match("%.lua$") then
                local stem = name:sub(1, -5)
                out[#out + 1] = stem == "init" and prefix:sub(1, -2) or (prefix .. stem)
            end
        end
    end
    walk(root, "lvim-picker.")
    table.sort(out)
    return out
end

describe("lvim-picker: every module loads")

for _, mod in ipairs(modules()) do
    it(mod, function()
        local ok, err = pcall(require, mod)
        truthy(ok, tostring(err))
    end)
end

describe("lvim-picker: setup and health")

it("routes the fuzzy options to the fuzzy config, not the picker's own", function()
    -- `opts.fuzzy` is peeled off and merged into lvim-picker.fuzzy.config; everything else goes
    -- into lvim-picker.config. A fuzzy key left in the top-level table would silently do nothing.
    local picker = require("lvim-picker")
    local config = require("lvim-picker.config")
    local fcfg = require("lvim-picker.fuzzy.config")
    local before_max, before_sort = fcfg.max_results, fcfg.sort
    picker.setup({ fuzzy = { max_results = 7 } })
    eq(7, fcfg.max_results, "the fuzzy option arrived")
    eq(before_sort, fcfg.sort, "its siblings survived")
    eq(nil, config.fuzzy, "and it was not left sitting in the picker's own config")
    fcfg.max_results = before_max
end)

it("registers its command", function()
    require("lvim-picker").setup({})
    eq(2, vim.fn.exists(":LvimPicker"))
end)

it("runs twice without stacking autocmds", function()
    local picker = require("lvim-picker")
    picker.setup({})
    local before = #vim.api.nvim_get_autocmds({ event = "ColorScheme" })
    picker.setup({})
    eq(before, #vim.api.nvim_get_autocmds({ event = "ColorScheme" }))
end)

it("the health check runs to completion", function()
    local health = require("lvim-picker.health")
    truthy(type(health.check) == "function", "no check() to run")
    local ok, err = pcall(health.check)
    truthy(ok, tostring(err))
end)
