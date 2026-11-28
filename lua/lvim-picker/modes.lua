--- The picker's client of the MODES (git-status, git-log, processes, docker, systemd, ssh, …). The modes are defined once, in the plugin
--- `lvim-fuzzy-plugin-modes` (data: its `[config.modes.*]` tables, changed or added in `~/.config/lvim-plugins/lvim-fuzzy-plugin-modes.toml`):
--- this module asks it through the plugin host (`lvim-plugin host`, the same one the previews use) and runs each mode as a finder: the
--- mode's command lists the rows, its preview command fills the preview, its `open` decides what confirming does. The command
--- templates (`{}`, `{2..}`, `{-1}`, `{q}`) are filled by the plugin too (`expand`): the one expander of lfz. Nothing about a mode is written
--- down here.
---
--- Left to the picker's own finders: the modes that are driven by the typed query (`live` / `pattern`: grep) and the
--- ones it has natively (files, directories, git files).
---@module "lvim-picker.modes"

local M = {}

--- Modes the picker already has as native finders.
local NATIVE = { files = true, dirs = true, ["git-files"] = true }

--- The modes, once the plugin has answered (nil: not asked yet).
---@type table[]?
local cache
--- The plugin that serves them.
---@type string?
local provider
--- The callers waiting for the first answer.
---@type fun(modes: table[])[]?
local waiting

---@return LvimUtilsPluginHost
local function host()
    return require("lvim-picker.media").host()
end

--- The programs of `m.requires` that are not installed.
---@param m table
---@return string[]
local function missing(m)
    local out = {}
    for _, prog in ipairs(m.requires or {}) do
        if vim.fn.executable(prog) ~= 1 then
            out[#out + 1] = prog
        end
    end
    return out
end

--- Ask for the modes; `cb(modes)` runs when the plugin has answered (at once, later, when already known). Every mode the picker can run: the
--- plugin's modes without the live/pattern ones and the native ones. Kept for the session (`M.reload()` drops them).
---@param cb fun(modes: table[])
function M.list(cb)
    if cache then
        return vim.schedule(function()
            cb(cache)
        end)
    end
    if waiting then
        waiting[#waiting + 1] = cb
        return
    end
    waiting = { cb }
    -- `known`: the plugin really answered. An answer that is none (no host, no modes plugin, a failed call) is given to the waiting callers but NOT
    -- kept: the next ask tries again (a plugin installed a moment later is seen without restarting Neovim)
    local function done(list, known)
        if known then
            cache = list
        end
        local w = waiting or {}
        waiting = nil
        for _, f in ipairs(w) do
            pcall(f, list)
        end
    end
    host().raw("list", {}, function(plugins)
        for _, p in ipairs(type(plugins) == "table" and plugins or {}) do
            if type(p.tables) == "table" and p.tables.modes == true then
                provider = p.name
            end
        end
        if not provider then
            return done({}, false)
        end
        host().call(provider, "modes", {}, function(ins)
            local out = {}
            local answered = type(ins) == "table" and type(ins.modes) == "table"
            for _, m in ipairs(type(ins) == "table" and ins.modes or {}) do
                if not (m.live or m.pattern or NATIVE[m.name]) then
                    m.title = (m.title and m.title ~= "") and m.title or m.name
                    m.missing = missing(m)
                    out[#out + 1] = m
                end
            end
            done(out, answered)
        end)
    end)
end

--- The modes known NOW (empty until the first answer): for what cannot wait (command completion). `M.list(function() end)` starts the asking.
---@return table[]
function M.known()
    return cache or {}
end

--- Forget the modes (the settings of the plugin changed).
function M.reload()
    cache = nil
    provider = nil
end

---@param name string
---@param cb fun(mode: table?)
function M.find(name, cb)
    M.list(function(all)
        for _, m in ipairs(all) do
            if m.name == name then
                return cb(m)
            end
        end
        cb(nil)
    end)
end

--- The names known now, for completion.
---@return string[]
function M.names()
    return vim.tbl_map(function(m)
        return m.name
    end, M.known())
end

--- `s` without its ANSI colour sequences.
---@param s string
---@return string
local function plain(s)
    return (s:gsub("\27%[[%d;:]*[%a]", ""):gsub("\27%][^\7\27]*[\7]", ""))
end

--- The delimiter of a mode's fields (`--delimiter=X` among its options; default: runs of whitespace).
---@param mode table
---@return string?
local function delimiter(mode)
    for _, o in ipairs(mode.options or {}) do
        local d = o:match("^%-%-delimiter=(.*)$")
        if d then
            return d
        end
    end
end

--- Fill the placeholders of `tpl` for `line` (`{}` the row, `{n}` / `{-1}` / `{2..}` fields, `{q}` the query, every value shell-quoted): the
--- plugin does it, with the expander lfz uses. `cb(text)`; on a failure the template is given back as it is (nothing is run on a guess).
---@param tpl string
---@param line string
---@param mode table
---@param query string?
---@param cb fun(text: string?, err: string?)
local function fill(tpl, line, mode, query, cb, raw)
    if not tpl:find("{", 1, true) then
        return cb(tpl)
    end
    host().call(provider or "lvim-fuzzy-plugin-modes", "expand", { template = tpl, line = line, query = query or "", delimiter = delimiter(mode), raw = raw or nil }, function(ins, err)
        if err or type(ins) ~= "table" or type(ins.text) ~= "string" then
            return cb(nil, err or "the modes plugin did not answer")
        end
        cb(ins.text)
    end)
end

--- Run `cmd` through the shell and collect stdout (async), `cb(lines)`.
---@param cmd string
---@param cb fun(lines: string[], code: integer)
local function shell_lines(cmd, cb)
    vim.system({ "sh", "-c", cmd }, { text = true }, function(o)
        vim.schedule(function()
            local lines = {}
            for l in (o.stdout or ""):gmatch("[^\r\n]+") do
                lines[#lines + 1] = plain(l)
            end
            cb(lines, o.code)
        end)
    end)
end

--- Run `cmd` in a terminal split (the program may be interactive: `less`, `man`, `ssh`).
---@param cmd string
local function in_terminal(cmd)
    vim.cmd("botright new")
    vim.fn.jobstart({ "sh", "-c", cmd }, { term = true })
    vim.cmd("startinsert")
end

--- What confirming a row does, from the mode's `open` (the lfz `--bind` syntax): `execute(...)` / `become(...)` (a
--- program in a terminal), `execute-silent(...)` (in the background), a plain command, or - none / `open` / `accept` -
--- the row itself: a file is edited, anything else goes to the clipboard.
---@param mode table
---@param line string
local function confirm(mode, line)
    --- the row itself: a file is edited, anything else goes to the clipboard
    local function the_row(path)
        if path and path ~= "" and vim.uv.fs_stat(path) then
            vim.cmd.edit(vim.fn.fnameescape(path))
            return
        end
        vim.fn.setreg("+", line)
        vim.fn.setreg('"', line)
        vim.notify("copied: " .. line, vim.log.levels.INFO)
    end
    local open = mode.open
    if type(open) == "string" and open ~= "" and open ~= "open" and open ~= "accept" then
        local kind, body = open:match("^([%w%-]+)%((.*)%)$")
        fill(body or open, line, mode, nil, function(cmd, err)
            if not cmd then
                return vim.notify("LvimPicker " .. mode.name .. ": " .. err, vim.log.levels.ERROR)
            end
            if kind == "execute-silent" then
                vim.system({ "sh", "-c", cmd }, { detach = true })
            else
                in_terminal(cmd)
            end
        end)
        return
    end
    -- a file row (git status: `XY path`, or a target template)
    if type(mode.target) == "string" and mode.target ~= "" then
        -- a file name for the picker to open, not a word for a shell: the values come unquoted
        fill(mode.target, line, mode, nil, function(t)
            the_row(t)
        end, true)
        return
    end
    local path
    if mode.name == "git-status" then
        path = line:match("^.. (.+)$")
        path = path and path:gsub("^.* %-> ", ""):gsub('^"(.*)"$', "%1")
    end
    the_row(path)
end

--- The async preview of a row: the mode's preview command, run for that row off the main thread. Only the newest
--- request is kept running: scrolling past rows kills the commands of the rows left behind.
---@param mode table
---@return fun(item: any, cb: fun(lines: string[], ft: string?))?
local function previewer(mode)
    if not mode.preview or mode.preview == "" then
        return nil
    end
    local running
    local asked = 0
    return function(item, cb)
        local line = type(item) == "table" and item.text or tostring(item)
        if running then
            pcall(function()
                running:kill(15)
            end)
        end
        -- the newest row is the one that counts: a row asked for after this one (before the plugin has filled the template) wins
        asked = asked + 1
        local mine = asked
        fill(mode.preview, line, mode, nil, function(cmd)
            if mine ~= asked or not cmd then
                return
            end
            local handle
            handle = vim.system({ "sh", "-c", cmd }, { text = true, timeout = 8000 }, function(o)
                vim.schedule(function()
                    if handle ~= running then
                        return -- a newer row asked meanwhile: this answer is stale
                    end
                    running = nil
                    if o.signal and o.signal ~= 0 then
                        return
                    end
                    local lines = {}
                    for l in ((o.stdout or "") .. (o.stderr or "")):gmatch("[^\r\n]*") do
                        lines[#lines + 1] = plain(l)
                    end
                    while #lines > 0 and lines[#lines] == "" do
                        lines[#lines] = nil
                    end
                    cb(lines, nil)
                end)
            end)
            running = handle
        end)
    end
end

--- Open mode `name` as a finder. `picker` is the `lvim-picker` module; `opts` the caller's options (layout, …).
---@param picker table
---@param name string
---@param opts? table
function M.open(picker, name, opts)
    M.find(name, function(mode)
        if not mode then
            vim.notify("LvimPicker: unknown mode '" .. tostring(name) .. "' (needs the plugin host `lvim-plugin` and the modes plugin)", vim.log.levels.ERROR)
            return
        end
        M.run(picker, mode, opts)
    end)
end

--- Run `mode` as a finder.
---@param picker table
---@param mode table
---@param opts? table
function M.run(picker, mode, opts)
    if mode.missing and #mode.missing > 0 then
        vim.notify(("LvimPicker %s: needs %s"):format(mode.name, table.concat(mode.missing, ", ")), vim.log.levels.WARN)
        return
    end
    if not mode.command or mode.command == "" then
        vim.notify("LvimPicker " .. mode.name .. ": the mode has no list command", vim.log.levels.WARN)
        return
    end
    shell_lines(mode.command, function(lines, code)
        if #lines == 0 and code ~= 0 then
            vim.notify(("LvimPicker %s: the command failed (%d)"):format(mode.name, code), vim.log.levels.WARN)
            return
        end
        picker.open(vim.tbl_extend("force", {
            title = mode.title ~= "" and mode.title or mode.name,
            key = "mode:" .. mode.name,
            items = lines,
            -- the picker shows its preview panel for a finder that has a `preview`; the async one fills it
            preview = function()
                return {}, nil
            end,
            preview_async = previewer(mode),
            on_confirm = function(it)
                local line = type(it) == "table" and (it.text or it) or it
                if type(line) == "string" and line ~= "" then
                    confirm(mode, line)
                end
            end,
        }, opts or {}))
    end)
end

return M
