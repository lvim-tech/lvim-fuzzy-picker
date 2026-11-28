--- A step of building a finder (the list provider and the preview provider (what the surface asks for), the numbers, the cursor, fetching and fitting the preview).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.providers"

return function(ctx)
    setfenv(1, ctx)

    list_provider = {
        cursorline = false,
        -- the SELECTION is the Sel stripe (not a window cursorline), so hide the hardware cursor while the
        -- list is focused (NORMAL mode) — the bright row, not a block cursor, shows where you are.
        hide_cursor = true,
        -- the scrollbar's view of the list: its matches over the rows that show (the buffer holds only the viewport)
        scroll = function(pan)
            local winbar = pan.win and api.nvim_win_is_valid(pan.win) and (vim.wo[pan.win].winbar or "") ~= ""
            return { off = (state.view_top or 1) - 1, total = #state.filtered, rows = view_height(), top = winbar and 1 or 0, bottom = 0 }
        end,
        -- the focused row's SOURCE value — so the surface's default `open`/split/vsplit/tab can act on it
        -- without the consumer wiring anything (items already carry `path`/`lnum`/`col`).
        selection = function()
            local it = state.filtered[state.sel]
            return it and it._src or nil
        end,
        size = function()
            return math.max(30, math.floor(vim.o.columns * 0.32)), list_panel_h() -- the LIST's own height
        end,
        render = function()
            local lines, hls = {}, {}
            -- VIEWPORT: build only the visible slice (+ margin) — O(viewport) regardless of #filtered.
            local vh = view_height()
            local top = clamp_view(vh)
            local last = math.min(#state.filtered, top + vh + VIEW_MARGIN - 1)
            for li = top, last do
                local it = state.filtered[li]
                local i = li - top + 1 -- 1-based BUFFER line of logical entry `li`
                local marked = is_marked(it._src)
                -- LIVE-source rows (e.g. live grep): the query-highlight decoration is computed HERE, for the
                -- visible rows only — never over the whole result set (rg did the real matching; this only
                -- lights the query chars up). Result items are fresh tables per delivery, so the memo
                -- (`_match_done`) can never carry a stale query's spans.
                -- LIVE-source AND blob-stream rows carry no precomputed match spans (an eager pass over the
                -- whole result set was O(all results) per keystroke); light up the query chars HERE, for the
                -- visible rows only. Result items are fresh tables per delivery, so `_match_done` never carries
                -- a stale query's spans.
                if (opts.source or state.blob) and not it._match_done then
                    local q = state.live_query
                    -- A LOCATION ROW carries the answer already: ripgrep matched the line and said
                    -- where. Mark that, in the TEXT after the locator, and leave the path alone.
                    local src = it._src
                    if type(src) == "table" and src.col and src.lnum and row_uses_rg_pattern(state, opts, q) then
                        local pattern = match_pattern() -- the rg pattern (grep mode / nothing typed in filter mode)
                        local locator = (it.text or ""):match("^[^:]*:%d+:%d+:")
                            or (it.text or ""):match("^[^:]*:%d+:%s*")
                        if locator and pattern and pattern ~= "" then
                            local body = (it.text or ""):sub(#locator + 1)
                            local found = preview_matches({ body }, pattern, regex_grep)
                            local bytes = {}
                            for _, r in ipairs(found) do
                                bytes[#bytes + 1] = { c0 = #locator + r.c0, c1 = #locator + r.c1 }
                            end
                            it.match_bytes = #bytes > 0 and bytes or nil
                        end
                    end
                    if it.match_bytes == nil and q and q ~= "" and opts.grep and state.grep_mode == "filter" then
                        -- a grep FILTER marks the query in the part its SCOPE reads
                        local sc = state.grep_scope or (config or {}).grep_scope or "line"
                        local path, loc, body = scope.split(it.text or "")
                        if path and sc == "line" then
                            local m = fuzzy.match_terms(q, body)
                            if m then
                                local off = vim.fn.strchars(loc)
                                for k, ci in ipairs(m) do
                                    m[k] = ci + off
                                end
                            end
                            it.match = m
                        elseif path and sc == "path" then
                            it.match = fuzzy.match_terms(q, path)
                        elseif path and sc == "file" then
                            local bytes = {}
                            for _, t in ipairs(scope.terms(q)) do
                                for _, r in ipairs(preview_matches({ body }, t.text, false)) do
                                    bytes[#bytes + 1] = { c0 = #loc + r.c0, c1 = #loc + r.c1 }
                                end
                            end
                            it.match_bytes = #bytes > 0 and bytes or nil
                        end
                    end
                    if it.match_bytes == nil and it.match == nil and q and q ~= "" then
                        -- through the shared term matcher, so a multi-term query lights up EVERY term (the
                        -- filter and the highlight must agree on what matched). `match_display` is name-focused
                        -- when `filename_match` is on and this row's NAME matches (so the highlight agrees with
                        -- the filename-bias ranking); else it is the whole-path term positions.
                        it.match = fuzzy.match_display(q, it.text)
                    end
                    it._match_done = true
                end
                -- Auto ft devicon for items that name a file (file lists / lsp locations / quickfix / …),
                -- resolved HERE — for the visible rows only — because the lookup is uncached ~3 µs/call and
                -- `normalize` runs over the whole candidate set (~2M rows on a huge tree). Memoised per grid
                -- item (`_icon_gen`); grid items are fresh tables per filter delivery, so a re-resolve is at
                -- most one viewport per keystroke. An EXPLICIT item icon (e.g. a diagnostic severity glyph)
                -- arrives non-nil from normalize and is left untouched.
                -- Per mode too (`_icon_gen`): a live lvim-icons mode switch resolves the auto icon again.
                if (it.icon == nil or it._icon_auto) and it._icon_gen ~= iconlib.generation() then
                    it._icon_gen = iconlib.generation()
                    local s = it._src
                    if type(s) == "table" then
                        local p = s.path
                            or (s.bufnr and api.nvim_buf_is_valid(s.bufnr) and api.nvim_buf_get_name(s.bufnr))
                        if p and p ~= "" then
                            it.icon, it.icon_hl = source.devicon(p)
                            it._icon_auto = it.icon ~= nil
                        end
                    end
                end
                -- An explicit glyph icon (a diagnostic severity, a symbol kind …) becomes its lvim-icons IMAGE where
                -- UI icons are images ("material"), in the item's icon colour — once per item and per mode: the
                -- original glyph is kept, so a live mode switch converts it again from the glyph.
                if not it._icon_auto and it.icon and it.icon ~= "" and it._uicon_gen ~= iconlib.generation() then
                    it._uicon_gen = iconlib.generation()
                    it._uicon_src = it._uicon_src or { it.icon, it.icon_hl }
                    it.icon, it.icon_hl = it._uicon_src[1], it._uicon_src[2]
                    local t, h, img = iconlib.ui_text(it.icon, it.icon_hl)
                    if img then
                        it.icon = t
                        it.icon_hl = it.icon_hl and iconlib.on_bg({ image = true, hl = h }, it.icon_hl) or h
                    end
                end
                -- A caller item can name its own match spans (`match_bytes`, byte ranges in its display text —
                -- e.g. a quickfix grep entry's col..end_col): shown while no query is typed; a typed query marks
                -- its own characters instead.
                if (it.match == nil or #it.match == 0) and it.match_bytes == nil and type(it._src) == "table" then
                    it.match_bytes = it._src.match_bytes
                end
                local row, spans, lead = list_row(it, marked, marker)
                -- A caller item can colour parts of its display text (`hl_spans`: `{ c0, c1, hl }` byte ranges,
                -- e.g. aligned file / line columns); they sit in the label, after the mark column and the icon.
                local src = type(it._src) == "table" and it._src or nil
                local colour
                if src and src.hl_spans then
                    local base = #row - #(it.text or "")
                    colour = {}
                    for _, sp in ipairs(src.hl_spans) do
                        colour[#colour + 1] = { c0 = base + sp[1], c1 = base + sp[2], hl = sp[3] }
                    end
                end
                -- A match past the window's right edge is a row that says nothing about why it
                -- matched. Scroll it in, fzf-style, unless the reader asked for wrapping instead.
                if not list_wrap and clip_ellipsis ~= false then
                    local fixed = src and src.locator_bytes and (#row - #(it.text or "") - lead + src.locator_bytes)
                    row, spans, colour =
                        clip_row(row, spans, lead, list_width(), clip_ellipsis or "…", fixed or nil, colour)
                end
                lines[i] = row
                local odd = (li % 2) == 1 -- stripe parity by LOGICAL index (stable while scrolling)
                local sel = li == state.sel
                local stripe = sel
                        and (odd and hl("sel_odd", "LvimUiMsgAreaSelOdd") or hl("sel_even", "LvimUiMsgAreaSelEven"))
                    or (odd and hl("row_odd", "LvimUiMsgAreaRowOdd") or hl("row_even", "LvimUiMsgAreaRowEven"))
                hls[#hls + 1] = { i - 1, 0, -1, stripe, sel and 200 or 100 } -- full-row tint (eol)
                -- the mark dot in the front column (above the row tint) — the multi-select indicator
                if marked then
                    hls[#hls + 1] = { i - 1, 0, lead, hl("marker", "LvimUiPickerMarker"), 220 }
                end
                -- the leading glyph keeps its OWN colour (e.g. diagnostic severity signs) — above the row
                -- stripe (incl. the selected row's strong tint) so it shows through; the row is `<lead><icon> …`.
                if it.icon and it.icon ~= "" and it.icon_hl then
                    hls[#hls + 1] = { i - 1, lead, lead + #it.icon, it.icon_hl, 210 }
                end
                for _, cs in ipairs(colour or {}) do
                    hls[#hls + 1] = { i - 1, cs.c0, cs.c1, cs.hl, 205 }
                end
                for _, ms in ipairs(spans) do
                    hls[#hls + 1] = { i - 1, ms.c0, ms.c1, hl("match", "LvimUiMsgAreaMatch"), 250 }
                end
            end
            -- No results: with a preview the `[no matches]` label lives in the PREVIEW panel (the list row
            -- stays blank under the prompt overlay); without a preview the list shows the tinted label itself.
            if #lines == 0 then
                if opts.preview then
                    lines = { "" }
                else
                    lines = { " " .. empty_text }
                    hls[1] = { 0, 0, -1, hl("preview_file", "LvimUiPeekFile"), 100 } -- a single yellow-tinted row
                end
            end
            return lines, hls
        end,
        keys = function(map, pan, st)
            state.list_pan, state.st = pan, st
            -- `list_wrap` soft-wraps long rows (so a match far to the right stays visible) — never with the
            -- "↳" continuation marker (tame_win sets showbreak=NONE for this window); default off = truncate.
            tame_win(pan.win, list_wrap)
            set_list_winbar()
            -- NORMAL-mode keys on the list (reached via <Esc> from the prompt): navigate + act without the
            -- query. `<C-l>`/`<C-h>` (panel nav) + the filter bar are owned by the surface chassis.
            if map then
                map({ "j", "<Down>" }, function()
                    move(1)
                end)
                map({ "k", "<Up>" }, function()
                    move(-1)
                end)
                map("<CR>", function()
                    confirm()
                end)
                map("<C-d>", function()
                    scroll_preview(1)
                end)
                map("<C-u>", function()
                    scroll_preview(-1)
                end)
                -- NOTE: <C-j>/<C-k> are the surface's SECTOR navigation (list → footer bar → … and, when
                -- hosted, on past the footer DOWN into the messages via `on_escape_below`). We do NOT bind
                -- them here — that would shadow the stack navigation.
                -- multi-select: the mark key toggles the row's mark + advances; the
                -- quickfix key sends the marked rows (or the focused one) to the quickfix list. The mark key
                -- (Tab) is bound AFTER the chassis, so it overrides the list ⇄ preview toggle on the LIST (the
                -- preview is still reachable via `<C-l>`); both keys come from config.keys.
                map(keylist(kcfg.mark), mark)
                map(keylist(kcfg.quickfix), to_quickfix)
                -- open in a split (config.keys.open_methods.<method>.n — plain keys, the list is in normal mode)
                for method, m in pairs({ vsplit = "vsplit", hsplit = "split" }) do
                    local km = (kcfg.open_methods or {})[method]
                    if type(km) == "table" and km.n then
                        map(keylist(km.n), function()
                            confirm(m)
                        end)
                    end
                end
                -- (grep) Ctrl-g toggles GREP ⇄ FILTER mode from the normal-mode list too.
                if grep_toggle then
                    map(keylist(kcfg.grep_filter), grep_toggle)
                end
                if scope_toggle then
                    map(keylist(kcfg.grep_scope), scope_toggle)
                end
                -- the keymap CHEATSHEET (normal mode only — in the prompt `g?` would type into the query).
                map(keylist(kcfg.help), function()
                    require("lvim-picker.help").show(opts.keys) -- + THIS finder's per-call row actions
                end)
                -- back to typing: `/` + <C-f> (NOT i/a — a consumer filter may own those, e.g. diagnostics).
                map({ "/", "<C-f>" }, focus_input)
                map({ "q", "<Esc>" }, cancel)
                for _, a in ipairs(opts.keys or {}) do
                    -- `mode` restricts a row action to ONE context (absent = both). A key that also EDITS the
                    -- query (<BS>, a letter) is declared `mode = "n"` by its consumer so it acts on the list but
                    -- still types in the prompt.
                    if a.mode ~= "i" then
                        map(a.key, function()
                            act(a.run)
                        end)
                    end
                end
            end
        end,
    }

    -- preview panel (optional). Two flavours:
    --   • `opts.preview_file` — the REAL file buffer (lvim-ui.preview): fully EDITABLE, two-way in
    --     sync with the file, its own `<C-h>`/`<C-l>` nav when focused. Items must carry `path` (+ lnum/col).
    --   • `opts.preview(src)` — a read-only scratch buffer of the returned `lines` (+ filetype, focus line).
    --- Line numbers in the preview: this call's `opts.preview_numbers`, else `config.preview.numbers` (off).
    function want_numbers()
        local want = opts.preview_numbers
        if want == nil then
            want = ((config or {}).preview or {}).numbers
        end
        return want == true
    end
    if opts.preview_file then
        local up = preview.new({
            item = function()
                local it = state.filtered[state.sel]
                local s = it and it._src
                return (s and s.path and s.path ~= "")
                        and { filename = s.path, lnum = s.lnum, col = s.col, end_lnum = s.end_lnum, end_col = s.end_col }
                    or nil
            end,
            -- a grep (or a caller-given pattern) marks its matches in the file preview too
            matches = (opts.grep or opts.match_pattern) and function()
                return match_pattern(), regex_grep
            end or nil,
            -- no number column in the preview (as lfz and lvc show it) unless asked: `config.preview.numbers = true` or this call's `opts.preview_numbers`
            number = want_numbers() and "normal" or "none",
            empty = empty_preview, -- the configurable "nothing to preview" placeholder text
        })
        preview_provider = {
            size = function()
                return math.max(40, math.floor(vim.o.columns * 0.5)), preview_panel_h() -- the PREVIEW's own height
            end,
            update = up.update,
            item = up.item, -- the focused location (lnum/col), so the dynamic peek can position its cursor
            reset = up.reset, -- so the dynamic peek float re-asserts the file winbar on a fresh window
            on_close = up.on_close,
            -- only capture the panel (for C-d/C-u scroll); the file buffer is editable, so we add NO keys
            -- that would shadow `i`/`a` — ui.preview binds the panel-nav keys itself on focus.
            keys = function(_, pan)
                state.preview_pan = pan
            end,
        }
    end
    preview_provider = preview_provider
        or (opts.preview or opts.preview_file_of)
            and {
                size = function()
                    -- Both panels share the CONTENT height (the taller of list/preview, capped) so the
                    -- container fits the bigger one; the preview lines live in `state.preview_lines` (filled by
                    -- the sync `fetch_preview` for in-memory finders, or ASYNC for file finders). With results
                    -- +1 for the winbar; with NO results a single tinted `[no matches]` row.
                    return math.max(40, math.floor(vim.o.columns * 0.5)), preview_panel_h() -- the PREVIEW's own height
                end,
                update = function(pan)
                    -- The winbar shows the file that is ACTUALLY displayed: `state.preview_loc` (the async
                    -- file-preview path sets which file landed — a row behind during a fast scroll), else the
                    -- current selection's own source. Keeps the panel body + title consistent.
                    set_preview_winbar(
                        pan,
                        state.preview_loc or (state.filtered[state.sel] and state.filtered[state.sel]._src) or nil
                    )
                    -- No results: a SINGLE styled "nothing to preview" row (no winbar, no number, no syntax) —
                    -- the same bar `ui.preview` paints for the editable file preview, so the two read identically.
                    if not has_results() then
                        if pan.win and api.nvim_win_is_valid(pan.win) then
                            vim.wo[pan.win].number = false
                        end
                        preview.set_syntax(pan.buf, nil)
                        preview.render_empty(pan.buf, NS, empty_preview)
                        return
                    end
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = want_numbers() -- restore line numbers
                    end
                    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
                    local lines = state.preview_lines or {}
                    vim.bo[pan.buf].modifiable = true
                    pcall(api.nvim_buf_set_lines, pan.buf, 0, -1, false, lines)
                    vim.bo[pan.buf].modifiable = false
                    preview.set_syntax(pan.buf, state.preview_ft) -- highlight WITHOUT a `filetype` (no LSP attach)
                    -- `focus` (a 1-based line) scrolls the preview to that row and centres it — used by grep
                    -- to jump the preview to the matched line.
                    local focus = state.preview_focus
                    if focus and pan.win and api.nvim_win_is_valid(pan.win) then
                        pcall(api.nvim_win_set_cursor, pan.win, { math.max(1, math.min(focus, #lines)), 0 })
                        api.nvim_win_call(pan.win, function()
                            vim.cmd("normal! zz")
                        end)
                    end
                    -- WHERE THE MATCHES ARE. Centring the matched LINE answers only half the question a grep
                    -- result raises; the other half is which characters matched, and on a long line that is
                    -- the half the reader is actually looking for. Every match of the live pattern in the
                    -- previewed slice is marked, and the one this result points AT (its own line:col) is
                    -- marked harder — so the focused hit reads apart from its neighbours.
                    if prevcfg.match ~= false then
                        local ranges = preview_matches(lines, match_pattern(), regex_grep)
                        for _, r in ipairs(ranges) do
                            local focused = focus ~= nil
                                and r.row == focus - 1
                                and state.preview_col ~= nil
                                and r.c0 <= state.preview_col - 1
                                and state.preview_col - 1 < r.c1
                            pcall(api.nvim_buf_set_extmark, pan.buf, NS, r.row, r.c0, {
                                end_col = r.c1,
                                hl_group = focused and hl("preview_match_focus", "LvimUiPeekTitle")
                                    or hl("preview_match", "LvimUiMsgAreaMatch"),
                                priority = focused and 260 or 250,
                            })
                        end
                    end
                end,
                keys = function(map, pan)
                    state.preview_pan = pan
                    tame_win(pan.win, opts.preview_wrap == true) -- no "↳" marker; wrap off unless opted in
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = want_numbers() -- line numbers in the preview
                    end
                    -- NORMAL-mode keys on the preview (focused via <Tab>): the buffer is read-only, so a stray
                    -- `i`/`a` would error E21 — map them (and `/`) back to typing; `q`/<Esc> close, `<CR>` opens
                    -- the focused item. (`j`/`k` scroll the file; <Tab> toggles back to the list via the chassis.)
                    if map then
                        map({ "i", "a", "/", "<C-f>" }, focus_input)
                        map({ "q", "<Esc>" }, cancel)
                        map("<CR>", function()
                            confirm()
                        end)
                    end
                end,
            }
        or nil

    function set_list_cursor()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            -- Map the LOGICAL selection to its buffer line in the rendered viewport slice (the render just
            -- clamped `view_top`, so the selection is always inside the slice; clamp to the buffer anyway).
            local row = state.sel - (state.view_top or 1) + 1
            local nbuf = api.nvim_buf_line_count(p.buf)
            pcall(api.nvim_win_set_cursor, p.win, { math.max(1, math.min(nbuf, row)), 0 })
        end
    end
    --- Fetch the CURRENT selection's SYNCHRONOUS in-memory preview (lsp / diagnostics / buffers — cheap, no
    --- disk). File-based previews (`opts.preview_file_of`) are read ASYNC below and must NOT be touched here
    --- (this runs on every rerender and would wipe the async-loaded lines). No preview / no selection ⇒ empty.
    async_memo = {} ---@type table<any, { lines: string[], ft: string? }>
    function fetch_preview()
        if opts.preview_file_of then
            return -- the async file-preview path owns state.preview_lines
        end
        if opts.preview_async then
            -- an ASYNC text preview (a command's output): shown from memory when seen before, else a placeholder
            -- until `opts.preview_async` calls back; a late answer for a row no longer selected is only remembered
            local it = state.filtered[state.sel]
            state.preview_picture, state.preview_ft, state.preview_focus = nil, nil, nil
            if not it then
                state.preview_lines = {}
                return
            end
            local key = it._src
            local hit = async_memo[key]
            if hit then
                state.preview_lines, state.preview_ft = hit.lines, hit.ft
                return
            end
            state.preview_lines = { "…" }
            opts.preview_async(key, function(lines, ft)
                async_memo[key] = { lines = lines, ft = ft }
                local cur = state.filtered[state.sel]
                if cur and cur._src == key then
                    state.preview_lines, state.preview_ft = lines, ft
                    pcall(preview_refresh)
                end
            end)
            return
        end
        if opts.preview_file or not opts.preview then
            -- the editable file preview owns its buffer (ui.preview); no scratch lines to cache
            state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
            state.preview_picture = nil
            return
        end
        local it = state.filtered[state.sel]
        if not it then
            state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
            state.preview_picture = nil
            return
        end
        local lines, ft, focus = opts.preview(it._src)
        state.preview_lines = (type(lines) == "table" and lines) or (lines and { tostring(lines) }) or {}
        state.preview_picture = nil
        state.preview_ft, state.preview_focus = ft, focus
    end
    -- Re-fit the surface to the CONTENT height (the taller of list/preview, capped) — only when it actually
    -- changes, so navigating within the same height doesn't reflow the windows.
    function refit()
        local h = content_h()
        if h ~= last_h and state.st and state.st.relayout then
            last_h = h
            state.st.relayout()
        end
    end
end
