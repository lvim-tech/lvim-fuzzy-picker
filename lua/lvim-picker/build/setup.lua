--- A step of building a finder (the finder's state, its options resolved (layout, filters, icons), the forward names the later steps assign).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.setup"

return function(ctx)
    setfenv(1, ctx)
    opts = opts or {}
    -- Default the LAYOUT from `config.layout` (default "area") when the caller gave none — so every
    -- finder + `:LvimPicker <finder>` lands in the configured layout unless overridden per call.
    opts.layout = opts.layout or (config or {}).layout or "area"
    -- The (kind, layout) slot key this managed open files its state under (nil ⇒ un-managed).
    sk = kind and slot_key(kind, opts.layout) or nil
    -- UN-MANAGED only: a finder already open? Close it FIRST via the shared registry so this
    -- open replaces it in place. In the MANAGED path the DOCK enforces one-visible-per-layout — it has already
    -- PARKED the previous consumer (keeping it on the stack), so we must NOT destroy it here.
    if not kind then
        source.close_active()
    end
    surface = require("lvim-ui.surface")
    items = normalize(opts.items, opts.format)
    -- No local cap by default: the panel content-fits and the CENTRAL dock geometry height caps it (the chassis
    -- clamps `auto` sizing to `dock.geometry.<layout>.height`). A number here (config or per call) is a
    -- deliberate LOCAL limit under that ceiling. `math.huge` would break `math.min` on integers, so use the
    -- screen height as the "no cap" value — the chassis clamps it down anyway.
    maxr = opts.max_rows or config.max_rows or vim.o.lines
    state = {
        filtered = items,
        sel = 1,
        -- Logical index of the FIRST rendered list row (viewport virtualization): the list buffer holds only
        -- the visible window (+ a small margin), never all filtered rows — see the viewport block below.
        view_top = 1,
        list_pan = nil,
        preview_pan = nil,
        st = nil,
        closed = false,
        -- The outcome was already delivered (confirm / cancel / a row action). While this stays false at close
        -- time the finder was dismissed externally (replaced by the next finder), which on_close treats as a
        -- cancel — so restore-on-cancel finders (colorschemes) still fire.
        handled = false,
        query = "",
        marked = {},
    }
    -- this finder's entry in the shared "open finder" registry (so the next open closes us first)
    active_entry = {
        close = function()
            if not state.closed and state.st then
                pcall(state.st.close)
            end
        end,
    }
    opener = api.nvim_get_current_win() -- the editor window the finder opened from (for the top-edge escape)

    -- Every highlight group is configurable + shared via `config.hl` (fall back to the built-in
    -- tint-canon / peek groups).
    pkcfg = config or {}
    phl = pkcfg.hl or {}
    function hl(key, default)
        return phl[key] or default
    end
    -- The mark for text scrolled out of a row's left edge; false switches the scrolling off.
    clip_ellipsis = opts.list_clip
    if clip_ellipsis == nil then
        clip_ellipsis = pkcfg.list_clip
    end
    empty_text = opts.empty_text or pkcfg.empty_text or "[no matches]"
    empty_preview = opts.empty_preview or pkcfg.empty_preview or "Nothing to preview"
    prevcfg = pkcfg.preview or {}
    -- list wrap: per-call `opts.list_wrap` wins; else the shared `config.list_wrap`.
    list_wrap = opts.list_wrap
    if list_wrap == nil then
        list_wrap = pkcfg.list_wrap == true
    end

    -- FILTER bars (optional): `opts.filters` is a list of GROUPS, each `{ buttons = { { id, label, key?,
    -- predicate?(src), hl?, hl_active? }, … }, active }`. An item is kept only if it passes EVERY group's
    -- active button predicate; the surviving pool is then fuzzy-filtered by the query. Header buttons toggle
    -- the active button live (see build_filter_bar / set_filter). `set_filter` is assigned after `refilter`.
    filters = opts.filters
    ---@type fun(gi: integer, id: string)
    function active_button(g)
        for _, b in ipairs(g.buttons) do
            if b.id == g.active then
                return b
            end
        end
        return g.buttons[1]
    end
    --- True when `src` passes every group's active predicate (optionally skipping `except`).
    ---@param src any
    ---@param except? table
    ---@return boolean
    function passes_filters(src, except)
        for _, g in ipairs(filters or {}) do
            if g ~= except then
                local b = active_button(g)
                if b and b.predicate and not b.predicate(src) then
                    return false
                end
            end
        end
        return true
    end
end
