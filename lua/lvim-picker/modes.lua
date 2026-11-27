--- The picker's client of lfz's MODES (git-status, git-log, processes, docker, systemd, ssh, …). The modes are defined
--- once, in `lvim-fuzzy-cli` (built-in ones and the user's own in its config); this module asks it for them
--- (`lvim-fuzzy-cli --modes-json`) and runs each as a finder: the mode's command lists the rows, its preview command
--- fills the preview, its `open` decides what confirming does. Nothing about a mode is written down here.
---
--- Left to the picker's own finders: the modes that are driven by the typed query (`live` / `pattern`: grep) and the
--- ones it has natively (files, directories, git files).
---@module "lvim-picker.modes"

local M = {}

--- Modes the picker already has as native finders.
local NATIVE = { files = true, dirs = true, ["git-files"] = true }

---@type table[]?
local cache

--- The engine's program, or nil.
---@return string?
local function engine()
    return require("lvim-utils.pluginhost").which("lvim-fuzzy-cli")
end

--- Every mode the picker can run: the engine's modes without the live/pattern ones and the native ones.
--- Cached for the session (`M.reload()` drops it).
---@return table[]
function M.list()
    if cache then
        return cache
    end
    cache = {}
    local exe = engine()
    if not exe then
        return cache
    end
    local out = vim.system({ exe, "--modes-json" }, { text = true }):wait(3000)
    if out.code ~= 0 or not out.stdout or out.stdout == "" then
        return cache
    end
    local ok, all = pcall(vim.json.decode, out.stdout)
    if not ok or type(all) ~= "table" then
        return cache
    end
    for _, m in ipairs(all) do
        if not (m.live or m.pattern or NATIVE[m.name]) then
            cache[#cache + 1] = m
        end
    end
    return cache
end

--- Forget the cached modes (the config of lfz changed).
function M.reload()
    cache = nil
end

---@param name string
---@return table?
function M.find(name)
    for _, m in ipairs(M.list()) do
        if m.name == name then
            return m
        end
    end
end

--- The names, for completion.
---@return string[]
function M.names()
    return vim.tbl_map(function(m)
        return m.name
    end, M.list())
end

--- `s` without its ANSI colour sequences.
---@param s string
---@return string
local function plain(s)
    return (s:gsub("\27%[[%d;:]*[%a]", ""):gsub("\27%][^\7\27]*[\7]", ""))
end

--- A shell-quoted word.
---@param s string
---@return string
local function q(s)
    return vim.fn.shellescape(s)
end

--- The delimiter of a mode's fields (`--delimiter=X` among its options; default: runs of whitespace).
---@param mode table
---@return string?
local function delimiter(mode)
    for _, o in ipairs(mode.options or {}) do
        local d = o:match("^%-%-delimiter=(.*)$")
        if d then
            return (d:gsub("\\t", "\t"))
        end
    end
end

--- Split `line` into fields by the mode's delimiter.
---@param line string
---@param delim string?
---@return string[]
local function fields(line, delim)
    local out = {}
    if not delim then
        for w in line:gmatch("%S+") do
            out[#out + 1] = w
        end
        return out
    end
    local pos = 1
    while true do
        local i, j = line:find(delim, pos, true)
        if not i then
            out[#out + 1] = line:sub(pos)
            break
        end
        out[#out + 1] = line:sub(pos, i - 1)
        pos = j + 1
    end
    return out
end

--- Fill the fzf-style placeholders of `tpl` for `line`: `{}` the row, `{n}` / `{-1}` a field, `{q}` the query.
--- Every value is shell-quoted.
---@param tpl string
---@param line string
---@param mode table
---@param query string?
---@return string
local function fill(tpl, line, mode, query)
    local f = fields(line, delimiter(mode))
    return (tpl:gsub("{([^{}]*)}", function(k)
        if k == "" then
            return q(line)
        elseif k == "q" then
            return q(query or "")
        elseif k == "+" then
            return q(line)
        end
        local n = tonumber(k)
        if not n then
            return nil -- not a placeholder (a brace of the command's own): left as it is
        end
        if n < 0 then
            n = #f + n + 1
        end
        return q(f[n] or "")
    end))
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
    local open = mode.open
    if type(open) == "string" and open ~= "" and open ~= "open" and open ~= "accept" then
        local kind, body = open:match("^([%w%-]+)%((.*)%)$")
        local cmd = body or open
        cmd = fill(cmd, line, mode, nil)
        if kind == "execute-silent" then
            vim.system({ "sh", "-c", cmd }, { detach = true })
        else
            in_terminal(cmd)
        end
        return
    end
    -- a file row (git status: `XY path`, or a target template)
    local path
    if type(mode.target) == "string" and mode.target ~= "" then
        path = fill(mode.target, line, mode, nil):gsub("^'(.*)'$", "%1")
    elseif mode.name == "git-status" then
        path = line:match("^.. (.+)$")
        path = path and path:gsub("^.* %-> ", ""):gsub('^"(.*)"$', "%1")
    end
    if path and path ~= "" and vim.uv.fs_stat(path) then
        vim.cmd.edit(vim.fn.fnameescape(path))
        return
    end
    vim.fn.setreg("+", line)
    vim.fn.setreg('"', line)
    vim.notify("copied: " .. line, vim.log.levels.INFO)
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
    return function(item, cb)
        local line = type(item) == "table" and item.text or tostring(item)
        if running then
            pcall(function()
                running:kill(15)
            end)
        end
        local cmd = fill(mode.preview, line, mode, nil)
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
    end
end

--- Open mode `name` as a finder. `picker` is the `lvim-picker` module; `opts` the caller's options (layout, …).
---@param picker table
---@param name string
---@param opts? table
function M.open(picker, name, opts)
    local mode = M.find(name)
    if not mode then
        vim.notify("LvimPicker: unknown mode '" .. tostring(name) .. "' (needs `lvim-fuzzy-cli` on PATH)", vim.log.levels.ERROR)
        return
    end
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
