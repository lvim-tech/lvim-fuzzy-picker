-- lvim-picker.source: the SOURCE layer of the finder: the LISTING commands (files / directories), the
-- content PREVIEW readers, and the async STREAMERS that feed the list. The engine and what it ignores are
-- user-configurable via `config.source` (engine / exclude / hidden / follow / respect_gitignore /
-- file_types), so a project's own fd / rg setup is matched.
--
---@module "lvim-picker.source"

local config = require("lvim-picker.config")
local iconlib = require("lvim-utils.icons")

local uv = vim.uv

local M = {}

-- ─── the single OPEN finder ────────────────────────────────────────────────────
-- Opening ANY finder must first FULLY close the one already open — releasing its docked area — so the new
-- finder REPLACES it in place instead of stacking above it. Each finder registers an `entry = { close = fn }`
-- after it opens and clears it on close; opening calls `close_active()` first.
---@type { close: fun() }?
M._active = nil

--- Close whatever finder is currently open, if any.
function M.close_active()
    local a = M._active
    M._active = nil
    if a and a.close then
        pcall(a.close)
    end
end

--- Register `entry` ({ close }) as the open finder.
---@param entry { close: fun() }
function M.set_active(entry)
    M._active = entry
end

--- Clear the registry if `entry` is still the open finder (called from a finder's own close).
---@param entry { close: fun() }
function M.clear_active(entry)
    if M._active == entry then
        M._active = nil
    end
end

--- The `guicursor` fragment for the finder INPUT caret, from `config.caret` ({ hl, shape }). `modes`
--- is the guicursor mode-list to apply it to ("i-ci-ve" for the insert prompt).
---@param modes string
---@return string
function M.caret_fragment(modes)
    local caret = (config or {}).caret or {}
    return modes .. ":" .. (caret.shape or "ver25") .. "-" .. (caret.hl or "LvimUiPickerCursor")
end

--- True when `bin` is an executable on PATH.
---@param bin string
---@return boolean
function M.has(bin)
    return vim.fn.executable(bin) == 1
end

--- Build the LIST command (argv) for `kind` ("files" | "dirs") from `config.source` — the engine and
--- what it ignores are user-configurable (`engine` / `exclude` / `hidden` / `follow` / `respect_gitignore` /
--- `file_types`). `engine = "auto"` picks the first available (fd → fdfind → rg → find); `rg` can only list
--- files, so a `dirs` request with rg falls back to fd/find. `find` has no ignore-file support (it always
--- lists everything but the excluded paths).
---@param kind "files"|"dirs"
---@return string[]
function M.build_list_cmd(kind)
    local cfg = (config or {}).source or {}
    local hidden = cfg.hidden ~= false
    local follow = cfg.follow == true
    local no_ignore = cfg.respect_gitignore == false
    local exclude = cfg.exclude or {}
    local want = cfg.engine or "auto"
    local order = want == "auto" and { "fd", "fdfind", "rg", "find" } or { want }
    local eng
    for _, c in ipairs(order) do
        if M.has(c) then
            eng = c
            break
        end
    end
    eng = eng or "find"
    if kind == "dirs" and eng == "rg" then -- rg lists files only
        eng = (M.has("fd") and "fd") or (M.has("fdfind") and "fdfind") or "find"
    end

    if eng == "fd" or eng == "fdfind" then
        local argv = { eng, "--color", "never", "--strip-cwd-prefix" }
        if kind == "dirs" then
            argv[#argv + 1], argv[#argv + 2] = "--type", "d"
        else
            for _, t in ipairs(cfg.file_types or { "f" }) do
                argv[#argv + 1], argv[#argv + 2] = "--type", t
            end
        end
        if hidden then
            argv[#argv + 1] = "--hidden"
        end
        if follow then
            argv[#argv + 1] = "--follow"
        end
        if no_ignore then
            argv[#argv + 1] = "--no-ignore"
        end
        for _, x in ipairs(exclude) do
            argv[#argv + 1], argv[#argv + 2] = "--exclude", x
        end
        return argv
    elseif eng == "rg" then -- files only
        local argv = { "rg", "--color", "never", "--files" }
        if hidden then
            argv[#argv + 1] = "--hidden"
        end
        if follow then
            argv[#argv + 1] = "--follow"
        end
        if no_ignore then
            argv[#argv + 1] = "--no-ignore"
        end
        for _, x in ipairs(exclude) do
            argv[#argv + 1], argv[#argv + 2] = "-g", "!" .. x
        end
        return argv
    end
    -- find: no gitignore support, just exclude the named paths
    local argv = { "find", ".", "-type", kind == "dirs" and "d" or "f" }
    for _, x in ipairs(exclude) do
        argv[#argv + 1], argv[#argv + 2], argv[#argv + 3] = "-not", "-path", "*/" .. x .. "/*"
    end
    return argv
end

--- The command (argv) to LIST files under cwd, from config.source.
---@return string[]
function M.file_list_cmd()
    return M.build_list_cmd("files")
end

--- The command (argv) to LIST directories under cwd, from config.source.
---@return string[]
function M.dir_list_cmd()
    return M.build_list_cmd("dirs")
end

--- The ft icon glyph + its highlight-group NAME for `name` (e.g. `"", "LvimIconBlue"`), or nil when icons
--- are off. For the TINT (lua-list) backend, which draws the glyph via an extmark coloured by the provider's
--- highlight group. The provider is the configured `icon_provider` (resolved via lvim-utils.icons).
---@param name string
---@return string? glyph, string? hl
function M.devicon(name)
    if (config or {}).show_icons == false then
        return nil
    end
    local r = iconlib.get(name, { provider = config.icon_provider, color_mode = config.icon_color_mode })
    return r.glyph, r.hl
end

--- Build the ripgrep argv for a LIVE content search of `query`, sharing the file-source config so CONTENT
--- search matches what `files` LISTS (hidden / .gitignore / excluded dirs). `regex = false` (the default)
--- matches the query literally (`--fixed-strings`); `regex = true` treats it as a pattern. `file` (optional)
--- restricts the search to that ONE path (the curbuf grep) instead of the whole cwd tree.
---@param query string
---@param regex? boolean
---@param file? string  restrict the search to this single file (nil = the whole cwd tree)
---@return string[]
function M.grep_cmd(query, regex, file)
    local rg = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    -- CAP each printed line's length (rg's own `--max-columns`): a broad content search over a huge tree hits
    -- minified bundles / cache / log files whose single line is MEGABYTES, and `--vimgrep` prints the WHOLE
    -- matched line — so an uncapped grep buffers gigabytes for a few hundred k matches (measured: "hel" over ~/
    -- = 15 GB) and a single blob_append of one monster line blocks the main thread. `--max-columns` truncates
    -- them; `--max-columns-preview` still shows the (truncated) line instead of omitting it, so a grep row is
    -- never longer than the panel needs. 0 disables the cap.
    local maxcol = tonumber((config or {}).grep_max_columns) or 512
    if maxcol > 0 then
        rg[#rg + 1] = "--max-columns"
        rg[#rg + 1] = tostring(maxcol)
        rg[#rg + 1] = "--max-columns-preview"
    end
    local src = (config or {}).source or {}
    if src.hidden ~= false then
        rg[#rg + 1] = "--hidden"
    end
    if src.follow == true then
        rg[#rg + 1] = "--follow"
    end
    if src.respect_gitignore == false then
        rg[#rg + 1] = "--no-ignore"
    end
    for _, x in ipairs(src.exclude or {}) do
        rg[#rg + 1] = "-g"
        rg[#rg + 1] = "!" .. x
    end
    if not regex then
        rg[#rg + 1] = "--fixed-strings"
    end
    rg[#rg + 1] = "--"
    rg[#rg + 1] = query
    if file and file ~= "" then
        rg[#rg + 1] = file -- restrict to the single buffer file (curbuf grep)
    end
    return rg
end

--- Read up to `n` lines of `path` for a preview, with a filetype guessed from the name.
---@param path string
---@param n? integer
---@return string[] lines, string filetype
function M.read_preview(path, n)
    local ft = vim.filetype.match({ filename = path }) or ""
    if vim.fn.filereadable(path) == 1 then
        return vim.fn.readfile(path, "", n or 500), ft
    end
    return { "[unreadable]" }, ""
end

-- The single fs_read chunk (bytes) and the total byte cap for an async preview read. The I/O runs on libuv's
-- THREADPOOL (off the main thread); only the newline split of the final buffer touches the main loop, bounded
-- to `max_lines` — so even a multi-GB file never blocks and never materialises unboundedly.
local PREVIEW_CHUNK = 256 * 1024
local PREVIEW_BYTE_CAP = 2 * 1024 * 1024

--- Read up to `max_lines` lines of `path` ASYNCHRONOUSLY (off the main thread via libuv fs), then deliver
--- `cb(lines, ft)` on the main loop. The read is DOUBLY BOUNDED — it stops at `PREVIEW_BYTE_CAP` bytes and the
--- split yields at most `max_lines` lines — so a huge file (a minified bundle, a log) can never freeze the
--- editor the way a synchronous `readfile` of `lnum+context` lines does. The filetype is guessed from the name
--- (no read). A DIRECTORY is listed instead (its entries as `ls -A` gives them, read asynchronously too). On an
--- open/read error → `cb({ "[unreadable]" }, "")`. The caller gen-guards + LRU-caches around this so a stale
--- read (superseded by a newer cursor position) is dropped and a re-visited file is instant.
---@param path string
---@param max_lines integer
---@param cb fun(lines: string[], filetype: string)
function M.read_preview_async(path, max_lines, cb)
    local ft = vim.filetype.match({ filename = path }) or ""
    local function fail()
        vim.schedule(function()
            cb({ "[unreadable]" }, "")
        end)
    end
    uv.fs_open(path, "r", 420, function(oerr, fd)
        if oerr or not fd then
            return fail()
        end
        local parts, total = {}, 0
        --- Only a regular file has lines to show: a directory OPENS fine and its first read fails (EISDIR),
        --- which used to deliver an empty preview instead of "[unreadable]".
        local function not_a_file()
            uv.fs_close(fd, function() end)
            fail()
        end
        local function finish()
            uv.fs_close(fd, function() end)
            local data = table.concat(parts)
            vim.schedule(function()
                -- Split at most `max_lines` lines on the main loop — O(bytes-up-to-max_lines), a small bounded
                -- slice, never the whole (possibly enormous) file.
                local lines, s, n = {}, 1, 0
                while n < max_lines do
                    local nl = data:find("\n", s, true)
                    if not nl then
                        if s <= #data then
                            lines[#lines + 1] = data:sub(s)
                        end
                        break
                    end
                    lines[#lines + 1] = data:sub(s, nl - 1)
                    s, n = nl + 1, n + 1
                end
                cb(lines, ft)
            end)
        end
        local function step(offset)
            uv.fs_read(fd, PREVIEW_CHUNK, offset, function(rerr, chunk)
                if rerr or not chunk or #chunk == 0 then -- error or EOF
                    return finish()
                end
                parts[#parts + 1] = chunk
                total = total + #chunk
                if total >= PREVIEW_BYTE_CAP then -- byte cap reached → stop (enough for `max_lines` of any sane file)
                    return finish()
                end
                step(offset + #chunk)
            end)
        end
        uv.fs_fstat(fd, function(serr, st)
            if not serr and st and st.type == "directory" then
                uv.fs_close(fd, function() end)
                uv.fs_scandir(path, function(derr, req)
                    if derr or not req then
                        return fail()
                    end
                    local names = {}
                    while true do
                        local name = uv.fs_scandir_next(req)
                        if not name then
                            break
                        end
                        names[#names + 1] = name
                    end
                    table.sort(names)
                    vim.schedule(function()
                        cb(vim.list_slice(names, 1, max_lines), "")
                    end)
                end)
                return
            end
            if serr or not st or st.type ~= "file" then
                return not_a_file()
            end
            step(0)
        end)
    end)
end

--- Run an argv synchronously and return its stdout lines (EMPTY on failure — a non-zero exit / raised error
--- yields `{}`, never the error text, so callers get a clean "no output" contract).
---@param argv string[]
---@return string[]
function M.run_lines(argv)
    local ok, res = pcall(vim.fn.systemlist, argv)
    if not ok or vim.v.shell_error ~= 0 then
        return {}
    end
    return res or {}
end

-- The yield between two drain slices of `spawn_stream` (ms). Small enough that a full queue keeps a high
-- ingest duty cycle (slice_ms work : REST ms idle), large enough that the event loop handles input / redraw /
-- other timers between slices — that gap is what makes a huge load FEEL smooth.
local STREAM_REST_MS = 2

--- Spawn `argv` and stream its stdout asynchronously, PACED: the libuv read callback only QUEUES each raw
--- chunk (no Lua work in the fast-event context), and a one-shot re-arming timer drains the queue in bounded
--- time slices — `config.stream_slice_ms` per slice, measured AROUND the `consume` calls so the budget covers
--- the consumer's real per-chunk cost — with a `STREAM_REST_MS` yield to the event loop between slices.
--- `consume(data, final)` processes one raw chunk on the main loop (`final = true` is a single end-of-stream
--- call with `data = ""`, for a line splitter to flush its trailing partial); `on_done()` fires once after
--- the final consume. Without pacing, a fast producer (fd emits ~2M lines in under a second) queues hundreds
--- of scheduled callbacks that the loop drains in ONE pass — a multi-hundred-ms freeze; paced, every
--- main-thread slice stays a few ms and input/redraw run in between, so a huge tree (e.g. `~/`) loads
--- smoothly. Returns a cancel function that kills the producer; a cancel also DROPS the queued backlog (the
--- consumer is gone — delivering it would be dead work), while `on_done` still fires once at process exit.
--- `max_lines` (optional) HARD-BOUNDS the queue in the FAST-EVENT read callback: once that many `\n` have been
--- seen the chunk is truncated at the cap, the producer is KILLED, and no more is queued — so an unbounded
--- producer (a broad `rg` grep that would emit gigabytes) can never flood the queue with more than ~`max_lines`
--- of data before it is stopped. A bounded producer (an `fd` path list) passes nil = no cap. The cap MUST be
--- enforced where the bytes ARRIVE, not in the (paced, slower) drain, or the queue floods before it triggers.
---
--- `count_opts` (optional, mutually exclusive with `max_lines`) is the GREP "hold all, count all" mode: a
--- `{ store = integer, counter = { total = integer } }` table. EVERY `\n` is tallied into `counter.total` (so
--- the caller's match count reaches the REAL total, e.g. 403k), but only the bytes up to `store` candidates are
--- QUEUED for the consumer (the blob) — beyond that the bytes are DISCARDED in the read callback (never buffered
--- → no OOM), yet still counted. The producer is NOT killed (the tally must run to rg's EOF for the true count).
--- `counter.total` is updated in place and read on the main thread (same loop thread → no data race).
---@param argv string[]
---@param consume fun(data: string, final: boolean)
---@param on_done fun()
---@param max_lines integer?  cap the queued lines in the read callback (kills the producer at the cap); nil = unbounded
---@param count_opts { store: integer, counter: { total: integer } }?  grep hold-all + true-count-tally mode
---@return fun() cancel
local function paced_stream(argv, consume, on_done, max_lines, count_opts)
    local slice_ns = ((config or {}).stream_slice_ms or 4) * 1e6
    ---@type string[], integer, integer  FIFO of raw stdout chunks (head/tail indices, slots nil-ed as read)
    local chunks, head, tail = {}, 1, 0
    local eof, finished, cancelled = false, false, false
    local line_count, capped = 0, false -- fast-event line tally for the `max_lines` bound
    local stored_full = false -- (count_opts) the `store` ceiling has been reached; further bytes are discarded
    ---@type vim.SystemObj?  forward-declared so the read callback can kill the producer at the cap
    local sys
    local timer = uv.new_timer()
    if not timer then
        -- No pacing timer, no stream — reported the same way a failed spawn is (below): signal done and
        -- hand back a cancel that has nothing to cancel.
        vim.schedule(on_done)
        return function() end
    end
    local armed = false -- a drain is already scheduled/pending (so the read callback never double-arms)

    ---@type fun(ms: integer)
    local arm

    --- Stop pacing, release the timer and report completion (runs once).
    local function finish()
        finished = true
        timer:stop()
        if not timer:is_closing() then
            timer:close()
        end
        on_done()
    end

    --- One bounded drain slice (main loop): feed queued chunks through `consume` until the time budget is
    --- spent (checked BETWEEN chunks, so it includes the consumer's real ingest work — the slice self-tunes to
    --- the per-chunk cost), then yield and re-arm. EOF with an empty queue runs the final `consume("", true)`
    --- and finishes.
    local function drain()
        armed = false
        if finished then
            return
        end
        if cancelled then -- consumer gone: drop the backlog, still complete once the producer exited
            chunks, head, tail = {}, 1, 0
            if eof then
                finish()
            end
            return
        end
        local deadline = uv.hrtime() + slice_ns
        while head <= tail do
            local data = chunks[head]
            chunks[head] = nil
            head = head + 1
            consume(data, false)
            if uv.hrtime() >= deadline then
                break
            end
        end
        if head <= tail then
            arm(STREAM_REST_MS) -- backlog remains → next slice after a short yield to the loop
        elseif eof then
            consume("", true) -- flush a line splitter's trailing partial (a no-op for raw consumers)
            finish()
        end
        -- queue empty, producer still running → stay idle; the next stdout chunk re-arms at 0
    end

    --- Schedule the next drain slice in `ms` (idempotent; safe from the fast-event read callback — luv
    --- timer ops are fast-context-legal, the main-thread work is deferred via vim.schedule).
    ---@param ms integer
    arm = function(ms)
        if armed or finished then
            return
        end
        armed = true
        timer:start(ms, 0, function()
            vim.schedule(drain)
        end)
    end

    local ok
    ok, sys = pcall(vim.system, argv, {
        text = true,
        stdout = function(err, data) -- fast-event ctx: ONLY queue the chunk (+ the cheap `max_lines` tally)
            if err or not data or capped then
                return
            end
            if count_opts then
                -- GREP hold-all + count-all: tally EVERY match line (so the counter reaches the real total),
                -- but queue only the bytes up to `store` candidates. Once the ceiling is crossed, the extra
                -- bytes are DISCARDED here (never queued → no OOM) while `counter.total` keeps climbing. rg is
                -- NOT killed — the count must run to EOF to reach the truth.
                local counter = count_opts.counter
                local before = counter.total
                local nls, s = 0, 1
                while true do
                    local nl = data:find("\n", s, true)
                    if not nl then
                        break
                    end
                    nls = nls + 1
                    s = nl + 1
                end
                counter.total = before + nls
                if stored_full then
                    return -- past the store ceiling → count only, queue nothing
                end
                if counter.total > count_opts.store then
                    -- this chunk crosses the ceiling: queue up to the (store - before)-th newline, drop the rest
                    local want = count_opts.store - before
                    stored_full = true
                    if want <= 0 then
                        return -- the ceiling was already exactly met by an earlier chunk → queue nothing
                    end
                    local seen, s2, cut = 0, 1, #data
                    while true do
                        local nl = data:find("\n", s2, true)
                        if not nl then
                            break
                        end
                        seen = seen + 1
                        if seen >= want then
                            cut = nl -- keep up to and including this newline (the last storable candidate)
                            break
                        end
                        s2 = nl + 1
                    end
                    data = data:sub(1, cut)
                end
            elseif max_lines then
                -- Count `\n` in this chunk; the moment the running tally reaches the cap, TRUNCATE the chunk at
                -- that newline, mark capped, and kill the producer — so no more than ~max_lines of data is ever
                -- queued (a broad grep can't flood gigabytes before the paced drain notices).
                local s = 1
                while true do
                    local nl = data:find("\n", s, true)
                    if not nl then
                        break
                    end
                    line_count = line_count + 1
                    if line_count >= max_lines then
                        data = data:sub(1, nl) -- keep up to and including this newline
                        capped = true
                        break
                    end
                    s = nl + 1
                end
            end
            tail = tail + 1
            chunks[tail] = data
            arm(0)
            if capped and sys then
                pcall(function()
                    sys:kill("sigterm") -- bound reached → stop the producer at the source
                end)
            end
        end,
    }, function()
        eof = true
        arm(0) -- drain whatever remains (incl. the final flush), then signal done
    end)
    if not ok then
        finished = true
        if not timer:is_closing() then
            timer:close()
        end
        vim.schedule(on_done)
        return function() end
    end
    return function()
        cancelled = true
        pcall(function()
            if sys then
                sys:kill("sigterm")
            end
        end)
    end
end

--- Spawn `argv` and stream its stdout LINES: `on_lines(lines)` is called (paced, on the main loop) with each
--- batch of complete lines, `on_done()` once after the last. Lines are split HERE, in Lua — used by the
--- fallback (per-string) streaming path and by consumers that want ready-made lines.
---@param argv string[]
---@param on_lines fun(lines: string[])
---@param on_done fun()
---@param max_lines integer?  cap the collected lines (kills the producer at the cap; e.g. grep's `grep_max`)
---@return fun() cancel
function M.spawn_stream(argv, on_lines, on_done, max_lines)
    local rest = "" -- partial trailing line carried between chunks
    local function consume(data, final)
        rest = rest .. data
        local lines, start = {}, 1
        while true do
            local nl = rest:find("\n", start, true)
            if not nl then
                break
            end
            lines[#lines + 1] = rest:sub(start, nl - 1)
            start = nl + 1
        end
        rest = rest:sub(start)
        if final and rest ~= "" then
            lines[#lines + 1] = rest
            rest = ""
        end
        if #lines > 0 then
            on_lines(lines)
        end
    end
    return paced_stream(argv, consume, on_done, max_lines)
end

--- Spawn `argv` and stream its stdout RAW BYTES: `on_bytes(data)` is called (paced, on the main loop) with
--- each stdout chunk exactly as it arrives — NO Lua line splitting. The blob-ingest streaming path hands
--- these chunks straight to the native matcher (which splits on `\n` itself), so a huge listing never
--- materialises per-line Lua strings. `on_done()` fires once at end of stream. `max_lines` caps the stream in
--- the read callback (kills the producer at the cap) — used by grep so a broad query never floods the queue.
---@param argv string[]
---@param on_bytes fun(data: string)
---@param on_done fun()
---@param max_lines integer?  cap the streamed lines in the read callback (kills the producer at the cap)
---@return fun() cancel
function M.spawn_stream_raw(argv, on_bytes, on_done, max_lines)
    local function consume(data, final)
        if not final and #data > 0 then
            on_bytes(data)
        end
    end
    return paced_stream(argv, consume, on_done, max_lines)
end

--- Spawn a grep `argv` and stream its `--vimgrep` stdout as RAW BYTES into `on_bytes` (the native blob), in the
--- "hold ALL matches, count ALL matches" mode (Variant B): the blob holds up to `store` candidates and beyond
--- that the bytes are DISCARDED but still TALLIED, so `counter.total` reaches the REAL match total (e.g. 403k)
--- without ever buffering past the ceiling → no OOM, ~0% main-thread block (exactly like the paced files load).
--- rg runs to EOF so the count reaches the truth (killed only on `cancel`). `counter` is the caller's table
--- (`{ total = 0 }`) updated in place; read it on the main thread. `on_done()` fires once at end of stream.
---@param argv string[]
---@param on_bytes fun(data: string)
---@param on_done fun()
---@param store integer  the native-blob candidate ceiling (config.grep_max) — bytes past it are counted, not stored
---@param counter { total: integer }  the caller table whose `.total` this updates to the TRUE match count
---@return fun() cancel
function M.spawn_grep_blob(argv, on_bytes, on_done, store, counter)
    local function consume(data, final)
        if not final and #data > 0 then
            on_bytes(data)
        end
    end
    return paced_stream(argv, consume, on_done, nil, { store = store, counter = counter })
end

-- Devicon colours are baked (once) into ANSI escapes — the shell-pipe map file (`icon_state`) and the
-- Lua-list cache (`lua_icon_cache`) — so a colourscheme change would otherwise leave every ft icon at its
-- OLD colour. Drop both caches (and remove the stale on-disk map file) on `ColorScheme`; they rebuild lazily
-- with the live palette on the next listing. (`rg_color_flags` already reads the palette live, so grep colours
-- track the theme on their own — nothing to invalidate there.)
vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LvimPickerSourceIcons", { clear = true }),
    callback = function()
        if type(icon_state) == "table" and icon_state.map then
            os.remove(icon_state.map)
        end
        icon_state = nil
        lua_icon_cache = {}
    end,
})

return M
