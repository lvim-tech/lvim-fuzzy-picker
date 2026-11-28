--- A step of building a finder (markers and the quickfix, the list's and the preview's geometry, the winbars and the counter).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.list"

return function(ctx)
    setfenv(1, ctx)
    -- mode-aware footer legend (prompt ⇄ list), assigned near focus_input; used at open + on switch
    -- The GREP controller (assigned after `refilter`, referenced by it + the keymaps): (re)start rg for a query,
    -- stop the in-flight rg, and the Ctrl-g grep⇄filter toggle. Nil for non-grep finders.

    -- A grep finder ran the pattern through ripgrep as a REGEX (`opts.regex`) or, by default, as a fixed
    -- string; the marks in the rows and the preview must read it the same way (see `preview_matches`).
    regex_grep = opts.regex == true
    --- The pattern whose matches are marked in a location row's text and in the PREVIEW: for a grep finder the
    --- pattern ripgrep ran — what the lines actually matched, and where the row's `line:col` points. The typed
    --- text is that pattern only in GREP mode; in FILTER mode (and for a fixed-query grep — cword / selection /
    --- …, which opens in filter mode) the typed text is a fuzzy filter over rg's matches, so marking IT left the
    --- rows and the preview unmarked on open and the focus mark pointing at the wrong characters. Any other
    --- finder marks the typed query.
    ---@return string?
    function match_pattern()
        if opts.match_pattern and opts.match_pattern ~= "" then
            return opts.match_pattern -- the caller's own (e.g. the grep a quickfix list came from)
        end
        if opts.grep then
            local gq = state.grep_query -- the blob controller: the live / frozen / fixed rg query
            if gq and gq ~= "" then
                return gq
            end
        elseif opts.query and opts.query ~= "" then
            return opts.query -- the fallback (ABI < 5) fixed-query grep stream
        end
        local q = state.live_query
        if q == nil or q == "" then
            q = state.query
        end
        return q
    end

    -- ── multi-select marking + quickfix (config.keys.mark / .quickfix) ──
    pkc = (config or {})
    kcfg = pkc.keys or {}
    marker = pkc.marker or "󰅂"
    --- A config key value (a single key, a list, or "") → a list of keys.
    ---@param v string|string[]|nil
    ---@return string[]
    function keylist(v)
        if type(v) == "table" then
            return v
        end
        return (type(v) == "string" and v ~= "") and { v } or {}
    end
    --- The mark-order index of a source value within `state.marked`, or nil.
    function marked_index(src)
        for i, s in ipairs(state.marked) do
            if s == src then
                return i
            end
        end
    end
    --- Whether a source value is marked (drives the front-column dot in the render).
    function is_marked(src)
        return src ~= nil and marked_index(src) ~= nil
    end
    --- Toggle the focused row's mark, then advance one row (multi-select `Tab` = toggle + down).
    function mark()
        local it = state.filtered[state.sel]
        if it and it._src ~= nil then
            local i = marked_index(it._src)
            if i then
                table.remove(state.marked, i)
            else
                state.marked[#state.marked + 1] = it._src
            end
        end
        move(1) -- advance + re-render (so the new dot shows)
    end
    --- Send the marked rows (or the focused one when none are marked) to the quickfix list; close + open it.
    function to_quickfix()
        local srcs = state.marked
        if #srcs == 0 then
            local cur = state.filtered[state.sel]
            srcs = (cur and cur._src ~= nil) and { cur._src } or {}
        end
        local qf = {}
        local pattern = (opts.grep or opts.match_pattern) and match_pattern() or nil
        for _, src in ipairs(srcs) do
            if type(src) == "table" then
                local text = src.qf_text or src.text or ""
                local end_col = src.end_col
                if pattern and not end_col and src.path and src.lnum and src.col then
                    -- the streamed (ABI < 5) grep row carries its display text `path:lnum  line`: keep the line
                    local shown = ("%s:%s  "):format(src.path, src.lnum)
                    if text:sub(1, #shown) == shown then
                        text = text:sub(#shown + 1)
                    end
                    -- where the match at `col` ends, so the list can mark it later (`end_col`, exclusive)
                    for _, r in ipairs(preview_matches({ text }, pattern, regex_grep)) do
                        if r.c0 <= src.col - 1 and src.col - 1 < r.c1 then
                            end_col = r.c1 + 1
                            break
                        end
                    end
                end
                qf[#qf + 1] = {
                    filename = src.path,
                    bufnr = (not src.path) and src.bufnr or nil,
                    -- 0 (not 1) when the entry has no real position (a plain file pick), so consumers can tell a
                    -- file list from a grep/diagnostic one; vim still jumps to the file's top.
                    lnum = src.lnum or 0,
                    col = src.col or 0,
                    end_lnum = end_col and src.lnum or nil,
                    end_col = end_col,
                    text = text,
                }
            end
        end
        if #qf == 0 then
            return
        end
        pcall(function()
            require("lvim-hud.overlay").clear()
        end) -- idempotent — drop the finder's statusline title/counter if it published one
        if state.st then
            state.st.close()
        end
        -- the grep pattern rides along in the list's context, so a later view of the list (the lvim-qf-loc
        -- browser) can mark its matches again
        vim.fn.setqflist({}, " ", {
            title = opts.title or "Picker",
            items = qf,
            context = pattern and { lvim_picker = { pattern = pattern, regex = regex_grep } } or nil,
        })
        vim.cmd("botright copen")
    end

    -- Kill the "↳" continuation marker on wrapped rows WITHOUT touching the user's global `showbreak`: the
    -- special window-local value "NONE" disables showbreak for THIS window only (an empty "" would just
    -- revert to the global) — no marker, no global mutation. (No `breakindent`: its virtual indent draws no
    -- text and so cannot carry the row tint — it would leave an un-tinted notch; instead continuations sit
    -- at column 0 as REAL wrapped text, fully covered by the row's `hl_eol` stripe.)
    --- The list window's width in cells, or 0 while it has none yet (the first render before layout).
    ---@return integer
    function list_width()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            return api.nvim_win_get_width(p.win)
        end
        return 0
    end

    function tame_win(win, wrap)
        if win and api.nvim_win_is_valid(win) then
            vim.wo[win].wrap = wrap or false
            vim.wo[win].list = false
            vim.wo[win].showbreak = "NONE"
        end
    end

    -- The title + match counter flow through the chassis (the SINGLE title path): a native centered
    -- border-title + the count in the border (default the bottom-right border-footer, per `counter`), OR —
    -- when `title_line="statusline"` (per-call or `ui_config`) — the centralized chrome-overlay title (the
    -- chassis owns that publish, not us). `count_fn` is the live `matches / candidate-pool` count (fzf-lua
    -- style: the pool grows as a stream feeds in); `refresh_count` re-applies it to the live border / overlay
    -- after every selection move / filter / type.
    -- The counter, always the REAL numbers (never the ≤max_results shown-row count). The two numbers only ever
    -- differ when a QUERY is actually narrowing a pool, so:
    --   • NO query → a SINGLE number (the pool count) — with nothing typed, "found == total" is meaningless, so
    --     we show just the count (a plain number renders as "N", not "N/N").
    --   • a query → `matched / total`, where MATCHED is the matcher's TRUE hit count (shrinks as you narrow),
    --     TOTAL the fixed pool.
    --   • LIVE grep → always a SINGLE number: rg IS the search (there is no separate pool to narrow against),
    --     so every found row is a matched row — a lone climbing match count is the honest display.
    function count_fn()
        -- GREP CONTROLLER (Variant B): the blob holds ALL rg matches (up to the config.grep_max store ceiling; a
        -- pathological overflow is still TALLIED, never stored). The MODE decides the counter:
        --   • GREP mode — rg IS the search, nothing filters on top, so matched == total == the REAL rg match
        --     count (`state.grep_total`, climbing to e.g. 403127 as rg streams) → shown fzf-style `N/N`.
        --   • FILTER mode (rg frozen; the typed query fuzzy-narrows the loaded blob) — `matched / loaded`, where
        --     matched (`state.match_total`, the matcher's TRUE hit count) SHRINKS as you type and `loaded`
        --     (`state.pool_n`) is the blob's candidate count.
        if opts.grep then
            if state.grep_mode == "filter" then
                local total = state.pool_n or 0
                return { current = state.match_total or total, total = total }
            end
            local n = state.grep_total or 0
            return n > 0 and { current = n, total = n } or 0
        end
        -- GREP (opts.count_files): `matches found / TOTAL FILES in the tree`. `current` = the grep matches (the
        -- fuzzy-narrowed hit count on the fixed-query/blob path, or the live-grep result count); `total` = the
        -- tree's file count (state.file_total, streamed in the background — see the file-count block). This is
        -- the denominator the user wants: how many files the grep searched, not the match count repeated.
        if opts.count_files then
            local cur
            if state.blob then
                cur = state.query == "" and (state.pool_n or 0) or (state.match_total or state.pool_n or 0)
            else
                cur = state.filtered and #state.filtered or 0
            end
            return { current = cur, total = state.file_total or cur }
        end
        if state.blob then
            local total = state.pool_n or 0
            if state.query == "" then
                return total -- no filter → just the count
            end
            return { current = state.match_total or total, total = total }
        end
        if opts.source then
            local cur = state.filtered and #state.filtered or 0
            return { current = cur, total = cur }
        end
        local cur = state.filtered and #state.filtered or 0
        if state.query == "" then
            return #items -- no filter → just the count
        end
        return { current = cur, total = #items }
    end
    function refresh_count()
        if state.st and state.st.set_counter then
            state.st.set_counter(count_fn)
        end
    end

    -- list panel: the filtered rows in the tint canon (odd BLUE / even YELLOW full-row stripes, the
    -- selected row a STRONG tint of its accent), matched chars in red. Selection is the Sel stripe (not a
    -- window cursorline), so it survives the row tints; navigation re-renders to move it.
    -- Dynamic height: the container fits the TALLER of the two panels, capped at `max_rows`. The list
    -- contributes its result count; the preview contributes its content's line count (cached on selection).
    -- 0 results ⇒ both are 0 ⇒ only the prompt + the preview winbar show. relayout() re-fits on every change.
    state.preview_lines = {}
    --- The LIST's own content height: the result count capped at `max_rows` (0 when empty — no body row).
    ---@return integer
    function list_h()
        return math.min(#state.filtered, maxr) -- 0 when empty (no [no matches] body row)
    end
    --- The PREVIEW's own content height: the editable file's line count (preview_file) or the cached scratch
    --- preview line count, capped at `max_rows`.
    ---@return integer
    function preview_h()
        if opts.preview_file then
            -- the editable preview fits the FILE: a 3-line file is 3 rows; a big one is capped at max_rows
            local it = state.filtered[state.sel]
            local s = it and it._src
            if s and s.path and s.path ~= "" then
                -- a loaded buffer knows its length; otherwise count at most `maxr` lines of the file — never
                -- LOAD it just to size the panel (that ran its BufRead/FileType/LSP work on every row)
                local b = vim.fn.bufnr(s.path)
                if b > 0 and vim.api.nvim_buf_is_loaded(b) then
                    return math.min(vim.api.nvim_buf_line_count(b), maxr)
                end
                local ok, lines = pcall(vim.fn.readfile, s.path, "", maxr)
                return math.max(1, ok and #lines or 1)
            end
            return 1
        end
        if opts.preview_file_of then
            -- ASYNC file preview: track the LIST height (the result COUNT, capped at max_rows) — NOT the
            -- previewed file's own line count. The file count would change for EVERY row as you scroll →
            -- `content_h` re-fingerprints → a `relayout()` on every scroll step that visibly tears the windows.
            -- The result count is STABLE while scrolling (it only changes on a new query), so this keeps the
            -- layout put during scroll (no tear) AND still AUTO-FITS the panel to the number of matches — a
            -- few-result grep gets a compact panel instead of a full-height one (the preview shows that many
            -- context rows). Identical to `list_h()` so the two panels always agree.
            -- A PICTURE needs room: the panel is as tall as it may be while one is shown (the layout changes
            -- only when a picture comes or goes, not row by row).
            if state.preview_picture then
                return maxr
            end
            return list_h()
        end
        return math.min(#state.preview_lines, maxr)
    end
    --- True when the filter left at least one result (drives the winbar / empty-state rendering).
    ---@return boolean
    function has_results()
        return #state.filtered > 0
    end
    -- Each panel fits ITS OWN content (+1 for its winbar with results; a single tinted row when empty). The
    -- surface MAXes them for a side-by-side (horizontal) layout, SUMs them when stacked (vertical), and the
    -- area auto-fits to that — capped at the configured height. `content_h` is just a fingerprint so `refit`
    -- relayouts whenever EITHER panel's height changes.
    function list_panel_h()
        return has_results() and (list_h() + 1) or 1
    end
    function preview_panel_h()
        -- empty ⇒ a SINGLE styled row (the "nothing to preview" bar, no winbar → no blank body row beneath)
        return has_results() and (preview_h() + 1) or 1
    end
    function content_h()
        return list_h() * 1000 + preview_h()
    end

    -- ── list viewport (virtualized render) ──────────────────────────────────
    -- The list buffer holds ONLY the rows its window can show (+ VIEW_MARGIN below), never the whole
    -- filtered set — so a render is O(viewport) at ANY scale (an uncapped live-grep result or a huge static
    -- `items` open used to build every row + stripe extmark: 0.4–1.6 s and ~600k extmarks at 200k).
    -- Selection, marks and actions keep addressing LOGICAL entries (`state.filtered[state.sel]`); only the
    -- buffer-line mapping shifts by `state.view_top - 1` (each entry is exactly ONE buffer line — `normalize`
    -- collapses newlines). Row striping is keyed by the LOGICAL index, so the odd/even pattern stays put
    -- while scrolling instead of re-phasing with the slice.
    VIEW_MARGIN = 4 -- overrender a few rows so the window height (winbar / relayout skew) never shows blanks
    --- The list viewport height: the live window height when the panel exists (a docked layout can exceed
    --- `max_rows`), else the content-fit height. May overcount by the winbar row — VIEW_MARGIN covers it.
    ---@return integer
    function view_height()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            return math.max(1, api.nvim_win_get_height(p.win))
        end
        return math.max(1, list_h())
    end
    --- Clamp `state.view_top` so the selection sits inside the viewport and the slice never starts past the
    --- tail. Called at the top of every list render — every path (move / filter / stream growth) goes
    --- through the render, so the slice can never drift from the selection.
    ---@param vh integer  the viewport height
    ---@return integer view_top
    function clamp_view(vh)
        local total = #state.filtered
        local top = state.view_top or 1
        if state.sel < top then
            top = state.sel
        elseif state.sel > top + vh - 1 then
            top = state.sel - vh + 1
        end
        top = math.max(1, math.min(top, math.max(1, total - vh + 1)))
        state.view_top = top
        return top
    end

    -- Each panel carries a WINBAR title, the lvim-lsp peek look: the list shows the title + result count,
    -- the preview shows the selected file (tail + dir). `%%` escapes a literal `%` in a name.
    --- Escape a string for use in a statusline/winbar format (doubles every literal `%`).
    ---@param s any
    ---@return string
    function esc(s)
        return (tostring(s or ""):gsub("%%", "%%%%"))
    end
    --- Paint the LIST panel's winbar: blank with a preview (the scoped prompt overlays it), else the
    --- title + result count; nothing when there are no results (the panel is a single row).
    function set_list_winbar()
        local p = state.list_pan
        if not (p and p.win and api.nvim_win_is_valid(p.win)) then
            return
        end
        -- No results ⇒ NO winbar (the panel is a single row — see list_panel_h); the prompt overlay owns it.
        if not has_results() then
            vim.wo[p.win].winbar = ""
            return
        end
        -- With a preview (lines OR the editable file) the scoped INPUT prompt overlays this row, so keep it
        -- blank (just reserve the row, so the first list item isn't hidden under the prompt); the title/count
        -- live in the statusline / the header. Without ANY preview the list owns its title bar.
        if opts.preview or opts.preview_file then
            vim.wo[p.win].winbar = ("%%#%s# %%="):format(hl("bar", "LvimUiPeekFileBar"))
        else
            vim.wo[p.win].winbar = ("%%#%s# %s %%#%s# %d %%#%s#%%="):format(
                hl("list_title", "LvimUiPeekTitle"),
                esc(opts.title or "Pick"),
                hl("list_count", "LvimUiPeekCount"),
                #state.filtered,
                hl("bar", "LvimUiPeekFileBar")
            )
        end
    end
    function set_preview_winbar(pan, it)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        -- No results ⇒ NO winbar; the "nothing to preview" bar is the panel's single styled row instead (drawn
        -- in the preview provider `update` via `preview.render_empty`), so there is no empty body row.
        if not has_results() then
            vim.wo[pan.win].winbar = ""
            return
        end
        if it and it.path and it.path ~= "" then
            local rel = vim.fn.fnamemodify(it.path, ":~:.")
            local tail = vim.fn.fnamemodify(rel, ":t")
            local dir = vim.fn.fnamemodify(rel, ":h")
            dir = (dir == "." or dir == "") and "" or (dir .. "/")
            -- the file's icon (from the configured icon_provider, when `preview.show_icon`)
            local file_hl = hl("preview_file", "LvimUiPeekFile")
            local icon = ""
            if prevcfg.show_icon ~= false then
                local r = iconlib.get(tail, { provider = config.icon_provider, color_mode = config.icon_color_mode })
                local gl = r.glyph
                if gl and gl ~= "" then
                    -- an lvim-icons IMAGE keeps its own group (its fg is the image id) on the file name's bg;
                    -- a font glyph takes the file name's colour, as before
                    local img_hl = iconlib.on_bg(r, file_hl)
                    icon = img_hl and ("%#" .. img_hl .. "#" .. esc(gl) .. "%#" .. file_hl .. "# ")
                        or (esc(gl) .. " ")
                end
            end
            -- name = icon + file (bright); dir = padded path on the winbar bg (so it blends into the bar)
            local dpl, dpr = prevcfg.dir_pad_left or 1, prevcfg.dir_pad_right or 1
            vim.wo[pan.win].winbar = ("%%#%s# %s%s %%#%s#%s%s%s%%#%s#%%="):format(
                file_hl,
                icon,
                esc(tail),
                hl("preview_dir", "LvimUiPickerPreviewDir"),
                string.rep(" ", dpl),
                esc(dir),
                string.rep(" ", dpr),
                hl("bar", "LvimUiPeekFileBar")
            )
        else
            -- A selected item with no path → its text; NO results → the empty label in the file-name spot.
            vim.wo[pan.win].winbar = ("%%#%s# %s %%#%s#%%="):format(
                hl("preview_file", "LvimUiPeekFile"),
                esc((type(it) == "table" and it.text) or (type(it) == "string" and it ~= "" and it) or empty_text),
                hl("bar", "LvimUiPeekFileBar")
            )
        end
    end
end
