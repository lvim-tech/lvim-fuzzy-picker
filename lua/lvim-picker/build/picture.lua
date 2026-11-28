--- A step of building a finder (a picture in the preview: attach it, put it back, redraw the preview when it changes).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.picture"

return function(ctx)
    setfenv(1, ctx)

    -- Forward declarations — the list panel's NORMAL-mode keys (defined with the panel, early) call these,
    -- but they are assigned further down (after the providers/state are wired).
    --- Re-render the preview. The panel is the one the picker captured when it was first drawn, else the
    --- surface's own: a finder that OPENS in `dynamic` never draws its docked preview (it is parked from the
    --- start), so nothing was captured and the peek float above the dock never followed the list.
    --- A PICTURE of the shown file (the shared engine's PNG): drawn under the table of facts that is the
    --- preview's text, by lvim-image (kitty placeholders where the terminal takes them). Re-made after every
    --- re-render of the panel (which rewrites its lines), and taken off when the preview is not a picture.
    function attach_picture(pp)
        state._attaching = true
        local ok_run, err = pcall(function()
            return attach_picture_now(pp)
        end)
        state._attaching = false
        if not ok_run then
            error(err, 0)
        end
    end
    --- Put the picture's grid back into `panel`'s buffer — called by lvim-ui's `paint` at the END of the panel's own
    --- write (leaving the input, the next keystroke): in the same turn, so no frame is ever drawn with the grid
    --- wiped (that gap was the blink). The picture itself is not sent again (lvim-image knows the terminal has it).
    function put_picture_back(panel)
        local old = state.preview_placement
        if state.closed or not state.preview_picture or not old or old.buf ~= panel.buf then
            return
        end
        state._attaching = true
        local ok = pcall(function()
            old.pl:render_placeholder()
        end)
        if ok and state.preview_desc then
            require("lvim-picker.media").paint(panel.buf, state.preview_desc)
        end
        state._attaching = false
    end
    attach_picture_now = function(pp)
        local old = state.preview_placement
        local pic = state.preview_picture
        -- WHERE the preview is shown now: the docked panel, or — in the `dynamic` layout — the peek float above
        -- the dock (its own window and buffer; the docked panel is parked behind the list then). Hidden: nowhere.
        local st = state.st
        local target = pp
        if st and st.preview_hidden then
            target = nil
        elseif st and st.preview_side == "dynamic" and st.dyn then
            target = { win = st.dyn.win, buf = st.dyn.buf }
        end
        pp = target
        local ok_win = pp and pp.win and pp.buf and vim.api.nvim_win_is_valid(pp.win) and vim.api.nvim_buf_is_valid(pp.buf)
        if pic and ok_win then
            -- The panel (the docked one, or the peek float) rewrites its lines whenever IT renders — leaving the
            -- input with <Esc>, a resize, the next keystroke — and that wipes the picture's grid. Watch the
            -- buffer: whenever its lines change from outside this function, put the picture back.
            state.preview_watched = state.preview_watched or {}
            local function watch(buf)
                if not (buf and vim.api.nvim_buf_is_valid(buf)) or state.preview_watched[buf] then
                    return
                end
                state.preview_watched[buf] = true
                vim.api.nvim_buf_attach(buf, false, {
                    on_lines = function()
                        if state.closed then
                            return true
                        end
                        if state._attaching or not state.preview_picture or state._reattach then
                            return
                        end
                        state._reattach = true
                        vim.schedule(function()
                            state._reattach = false
                            if state.closed or not state.preview_picture then
                                return
                            end
                            attach_picture(state.preview_pan or (state.st and state.st.preview_panel))
                        end)
                    end,
                    on_detach = function()
                        if state.preview_watched then
                            state.preview_watched[buf] = nil
                        end
                    end,
                })
            end
            -- every place the preview can be shown in: this one, the docked panel, the peek float — rotating the
            -- preview re-renders whichever it moves to, and that is the moment to put the picture there
            local panel = state.preview_pan or (state.st and state.st.preview_panel)
            if panel and panel.buf and not panel.after_paint then
                panel.after_paint = put_picture_back
            end
            watch(pp.buf)
            watch(panel and panel.buf)
            watch(state.st and state.st.dyn and state.st.dyn.buf)
            -- as lvc and lfz draw it: no number column; the panel's own render puts these back on every refresh
            for _, o in ipairs({ "number", "relativenumber", "list", "cursorline" }) do
                pcall(function()
                    vim.wo[pp.win][o] = false
                end)
            end
            pcall(function()
                vim.wo[pp.win].signcolumn = "no"
                vim.wo[pp.win].wrap = false
            end)
        end
        local win_h = ok_win and vim.api.nvim_win_get_height(pp.win) or 0
        if old and pic and ok_win and old.pic == pic and old.win == pp.win and old.buf == pp.buf and old.h == win_h then
            -- the same picture in the same panel: put its grid back (the render replaced the lines)
            if pcall(function()
                old.pl:render_placeholder()
            end) then
                if state.preview_desc then
                    require("lvim-picker.media").paint(pp.buf, state.preview_desc)
                end
                return
            end
        end
        if old then
            pcall(function()
                old.pl:close()
            end)
            state.preview_placement = nil
        end
        if state.closed or not (pic and ok_win) then
            return
        end
        local ok, li = pcall(require, "lvim-image")
        if not ok then
            return
        end
        -- the room the picture really has: the window less its number / sign columns, and less the facts above it
        local info = vim.fn.getwininfo(pp.win)[1] or {}
        local head = state.preview_facts or {}
        pcall(function()
            vim.wo[pp.win].wrap = false
        end)
        -- as lvc and lfz draw it: no number column, and the table of facts in the same colours
        for _, o in ipairs({ "number", "relativenumber", "list", "cursorline" }) do
            pcall(function()
                vim.wo[pp.win][o] = false
            end)
        end
        pcall(function()
            vim.wo[pp.win].signcolumn = "no"
        end)
        local info = vim.fn.getwininfo(pp.win)[1] or info
        -- a WIDE, LOW preview (above the dock, or a short dock beside the list): the facts in a column on the
        -- left, the picture beside them — under the facts it would be a strip. The same rule lvc and lfz use
        -- (width >= 60 and at least three times the height).
        local text_w = vim.api.nvim_win_get_width(pp.win) - (info.textoff or 0)
        local side = text_w >= 60 and text_w >= 3 * win_h
        local pl = li.attach(pp.buf, pp.win, pic, {
            header = (not side) and head or nil,
            gutter = side and head or nil,
            center = false,
            max_width = math.max(1, vim.api.nvim_win_get_width(pp.win) - (info.textoff or 0)),
            -- the rows the window has for it — but a window that has not grown to its content yet (this runs
            -- before the panel's relayout) is too short to say: then the rows reserved for it
            max_height = (win_h > (side and 0 or #head) + 1) and math.min((config or {}).picture_rows or 14, win_h)
                or (config or {}).picture_rows or 14,
        })
        if pl then
            state.preview_placement = { pl = pl, pic = pic, win = pp.win, buf = pp.buf, h = win_h }
            -- once the panel has settled (its relayout comes after this), look again: a different height
            -- remakes the picture to fit
            vim.defer_fn(function()
                if state.closed or not state.preview_picture then
                    return
                end
                attach_picture(state.preview_pan or (state.st and state.st.preview_panel))
            end, 80)
            if state.preview_desc then
                require("lvim-picker.media").paint(pp.buf, state.preview_desc)
            end
        end
    end
    function preview_refresh()
        local pp = state.preview_pan or (state.st and state.st.preview_panel)
        if pp and pp.refresh then
            pp.refresh()
        end
        attach_picture(pp)
    end
end
