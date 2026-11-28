-- A finder built end to end: `build` runs its steps (lua/lvim-picker/build/*.lua) in one context — the surface opens, the typed query narrows the
-- list, the handle says it is open, and closing it leaves nothing behind.

local picker = require("lvim-picker")

--- The text of every window's first lines that mentions `needle`.
local function rows_with(needle)
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        local l = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 10, false), "|"):gsub("%s+", " ")
        if l:find(needle, 1, true) then
            out[#out + 1] = l
        end
    end
    return out
end

describe("lvim-picker: a finder built from its steps")

it("opens, lists its items, narrows them as a query is typed, and closes", function()
    local handle
    picker.open({
        title = "Spec",
        items = { "alpha", "beta", "gamma", "alphabet", "delta" },
        on_confirm = function() end,
        on_open = function(h)
            handle = h
        end,
    })
    vim.wait(500, function()
        return handle ~= nil
    end, 10)
    truthy(handle and handle.is_open(), "the finder is open")
    local all = rows_with("beta")
    truthy(#all > 0 and all[1]:find("gamma", 1, true) ~= nil, "every item is listed")
    -- a finder opens with its input band focused
    local ib = vim.api.nvim_get_current_buf()
    truthy(vim.bo[ib].modifiable, "the input band is the focused buffer")
    vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "alph" })
    vim.api.nvim_exec_autocmds({ "TextChangedI", "TextChanged" }, { buffer = ib })
    -- the list window: the one that shows "alphabet"; once narrowed it no longer shows "beta"
    vim.wait(800, function()
        for _, l in ipairs(rows_with("alphabet")) do
            if not l:find("beta", 1, true) then
                return true
            end
        end
        return false
    end, 20)
    local narrowed = rows_with("alphabet")
    truthy(#narrowed > 0, "the matches stay")
    local list_row = narrowed[#narrowed]
    truthy(not list_row:find("beta", 1, true) and not list_row:find("gamma", 1, true), "what does not match goes: " .. list_row)
    require("lvim-picker.source").close_active()
    vim.wait(200)
    truthy(not handle.is_open(), "closed")
end)

describe("lvim-picker: the :LvimPicker command")

it("knows its finders and layouts (completion and layout tokens)", function()
    picker.setup_command()
    local first = vim.fn.getcompletion("LvimPicker ", "cmdline")
    truthy(vim.tbl_contains(first, "files"), "a finder is offered")
    truthy(vim.tbl_contains(first, "float"), "a layout is offered")
    local second = vim.fn.getcompletion("LvimPicker float ", "cmdline")
    truthy(vim.tbl_contains(second, "grep"), "after a layout the finders come")
end)
