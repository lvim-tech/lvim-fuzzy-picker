--- The ready-made finders (files, directories, grep and its variants, buffers' neighbours: oldfiles, help tags, git files, colorschemes, commands, marks,
--- keymaps, quickfix, jumplist): each one lists with the source helpers and opens through `M.open` / `pick_items`. Moved out of init.lua; it is
--- called once from there, with what the finders share with the rest (`M`, `pick_items`, `filter`, `normalize`, `preview_span`).
---@module "lvim-picker.finders"

local api = vim.api
local config = require("lvim-picker.config")
local fuzzy = require("lvim-picker.fuzzy")
local preview = require("lvim-ui.preview")
local source = require("lvim-picker.source")
local has = source.has
local file_list_cmd = source.file_list_cmd
local dir_list_cmd = source.dir_list_cmd
local read_preview = source.read_preview
local run_lines = source.run_lines
local spawn_stream = source.spawn_stream
local spawn_stream_raw = source.spawn_stream_raw

return function(M, pick_items, filter, normalize, preview_span)
    --- Configure `spec` (a tint finder whose candidates ARE their paths — files / directories / git_files) to
    --- STREAM `list_cmd` into the pool. GAP-5: when the native matcher supports blob ingestion (ABI ≥ 5) the raw
    --- stdout bytes go straight to the native context (`blob_stream` + `blob_item` — no Lua per-row work, so a
    --- multi-million-file tree never builds a Lua string pool); otherwise it falls back to the per-string line
    --- stream (`stream`). `text == path` for these finders, so `_src` is `{ path = text }` either way.
    ---@param spec table  the finder spec passed to M.open (mutated in place)
    ---@param list_cmd string[]  the listing command (argv)
    local function stream_paths(spec, list_cmd)
        if fuzzy.has_blob() then
            spec.blob_stream = function(feed_bytes, done)
                return spawn_stream_raw(list_cmd, feed_bytes, done)
            end
            spec.blob_item = function(text)
                return { path = text }
            end
        else
            spec.stream = function(feed, done)
                return spawn_stream(list_cmd, function(lines)
                    local batch = {}
                    for _, p in ipairs(lines) do
                        if p ~= "" then
                            batch[#batch + 1] = { text = p, path = p }
                        end
                    end
                    feed(batch)
                end, done)
            end
        end
    end

    --- Parse one ripgrep `--vimgrep` line (`path:lnum:col:text`) into a location item. Shared by the grep blob
    --- path (as `blob_item`, deriving `_src` from the candidate text on demand) and the fallback item stream.
    --- Returns nil for a line that is not a location (so the caller can decide the fallback).
    ---@param line string
    ---@return { path: string, lnum: integer, col: integer, text: string }?
    local function grep_item(line)
        local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if file then
            return { path = file, lnum = tonumber(lnum), col = tonumber(col), text = text or "" }
        end
    end

    --- A BOUNDED line streamer for a grep argv, building location ITEMS (the fallback when the native library
    --- predates the blob API, ABI < 5). Same `config.grep_max` cap (enforced in the read callback) + async
    --- streaming as the blob path — never floods the queue, never blocks. Returns a producer for `opts.stream`.
    ---@param argv string[]
    ---@return fun(feed: fun(raw: table[]), done: fun()): fun()
    local function grep_item_stream(argv)
        return function(feed, done)
            return spawn_stream(argv, function(lines)
                local batch = {}
                for _, ln in ipairs(lines) do
                    local it = grep_item(ln)
                    if it then
                        it.text = ("%s:%s  %s"):format(it.path, it.lnum, it.text) -- display; _src keeps path/lnum/col
                        batch[#batch + 1] = it
                    end
                end
                if #batch > 0 then
                    feed(batch)
                end
            end, done, (config or {}).grep_max or 500000)
        end
    end

    --- Fuzzy file finder under cwd; confirming edits the file, with a content preview. `opts` forwarded to open.
    ---@param opts? table
    function M.files(opts)
        opts = opts or {}
        opts.key = opts.key or "files" -- dock kind key
        local spec = {
            title = "Files",
            on_confirm = function(it)
                if it and it.path then
                    vim.cmd.edit(vim.fn.fnameescape(it.path))
                end
            end,
            -- ASYNC file preview (read off the main thread, LRU-cached) so it follows the cursor while scrolling.
            preview_file_of = function(s)
                return s.path and s.path ~= "" and { path = s.path } or nil
            end,
        }
        stream_paths(spec, file_list_cmd())
        M.open(vim.tbl_extend("force", spec, opts or {}))
    end

    --- Fuzzy directory finder under cwd; confirming `:cd`s into the chosen directory. `opts` forwarded to open.
    ---@param opts? table
    function M.directories(opts)
        opts = opts or {}
        opts.key = opts.key or "directories"
        local spec = {
            title = "Directories",
            on_confirm = function(it)
                if it and it.path then
                    vim.cmd.cd(vim.fn.fnameescape(it.path))
                end
            end,
            -- ASYNC preview (the listing is read off the main thread, LRU-cached), so it follows the cursor.
            preview_file_of = function(s)
                return s.path and s.path ~= "" and { path = s.path } or nil
            end,
        }
        stream_paths(spec, dir_list_cmd())
        M.open(vim.tbl_extend("force", spec, opts or {}))
    end

    --- LIVE grep (ripgrep) under cwd: each query re-runs `rg`, the matches ARE the results, with a preview that
    --- jumps to the matched line; confirming opens the file at that line. `opts` forwarded to open.
    ---@param opts? table
    function M.grep(opts)
        opts = opts or {}
        opts.key = opts.key or "grep" -- a fixed-query variant (cword / …) sets its own key BEFORE calling here
        if not has("rg") then
            vim.notify("lvim-picker.grep needs ripgrep (rg)", vim.log.levels.WARN)
            return
        end
        local fixed = opts.query ~= nil and opts.query ~= "" -- a fixed-query grep (cword / cWORD / selection / …)
        local tint = {
            title = "Grep",
            -- ASYNC file preview, focused on the matched line — read off the main thread + LRU-cached, so scrolling
            -- grep results (every row a different file:line) follows the cursor instead of a per-move disk read.
            preview_file_of = function(s)
                -- The COLUMN travels too: without it the preview can centre the matched LINE but has
                -- nothing to point at inside it, which is the whole question a grep result raises.
                return s.path and s.path ~= "" and { path = s.path, lnum = s.lnum, col = s.col } or nil
            end,
            on_confirm = function(it)
                if it and it.path then
                    vim.cmd.edit(vim.fn.fnameescape(it.path))
                    pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, (it.col or 1) - 1 })
                    vim.cmd("normal! zz")
                end
            end,
        }
        if fuzzy.has_blob() then
            -- VARIANT B — the GREP CONTROLLER holds EVERY rg match in the native blob (like fzf keeps them in its
            -- own process), so there is NO browse cap and the counter climbs to the REAL total (e.g. 403127) as rg
            -- streams. LIVE grep (no fixed query): the typed query drives rg, re-grepping into a fresh blob per
            -- change; Ctrl-g freezes rg and fuzzy-filters the loaded results. FIXED-query grep: rg runs ONCE, then
            -- the typed query fuzzy-narrows the blob. `config.grep_max` is the native STORE ceiling (a broader query
            -- is still fully counted, never stored — no OOM). `blob_item` re-derives path/lnum/col from each line.
            tint.grep = {
                live = not fixed,
                query = opts.query,
                regex = opts.regex,
                file = opts.file,
            }
            tint.blob_item = function(text)
                return grep_item(text) or { path = text, text = text }
            end
        else
            -- FALLBACK (native library predates ABI 5 / the Lua matcher): the bounded source/stream path with the
            -- `matches / total-files` counter. rg's stdout is capped at `config.grep_max` in the read callback (rg
            -- killed at the cap) so a broad query never floods the queue. No Ctrl-g / uncapped browse on this path.
            tint.count_files = true -- counter = `matches found / TOTAL FILES in the tree` (background fd count)
            if fixed then
                -- rg runs ONCE for the fixed query; its bounded item stream feeds the matcher, then you fuzzy-filter.
                tint.stream = grep_item_stream(source.grep_cmd(opts.query, opts.regex, opts.file))
            else
                -- LIVE grep: each typed query re-runs `rg` (rg IS the search). rg's stdout is STREAMED in chunks and
                -- capped at `config.grep_max`; the previous rg is killed before the next spawns (and on close).
                local grep_cancel ---@type fun()?
                local function kill_grep()
                    if grep_cancel then
                        pcall(grep_cancel) -- kills rg + drops any queued backlog (spawn_stream cancel)
                        grep_cancel = nil
                    end
                end
                --- One raw vimgrep line → a GRID item, or nil for a non-location line. Built directly (not via
                --- `normalize`) so the progressive live stream can APPEND to one growing list — `source_raw` tells
                --- the finder to skip re-normalising it per batch.
                ---@param line string
                ---@return table?
                local function live_item(line)
                    local it = grep_item(line)
                    if it then
                        return { text = ("%s:%s  %s"):format(it.path, it.lnum, it.text), _src = it }
                    end
                end
                tint.source_raw = true -- `out` already holds grid items; skip re-normalising per delivery
                tint.source = function(query, cb)
                    kill_grep() -- cancel the previous query's rg before starting a new one (no pile-up)
                    if query == nil or #query < 2 then -- wait for a couple of chars (rg over a huge tree is heavy)
                        cb({})
                        return
                    end
                    local out, tick_scheduled = {}, false
                    local function deliver() -- coalesce a burst of drains into one re-render; keep the count live
                        if tick_scheduled then
                            return
                        end
                        tick_scheduled = true
                        vim.defer_fn(function()
                            tick_scheduled = false
                            cb(out)
                        end, (config or {}).stream_refresh_ms or 50)
                    end
                    grep_cancel = spawn_stream(source.grep_cmd(query, opts.regex, opts.file), function(lines)
                        for _, ln in ipairs(lines) do
                            local it = live_item(ln)
                            if it then
                                out[#out + 1] = it
                            end
                        end
                        deliver()
                    end, function() -- rg exited: one FINAL delivery with the complete (bounded) match set
                        cb(out)
                    end, (config or {}).grep_max or 500000) -- cap enforced in the read callback (no queue flood)
                end
                tint.on_close = kill_grep -- kill any in-flight rg when the finder closes
            end
        end
        M.open(vim.tbl_extend("force", tint, opts))
    end

    --- Grep the word under the cursor (`<cword>`), then fuzzy-filter the matches.
    ---@param opts? table
    function M.grep_cword(opts)
        opts = opts or {}
        opts.key = opts.key or "grep_cword"
        opts.query = opts.query or vim.fn.expand("<cword>")
        opts.title = opts.title or ("Grep: " .. opts.query)
        return M.grep(opts)
    end

    --- Grep the WORD under the cursor (`<cWORD>` — includes punctuation), then fuzzy-filter the matches.
    ---@param opts? table
    function M.grep_cWORD(opts)
        opts = opts or {}
        opts.key = opts.key or "grep_cWORD"
        opts.query = opts.query or vim.fn.expand("<cWORD>")
        opts.title = opts.title or ("Grep: " .. opts.query)
        return M.grep(opts)
    end

    --- Grep the last visual selection (`'<`..`'>`), then fuzzy-filter the matches.
    ---@param opts? table
    function M.grep_visual(opts)
        opts = opts or {}
        opts.key = opts.key or "grep_visual"
        local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
        local lines = vim.fn.getline(s[2], e[2])
        -- The two-argument `getline` always returns the RANGE as a list (the union is the one-argument form).
        ---@cast lines string[]
        if #lines > 0 then
            lines[#lines] = lines[#lines]:sub(1, e[3])
            lines[1] = lines[1]:sub(s[3])
        end
        opts.query = (table.concat(lines, " "):gsub("%s+", " "))
        opts.title = opts.title or ("Grep: " .. opts.query)
        return M.grep(opts)
    end

    --- Prompt for a search string, then grep it (fixed) and fuzzy-filter the matches.
    ---@param opts? table
    function M.grep_word(opts)
        opts = opts or {}
        opts.key = opts.key or "grep_word"
        require("lvim-ui").input({
            prompt = "Grep",
            callback = function(confirmed, q)
                if confirmed == true and q and q ~= "" then
                    opts.query, opts.title = q, "Grep: " .. q
                    M.grep(opts)
                end
            end,
        })
    end

    --- Live-grep the CURRENT file only.
    ---@param opts? table
    function M.grep_curbuf(opts)
        opts = opts or {}
        opts.key = opts.key or "grep_curbuf"
        local file = api.nvim_buf_get_name(0)
        if file == "" or vim.fn.filereadable(file) ~= 1 then
            vim.notify("lvim-picker.grep_curbuf: current buffer has no file on disk", vim.log.levels.WARN)
            return
        end
        opts.file = file
        opts.title = opts.title or ("Grep (buf): " .. vim.fn.fnamemodify(file, ":t"))
        return M.grep(opts)
    end

    --- Fuzzy finder over RECENT files (`v:oldfiles`, readable only), newest first; confirming edits the file.
    ---@param opts? table
    function M.oldfiles(opts)
        opts = opts or {}
        opts.key = opts.key or "oldfiles"
        local items, seen = {}, {}
        for _, p in ipairs(vim.v.oldfiles or {}) do
            if not seen[p] and vim.fn.filereadable(p) == 1 then
                seen[p] = true
                items[#items + 1] = { text = vim.fn.fnamemodify(p, ":~:."), path = p }
            end
        end
        pick_items({
            title = "Recent",
            items = items,
            icon = true, -- coloured ft devicon per recent file
            opts = opts,
            on_confirm = function(it)
                if it and it.path then
                    vim.cmd.edit(vim.fn.fnameescape(it.path))
                end
            end,
            -- the file is read ASYNC, like files: follows the cursor while scrolling
            preview_file_of = function(s)
                return s.path and s.path ~= "" and { path = s.path } or nil
            end,
        })
    end

    --- Fuzzy finder over HELP tags; confirming opens that help topic.
    ---@param opts? table
    function M.help_tags(opts)
        opts = opts or {}
        opts.key = opts.key or "help_tags"
        local items = {}
        for _, t in ipairs(vim.fn.getcompletion("", "help")) do
            items[#items + 1] = { text = t, tag = t }
        end
        pick_items({
            title = "Help",
            items = items,
            opts = opts,
            on_confirm = function(it)
                if it and it.tag then
                    pcall(vim.cmd.help, it.tag)
                end
            end,
        })
    end

    --- Fuzzy finder over GIT-tracked files (`git ls-files`); confirming edits the file, with a content preview.
    --- No-op outside a git work tree.
    ---@param opts? table
    function M.git_files(opts)
        opts = opts or {}
        opts.key = opts.key or "git_files"
        local inside = run_lines({ "git", "rev-parse", "--is-inside-work-tree" })[1]
        if inside ~= "true" then
            vim.notify("lvim-picker.git_files: not inside a git work tree", vim.log.levels.WARN)
            return
        end
        local spec = {
            title = "Git files",
            on_confirm = function(it)
                if it and it.path then
                    vim.cmd.edit(vim.fn.fnameescape(it.path))
                end
            end,
            -- ASYNC file preview, like files: follows the cursor while scrolling.
            preview_file_of = function(s)
                return s.path and s.path ~= "" and { path = s.path } or nil
            end,
        }
        stream_paths(spec, { "git", "ls-files" }) -- the rev-parse guard above is a quick check
        M.open(vim.tbl_extend("force", spec, opts or {}))
    end

    --- Fuzzy finder over installed COLORSCHEMES; confirming applies it (`:colorscheme`). Restores the current
    --- scheme on cancel so browsing is non-destructive.
    ---@param opts? table
    function M.colorschemes(opts)
        opts = opts or {}
        opts.key = opts.key or "colorschemes"
        local current = vim.g.colors_name
        local items = {}
        for _, c in ipairs(vim.fn.getcompletion("", "color")) do
            items[#items + 1] = { text = c, name = c }
        end
        pick_items({
            title = "Colorschemes",
            items = items,
            opts = opts,
            on_confirm = function(it)
                if it and it.name then
                    pcall(vim.cmd.colorscheme, it.name)
                end
            end,
            on_cancel = function()
                if current then
                    pcall(vim.cmd.colorscheme, current)
                end
            end,
        })
    end

    --- Fuzzy finder over EX commands; confirming drops `:<cmd> ` into the command line (so args can be added)
    --- rather than running it blindly.
    ---@param opts? table
    function M.commands(opts)
        opts = opts or {}
        opts.key = opts.key or "commands"
        local items = {}
        for _, c in ipairs(vim.fn.getcompletion("", "command")) do
            items[#items + 1] = { text = c, cmd = c }
        end
        pick_items({
            title = "Commands",
            items = items,
            opts = opts,
            on_confirm = function(it)
                if it and it.cmd then
                    vim.api.nvim_feedkeys(":" .. it.cmd .. " ", "n", false)
                end
            end,
        })
    end

    --- Jump to a `[file] lnum:col  text` location item: open its file (if any) and place the cursor. Shared by
    --- the marks / quickfix / jumplist finders, which all produce `{ path?, bufnr?, lnum, col, text }`.
    ---@param it table
    local function jump_to(it)
        if not it then
            return
        end
        if it.path and it.path ~= "" then
            vim.cmd.edit(vim.fn.fnameescape(it.path))
        elseif it.bufnr and api.nvim_buf_is_valid(it.bufnr) then
            api.nvim_set_current_buf(it.bufnr)
        end
        -- A quickfix entry without a line carries `lnum = 0`; `nvim_win_set_cursor` rejects row 0, so the jump
        -- landed nowhere. Row 1 is the honest landing for "this file, no line".
        pcall(api.nvim_win_set_cursor, 0, { math.max(1, it.lnum or 1), math.max(0, (it.col or 1) - 1) })
        vim.cmd("normal! zz")
    end
    M._jump_to = jump_to

    --- Preview a location item: the file/buffer content with a focus on the target line.
    ---@param it table
    ---@return string[] lines, string filetype, integer? focus
    local function preview_location(it)
        -- a buffer that holds the file is what to show (it may have unsaved changes), and it is in memory
        local b = it.bufnr
        if not (b and api.nvim_buf_is_valid(b)) and it.path and it.path ~= "" then
            b = vim.fn.bufnr(it.path)
        end
        if b and b > 0 and api.nvim_buf_is_loaded(b) then
            return api.nvim_buf_get_lines(b, 0, preview_span(it.lnum), false), vim.bo[b].filetype, it.lnum
        end
        if it.path and it.path ~= "" then
            local lines, ft = read_preview(it.path, preview_span(it.lnum))
            return lines, ft, it.lnum
        end
        return { "[no preview]" }, "", nil
    end

    --- The file a location item previews ASYNC (`preview_file_of`): its path, or its buffer's name when the buffer
    --- is not loaded (a quickfix entry, a jump), focused on its line. Nil when a LOADED buffer holds it — then the
    --- in-memory `preview_location` shows it, unsaved changes included.
    ---@param it table
    ---@return { path: string, lnum: integer?, col: integer? }?
    local function location_file_of(it)
        local b = it.bufnr
        if b and api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) then
            return nil
        end
        local path = (it.path and it.path ~= "" and it.path)
            or (b and api.nvim_buf_is_valid(b) and api.nvim_buf_get_name(b))
            or ""
        if path == "" or vim.fn.bufloaded(path) == 1 then
            return nil
        end
        return { path = path, lnum = it.lnum, col = it.col }
    end

    --- Fuzzy finder over MARKS (`:marks`); confirming jumps to the mark, with a preview at its line.
    ---@param opts? table
    function M.marks(opts)
        opts = opts or {}
        opts.key = opts.key or "marks"
        local items = {}
        for _, m in ipairs(vim.fn.getmarklist()) do -- global marks (A–Z, 0–9, …)
            local p = vim.fn.fnamemodify(m.file or "", ":~:.")
            items[#items + 1] = {
                text = ("%s  %s:%d"):format(m.mark, p, m.pos[2]),
                path = m.file,
                lnum = m.pos[2],
                col = m.pos[3],
            }
        end
        for _, m in ipairs(vim.fn.getmarklist(api.nvim_get_current_buf())) do -- buffer-local marks (a–z)
            items[#items + 1] = {
                text = ("%s  :%d"):format(m.mark, m.pos[2]),
                bufnr = api.nvim_get_current_buf(),
                lnum = m.pos[2],
                col = m.pos[3],
            }
        end
        pick_items({
            title = "Marks",
            items = items,
            opts = opts,
            on_confirm = jump_to,
            preview = preview_location, -- a location whose file is open in a buffer (shown from memory)
            preview_file_of = location_file_of, -- otherwise the file is read ASYNC (follows the cursor)
        })
    end

    --- Fuzzy finder over KEYMAPS (all modes); confirming feeds the mapping's lhs. The preview shows its rhs /
    --- description.
    ---@param opts? table
    function M.keymaps(opts)
        opts = opts or {}
        opts.key = opts.key or "keymaps"
        local items = {}
        for _, mode in ipairs({ "n", "i", "v", "x", "o", "c", "t" }) do
            for _, k in ipairs(vim.api.nvim_get_keymap(mode)) do
                items[#items + 1] = {
                    text = ("%s  %s  %s"):format(mode, k.lhs, (k.desc or k.rhs or ""):gsub("%s+", " ")),
                    mode = mode,
                    lhs = k.lhs,
                    detail = k.desc or k.rhs or "",
                }
            end
        end
        pick_items({
            title = "Keymaps",
            items = items,
            opts = opts,
            on_confirm = function(it)
                if it and it.lhs and it.mode == "n" then
                    api.nvim_feedkeys(api.nvim_replace_termcodes(it.lhs, true, false, true), "m", false)
                end
            end,
            preview = function(it)
                return { it.mode .. "  " .. it.lhs, "", it.detail }, ""
            end,
        })
    end

    --- Fuzzy finder over the QUICKFIX list; confirming jumps to the entry, with a preview at its line.
    ---@param opts? table
    function M.quickfix(opts)
        opts = opts or {}
        opts.key = opts.key or "quickfix"
        local items = {}
        for _, e in ipairs(vim.fn.getqflist()) do
            local p = e.bufnr ~= 0 and vim.fn.fnamemodify(api.nvim_buf_get_name(e.bufnr), ":~:.") or ""
            items[#items + 1] = {
                text = ("%s:%d  %s"):format(p, e.lnum, (e.text or ""):gsub("^%s+", "")),
                bufnr = e.bufnr ~= 0 and e.bufnr or nil,
                lnum = e.lnum,
                col = e.col,
            }
        end
        pick_items({
            title = "Quickfix",
            items = items,
            opts = opts,
            on_confirm = jump_to,
            preview = preview_location, -- a location whose file is open in a buffer (shown from memory)
            preview_file_of = location_file_of, -- otherwise the file is read ASYNC (follows the cursor)
        })
    end

    --- Fuzzy finder over the JUMPLIST (newest first); confirming jumps to the location, with a preview.
    ---@param opts? table
    function M.jumplist(opts)
        opts = opts or {}
        opts.key = opts.key or "jumplist"
        local jumps = vim.fn.getjumplist()[1] or {}
        local items = {}
        for i = #jumps, 1, -1 do -- newest first
            local j = jumps[i]
            if api.nvim_buf_is_valid(j.bufnr) then
                local p = vim.fn.fnamemodify(api.nvim_buf_get_name(j.bufnr), ":~:.")
                items[#items + 1] = {
                    text = ("%s:%d"):format(p ~= "" and p or "[No Name]", j.lnum),
                    bufnr = j.bufnr,
                    lnum = j.lnum,
                    col = (j.col or 0) + 1,
                }
            end
        end
        pick_items({
            title = "Jumplist",
            items = items,
            opts = opts,
            on_confirm = jump_to,
            preview = preview_location, -- a location whose file is open in a buffer (shown from memory)
            preview_file_of = location_file_of, -- otherwise the file is read ASYNC (follows the cursor)
        })
    end

    -- ── unified command ───────────────────────────────────────────────────────────
    -- `:LvimPicker <finder> [layout]` — one entry point for every finder above. The 2nd arg ("area"|"float"|
    -- "bottom") overrides `config.layout` for this call; bare = the configured default.
    local FINDERS = {
        "files",
        "grep",
        "grep_cword",
        "grep_cWORD",
        "grep_word",
        "grep_visual",
        "grep_curbuf",
        "buffers",
        "oldfiles",
        "git_files",
        "directories",
        "help_tags",
        "commands",
        "keymaps",
        "marks",
        "quickfix",
        "jumplist",
        "colorschemes",
    }
    local LAYOUTS = { "area", "float", "bottom" }
end
