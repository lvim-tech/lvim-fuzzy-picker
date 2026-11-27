--- The picker's client of the lvim preview plugins. lvc, lfz and this picker show a file the same way because the
--- PLUGINS (lvim-fuzzy-plugin-preview) choose the engine for its type from their configuration and compute the answer:
--- a table of facts, a picture as a PNG in the plugin's cache, a directory's entries, a table, an archive's tree,
--- text. The picker only turns the answer into lines of its preview buffer. It asks through the plugin host
--- (`lvim-plugin host`, the client in lvim-utils.pluginhost); without it nothing here answers and the picker previews text as it
--- always did.
---@module "lvim-picker.media"

local M = {}

--- The plugin host's client, as the tool `lvim-fuzzy-picker`: the plugins decide from THEIR configuration (the shared files, then the picker's
--- own `config.plugins`) which engine shows a file type. Made when first asked, so a setup() after this module loaded is read.
local client

---@return LvimUtilsPluginHost
local function host()
    if not client then
        client = require("lvim-utils.pluginhost").new({
            tool = "lvim-fuzzy-picker",
            plugins = require("lvim-picker.config").plugins,
        })
    end
    return client
end

--- Ask the preview plugins about `path` (through the plugin host, off the main thread): the plugins decide from THEIR configuration which
--- engine shows this file type. `cb(instruction)`: the first instruction of the answer (`{ op = "preview", facts?, missing?, body?, renderer?,
--- picture? }`), or nil when no plugin has a preview (pass), the host is missing, or it failed.
---@param path string
---@param cb fun(ins: table?)
function M.plugin(path, cb)
    host().call("lvim-fuzzy-plugin-preview", "preview", { path = path, max_px = { 1000, 800 }, host = "lvim-fuzzy-picker" }, function(ins, err)
        if err or type(ins) ~= "table" or ins.op ~= "preview" then
            return cb(nil)
        end
        cb(ins)
    end)
end

local function strip_ansi(s)
    return (s:gsub("\27%[[%d;:]*[A-Za-z]", ""))
end

local function human(n)
    local u = { "B", "K", "M", "G", "T" }
    local i = 1
    while n >= 1024 and i < #u do
        n, i = n / 1024, i + 1
    end
    return i == 1 and ("%d B"):format(n) or ("%.1f %s"):format(n, u[i])
end

--- The body of a plugin's answer as plain lines (the picker's preview is a buffer): a directory's entries, a
--- table's columns aligned, an archive's tree, text (colour codes dropped).
---@param body table?
---@return string[]
local function body_lines(body)
    local out = {}
    if type(body) ~= "table" then
        return out
    end
    if body.type == "entries" then
        for _, r in ipairs(body.rows or {}) do
            local name = r.name .. (r.dir and "/" or "")
            out[#out + 1] = r.dir and (" " .. name) or (" " .. name .. "  " .. human(r.size or 0))
        end
    elseif body.type == "table" then
        local w = {}
        for _, row in ipairs(body.rows or {}) do
            for c, cell in ipairs(row) do
                w[c] = math.max(w[c] or 0, vim.fn.strdisplaywidth(cell))
            end
        end
        for r, row in ipairs(body.rows or {}) do
            local cells = {}
            for c, cell in ipairs(row) do
                cells[c] = cell .. string.rep(" ", w[c] - vim.fn.strdisplaywidth(cell))
            end
            out[#out + 1] = " " .. table.concat(cells, " │ ")
            if r == 1 then
                local rule = {}
                for c = 1, #cells do
                    rule[c] = string.rep("─", w[c])
                end
                out[#out + 1] = " " .. table.concat(rule, "─┼─")
            end
        end
    elseif body.type == "tree" then
        for _, r in ipairs(body.rows or {}) do
            out[#out + 1] = " " .. string.rep("  ", r.depth or 0) .. r.name .. (r.dir and "/" or "")
        end
    elseif body.type == "text" then
        for _, l in ipairs(body.lines or {}) do
            out[#out + 1] = body.ansi and strip_ansi(l) or l
        end
    end
    return out
end

--- A plugin's answer as the picker draws previews: `{ info, missing, picture?, lines }`, where `lines` are the
--- facts (as `M.lines` makes them) and the red missing-program lines, then the body. `info` / `missing` go to
--- `M.paint`.
---@param ins table
---@return table
function M.from_plugin(ins)
    local d = { kind = "plugin", info = ins.facts or {}, missing = ins.missing or {}, picture = ins.picture }
    local lines = M.lines(d)
    vim.list_extend(lines, body_lines(ins.body))
    d.lines = lines
    return d
end

--- Open `path` the way the open plugin says (through the plugin host: the plugin's configuration decides which program opens which
--- type — the one rule lvc and lfz open files by): a picture in its viewer, a PDF in its reader, … started detached. True when the
--- file was HANDLED here: a program was started, or the program that would open it is not installed (said, nothing opened). False
--- for what the editor opens (text, a directory), when no plugin has an answer, and when the host is missing — the picker then opens
--- it as a buffer.
---@param path string
---@return boolean
function M.open_external(path)
    if path == "" or vim.fn.isdirectory(path) == 1 or not host().available() then
        return false
    end
    local done, j = false, nil
    host().call("lvim-fuzzy-plugin-open", "open", { path = path, host = "lvim-fuzzy-picker" }, function(ins)
        done, j = true, ins
    end)
    vim.wait(5000, function()
        return done
    end, 10)
    if type(j) ~= "table" then
        return false
    end
    if j.missing and type(j.missing) == "table" and #j.missing > 0 then
        vim.notify(table.concat(j.missing, "; "), vim.log.levels.ERROR)
        return true
    end
    j.cmd = j.cmd or nil
    if j.action ~= "exec" or type(j.cmd) ~= "string" then
        return false
    end
    local job = vim.fn.jobstart({ "sh", "-c", j.cmd }, { detach = true })
    if job <= 0 then
        return false
    end
    vim.notify("opened " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    return true
end

local ns = vim.api.nvim_create_namespace("lvim-picker-media")

--- Colour the table of facts (`lines` as `M.lines` made them) in `buf` as lvim-commander and lvim-fuzzy-cli draw
--- it: labels blue, values yellow, the `  ·  ` between the parts of a value dim.
---@param buf integer
---@param d table
function M.paint(buf, d)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local w = 0
    for _, row in ipairs(d.info or {}) do
        w = math.max(w, vim.fn.strdisplaywidth(row[1]))
    end
    local info = d.info or {}
    -- what the machine lacks for a full preview: one red line each, after the facts
    for j, m in ipairs(type(d.missing) == "table" and d.missing or {}) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, #info + j - 1, 1, {
            end_col = 1 + #("✗ " .. m),
            hl_group = "LvimUiPeekFactMissing",
            priority = 300,
        })
    end
    for i, row in ipairs(d.info or {}) do
        local lab_pad = w - vim.fn.strdisplaywidth(row[1])
        local lab_start, lab_end = 1 + lab_pad, 1 + lab_pad + #row[1] -- one column in, as lvc and lfz draw it
        local line = i - 1
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, lab_start, { end_col = lab_end, hl_group = "LvimUiPeekFactLabel", priority = 300 })
        local col = lab_end + 2
        local first = true
        for part in (row[2] .. "  ·  "):gmatch("(.-)  ·  ") do
            if not first then
                pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, col, { end_col = col + #"  ·  ", hl_group = "LvimUiPeekFactDot", priority = 300 })
                col = col + #"  ·  "
            end
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, col, { end_col = col + #part, hl_group = "LvimUiPeekFactValue", priority = 300 })
            col = col + #part
            first = false
        end
    end
end

--- The facts of a description as lines: the labels right-aligned in a column, the values after them.
---@param d table
---@return string[]
function M.lines(d)
    local w = 0
    for _, row in ipairs(d.info or {}) do
        w = math.max(w, vim.fn.strdisplaywidth(row[1]))
    end
    local out = {}
    for _, row in ipairs(d.info or {}) do
        out[#out + 1] = " " .. string.rep(" ", w - vim.fn.strdisplaywidth(row[1])) .. row[1] .. "  " .. row[2]
    end
    for _, m in ipairs(type(d.missing) == "table" and d.missing or {}) do
        out[#out + 1] = " ✗ " .. m
    end
    return out
end

return M
