--- A step of building a finder (apply a result, the blob rows, `refilter` (the heart), the grep controller, the debounce, the filter buttons).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.filter"

return function(ctx)
    setfenv(1, ctx)
    --- Apply a new result list (from the fuzzy filter or a live source) to the UI. `light` forwards to
    --- `rerender` — set for the high-frequency refreshes while a tree is still streaming (count + rows only).
    --- POSITION: a QUERY CHANGE (`state.reset_pos`, set in `refilter`) jumps back to the top (sel=1, view_top=1)
    --- — a new search starts at the best match. A same-query APPEND (a streaming refresh / a progressive grep
    --- batch, where results only grow at the tail) PRESERVES the selection + viewport, clamped to the new
    --- bounds — so browsing while results pour in stays put like fzf, instead of being yanked back to the top.
    ---@param list table[]
    ---@param light boolean?
    function apply(list, light)
        if state.closed then
            return
        end
        state.filtered = list
        -- Reset the scroll to the top only when the QUERY actually CHANGED since the last applied list — a new
        -- search starts at the best match. Progressive/streaming refreshes of the SAME query (a live-grep batch,
        -- a files stream tick — possibly MANY per one `refilter`) keep the selection + viewport, clamped to the
        -- grown list, so browsing while results pour in stays put like fzf.
        if state.query ~= state.rendered_query then
            state.sel, state.view_top = 1, 1
        else
            local n = math.max(1, #list)
            state.sel = math.max(1, math.min(state.sel or 1, n))
            state.view_top = math.max(1, math.min(state.view_top or 1, n))
        end
        state.rendered_query = state.query
        rerender(light)
        if opts.hints and state.refresh_footer then
            state.refresh_footer()
        end
    end
    --- (blob stream) Turn `fuzzy.blob_filter` results (`{ idx, text }`, `idx` = the 1-based NATIVE candidate
    --- index) into grid rows. The `_src` item is DERIVED from the text via `opts.blob_item` and CACHED by
    --- native index in `state.src_cache`, so the SAME candidate always yields the SAME `_src` table — a stable
    --- identity across refilters that multi-select marks (keyed by `_src`) rely on. Text is carried on the row;
    --- the icon (from `_src.path`) and the match spans are resolved lazily in the render, for visible rows only.
    ---@param list { idx: integer, text: string }[]
    ---@return table[]
    function blob_rows(list)
        local cache = state.src_cache
        local out = {}
        for i, r in ipairs(list) do
            local src = cache[r.idx]
            if not src then
                src = opts.blob_item(r.text)
                cache[r.idx] = src
            end
            out[i] = { text = r.text, _src = src, idx = r.idx }
        end
        return out
    end
    --- A grep FILTER over `blob`, reading the part `state.grep_scope` names (see lvim-picker.scope): the
    --- engine searches "line" / "path" in that part of each row and "file" in the row's file (every term
    --- exact). Same callback shape as blob_filter.
    ---@param blob LvimFuzzyBlob
    ---@param q string
    ---@param cb fun(list: { idx: integer, text: string }[], total: integer)
    function scoped_filter(blob, q, cb)
        local sc = state.grep_scope or (config or {}).grep_scope or "line"
        fuzzy.blob_filter(blob, q, cb, { scope = sc })
    end
    -- A generation guard so a slow async source/filter callback for an OLD query can't overwrite a newer one.
    refilter_gen = 0
    --- Re-run the filter (static list) or live source for query `q`, then push the ranked results to the UI.
    --- `light` is set by the stream feed for the many-per-second refreshes while a tree loads → a cheap re-render
    --- (count + rows, no preview / relayout); user-driven refilters leave it nil for a full re-render.
    ---@param q string?
    ---@param light boolean?
    function refilter(q, light)
        state.query = q or ""
        refilter_gen = refilter_gen + 1
        local mygen = refilter_gen
        local function guarded(list)
            if mygen == refilter_gen then
                -- A live source returns raw items (no fuzzy step), so the query is highlighted in each result
                -- text ourselves — but LAZILY, in the list render, for the VISIBLE rows only (an eager pass
                -- here was O(all results) per keystroke). `live_query` records which query produced THIS
                -- result set (gen-guarded), so the render decorates against the right needle.
                state.live_query = state.query
                -- `source_raw`: the source already delivers grid items (a live grep appends into ONE growing
                -- list — see the progressive delivery), so DON'T re-normalise the whole (up to grep_max) list on
                -- every progressive batch — that O(n) re-wrap per delivery was the live-grep stutter. Otherwise
                -- normalise the raw items once here.
                apply(opts.source_raw and list or normalize(list, opts.format), light)
            end
        end
        if opts.grep then
            -- GREP CONTROLLER (Variant B). The blob holds ALL rg matches; the MODE decides what the typed query
            -- does. GREP mode: the query DRIVES rg (re-grep into a fresh blob on a real change), and the blob is
            -- rendered in SOURCE ORDER (blob_filter "") — every match browsable, the counter the true rg total.
            -- FILTER mode (Ctrl-g froze rg): the query FUZZY-FILTERS the loaded blob (blob_filter `query`), the
            -- counter `matched/loaded`. `live_query` is the typed text either way, so the render lights up the
            -- needle (grep) / the fuzzy term (filter) in the VISIBLE rows only.
            if state.grep_mode == "grep" then
                local grep_q = state.query
                if #grep_q < (opts.grep.min_chars or 2) then
                    grep_stop() -- too short to grep a huge tree → clear the list + counter, wait for more chars
                    state.grep_query, state.grep_total = grep_q, 0
                    apply({}, light)
                    return
                end
                if grep_q ~= state.grep_query then
                    -- A NEW query → (re)grep into a FRESH (empty) blob; its paced stream ticks call `refilter`
                    -- again (same query) as matches arrive, and THAT is what renders. Do NOT render the empty
                    -- fresh blob here — keep the CURRENT rows on screen until the new results stream in, so
                    -- re-typing a live grep never flashes an empty list between keystrokes (fzf keeps its rows the
                    -- same way while it reloads). Without this, every keystroke cleared the list → the flicker.
                    grep_start(grep_q)
                    return
                end
                -- Same query = a stream tick (or a manual refresh): render the (growing) blob in source order.
                state.live_query = grep_q
                if state.blob then
                    fuzzy.blob_filter(state.blob, "", function(list, total)
                        if mygen == refilter_gen then
                            -- Do NOT blank the list while a fresh (re)grep is still streaming its first matches:
                            -- an EMPTY pass with an empty pool and rg not yet done = "results are coming", not
                            -- "no matches". Keep the CURRENT rows until real matches arrive (or rg finishes
                            -- empty). This is what makes a Ctrl-g FILTER→GREP return smooth — no empty flash.
                            if #list == 0 and (state.pool_n or 0) == 0 and not state.grep_done then
                                return
                            end
                            state.match_total = total
                            apply(blob_rows(list), light)
                        end
                    end)
                end
                return
            end
            -- FILTER mode: fuzzy-filter the FROZEN blob (rg not re-run), reading the part the SCOPE names.
            state.live_query = state.query
            if state.blob then
                scoped_filter(state.blob, state.query, function(list, total)
                    if mygen == refilter_gen then
                        state.match_total = total
                        apply(blob_rows(list), light)
                    end
                end)
            end
            return
        end
        if state.blob then
            -- BLOB STREAM (GAP-5): the candidate POOL lives entirely in the native matcher — there is no Lua
            -- `items` array to fuzzy over. Rank the native pool and materialise ONLY the ranked top-K rows
            -- (their text pulled from the blob by index). `live_query` records which query produced this set so
            -- the render lights up the query chars for the VISIBLE rows only (like the live-source path).
            state.live_query = state.query
            fuzzy.blob_filter(state.blob, state.query, function(list, total)
                if mygen == refilter_gen then
                    state.match_total = total -- the TRUE matched count (before max_results) → the live counter
                    apply(blob_rows(list), light)
                end
            end)
        elseif opts.source then
            -- LIVE source: the query drives the results (e.g. ripgrep) — no fuzzy over a static list.
            opts.source(state.query, guarded)
        else
            -- STATIC list: narrow by the active filter bars FIRST, then fuzzy-filter the survivors.
            local pool = items
            if filters then
                -- The narrowed pool depends ONLY on the item set + which filter buttons are active, NEVER on the
                -- query. Rebuilding it (a NEW table) on every keystroke invalidated the reference-keyed candidate
                -- caches (`_texts_cache` here + fuzzy's file cache) → a full fzf temp-file rewrite per keypress.
                -- Cache it keyed by the item set (ref + length, so a refresh/stream growth rebuilds) and the
                -- active-button ids, so a pure query change REUSES the same pool table (caches stay warm).
                local parts = {}
                for _, g in ipairs(filters) do
                    parts[#parts + 1] = tostring(g.active)
                end
                local key = table.concat(parts, "|")
                if
                    state.filter_pool
                    and state.filter_pool_src == items
                    and state.filter_pool_len == #items
                    and state.filter_pool_key == key
                then
                    pool = state.filter_pool
                else
                    pool = {}
                    for _, it in ipairs(items) do
                        if passes_filters(it._src) then
                            pool[#pool + 1] = it
                        end
                    end
                    state.filter_pool, state.filter_pool_src, state.filter_pool_len, state.filter_pool_key =
                        pool, items, #items, key
                end
            end
            filter(pool, state.query, function(list)
                if mygen == refilter_gen then
                    apply(list, light)
                end
            end)
        end
    end
    -- ── GREP controller (Variant B: hold ALL rg matches in the native blob) ──────────────────────────────────
    -- Only assigned for a grep finder (opts.grep). The blob is RE-CREATED per grep query (a new needle = a new
    -- candidate set, so native indices restart at 1 and the src-cache must be cleared with it). rg streams into
    -- the blob paced + bounded: up to `config.grep_max` candidates are STORED and browsable; a broader-than-that
    -- query is still fully COUNTED (the tally in source.spawn_grep_blob) so the counter shows the real total
    -- without ever buffering past the ceiling. Killed on close / on a re-grep / on the Ctrl-g freeze.
    if opts.grep then
        ---@type fun()?  the in-flight rg's cancel (kills rg + drops its queued backlog)
        local grep_cancel
        grep_stop = function()
            if grep_cancel then
                pcall(grep_cancel)
                grep_cancel = nil
            end
        end
        --- (Re)start ripgrep for `query`: free the old blob, open a fresh one, and stream rg into it. A grep
        --- GENERATION guards the async feed/done/tick callbacks so a superseded run (a newer query, or close)
        --- can never touch the freed blob.
        ---@param query string
        grep_start = function(query)
            grep_stop()
            if state.blob then
                fuzzy.blob_free(state.blob) -- a new query = a new candidate set → reclaim the old pool eagerly
            end
            state.blob = fuzzy.blob_new()
            state.src_cache = {} -- native index → derived `_src` (indices restart at 1 for the fresh blob)
            state.pool_n, state.grep_total, state.grep_query = 0, 0, query
            state.grep_done = false -- a fresh (re)grep is streaming → don't blank the list on an empty early pass
            state.grep_gen = (state.grep_gen or 0) + 1
            local mygen = state.grep_gen
            local myblob = state.blob
            if not myblob then
                return -- blob_new failed (should not happen — opts.grep is only set when fuzzy.has_blob())
            end
            local counter = { total = 0 } -- rg's read callback tallies the TRUE match count in here (incl. overflow)
            local tick_scheduled = false
            --- Push the growing pool + the live tally to the UI (a LIGHT refilter — count + rows only — while
            --- streaming; a FULL final pass fetches the preview + fits the surface).
            ---@param final boolean
            local function tick(final)
                if state.closed or mygen ~= state.grep_gen then
                    return -- superseded (a newer grep / close) → don't touch the (freed) blob
                end
                state.pool_n = fuzzy.blob_count(myblob)
                state.grep_total = counter.total
                refilter(state.query, not final)
            end
            local function feed_bytes(data)
                if state.closed or mygen ~= state.grep_gen or type(data) ~= "string" or #data == 0 then
                    return
                end
                fuzzy.blob_append(myblob, data)
                if not tick_scheduled then
                    tick_scheduled = true
                    vim.defer_fn(function()
                        tick_scheduled = false
                        tick(false)
                    end, (config or {}).stream_refresh_ms or 50)
                end
            end
            local function done()
                if state.closed or mygen ~= state.grep_gen then
                    return
                end
                state.grep_done = true -- rg finished: an empty result is now REAL ("no matches"), so render it
                fuzzy.blob_flush(myblob) -- a final line without a trailing newline becomes a candidate
                tick(true)
            end
            local argv = source.grep_cmd(query, opts.grep.regex, opts.grep.file)
            grep_cancel = source.spawn_grep_blob(argv, feed_bytes, done, (config or {}).grep_max or 500000, counter)
        end
        --- Ctrl-g: flip GREP mode ⇄ FILTER mode (like fzf-lua's `<ctrl-g>`) — LIVE grep only. GREP→FILTER
        --- FREEZES rg at the current result set (the typed query then fuzzy-filters the loaded blob); FILTER→GREP
        --- resumes the live search (a re-grep is forced for the current query).
        grep_toggle = function()
            if not opts.grep.live then
                return -- a fixed-query grep is always in FILTER mode; there is no live search to toggle
            end
            --- Read / replace the query input line (so the mode swap can CLEAR it for a fresh filter and RESTORE
            --- the grep query when returning). Placing the cursor at the end keeps typing natural.
            local function input_text()
                return (state.input_buf and api.nvim_buf_is_valid(state.input_buf))
                        and (api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or "")
                    or ""
            end
            local function set_input(text)
                if state.input_buf and api.nvim_buf_is_valid(state.input_buf) then
                    api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { text })
                    local w = vim.fn.bufwinid(state.input_buf)
                    if w ~= -1 then
                        pcall(api.nvim_win_set_cursor, w, { 1, #text })
                    end
                end
            end
            if state.grep_mode == "grep" then
                state.grep_mode = "filter"
                grep_stop() -- freeze: stop driving rg; keep the blob as-is
                state.grep_saved_input = input_text() -- remember the grep query…
                set_input("") -- …and CLEAR the input for a fresh fuzzy filter over the loaded results
                state.query = ""
            else
                state.grep_mode = "grep"
                state.grep_query = nil -- force a re-grep of the restored query on the next refilter
                local restored = state.grep_saved_input or ""
                set_input(restored) -- RESTORE the grep query
                state.query = restored
                state.grep_saved_input = nil
            end
            if state.update_mode then
                state.update_mode() -- reflect the mode in the title indicator + the search-bar badge
            end
            refilter(state.query)
        end
        --- Ctrl-s: cycle what the FILTER reads in each result — the line's text → the path → the whole file
        --- (lvim-picker.scope). Applies at once in FILTER mode; in GREP mode it is remembered for the next filter.
        scope_toggle = function()
            state.grep_scope = scope.next(state.grep_scope or (config or {}).grep_scope or "line")
            if state.update_mode then
                state.update_mode()
            end
            if state.grep_mode == "filter" then
                refilter(state.query)
            end
        end
        -- `grep_stop` is called from on_close too; expose it via state so the teardown reaches it.
        state.grep_stop = grep_stop
    end

    -- Query-driven refilter is DEBOUNCED: at huge pool sizes one match is ~100–165 ms, and running it
    -- synchronously on EVERY keystroke stacks up and freezes the UI while typing fast. Coalesce rapid
    -- keystrokes so the match runs once the user pauses (`config.debounce_ms`; 0 = off, for small/instant
    -- sets). `state.query` is recorded immediately so the prompt / gen stay in sync before the match runs.
    -- A generation guard lets superseded defer_fn timers fire as cheap no-ops (auto-closed) — no leak.
    debounce_gen = 0
    function refilter_debounced(q)
        state.query = q or ""
        local ms = (config or {}).debounce_ms or 50
        if ms <= 0 then
            refilter(state.query)
            return
        end
        debounce_gen = debounce_gen + 1
        local mygen = debounce_gen
        vim.defer_fn(function()
            if mygen == debounce_gen and not state.closed then
                refilter(state.query)
            end
        end, ms)
    end
    -- Activate filter button `id` in group `gi`: re-narrow + re-render, then re-sync the button specs' live
    -- `active` flags (so the header re-paints the NEW active button, not the build-time one) + counts.
    set_filter = function(gi, id)
        if not (filters and filters[gi]) then
            return
        end
        filters[gi].active = id
        if state.sync_filter then
            state.sync_filter()
        end
        refilter(state.query)
        if state.st and state.st.refresh_chrome then
            state.st.refresh_chrome()
        end
    end
end
