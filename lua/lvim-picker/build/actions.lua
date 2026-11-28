--- A step of building a finder (preview scrolling, the hand-off, confirm and cancel, the footer legend, focus, row actions).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.actions"

return function(ctx)
    setfenv(1, ctx)
    scroll_preview = function(dir, line)
        -- The surface knows which window holds the preview right now — the docked panel, or the `dynamic`
        -- peek FLOAT above the dock (where the docked panel is parked, so scrolling it did nothing).
        if state.st and state.st.scroll_preview then
            return state.st.scroll_preview(dir, line)
        end
        local p = state.preview_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            api.nvim_win_call(p.win, function()
                local key = line and (dir > 0 and "<C-e>" or "<C-y>") or (dir > 0 and "<C-d>" or "<C-u>")
                vim.cmd("normal! " .. api.nvim_replace_termcodes(key, true, false, true))
            end)
        end
    end
    -- Coalesce the picker teardown with whatever a consumer opens in its callback (lvim-space re-opening a
    -- panel on the search step-back) into ONE zone reflow — so
    -- the shared area zone and its backdrop never collapse-then-regrow between the two surfaces (the flicker on
    -- the way back). `surface.zone_handoff` routes to the host zone's coalescer (msgarea's lazyredraw + single
    -- flush), so close + re-open paint as one frame. Off the area zone there is no shared zone to coalesce.
    function with_handoff(fn)
        -- HOLD the backdrop across the teardown + the tick after it — for EVERY layout:
        -- closing this surface drops focus to the editor, and Neovim applies that focus-fall a beat after the
        -- frame, so the focus-aware veil would lift (bright editor) before the consumer's reopened panel re-dims
        -- it. The hold suppresses that lift; the scheduled release reconciles against the settled focus. The lift
        -- race is focus-driven (layout-independent); the ZONE handoff below is the area-only coalescing part.
        local ok_dim, dim = pcall(require, "lvim-utils.dim")
        local held = ok_dim and type(dim.hold_backdrop) == "function"
        if held then
            dim.hold_backdrop(true)
        end
        local ok, err = pcall(function()
            if opts.layout == "area" then
                require("lvim-ui.surface").zone_handoff(fn)
            else
                fn()
            end
        end)
        if held then
            -- Event-driven release: settle on a protected WinEnter (the reopened panel), not a fixed schedule
            -- that could land on the transient editor focus-fall and reconcile to a lift.
            dim.release_backdrop_when_settled()
        end
        if not ok then
            error(err)
        end
    end
    -- `opts.replace_before_close`: the consumer's callback OPENS a replacement dock in the same area zone (the
    -- lvim-space search step-back re-opens its panel). Run the callback FIRST so the new dock's `surface.open`
    -- sees this finder as the area occupant and closes it in the BACKGROUND after its own windows exist + hold
    -- focus (no editor focus-fall / tremble). The explicit `st.close()` after is then a no-op (already closed).
    -- Default (nil) keeps close-first, which other consumers rely on.
    --- Confirm the focused row. `method` ("vsplit" | "split") first opens a split of the window the finder
    --- was opened from, so the consumer's `on_confirm` (which opens the item in the CURRENT window) lands there.
    ---@param method? "vsplit"|"split"
    confirm = function(method)
        local it = state.filtered[state.sel]
        -- a file that is not text (a picture, a PDF …) opens in the program the open plugin says — as in lvc and
        -- lfz — and the finder stays open; text and directories go on to open in this editor
        if it and opts.preview_file_of then
            local loc = opts.preview_file_of(it._src)
            if loc and loc.path and loc.path ~= "" and require("lvim-picker.media").open_external(loc.path) then
                return
            end
        end
        state.handled = true -- we own the outcome → on_close must not also fire on_cancel
        with_handoff(function()
            local function route()
                if it and opts.on_confirm then
                    opts.on_confirm(it._src)
                end
            end
            if opts.replace_before_close then
                route()
                if state.st then
                    state.st.close()
                end
            else
                if state.st then
                    state.st.close()
                end
                if method and it then
                    if opener and api.nvim_win_is_valid(opener) then
                        api.nvim_set_current_win(opener)
                    end
                    vim.cmd(method)
                end
                route()
            end
        end)
    end
    -- Dismiss the finder (no choice). Shared by the prompt (<C-c>) and NORMAL-mode list (q / <Esc>).
    cancel = function()
        vim.cmd("stopinsert")
        state.handled = true -- deliver on_cancel HERE (not again from on_close)
        with_handoff(function()
            if opts.replace_before_close and opts.on_cancel then
                opts.on_cancel() -- opens the replacement dock, which evicts this finder in the background
                if state.st then
                    state.st.close() -- idempotent (already evicted)
                end
            else
                if state.st then
                    state.st.close()
                end
                if opts.on_cancel then
                    opts.on_cancel()
                end
            end
        end)
    end
    -- MODE-AWARE footer legend. The move keys differ by focus — in the PROMPT (insert) `C-j`/`C-k` move the
    -- selection (`j`/`k` would type); in the NORMAL list `j`/`k` move and the filter hotkeys (`Tab` mark,
    -- `<C-q>` qf) activate directly. So the footer is rebuilt on every prompt⇄list switch via `set_footer`, and
    -- shows the keys that ACTUALLY work in the current context. `<C-f>` is the FOCUS toggle between them (labelled
    -- "focus" in both). Config-bound keys are labelled from their live `config.keys` value.
    function klabel(k)
        if type(k) == "table" then
            k = k[1]
        end
        return (tostring(k or ""):gsub("^<(.-)>$", "%1"))
    end
    ---@param ctx "prompt"|"list"
    ---@return table[]  the footer item list for this focus context
    build_footer = function(ctx)
        -- ONE run of hints for everything the picker does — no group boxes between open / move / mark / preview /
        -- focus / close. The ONLY exception is the cheatsheet: `help` is pulled to the very end and set apart by a
        -- single `●` (config.footer_separator, `LvimUiFooterSep`), so "where the full key list is written down"
        -- reads as its own thing rather than one hint among the actions.
        if opts.hints then
            local cur = state.filtered and state.filtered[state.sel or 1]
            local ok, own = pcall(opts.hints, ctx, cur and (cur._src or cur) or nil)
            if ok and type(own) == "table" then
                return own
            end
        end
        local hints
        if ctx == "list" then
            hints = {
                { key = "<CR>", name = "open" },
                { key = "j/k", name = "move" },
                { key = klabel(kcfg.mark), name = "mark" },
                { key = klabel(kcfg.quickfix), name = "qf" },
            }
        else -- prompt (insert): C-j/k move the selection while you type
            hints = {
                { key = "<CR>", name = "open" },
                { key = "C-j/k", name = "move" },
            }
        end
        do -- open in a split: `v`/`x` on the list, `C-v`/`C-x` while typing (config.keys.open_methods)
            local om = kcfg.open_methods or {}
            local side = ctx == "list" and "n" or "i"
            local v, x = (om.vsplit or {})[side], (om.hsplit or {})[side]
            if v and x then
                hints[#hints + 1] = { key = klabel(v) .. "/" .. klabel(x):gsub("^C%-", ""), name = "split" }
            end
        end
        if preview_provider then
            hints[#hints + 1] = { key = "C-d/u", name = "preview" }
            -- one line at a time, turn the preview (right → left → above), and hide / show it
            local ld, lu = keylist(kcfg.preview_line_down)[1], keylist(kcfg.preview_line_up)[1]
            if ld and lu then
                hints[#hints + 1] = { key = klabel(ld) .. "/" .. klabel(lu):gsub("^C%-", ""), name = "line" }
            end
            local np, pp_ = keylist(kcfg.preview_next)[1], keylist(kcfg.preview_prev)[1]
            if np and pp_ then
                hints[#hints + 1] = { key = klabel(np) .. "/" .. klabel(pp_):gsub("^C%-", ""), name = "turn" }
            elseif np then
                hints[#hints + 1] = { key = klabel(np), name = "turn" }
            end
            local tg = keylist(kcfg.preview_toggle)[1]
            if tg then
                hints[#hints + 1] = { key = klabel(tg), name = "hide" }
            end
        end
        for _, a in ipairs(opts.keys or {}) do
            -- a `mode`-restricted row action is only hinted in the context it actually works in
            if a.name and (a.mode == nil or a.mode == (ctx == "list" and "n" or "i")) then
                hints[#hints + 1] = { key = a.key, name = a.name }
            end
        end
        if opts.grep and opts.grep.live then
            hints[#hints + 1] = { key = klabel(kcfg.grep_filter), name = "grep⇄filter" }
        end
        if opts.grep then
            hints[#hints + 1] = { key = klabel(kcfg.grep_scope), name = "filter scope" }
        end
        -- ONE name in both contexts: `C-f` is a FOCUS toggle (prompt ⇄ list), not two separate commands. Naming it
        -- after its destination ("list" / "type") read as if the picker had two different keys there.
        hints[#hints + 1] = { key = "C-f", name = "focus" }
        -- CLOSE is context-aware, because the keys are: the PROMPT (insert) cancels with `<C-c>`; on the LIST
        -- (normal) `q` / `<Esc>` close (there `<C-c>` does nothing, and `<Esc>` from the prompt drops to the list
        -- rather than closing). The footer used to say `C-c` in both, so the hint was wrong the moment you left
        -- the input.
        hints[#hints + 1] = ctx == "list" and { key = "q/Esc", name = "close" } or { key = "C-c", name = "close" }
        -- help LAST, in its own group: a `●` separator, then the cheatsheet key. LIST context only — in the prompt
        -- the key would type into the query.
        if ctx == "list" then
            local sep = (config or {}).footer_separator or "\u{f09de}"
            hints[#hints + 1] =
                { type = "separator", text = sep, style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
            hints[#hints + 1] = { key = klabel(kcfg.help), name = "help" }
        end
        return hints
    end
    function set_footer_ctx(ctx)
        state.footer_ctx = ctx
        if state.st and state.st.set_footer then
            state.st.set_footer({ bars = { { items = build_footer(ctx) } } })
        end
    end
    state.refresh_footer = function()
        set_footer_ctx(state.footer_ctx or "prompt")
    end
    -- TWO MODES: the prompt is INSERT (fuzzy type); <Esc> drops to NORMAL on the list (j/k move,
    -- <C-l>/<C-h> panel nav, the filter bar) — `focus_input` returns to typing, `focus_list` leaves insert.
    focus_input = function()
        local w = state.input_buf and vim.fn.bufwinid(state.input_buf) or -1
        if w ~= -1 then
            api.nvim_set_current_win(w)
            vim.cmd("startinsert!")
            set_footer_ctx("prompt") -- typing again → the prompt-context key hints
        end
    end
    function focus_list()
        vim.cmd("stopinsert")
        if state.st and state.st.focus_block then
            state.st.focus_block("list")
        end
        set_footer_ctx("list") -- on the list → the normal-mode key hints (j/k move · Tab mark · C-q qf)
    end
    -- Run a consumer `opts.keys` action on the SELECTED item: it gets the item's source value, a `close`
    -- callback (dismiss the finder, or keep it open), and the MARKED source values (the multi-select, in mark
    -- order — empty when nothing is marked) so an action can operate on the whole selection. No selection ⇒ no-op.
    act = function(run)
        local it = state.filtered[state.sel]
        if not it then
            return
        end
        local marked = {}
        for _, s in ipairs(state.marked) do
            marked[#marked + 1] = s
        end
        -- Wrap the WHOLE action in a handoff: a row action's `close` re-opens the launching panel right after
        -- dismissing the finder (the search <BS> step-back), so the picker teardown and that re-open coalesce
        -- into one zone reflow (no backdrop flicker on the way back), same as confirm/cancel.
        -- With `replace_before_close` the action re-opens its panel BEFORE calling `close` — that re-open evicts
        -- this finder (its `surface.on_close` runs THEN). Mark `state.handled` NOW so that eviction-driven
        -- on_close does not ALSO fire `on_cancel` and re-open the panel a second time.
        if opts.replace_before_close then
            state.handled = true
        end
        with_handoff(function()
            run(it._src, function()
                state.handled = true -- the row action owns the outcome → on_close must not fire on_cancel
                if state.st then
                    state.st.close()
                end
            end, marked)
        end)
    end
end
