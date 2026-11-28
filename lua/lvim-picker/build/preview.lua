--- A step of building a finder (the preview cache, the async requests and their pump, re-rendering, scheduling, moving).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.preview"

return function(ctx)
    setfenv(1, ctx)

    -- ── ASYNC FILE PREVIEW (opts.preview_file_of) ─────────────────────────────
    -- For finders whose preview is a FILE on disk (grep / files), the read runs OFF the main thread
    -- (source.read_preview_async) so the preview can FOLLOW THE CURSOR while you hold `j` — a synchronous
    -- readfile of a deep-line big file was the scroll freeze, and a settle-debounce only updated it on release.
    -- An LRU cache keyed by PATH makes re-visiting a file instant (scrolling within one grep file, or back over
    -- rows), and a SINGLE in-flight read that always re-targets the LATEST selection keeps the preview
    -- converging on the current row like fzf (never a pile of parallel reads, never a stale frame kept).
    preview_cache = {} ---@type table<string, { lines: string[], ft: string, picture: string? }>
    preview_lru = {} ---@type string[]  MRU-ordered paths (index 1 = most recently used)
    preview_inflight = false
    -- Every preview request takes a number; showing a preview from memory (the sync fallback below) records its
    -- number, and an async read requested BEFORE it is then cached but not shown — it must not replace the
    -- newer in-memory preview when it lands.
    preview_seq, preview_sync_seq = 0, 0
    ---@type { sel: integer, path: string, lnum: integer?, col: integer?, ft: string?, max: integer }?
    --- Look a file up in the LRU cache, promoting it to most-recent on a hit.
    ---@param path string
    ---@return { lines: string[], ft: string }?
    function cache_get(path)
        local e = preview_cache[path]
        if e then
            for i, p in ipairs(preview_lru) do
                if p == path then
                    table.remove(preview_lru, i)
                    break
                end
            end
            table.insert(preview_lru, 1, path)
        end
        return e
    end
    --- Insert a file's preview lines into the LRU cache, evicting the least-recently-used beyond the configured
    --- size so a long session never accumulates unbounded preview buffers.
    ---@param path string
    ---@param lines string[]
    ---@param ft string
    function cache_put(path, lines, ft, picture, facts)
        if not preview_cache[path] then
            table.insert(preview_lru, 1, path)
        end
        preview_cache[path] = { lines = lines, ft = ft, picture = picture, facts = facts }
        local cap = (config or {}).preview_cache or 32
        while #preview_lru > cap do
            local old = table.remove(preview_lru)
            preview_cache[old] = nil
        end
    end
    --- Show `entry`'s lines in the preview, focused on `want.lnum`. `state.preview_loc` records WHICH file is
    --- shown (the render's winbar reads it), so the panel body + title stay consistent even when a read lands a
    --- row or two behind a fast scroll (it converges as the pump reads the current selection next).
    ---@param want { path: string, lnum: integer?, col: integer?, ft: string? }
    ---@param entry { lines: string[], ft: string }
    function apply_async_preview(want, entry)
        state.preview_lines = entry.lines
        state.preview_facts = nil
        state.preview_picture = entry.picture
        state.preview_desc = entry.facts
        if entry.picture then
            -- the panels size themselves by the lines they show (the peek above the dock too): the facts are
            -- followed by blank lines the picture is drawn over, so there is room for it
            state.preview_facts = entry.lines
            local pad = {}
            for i = 1, (config or {}).picture_rows or 14 do
                pad[i] = ""
            end
            state.preview_lines = vim.list_extend(vim.list_slice(entry.lines, 1), pad)
        end
        state.preview_ft = want.ft or entry.ft
        state.preview_focus = want.lnum and math.max(1, math.min(want.lnum, #entry.lines)) or nil
        state.preview_col = want.col
        state.preview_loc = { path = want.path, lnum = want.lnum, col = want.col }
        refit() -- the preview height is capped at max_rows, so this relayouts only on the FIRST load, then holds
        preview_refresh()
        set_list_winbar()
    end
    --- Drain the pending preview request: a cache hit applies instantly; a miss starts ONE async read (marking
    --- `preview_inflight`) whose completion applies it, caches it, and pumps again — so the newest `preview_want`
    --- is always what gets read next.
    function pump_preview()
        if preview_inflight or not preview_want then
            return
        end
        local want = preview_want
        preview_want = nil
        local hit = cache_get(want.path)
        if hit then
            apply_async_preview(want, hit)
            return pump_preview() -- a newer selection may already be waiting
        end
        preview_inflight = true
        source.read_preview_async(want.path, want.max, function(lines, ft, picture, facts)
            preview_inflight = false
            if state.closed then
                return
            end
            cache_put(want.path, lines, ft, picture, facts)
            if want.seq > preview_sync_seq then
                apply_async_preview(want, { lines = lines, ft = ft, picture = picture, facts = facts })
            end
            pump_preview()
        end)
    end
    --- Request the async preview for the CURRENT selection (the file `opts.preview_file_of` maps it to). No
    --- file ⇒ the finder's in-memory `opts.preview` when it has one (e.g. a location whose file is open in a
    --- buffer — the buffer may hold unsaved changes, and it is in memory anyway), else clear the preview.
    function request_preview()
        local it = state.filtered[state.sel]
        local loc = (it and it._src and opts.preview_file_of and opts.preview_file_of(it._src)) or nil
        preview_seq = preview_seq + 1
        if not (loc and loc.path and loc.path ~= "") then
            preview_want = nil
            preview_sync_seq = preview_seq
            if it and opts.preview then
                local lines, ft, focus = opts.preview(it._src)
                state.preview_lines = (type(lines) == "table" and lines) or (lines and { tostring(lines) }) or {}
                state.preview_picture = nil
                state.preview_ft, state.preview_focus = ft, focus
            else
                state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
                state.preview_picture = nil
            end
            state.preview_loc, state.preview_col = nil, nil
            refit()
            preview_refresh()
            return
        end
        -- Read up to `lnum + context` lines (so the match is on-screen), hard-capped at `preview_max_lines` so a
        -- match DEEP in a huge file never materialises tens of thousands of lines on the main thread.
        local span = math.max(500, (loc.lnum or 0) + 200)
        local maxl = math.min(span, (config or {}).preview_max_lines or 2000)
        preview_want =
            { sel = state.sel, seq = preview_seq, path = loc.path, lnum = loc.lnum, col = loc.col, ft = loc.ft, max = maxl }
        pump_preview()
    end

    --- Re-render after a result / selection change. `light` (the frequent re-renders WHILE a tree streams in,
    --- and every scroll MOVE) does the LIST + chrome only — O(viewport), no preview work, no relayout churn —
    --- so it is always a couple ms. A FULL re-render (`light` nil) also drives the preview: the async file read
    --- (opts.preview_file_of) or the synchronous in-memory fetch (opts.preview). The preview height is capped at
    --- max_rows, so once it is loaded `refit()` is a no-op and scrolling never relayouts.
    ---@param light boolean?
    function rerender(light)
        if not light then
            fetch_preview()
        end
        refit()
        if state.list_pan and state.list_pan.refresh then
            state.list_pan.refresh()
        end
        if not light then
            if opts.preview_file_of then
                request_preview() -- async: fills state.preview_lines + refreshes the panel on completion
            else
                preview_refresh()
            end
        end
        set_list_winbar() -- the result count in the winbar follows the list
        set_list_cursor() -- scroll the window to keep the selection in view
        refresh_count() -- re-apply the live match count to the chassis border / overlay counter
    end
    -- SYNC preview (the in-memory finders — buffers / lsp / diagnostics / help / keymaps / the editable file
    -- preview). It FOLLOWS THE CURSOR at once on every move, like the async file preview: a trailing debounce
    -- only updated it when a held key was released (the repeat is faster than the settle). `preview_debounce_ms`
    -- > 0 caps how OFTEN it updates while scrolling (the first move and the final position always update).
    -- FILE / directory finders do not come here — their preview is async (request_preview).
    preview_gen, preview_last = 0, 0
    function show_sync_preview()
        preview_last = vim.uv.hrtime() / 1e6
        fetch_preview()
        refit()
        preview_refresh()
        set_list_winbar()
    end
    function schedule_preview()
        if opts.preview_file_of or not (opts.preview or opts.preview_file) then
            return
        end
        preview_gen = preview_gen + 1
        local mygen = preview_gen
        local wait = ((config or {}).preview_debounce_ms or 0) - (vim.uv.hrtime() / 1e6 - preview_last)
        if wait <= 0 then
            return show_sync_preview()
        end
        vim.defer_fn(function()
            if mygen == preview_gen and not state.closed then
                show_sync_preview()
            end
        end, math.ceil(wait))
    end
    move = function(d)
        if #state.filtered == 0 then
            return
        end
        state.sel = math.max(1, math.min(#state.filtered, state.sel + d))
        rerender(true) -- LIGHT: move the selection stripe + list cursor + count now (a couple ms, never blocks)
        if opts.hints and state.refresh_footer then
            state.refresh_footer() -- the buttons depend on the row
        end
        if opts.preview_file_of then
            request_preview() -- async file preview — follows the cursor while holding `j` (fzf-like)
        else
            schedule_preview() -- the sync preview of the in-memory finders, at once
        end
    end
end
