--- A step of building a finder (the layout blocks, the prompt, the filter bar and `surface.open` itself).
---
--- Every step of `build` runs in the finder's CONTEXT (`ctx`, one table for the whole finder): the step's function environment IS that table, so a
--- name that is not a local of the step is a field of the context — the state, the options, the helpers the other steps define. What used to be a
--- local of the one big `build` function is now a field (`function refit()` here is `ctx.refit` for every step); real globals (`vim`, `pcall` …) are
--- found through the context's metatable. See `lvim-picker.build`.
---@module "lvim-picker.build.surface"

return function(ctx)
    setfenv(1, ctx)

    -- layout: a centred float (default), a "bottom" dock that FLOATS over the bottom rows (statusline
    -- unaffected), or "area" — the Emacs-minibuffer model: it GROWS `cmdheight` like the msgarea cmdline
    -- zone, so a global statusline (heirline) rises ABOVE it. Both bottom/area dock full-width borderless.
    bottom = opts.layout == "bottom"
    area = opts.layout == "area"

    -- (HOSTED area) An `area` finder homes in the msgarea zone via the surface engine's auto-host provider
    -- (position="cmdline" + no explicit host): the zone reserves rows above the messages, the surface follows
    -- the rect, and the engine wires the descend (`on_escape_below`) + release. The picker never references
    -- msgarea; `area` alone gates the `C-j msgs` footer hint below.
    -- preview side: where the preview panel sits relative to the list — `right` / `left` (side by side) or
    -- `dynamic` (a peek FLOAT above a full-width list). Vertical DOCKED stacking is gone: the two panels then
    -- split the dock's rows and neither is readable.
    side = opts.preview_side or (config or {}).preview_side or "right"
    if side == "dynamic" and not (bottom or area) then
        side = "right" -- a centred float has no room above it for the peek; it keeps the preview beside the list
    end
    -- BOTH data panels — the LIST and the PREVIEW — carry the single-source content ring (`surface.CONTENT_BORDER`,
    -- resolved live to `ui_config.content_border` at open time), so they read as two matching nested frames. The
    -- scoped INPUT prompt overlays the list's first (winbar) row but the surface places scoped bands INSIDE the
    -- panel border (`panel_content_rect`, at `row + top_inset`), so the prompt sits within the list ring — it does
    -- not land ON the top border. The NAV bands (footer, search) are bars, not blocks, so they stay borderless.
    pbord = surface.CONTENT_BORDER
    -- The title is the chassis native centered border-title (built from this box); the match counter rides the
    -- border per `counter` (default the bottom-right border-footer). Styled via the picker's `hl` overrides.
    title_box = (opts.title ~= nil and opts.title ~= "")
            and {
                icon = opts.icon,
                text = opts.title,
                style = {
                    icon = { hl = hl("title_icon", "LvimUiPeekTitleIcon") },
                    text = { hl = hl("title", "LvimUiPeekTitle") },
                },
            }
        or nil
    -- Prompt badge (shared `config.prompt`): an icon and/or label on the STRONG tint, then a gap on the LIGHT
    -- input tint before the typed text. Built HERE (before `update_mode`) so a live-grep <C-g> toggle can swap
    -- it — FILTER mode uses `filter_icon`/`filter_label` so the SEARCH BAR itself signals the mode.
    prompt_hl = hl("prompt", "LvimUiPickerPrompt")
    input_hl = hl("input", "LvimUiPickerInput")
    ---@param mode string?  "filter" swaps to the filter badge; anything else = the normal (grep/search) badge
    ---@return table  the prompt chunk list: `{ badge, prompt_hl }` + `{ gap, input_hl }`
    function build_prompt(mode)
        local pcfg = (config or {}).prompt or {}
        local sp = string.rep
        local is_filter = mode == "filter"
        local icon = is_filter and (pcfg.filter_icon or pcfg.icon or "") or (pcfg.icon or "")
        local label = is_filter and (pcfg.filter_label or pcfg.label or "") or (pcfg.label or "")
        local has_icon = icon ~= ""
        local has_label = label ~= ""
        local badge = sp(" ", pcfg.pad_left or 1)
        if has_icon then
            badge = badge .. icon
        end
        if has_icon and has_label then
            badge = badge .. sp(" ", pcfg.icon_gap or 1)
        end
        if has_label then
            badge = badge .. label
        end
        badge = badge .. sp(" ", pcfg.pad_right or 1)
        return { { badge, prompt_hl }, { sp(" ", pcfg.input_gap or 1), input_hl } }
    end
    -- (grep, live only) the Ctrl-g MODE indicator: the TITLE gains "󰅂 filter" AND the SEARCH BAR badge swaps to
    -- the filter badge while rg is frozen (the query fuzzy-filters the loaded results). Applied live via
    -- `set_title` + `set_prompt` (an IN-PLACE repaint — the query text, cursor and on_change are untouched).
    if opts.grep then
        state.update_mode = function()
            if not (state.st and state.st.set_title) then
                return
            end
            -- FILTER mode names what the filter reads (the scope): "Grep 󰅂 Filter · line"
            local sc = state.grep_scope or (config or {}).grep_scope or "line"
            local suffix = (state.grep_mode == "filter") and (" 󰅂 Filter · " .. sc) or ""
            state.st.set_title({
                icon = opts.icon,
                text = (opts.title or "Grep") .. suffix,
                style = {
                    icon = { hl = hl("title_icon", "LvimUiPeekTitleIcon") },
                    text = { hl = hl("title", "LvimUiPeekTitle") },
                },
            })
            if opts.grep.live and state.st.set_prompt and not opts.prompt then -- swap the search-bar badge to match the mode
                state.st.set_prompt(build_prompt(state.grep_mode), prompt_hl, input_hl)
            end
        end
    end
    list_block = {
        id = "list",
        provider = list_provider,
        border = pbord, -- the scoped prompt now sits INSIDE this border (surface panel_content_rect)
        -- 40% width side-by-side (horizontal); in a VERTICAL stack the height carries no weight, so it AUTO-fits
        -- the match count (the surface re-derives the weight per stack axis on rotation).
        size = { width = { fixed = 0.4 } },
        -- `shrink_first`: when a stacked (above/below) area can't hold both panels within the area height cap, the
        -- LIST gives up rows first (it scrolls to the focused line) so the PREVIEW keeps its content-fit height —
        -- PREVIEW PRIORITY (the file you're inspecting stays fully visible; the list scrolls).
        shrink_first = true,
    }
    preview_block = preview_provider and { id = "preview", provider = preview_provider, border = pbord }
    if not preview_block then
        blocks = { list_block }
    elseif side == "left" then
        blocks = { preview_block, list_block }
    else
        blocks = { list_block, preview_block }
    end
    -- SLOT geometry (the float/area/bottom width + height) comes from the CENTRAL authority
    -- (lvim-utils.config.dock.geometry → dock.slot): the surface derives it when we pass NO `size`, so the
    -- picker no longer computes its own. `max_rows` still caps the LIST content height INSIDE the slot
    -- (consumer-internal — not a duplicate size), and the preview side still rotates (C-n/C-p) — only the total
    -- slot height is no longer picker-owned. FORCE — the effective per-layout anchored override: a per-call
    -- `opts.force[layout]` wins, else the plugin's own `config.dock.force[layout]` (empty {} = inherit the central
    -- geometry). Deep-copied so the `opts.height` rows-override (an EXPLICIT per-call size) can win on top. The
    -- resolved slot (`{ height?, width?, height_auto?, width_auto? }`) is passed to the surface as its `slot`
    -- override (wins over the shared geometry for this open only); its `backdrop` goes to the surface `backdrop`
    -- seam below. area/bottom ignore width (full-width), so a forced width there is a no-op — as documented.
    eff_force = (opts.force and opts.force[opts.layout])
        or ((config or {}).dock and config.dock.force and config.dock.force[opts.layout])
    slot_override = eff_force and vim.deepcopy(eff_force) or {}
    if opts.height then
        slot_override.height, slot_override.height_auto = opts.height, false
    end
    if not next(slot_override) then
        slot_override = nil
    end
    -- The prompt badge (built by `build_prompt` above, in the GREP/search variant): a per-call `opts.prompt`
    -- STRING overrides it; a live-grep <C-g> toggle later swaps to the FILTER badge via `state.st.set_prompt`.
    prompt_text = opts.prompt or build_prompt("grep")
    -- The footer legend is MODE-AWARE (`build_footer`, defined near `focus_input`): the finder opens in the
    -- PROMPT, so it starts with the prompt-context hints; `focus_input`/`focus_list` swap it on every switch.
    footer_items = build_footer("prompt")

    -- The header FILTER bar, built through the SHARED filter-group model (lvim-ui.filters) — identical to
    -- the one ui.tabs uses. The picker only supplies the SEMANTICS: the live count (items passing the OTHER
    -- groups AND this button's predicate) and the activation (set_filter). Colours default to LvimUiPeekFilter*.
    ---@return table  the header bar band spec handed to the surface
    function build_filter_bar()
        local fb = ui_filters.bar(filters, {
            count = function(g, b)
                local n = 0
                for _, it in ipairs(items) do
                    if passes_filters(it._src, g) and (not b.predicate or b.predicate(it._src)) then
                        n = n + 1
                    end
                end
                return n
            end,
            on_select = set_filter,
        })
        state.sync_filter = fb.sync
        return fb.band
    end

    -- (HOSTED area) When the msgarea zone is enabled, a `position = "cmdline"` finder auto-homes in the zone —
    -- the surface ENGINE creates the reserve (priority 5, ABOVE the messages that compose below), owns the
    -- height (clamped to `max_height * rows`), wires the descend + reflow-follow, and bumps the zindex above the
    -- zone. We only ask for the cmdline dock; no `host` is passed. Zone off → the surface grows cmdheight itself.
    surface.open({
        mode = "float",
        -- "area" sits IN the cmdline region (grows cmdheight, heirline above) like the msgarea zone; "bottom"
        -- just floats over the bottom rows. When the msgarea zone is on, the engine re-homes us INSIDE it.
        position = area and "cmdline" or (bottom and "bottom") or nil,
        -- (HOSTED) <C-j> off the bottom sector descends INTO the messages composed below — wired by the surface
        -- auto-host provider (its `on_escape_below` = the zone's focus_messages); the picker no longer sets it.
        -- <C-k> off the TOP sector (the header/filter bar) leaves the finder UP to the editor it opened from,
        -- instead of wrapping down to the footer.
        on_escape_above = function()
            if opener and api.nvim_win_is_valid(opener) then
                api.nvim_set_current_win(opener)
            end
        end,
        -- HOSTED: float ABOVE the msgarea zone's own content panel (container 200 / panel 201) so our list /
        -- preview aren't covered by it — our panels land at 211, the prompt at 212, all clear of the messages
        -- that render in the zone panel BELOW us. Unhosted area stays in the cmdline layer at 200.
        -- Unhosted area sits in the cmdline layer at 200; when the engine auto-hosts (msgarea on) it FORCES
        -- 210 (above the zone's own panels), so this base only applies to the zone-off case.
        zindex = area and 200 or nil,
        header_air = false, -- no LEADING air row; the filter bar (or the input prompt) is the top content row
        preview_side = preview_provider and side or nil, -- so the surface can rotate the preview live (C-n/C-p)
        scrollbar = (function() -- the thumbs beside the list and the preview: this call's, else the picker's, else the chassis' (nil)
            if opts.scrollbar ~= nil then
                return opts.scrollbar
            end
            return config.scrollbar
        end)(),
        lock_keys = true, -- modal list: only the bound keys act; every other key is a no-op (the editable preview is exempt)
        title = title_box, -- the chassis native centered border-title
        title_line = opts.title_line, -- title placement: "row" (default) | "statusline" (chassis overlay) | "border" (opt-in)
        title_pos = opts.title_pos or config.title_pos, -- alignment — ONE config value for every layout
        count = count_fn, -- the live match / pool count → the chassis border counter (default bottom-right footer)
        counter = opts.counter, -- count placement: "footer" (default) | "title"
        -- The container border is CONFIG-DRIVEN on EVERY layout (float + docked) — `surface.FRAME_BORDER`
        -- resolves LIVE to `ui_config.border`, so there is NO hardcoded per-layout border. Each content block
        -- carries its OWN ring (CONTENT_BORDER); the chassis draws the configurable inter-panel divider
        -- (`ui_config.separator`) BETWEEN the list and preview — auto-oriented, only at the gap, so a SINGLE
        -- panel (preview hidden / no preview) shows none.
        border = surface.FRAME_BORDER,
        -- No `size`: the surface derives the slot from the central geometry (dock.slot) when none is passed.
        -- `slot` is the optional per-open anchored override (force + a rows `opts.height` for a docked layout).
        slot = slot_override,
        -- FORCE backdrop: the surface's own backdrop seam (merged over the central `dock.geometry.<layout>.backdrop`
        -- inside dock.slot). nil = inherit the central default; a `force[layout].backdrop` table/false wins here.
        backdrop = eff_force and eff_force.backdrop,
        header = {
            bars = (function()
                local hb = {}
                -- The title + counter are the chassis border-title / border-counter (no CONTENT title row). The
                -- header bars are the filter bar (when any) + the scoped input prompt.
                if filters then
                    hb[#hb + 1] = build_filter_bar() -- a real header row above the prompt
                    hb[#hb + 1] = { text = "" } -- 1 blank air row under the filter (button) bar
                end
                hb[#hb + 1] = {
                    input = true,
                    prompt = prompt_text,
                    placeholder = opts.placeholder,
                    prompt_hl = prompt_hl,
                    input_hl = input_hl,
                    filetype = "lvim-picker-prompt",
                    -- scope the prompt to the LIST panel (by id, so it tracks it through every preview rotation):
                    -- the input always sits just above the list, never over the preview.
                    scope_id = preview_provider and "list" or nil,
                    on_change = refilter_debounced,
                    keys = function(buf, st)
                        state.st = st
                        state.input_buf = buf -- so NORMAL-mode list can jump back to typing (focus_input)
                        -- a fixed-query grep opens in FILTER mode: show its scope in the title from the start
                        if opts.grep and state.grep_mode == "filter" and state.update_mode then
                            vim.schedule(state.update_mode)
                        end
                        -- the typed-text caret (config.caret). Through the
                        -- cursor module so it coexists with cursor-hiding; cleared on close.
                        pcall(require("lvim-utils.cursor").mark_cursor_buffer, buf, source.caret_fragment("i-ci-ve"))
                        local function imap(lhs, fn)
                            vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
                        end
                        -- open in a split while typing (config.keys.open_methods.<method>.i — Ctrl chords)
                        for method, m in pairs({ vsplit = "vsplit", hsplit = "split" }) do
                            local km = (kcfg.open_methods or {})[method]
                            if type(km) == "table" and km.i then
                                for _, k in ipairs(keylist(km.i)) do
                                    imap(k, function()
                                        vim.cmd("stopinsert")
                                        confirm(m)
                                    end)
                                end
                            end
                        end
                        imap("<C-j>", function()
                            move(1)
                        end)
                        imap("<Down>", function()
                            move(1)
                        end)
                        imap("<C-k>", function()
                            move(-1)
                        end)
                        imap("<Up>", function()
                            move(-1)
                        end)
                        imap("<C-d>", function()
                            scroll_preview(1)
                        end)
                        imap("<C-u>", function()
                            scroll_preview(-1)
                        end)
                        -- … and one line at a time
                        for _, k in ipairs(keylist(kcfg.preview_line_down)) do
                            imap(k, function()
                                scroll_preview(1, true)
                            end)
                        end
                        for _, k in ipairs(keylist(kcfg.preview_line_up)) do
                            imap(k, function()
                                scroll_preview(-1, true)
                            end)
                        end
                        -- turn / hide the preview from the query too (the list has the surface's own keys)
                        local function turn(dir)
                            return function()
                                vim.cmd("stopinsert") -- the rotation hands the focus to the list (normal mode)
                                local st = state.st
                                if st and st.rotate_preview then
                                    st.rotate_preview(dir)
                                end
                            end
                        end
                        for _, k in ipairs(keylist(kcfg.preview_next)) do
                            imap(k, turn(1))
                        end
                        for _, k in ipairs(keylist(kcfg.preview_prev)) do
                            imap(k, turn(-1))
                        end
                        for _, k in ipairs(keylist(kcfg.preview_toggle)) do
                            imap(k, function()
                                vim.cmd("stopinsert")
                                local st = state.st
                                if st and st.toggle_preview then
                                    st.toggle_preview()
                                end
                            end)
                        end
                        imap("<CR>", function()
                            vim.cmd("stopinsert")
                            confirm()
                        end)
                        imap("<C-c>", cancel) -- hard cancel from the prompt
                        -- (grep) Ctrl-g: toggle GREP ⇄ FILTER mode (drive rg vs fuzzy-filter the loaded blob).
                        if grep_toggle then
                            for _, k in ipairs(keylist(kcfg.grep_filter)) do
                                imap(k, grep_toggle)
                            end
                        end
                        if scope_toggle then
                            for _, k in ipairs(keylist(kcfg.grep_scope)) do
                                imap(k, scope_toggle)
                            end
                        end
                        -- <Esc> / <C-f> drop to NORMAL on the list (where the filter hotkeys
                        -- activate directly — typing in INSERT would feed them to the query). <C-f> in normal
                        -- toggles back to typing.
                        imap("<Esc>", focus_list)
                        imap("<C-f>", focus_list)
                        -- consumer row actions: `opts.keys = { { key = lhs, run = fn(item, close) } }` — e.g.
                        -- open in a split, run a code action, yank. `run` gets the selected item + a close fn.
                        for _, a in ipairs(opts.keys or {}) do
                            -- Honour `mode`: a consumer that declared `mode = "n"` (e.g. lvim-space's <BS> =
                            -- "step back to the panel") means the LIST only — binding it here stole <BS> from the
                            -- query, so a backspace left insert mode instead of deleting a character.
                            if a.mode ~= "n" then
                                imap(a.key, function()
                                    -- `keep_insert`: an action that leaves the finder where it is (a step through
                                    -- the list) keeps the query typing; anything else leaves insert first
                                    if not a.keep_insert then
                                        vim.cmd("stopinsert")
                                    end
                                    act(a.run)
                                end)
                            end
                        end
                    end,
                }
                return hb
            end)(),
        },
        content = { blocks = blocks },
        footer = {
            bars = {
                {
                    items = footer_items,
                },
            },
        },
        close_keys = {}, -- the input owns <Esc>/<C-c>; the panels are not normally focused
        on_close = function()
            state.closed = true
            if state.preview_placement then -- the picture of an image preview goes with the picker
                pcall(function()
                    state.preview_placement.pl:close()
                end)
                state.preview_placement = nil
            end
            -- Dismissed externally (replaced by the next finder via the shared registry, or a surface-owned
            -- close) with no confirm / cancel / row action having run → treat it as a cancel so restore-on-cancel
            -- finders (e.g. colorschemes) are not silently skipped. `confirm`/`cancel`/`act` set `state.handled`.
            if not state.handled and opts.on_cancel then
                pcall(opts.on_cancel)
            end
            if opts.on_close then -- a finder's own teardown hook (e.g. live grep killing its in-flight rg)
                pcall(opts.on_close)
            end
            pcall(function()
                require("lvim-hud.overlay").clear()
            end) -- idempotent: drop the chrome-overlay title/counter if `title_line="statusline"` published it
            if state.stream_cancel then -- kill a still-running async producer (e.g. `fd` over a huge tree)
                pcall(state.stream_cancel)
                state.stream_cancel = nil
            end
            if state.count_cancel then -- kill the background grep file-count (fd) if still running
                pcall(state.count_cancel)
                state.count_cancel = nil
            end
            if state.grep_stop then -- kill an in-flight grep rg (the controller's live/fixed producer)
                pcall(state.grep_stop)
            end
            release_run(state, items) -- drop THIS run's cached candidate texts + prepared fuzzy context (not another live finder's)
            if state.blob then -- free the native blob-stream pool (a huge tree's SoA reclaimed eagerly)
                fuzzy.blob_free(state.blob)
                state.blob = nil
                state.src_cache = nil
            end
            if state.input_buf then -- drop the custom blue caret registration (cursor module restores normal)
                pcall(require("lvim-utils.cursor").mark_cursor_buffer, state.input_buf, nil)
            end
            source.clear_active(active_entry) -- forget the current finder once it closes (only if it is still us)
            -- (the engine releases its own auto-host msgarea segment on surface close — nothing to do here)
            if state.live_augroup then
                pcall(api.nvim_del_augroup_by_id, state.live_augroup)
                state.live_augroup = nil
            end
            -- DOCK bookkeeping. A DOCK-DRIVEN teardown (`state.dock_teardown` — a park via `hide`, or a kill via
            -- `close`) is silent: it must NOT re-notify the dock (it drove this) and must NOT forget the opts (a
            -- park keeps them; `close` already cleared them). A SELF / EXTERNAL close (a confirm / cancel / `:q`)
            -- means the finder is DONE — forget it and tell the dock to DROP the entry (without revealing another;
            -- focus returns to the editor the finder opened from, so a confirm's own file-open lands there).
            if sk then
                if not state.dock_teardown then
                    -- PARK + REMEMBER: a self / external close (confirm / cancel / q / :q, or replaced by
                    -- another finder) KEEPS the remembered rebuild (`pending[sk]`) so the entry stays alive —
                    -- cyclable with <Leader>n/p and listed in the <Leader>m menu — and only COLLAPSES the layout
                    -- (no neighbour revealed, focus returns to the editor). Only `<Leader>x` (dock M.close →
                    -- consumer.close) truly forgets the rebuild + drops the entry from the stack. Pass the STORED
                    -- dock entry KEY (id, layout), not a reconstructed one.
                    local d = get_dock()
                    if d and entry_keys[sk] then
                        pcall(d.parked, entry_keys[sk])
                    end
                end
                if live[sk] == state then
                    live[sk] = nil
                end
            end
        end,
    })
end
