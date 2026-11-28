--- A step of building a finder (after the surface is open: the dock bookkeeping, on_open, refresh events, the file counter, grep, the streams).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.start"

return function(ctx)
    setfenv(1, ctx)

    source.set_active(active_entry) -- track THIS finder as the open one (its surface is now live)
    if sk then
        live[sk] = state -- expose the live surface to the dock consumer (buffers / focus / is_current / re-show)
    end

    -- initial: show all, select the first, preview it (fetch + fit + render)
    rerender()

    -- A handle for the caller to drive this open finder from outside (e.g. keep its selection in step with a
    -- list navigated elsewhere): `select(pred)` moves the selection to the first visible row whose source item
    -- satisfies `pred`; `is_open()` tells whether the finder still shows.
    if opts.on_open then
        pcall(opts.on_open, {
            select = function(pred)
                if state.closed then
                    return false
                end
                for i, it in ipairs(state.filtered) do
                    if pred(it._src) then
                        state.sel = i
                        move(0)
                        return true
                    end
                end
                return false
            end,
            is_open = function()
                return not state.closed
            end,
            -- REPLACE the rows in place (a new list behind the same finder) — no close / re-open, so nothing
            -- flickers. `patch` updates options read while rendering (e.g. `match_pattern`, `regex`). The
            -- marks are dropped (they belong to the old rows) and the selection goes to the top.
            set_items = function(fresh, patch)
                if state.closed or type(fresh) ~= "table" then
                    return
                end
                for k, v in pairs(patch or {}) do
                    opts[k] = v
                end
                if patch and patch.regex ~= nil then
                    regex_grep = patch.regex == true
                end
                state.marked = {}
                items = normalize(fresh, opts.format)
                state.rendered_query = nil -- a new list starts at its top
                refilter(state.query)
            end,
            -- the LIST window (nil while it has none) — for a consumer that lays its own float over the rows
            list_win = function()
                local p = state.list_pan
                if not state.closed and p and p.win and api.nvim_win_is_valid(p.win) then
                    return p.win
                end
            end,
            -- the visible rows' source items, in display order, and the selected row's index into them
            visible = function()
                local out = {}
                for i, it in ipairs(state.closed and {} or state.filtered) do
                    out[i] = it._src
                end
                return out, state.sel
            end,
            -- the cursor on the LIST, in normal mode (out of the query): list keys work at once
            focus_list = function()
                if not state.closed then
                    focus_list()
                end
            end,
        })
    end

    if opts.start_in_list then
        -- the surface enters the query on open (scheduled): leave it once that has happened
        vim.defer_fn(function()
            if not state.closed then
                focus_list()
            end
        end, 40)
    end

    -- LIVE refresh: re-fetch the static items on `opts.refresh_events` (e.g. "DiagnosticChanged") via
    -- `opts.refresh()`, then re-narrow (filters) + re-fuzzy + re-render. Coalesce a burst into ONE reload.
    -- `opts.close_on_empty` dismisses the finder once nothing is left (e.g. all diagnostics fixed). Torn
    -- down in on_close.
    if opts.refresh and opts.refresh_events and not opts.source then
        state.live_augroup =
            api.nvim_create_augroup("LvimPickerLive_" .. tostring(state.st and state.st.container_buf or 0), {})
        local scheduled = false
        api.nvim_create_autocmd(opts.refresh_events, {
            group = state.live_augroup,
            callback = function(ev)
                -- ignore the echo from our OWN preview buffers (mirroring would loop)
                if state.preview_pan and state.preview_pan.buf == ev.buf then
                    return
                end
                if scheduled or state.closed then
                    return
                end
                scheduled = true
                vim.schedule(function()
                    scheduled = false
                    if state.closed then
                        return
                    end
                    -- Do NOT rebuild while a multi-select is in progress: a refresh produces NEW item tables, so
                    -- the marks (keyed by source value) would vanish and the cursor jump to the top mid-marking
                    -- (and the stale-list re-render could even crash). Hold the live update until the marks clear.
                    if #state.marked > 0 then
                        return
                    end
                    local fresh = opts.refresh()
                    if type(fresh) ~= "table" then
                        return
                    end
                    if #fresh == 0 and opts.close_on_empty and state.st then
                        state.st.close()
                        return
                    end
                    items = normalize(fresh, opts.format)
                    refilter(state.query)
                end)
            end,
        })
    end

    -- (grep) BACKGROUND FILE COUNT: grep's counter is `matches / total files in the tree`, so — alongside rg —
    -- stream the SAME file list the `files` finder uses (`file_list_cmd`) purely to COUNT it (the bytes are
    -- discarded, only newlines are tallied; paced + 0%-blocked exactly like the files load). The count climbs to
    -- the tree's file total, which `count_fn` uses as the counter's denominator. Killed in on_close.
    if opts.count_files then
        state.file_total = 0
        local pending_c = false
        state.count_cancel = spawn_stream_raw(file_list_cmd(), function(data)
            local _, n = data:gsub("\n", "\n")
            state.file_total = state.file_total + n
            if not pending_c then -- coalesce the counter refresh (the number climbs smoothly, not per chunk)
                pending_c = true
                vim.defer_fn(function()
                    pending_c = false
                    if not state.closed then
                        refresh_count()
                    end
                end, (config or {}).stream_refresh_ms or 50)
            end
        end, function()
            if not state.closed then
                refresh_count()
            end
        end)
    end

    -- GREP CONTROLLER (Variant B): kick off the search. A LIVE grep waits for the user to type (>= min_chars) —
    -- refilter's on_change drives the first rg. A FIXED-query grep (cword / cWORD / selection / prompt / curbuf)
    -- runs rg ONCE now, into the blob, and starts in FILTER mode so the typed query fuzzy-narrows the results.
    -- Requires ABI ≥ 5 (M.grep only sets opts.grep on the blob path); the fallback uses opts.source / opts.stream.
    if opts.grep then
        state.grep_mode = opts.grep.live and "grep" or "filter"
        if not opts.grep.live then
            grep_start(opts.grep.query or "")
        end
        return
    end

    -- ASYNC BLOB STREAM (GAP-5): `opts.blob_stream(feed_bytes, done)` produces the listing incrementally, and
    -- `feed_bytes(raw)` hands the producer's RAW stdout bytes STRAIGHT to the native matcher (which splits on
    -- `\n` and stores each line as a candidate) — ZERO Lua per-row string/table work, so a ~2M-file tree loads
    -- without building (and interning + GC-ing) a multi-million-string Lua pool. The candidate pool IS the
    -- native context; `refilter` ranks it and materialises only the top-K rows. `opts.blob_item(text)` derives
    -- an item's `_src` from its path (files/dirs/git: `{ path = text }`). The producer is killed + the context
    -- freed in on_close. Needs the native library (`fuzzy.has_blob()`); a finder falls back to `opts.stream` otherwise.
    -- Mutually exclusive with the per-query live `source` and the per-string `stream`.
    if opts.blob_stream and not opts.source then
        state.blob = fuzzy.blob_new()
    end
    if state.blob then
        state.src_cache = {} -- native index → derived `_src` item (stable identity for marks; see blob_rows)
        state.pool_n = 0
        local tick_scheduled = false
        --- Ingest one raw stdout chunk into the native pool (no Lua per-row work), then schedule ONE coalesced
        --- light refilter so the count + visible rows track the growing pool.
        ---@param data string
        local function feed_bytes(data)
            if state.closed or type(data) ~= "string" or #data == 0 then
                return
            end
            state.pool_n = fuzzy.blob_append(state.blob, data)
            if not tick_scheduled then
                tick_scheduled = true
                vim.defer_fn(function()
                    tick_scheduled = false
                    if not state.closed then
                        refilter(state.query, true) -- LIGHT: count + rows only (see rerender)
                    end
                end, (config or {}).stream_refresh_ms or 200)
            end
        end
        local function done()
            if state.closed then
                return
            end
            fuzzy.blob_flush(state.blob) -- a final line without a trailing newline becomes a candidate
            state.pool_n = fuzzy.blob_count(state.blob)
            refilter(state.query) -- FULL final pass: fetch the preview + fit the surface to the result
        end
        state.stream_cancel = opts.blob_stream(feed_bytes, done)
        return
    end

    -- ASYNC STREAM source: `opts.stream(feed, done)` produces candidates incrementally (a spawned `fd` / `rg`
    -- streamed in via `spawn_stream`), so the open NEVER blocks on a huge tree. `feed(raw)` appends the batch
    -- to the candidate pool and schedules ONE coalesced refilter (fuzzy is already async); `done()` does a
    -- final pass. The producer is killed in on_close. Mutually exclusive with the per-query live `source`. This
    -- is the FALLBACK path (an older .so without blob ingestion) — the blob path above supersedes it when ABI≥5.
    if opts.stream and not opts.source then
        local tick_scheduled = false
        local function feed(raw)
            if state.closed or type(raw) ~= "table" or #raw == 0 then
                return
            end
            local n = #items -- one length probe per batch, not one per row (this loop runs ~2M times on ~/)
            for _, it in ipairs(normalize(raw, opts.format)) do
                n = n + 1
                items[n] = it
            end
            if not tick_scheduled then
                tick_scheduled = true
                -- Coalesce a burst of stream chunks into one re-render. Long enough (config.stream_refresh_ms)
                -- that the async query match SETTLES between refreshes instead of being superseded every time
                -- (which would show nothing until the stream ended), and it thins the per-refresh ensure_ctx
                -- append while files pour in.
                vim.defer_fn(function()
                    tick_scheduled = false
                    if not state.closed then
                        refilter(state.query, true) -- LIGHT: count + rows only, no preview / relayout (see rerender)
                    end
                end, (config or {}).stream_refresh_ms or 200)
            end
        end
        local function done()
            if not state.closed then
                refilter(state.query) -- FULL final pass: now fetch the preview + fit the surface to the result
            end
        end
        state.stream_cancel = opts.stream(feed, done)
    end
end
