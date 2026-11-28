-- lvim-picker: the native fuzzy-finder — the tint-striped Lua list plus the ready-made finders.
-- A native fuzzy finder built on the lvim-ui.surface chassis: a centred float with a typed query
-- INPUT band on top (a surface header input), a results LIST panel on the left and a scrollable PREVIEW
-- panel on the right — the diagnostics-peek layout, but fuzzy. The MATCHING ENGINE is lvim-fuzzy — the
-- shared native engine of the lvim-tech set (lvim-fuzzy-core in-process through FFI, the same as the
-- terminal finder; fzf's query syntax): the candidate set is prepared once per pool (a stream-grown pool
-- appends only its tail), each keystroke is one match call, and the surface renders the result. So ranking
-- is lvim-fuzzy's exactly while WE own the view (engine vs view, like the blink integration). Highlight
-- positions come from the engine too, for the visible rows only, so the matched characters light up in the
-- list. The LIST is viewport-virtualized: the buffer holds only the visible window of rows, so a
-- render is O(viewport) at any scale (see the viewport block in `build`).
--
---@module "lvim-picker"

local api = vim.api
local config = require("lvim-picker.config")
local fuzzy = require("lvim-picker.fuzzy")
local utils = require("lvim-utils.utils")
local iconlib = require("lvim-utils.icons")
local ui_filters = require("lvim-ui.filters")
local preview = require("lvim-ui.preview")
-- The listing commands / preview readers / async streamers live in picker.source (what they list and ignore
-- is `config.source`). Aliased as locals to keep the call sites short.
local rows = require("lvim-picker.rows")
local normalize, row_uses_rg_pattern, clip_row, list_row, preview_matches = rows.normalize, rows.row_uses_rg_pattern, rows.clip_row, rows.list_row, rows.preview_matches
local source = require("lvim-picker.source")
local scope = require("lvim-picker.scope")
local has = source.has
local file_list_cmd = source.file_list_cmd
local dir_list_cmd = source.dir_list_cmd
local read_preview = source.read_preview
local run_lines = source.run_lines
local spawn_stream = source.spawn_stream
local spawn_stream_raw = source.spawn_stream_raw

--- How many lines a location/grep preview must read to always include the FOCUS line: the default 500 cap
--- plus a screenful of context below it, so a match DEEP in a large file previews at the right spot instead of
--- clamping to line 500 (the focus is otherwise `min(lnum, 500)`).
---@param lnum integer?
---@return integer
local function preview_span(lnum)
    return math.max(500, (lnum or 0) + 200)
end

local M = {}

--- Open a finder over a Lua list of ITEMS (buffers, recent files, marks, quickfix, …) with its own preview
--- and callbacks; `opts` (the caller's per-call options) win over the spec.
---@param spec { title: string, items: table[], preview?: function, preview_file_of?: function, on_confirm?: function, on_cancel?: function, opts?: table }
local function pick_items(spec)
    local items = spec.items or {}
    M.open(vim.tbl_extend("force", {
        title = spec.title,
        items = items,
        preview = spec.preview,
        preview_file_of = spec.preview_file_of, -- the tint list's async file preview, when the finder has one
        on_confirm = spec.on_confirm,
        on_cancel = spec.on_cancel,
    }, spec.opts or {}))
end

local NS = api.nvim_create_namespace("lvim-utils-picker")


-- Single-slot cache of the candidate `texts` array, keyed by the pool table + its length: the query changes
-- on every keystroke but the candidate set does NOT, so rebuild this (and, downstream, fzf's stdin) only when
-- the pool actually changes — appended (stream → length grows), replaced (refresh → new ref) or narrowed (a
-- filter → new ref). This keeps per-keystroke work O(1) over a huge list.
---@type { pool: table[], len: integer, texts: string[] }?
local _texts_cache
--- Filter `items` (normalised `{ text, icon?, _src }`) by `query` via the shared fuzzy engine and hand the
--- ranked GRID items (`{ text, icon, icon_hl, _src, match }`) to `cb`. Empty query = all, source order.
---@param items table[]
---@param query string
---@param cb fun(list: table[])
local function filter(items, query, cb)
    local texts
    if _texts_cache and _texts_cache.pool == items then
        texts = _texts_cache.texts
        if _texts_cache.len < #items then
            -- the SAME pool grew (stream feed) — EXTEND the cached array (O(new)) instead of rebuilding it
            -- (O(all)) on every chunk; otherwise the open freezes as the list approaches its full size.
            for i = _texts_cache.len + 1, #items do
                texts[i] = items[i].text
            end
            _texts_cache.len = #items
        elseif _texts_cache.len > #items then
            texts = nil -- shrank (not expected for a stream) — rebuild below
        end
    end
    if not texts then
        texts = {}
        for i, it in ipairs(items) do
            texts[i] = it.text
        end
        _texts_cache = { pool = items, len = #items, texts = texts }
    end
    fuzzy.filter(texts, query, function(ranked)
        local out = {}
        for i, r in ipairs(ranked) do
            local it = items[r.idx]
            out[i] = { text = it.text, icon = it.icon, icon_hl = it.icon_hl, _src = it._src, match = r.match }
        end
        cb(out)
    end)
end

--- Drop the candidate-text cache + the prepared fuzzy context of a CLOSING finder — only when they are ITS
--- (its normalised `items` or its filter-narrowed pool). The cache is module-level (one slot), so a finder
--- closing while ANOTHER is live (a second layout — the dock holds several) used to release the live one's
--- context, and its next keystroke re-prepared the whole pool.
---@param state table   the closing finder's state (`filter_pool` = its narrowed pool, when filters exist)
---@param items table[] the closing finder's normalised item list
local function release_run(state, items)
    local c = _texts_cache
    if c and (c.pool == items or c.pool == state.filter_pool) then
        fuzzy.release(c.texts)
        _texts_cache = nil
    end
end
M._filter, M._release_run = filter, release_run
M._texts_pool = function()
    return _texts_cache and _texts_cache.pool or nil
end

M._row_uses_rg_pattern = rows.row_uses_rg_pattern



M._preview_matches = rows.preview_matches -- internal test seam

-- ─── dock-stack integration (lvim-utils.dock) ──────────────────────────────────
-- Each opened finder KIND is an entry in the shared DOCK-STACK manager, whose base identity is
-- `id = "lvim-picker:<kind>"` — so `files` ≠ `grep` ≠ `buffers` stack as distinct instances, one visible
-- at a time, cyclable with `<Leader>n`/`<Leader>p`, killable with `<Leader>x`, listed in the `<Leader>m`
-- menu. The dock keys every entry by (id, LAYOUT), so the SAME kind opened in a DIFFERENT layout is a
-- SEPARATE entry with its OWN surface: `files` can be docked in float AND bottom AND area at once (one entry
-- per stack). All open-state is therefore kept PER (kind, layout) under a composite SLOT KEY. Re-opening the
-- SAME (kind, layout) RE-SHOWS that one entry (dedup) — since a finder has no meaningful "parked query", the
-- re-show REBUILDS that kind fresh in place (still the single entry for that (kind, layout)).
--
-- A (kind, layout) slot is remembered by a `rebuild` CLOSURE (`pending[sk]`) that re-materialises THAT slot's
-- surface (`build(opts, kind)`). `route(managed, kind, layout, meta, rebuild, slot)`
-- does the managed wiring (remember the rebuild, refresh the consumer's name / icon / anchored force slot,
-- `dock.open` — STORING the returned entry key in `entry_keys[sk]`) or, when un-managed (no manager / no key /
-- `dock_stack = false`), just calls `rebuild()` directly (the classic
-- `source.close_active` replace-in-place). The consumer's `show` runs the remembered `rebuild`, `hide` parks
-- the live surface (close it, KEEP the rebuild → restorable). A NATURAL close (confirm / cancel / q / :q, or
-- replaced) also PARKS + REMEMBERS (via `dock.parked(entry_keys[sk])`): the entry stays alive, cyclable and in
-- the `<Leader>m` menu — only `<Leader>x` (the consumer's `close`) forgets the rebuild + drops it. The live
-- surface `state` is exposed via `live[sk]` (`.st` / `.input_buf` / `.list_pan` / `.preview_pan`), so the
-- consumer's `buffers` / `focus` / `is_current` read it.

---@type table|false|nil  cached lvim-utils.dock module (nil = unprobed, false = probed & absent)
local dock_mod = nil
--- The dock-stack manager, or nil when unavailable — then the picker docks directly, un-managed.
---@return table?
local function get_dock()
    if dock_mod == nil then
        local ok, m = pcall(require, "lvim-utils.dock")
        dock_mod = ok and m or false
    end
    return dock_mod or nil
end

-- ── per-(kind, layout) state ─────────────────────────────────────────────────
-- The dock keys every entry by (id, LAYOUT): the SAME finder KIND opened in a DIFFERENT layout is a
-- SEPARATE dock entry with its OWN surface — so `files` can be docked in float AND bottom AND area at once,
-- three live entries. Every piece of open-state is therefore kept PER (kind, layout), under a composite
-- SLOT KEY `kind .. SK_SEP .. layout` (a re-open of the SAME (kind, layout) re-uses the slot → one entry per
-- stack, never a duplicate). `id` stays the base identity ("lvim-picker:<kind>") — layout is NOT baked into it;
-- the dock composes the (id, layout) entry key and RETURNS it, which we STORE in `entry_keys[sk]` and pass
-- back to the lifecycle APIs (`parked`/`refresh_leader`/`dropped`) for THIS entry.
local SK_SEP = "\30"
--- Compose the per-(kind, layout) slot key.
---@param kind string
---@param layout string
---@return string
local function slot_key(kind, layout)
    return kind .. SK_SEP .. layout
end
---@type table<string, table>   slot key → the memoised LvimDockConsumer handle (one per (kind, layout))
local consumers = {}
---@type table<string, fun()>   slot key → the REBUILD closure that re-materialises that finder on show; nil =
--- forgotten/dead (the dock's `is_alive` reads this).
local pending = {}
---@type table<string, table>   slot key → the live surface `state` while it exists (nil = parked); the consumer
--- reads `.st` / `.list_pan` / `.preview_pan` / `.input_buf`.
local live = {}
---@type table<string, string>  slot key → the dock ENTRY KEY (id, layout) returned by `dock.open` — passed back
--- to the lifecycle APIs (`parked`/`refresh_leader`/`dropped`) for THIS entry (never a reconstructed key).
local entry_keys = {}

--- Human label + Nerd glyph per built-in finder kind — the entry name + the `<Leader>m` dock-menu row icon.
---@type table<string, { name: string, icon: string }>
local KIND_META = {
    files = { name = "Files", icon = "󰈔" },
    grep = { name = "Grep", icon = "󰊄" },
    grep_cword = { name = "Grep (word)", icon = "󰊄" },
    grep_cWORD = { name = "Grep (WORD)", icon = "󰊄" },
    grep_word = { name = "Grep (prompt)", icon = "󰊄" },
    grep_visual = { name = "Grep (selection)", icon = "󰊄" },
    grep_curbuf = { name = "Grep (buffer)", icon = "󰊄" },
    buffers = { name = "Buffers", icon = "󰓩" },
    directories = { name = "Directories", icon = "󰉋" },
    git_files = { name = "Git files", icon = "󰊢" },
    oldfiles = { name = "Recent", icon = "󰋚" },
    help_tags = { name = "Help", icon = "󰋖" },
    commands = { name = "Commands", icon = "󰘳" },
    keymaps = { name = "Keymaps", icon = "󰌌" },
    marks = { name = "Marks", icon = "󰃀" },
    quickfix = { name = "Quickfix", icon = "󰁨" },
    jumplist = { name = "Jumplist", icon = "󰆾" },
    colorschemes = { name = "Colorschemes", icon = "󰏘" },
}

-- forward declaration: `build` constructs the finder surface; a consumer's `show` calls it to materialise a kind
local build
--- The steps of building a finder, in order: each is `lua/lvim-picker/build/<name>.lua` and runs in the finder's context.
local BUILD_STEPS = { "setup", "picture", "list", "providers", "preview", "filter", "actions", "surface", "start" }

--- Resolve the dock KIND key for a finder open: an explicit `opts.key` wins; else a stable slug from the title;
--- else nil (no stable identity ⇒ un-managed, so it docks directly rather than force a bad key).
---@param opts { key?: string, title?: string }
---@return string?
local function resolve_key(opts)
    if type(opts.key) == "string" and opts.key ~= "" then
        return opts.key
    end
    local title = opts.title
    if type(title) == "string" and title ~= "" then
        local slug = title:lower():gsub("%s+", "-"):gsub("[^%w%-_]", "")
        if slug ~= "" then
            return slug
        end
    end
    return nil
end

--- The live surface buffers of slot `sk` (input / list / preview / container) — where the dock installs its
--- buffer-local `<Leader>` owner. Empty when the slot is parked (no live surface).
---@param sk string  the (kind, layout) slot key
---@return integer[]
local function kind_buffers(sk)
    local st = live[sk]
    if not st then
        return {}
    end
    local out = {}
    local function add(b)
        if b and api.nvim_buf_is_valid(b) then
            out[#out + 1] = b
        end
    end
    add(st.input_buf) -- the query INPUT band buffer
    add(st.list_pan and st.list_pan.buf)
    add(st.preview_pan and st.preview_pan.buf)
    add(st.st and st.st.container_buf)
    return out
end

--- Every live window of slot `sk`'s surface (container / content panels / input band) — for `is_current`.
---@param sk string  the (kind, layout) slot key
---@return integer[]
local function kind_windows(sk)
    local st = live[sk]
    if not st then
        return {}
    end
    local out = {}
    local function add(w)
        if w and w ~= -1 and api.nvim_win_is_valid(w) then
            out[#out + 1] = w
        end
    end
    local s = st.st
    if s then
        add(s.container_win)
        for _, p in ipairs(s.panels or {}) do
            add(p.win)
        end
    end
    if st.input_buf then
        add(vim.fn.bufwinid(st.input_buf))
    end
    return out
end

--- Build (once, memoised in `consumers[sk]`) + return the dock consumer for finder `kind` in `layout`. There is
--- ONE consumer PER (kind, layout): `id` is the
--- UNCHANGED base identity (`"lvim-picker:"..kind`) — the dock composes the (id, layout) entry key — and
--- `layout` is FIXED for this slot, so opening `files` in float and `files` in bottom are two independent
--- consumers / surfaces / dock entries. `show` runs this slot's remembered `rebuild` (tearing down any surface
--- still live in this slot first, so a re-open rebuilds fresh — one entry per (kind, layout)); `hide` PARKS
--- (close the surface, KEEP the rebuild → restorable); `close` tears it down AND forgets the rebuild (dropped
--- from the stack); `is_alive` tracks whether the rebuild is still remembered.
---@param kind string
---@param layout string  "float" | "area" | "bottom" — the layout THIS consumer occupies (fixed)
---@return table  the LvimDockConsumer handle
local function get_consumer(kind, layout)
    local sk = slot_key(kind, layout)
    local c = consumers[sk]
    if c then
        return c
    end
    local id = "lvim-picker:" .. kind -- base identity, UNCHANGED across layouts — the dock keys the entry by (id, layout)
    --- Close the live surface of this slot as a DOCK-DRIVEN teardown: flag `dock_teardown` so the finder's
    --- `on_close` neither re-notifies the dock nor forgets the opts, then close it.
    local function teardown_surface()
        local st = live[sk]
        if st and st.st then
            st.dock_teardown = true
            pcall(st.st.close)
        end
    end
    c = {
        id = id,
        name = kind,
        layout = layout, -- which stack THIS entry joins (fixed for this per-(kind, layout) consumer)
        show = function()
            local rebuild = pending[sk]
            if not rebuild then
                return
            end
            teardown_surface() -- a re-open of the visible slot rebuilds fresh in place
            rebuild() -- the finder's `build(opts, kind)`
        end,
        hide = teardown_surface, -- PARK: close the surface, KEEP the rebuild (restorable on the stack)
        close = function()
            teardown_surface()
            pending[sk] = nil -- FORGET the rebuild → is_alive false → dropped from the stack
            live[sk] = nil
            entry_keys[sk] = nil
        end,
        is_alive = function()
            return pending[sk] ~= nil
        end,
        focus = function()
            local st = live[sk]
            if not st then
                return
            end
            -- a finder may register its own `dock_focus`; else focus its INPUT band (or the container)
            if st.dock_focus then
                pcall(st.dock_focus)
                return
            end
            local w = st.input_buf and vim.fn.bufwinid(st.input_buf) or -1
            if w == -1 and st.st and st.st.container_win and api.nvim_win_is_valid(st.st.container_win) then
                w = st.st.container_win
            end
            if w ~= -1 and api.nvim_win_is_valid(w) then
                pcall(api.nvim_set_current_win, w)
            end
        end,
        buffers = function()
            return kind_buffers(sk)
        end,
        is_current = function()
            local cur = api.nvim_get_current_win()
            for _, w in ipairs(kind_windows(sk)) do
                if w == cur then
                    return true
                end
            end
            return false
        end,
    }
    consumers[sk] = c
    return c
end

---@class LvimPickerGrepSpec
---@field live boolean  true = the typed query DRIVES rg (re-grep per keystroke); false = a one-shot fixed-query grep
---@field query? string  the fixed rg query (when `live = false`) — grepped ONCE, then the typed query fuzzy-filters the blob
---@field regex? boolean  treat the query as a regex (default false = literal `--fixed-strings`)
---@field file? string  restrict the search to this single file (the curbuf grep)
---@field min_chars? integer  minimum typed chars before a live grep runs rg (default 2 — rg over a huge tree is heavy)

---@class LvimPickerOpts
---@field items? any[]  STATIC candidates (strings, or tables — see `format`), fuzzy-filtered as you type
--- A table item may also carry `icon` / `icon_hl`, `hl_spans` (`{ c0, c1, hl }` byte ranges of its display text
--- to colour, e.g. aligned columns), `match_bytes` (`{ c0, c1 }` ranges marked as the match while no query is
--- typed) and `locator_bytes` (how many leading bytes of its text a long row never scrolls away).
---@field source? fun(query: string, cb: fun(items: any[]))  a LIVE source: each query produces the results (e.g. ripgrep); use instead of `items`
---@field source_raw? boolean  the `source` cb already delivers GRID items (`{ text, _src, … }`), so skip normalising them — for a progressive source that appends into one growing list (live grep)
---@field count_files? boolean  count the tree's files in the background (via the files list command) and use it as the counter's TOTAL — grep shows `matches found / total files`
---@field stream? fun(feed: fun(raw: any[]), done: fun()): fun()  an ASYNC streaming producer (e.g. `fd`): feeds candidates in incrementally; returns a cancel fn
---@field blob_stream? fun(feed_bytes: fun(data: string), done: fun()): fun()  a RAW-BYTE streaming producer (GAP-5): feeds stdout chunks straight to the native matcher (no Lua per-row work); needs `blob_item`; requires ABI ≥ 5
---@field blob_item? fun(text: string): table  derive a candidate's `_src` item from its text (path) for the blob-stream path (e.g. `function(t) return { path = t } end`)
---@field grep? LvimPickerGrepSpec  the GREP controller (Variant B): hold ALL rg matches in the native blob; the MODE (grep|filter) decides whether the typed query drives rg or fuzzy-filters the frozen blob; requires ABI ≥ 5
---@field on_confirm fun(item: any)  called with the chosen item's source value
---@field on_cancel? fun()  called when the finder is dismissed without a choice (incl. replaced by the next finder)
---@field replace_before_close? boolean  run on_confirm/on_cancel/row-actions BEFORE closing the finder — the callback re-opens a dock in THIS finder's area zone, so its `surface.open` evicts the finder in the background (after the new windows hold focus) instead of a focus-fall to the editor. The finder's own close after is a no-op. Set by lvim-space search.
---@field on_close? fun()  finder-owned teardown run on close (e.g. a live source killing its in-flight process)
---@field format? fun(item: any): string  display text for a table item (default: `item.text`)
---@field preview? fun(item: any): string[], string?, integer?  preview lines (+ a filetype, + a 1-based focus line) per selection (SYNCHRONOUS, in-memory finders)
---@field preview_async? fun(item: any, cb: fun(lines: string[], ft: string?))  an ASYNC text preview per selection (a command's output): the preview shows "…" until `cb` is called; answers are remembered per item
---@field preview_file_of? fun(item: any): { path: string, lnum?: integer, col?: integer, ft?: string }?  map an item to a FILE location previewed ASYNC (read off the main thread, LRU-cached) so the preview follows the cursor while scrolling; used by files/grep
---@field on_open? fun(handle: { select: fun(pred: fun(item: any): boolean): boolean, is_open: fun(): boolean, focus_list: fun(), set_items: fun(items: any[], patch?: table), list_win: fun(): integer?, visible: fun(): any[], integer })  receives a handle to drive the open finder from outside
---@field match_pattern? string  the search pattern whose matches are marked in the rows' preview (and kept on `<C-q>`), as ripgrep ran it — see `regex`
---@field preview_file? boolean  preview the item's REAL file buffer (EDITABLE, 2-way synced) instead of `preview` lines; items need `path` (+ lnum/col)
---@field preview_side? "right"|"left"|"dynamic"|"hide"  where the preview sits (default `config.preview_side`); `dynamic` = full-width list + a peek float above it (native-qf style); `hide` = no preview (toggle with <C-e>)
---@field preview_numbers? boolean  show line numbers in the preview (default: `config.preview.numbers`, off)
---@field preview_wrap? boolean  soft-wrap the preview (default false)
---@field list_wrap? boolean  soft-wrap the list rows (no "↳" marker) so far-right matches stay visible (default false)
---@field list_clip? string|false  the mark for text scrolled off a row's left edge; `false` switches the row scrolling off (default `config.list_clip`)
---@field empty_text? string  shown when there are no results (list body + preview winbar)
---@field empty_preview? string  the "nothing to preview" placeholder bar text (default "Nothing to preview")
---@field scrollbar? boolean|table  the thumbs right of the list and the preview: true / false, or { list = bool, preview = bool } (default: `config.scrollbar`)
---@field title? string  the finder title — the chassis native centered border-title
---@field icon? string  an optional leading glyph fronting the title
---@field title_line? string  title placement: "row" (a top content row, default) | "statusline" (the centralized chrome overlay) | "border" (opt-in native border-title)
---@field title_pos? "left"|"center"|"right"  title alignment override for THIS open (default: `config.title_pos`, layout-independent)
---@field counter? string  match-count placement: "footer" (default — the bottom-right border) | "title" (folded into the border-title)
---@field prompt? string  the query prompt prefix (default "󰅂 ")
---@field placeholder? string  the hint in the empty query field (default "type to search…")
---@field start_in_list? boolean  open with the cursor on the LIST (normal mode), not in the query: `/` or `C-f` types
---@field hints? fun(ctx: "prompt"|"list", item: any): { key: string, name: string }[]  REPLACES the footer legend (the caller says exactly which buttons show, per selected row); re-asked whenever the selection moves
---@field keys? { key: string, name?: string, mode?: "n"|"i", keep_insert?: boolean, run: fun(item: any, close: fun()) }[]  extra row actions (split, code action…); `name` adds a footer hint; `mode` restricts the binding to the LIST (n) or the PROMPT (i) — absent = both; `keep_insert` keeps the query in insert mode after the action
---@field filters? LvimUiFilterGroup[]  header filter button GROUPS — each `{ active = id, buttons = { { id, label, key?, predicate?(src), hl?, hl_active?, hl_hover_active? }, … } }`; activate a filter by its key in NORMAL mode
---@field refresh? fun(): any[]  re-fetch the static items live (e.g. on DiagnosticChanged) — see refresh_events
---@field refresh_events? string[]  autocmd events that trigger a refresh
---@field close_on_empty? boolean  dismiss the finder when a refresh leaves no items (e.g. all diagnostics fixed)
---@field max_rows? integer  OPTIONAL local row cap; nil = follow the central dock geometry height
---@field layout? "float"|"bottom"|"area"  centred float (default), a bottom dock, or the cmdheight area (heirline above)
---@field height? integer  rows for the bottom layout (default 16)
---@field key? string  the dock KIND key — this finder's stable identity in the dock stack (id = "lvim-picker:"..key); nil ⇒ derived from the title, else un-managed
---@field dock_stack? boolean  PER-CALL override of the picker's own `config.dock.dock_stack` for THIS open: true = managed stack consumer, false = geometry-only standalone. nil ⇒ inherit `config.dock.dock_stack`. Caller plugins (lvim-lsp, lvim-qf-loc) opening THROUGH the picker set this to control docking for their entry.
---@field force? { float?: table, area?: table, bottom?: table }  PER-CALL anchored geometry override (per layout), deep-merged over the central dock geometry AND `config.dock.force`; wins for THIS open. Each layout may carry height/height_auto/backdrop/auto_hide/keep_focus (float ALSO width/width_auto; area/bottom are always full-width). `opts.height` still wins as an explicit rows size.

--- Actually CONSTRUCT + open a finder surface (the real work behind `M.open`): a centred float with a query
--- input on top, a results list and (with `preview`) a scrollable preview beside it. When `kind` is given the
--- open is MANAGED by the dock (which already parked the previous consumer, so we do NOT `close_active` here);
--- when `kind` is nil it is un-managed — `source.close_active` replaces the previous finder in place. The
--- (kind, layout) SLOT KEY (`sk`) — computed from `kind` + the resolved `opts.layout` — is what all managed
--- open-state (`live[sk]` + the `dock.parked(entry_keys[sk])` bookkeeping) is filed under, so the SAME kind
--- open in two layouts is two independent surfaces.
---@param opts LvimPickerOpts
---@param kind string?  the dock kind (managed) or nil (un-managed)
build = function(opts, kind)
    -- ONE context for the finder: its state, its options, and every helper the steps below define live in `ctx` (formerly the locals of this one
    -- 2 600-line function). The steps run in order, each in the context as its environment — see `lvim-picker.build`.
    local ctx = setmetatable({
        opts = opts,
        kind = kind,
        -- what this file shares with the steps
        NS = NS, api = api, clip_row = clip_row, config = config, entry_keys = entry_keys, file_list_cmd = file_list_cmd, filter = filter, fuzzy = fuzzy, get_dock = get_dock, iconlib = iconlib, list_row = list_row, live = live, normalize = normalize, preview = preview, preview_matches = preview_matches, release_run = release_run, row_uses_rg_pattern = row_uses_rg_pattern, rows = rows, scope = scope, slot_key = slot_key, source = source, spawn_stream_raw = spawn_stream_raw, ui_filters = ui_filters,
    }, { __index = _G })
    for _, step in ipairs(BUILD_STEPS) do
        require("lvim-picker.build." .. step)(ctx)
    end
end

--- Route a finder-KIND open through the dock stack. MANAGED (the caller already resolved: dock manager present
--- AND a stable key AND the effective `dock_stack` flag): remember the `rebuild` closure (the dock's `is_alive`
--- reads it), refresh the consumer's live name / icon / layout / anchored `slot` (force) override, and
--- SHOW-OR-CREATE it through the dock — which dedups by id and enforces one-visible-per-layout (parking any
--- OTHER visible consumer there), then calls the consumer's `show`, which runs the rebuild. UN-MANAGED (no
--- manager / no key / `dock_stack = false`): just run `rebuild()` (the classic replace-in-place).
---@param managed boolean  route through the dock stack (dock present AND `kind` AND the effective `dock_stack`)
---@param kind string?    the dock kind (nil ⇒ un-managed)
---@param layout string  the dock layout this kind occupies ("area"|"bottom"|"float")
---@param meta { title?: string, icon?: string }  entry display name / glyph source (falls back to KIND_META)
---@param rebuild fun()  (re)materialises this (kind, layout) slot's surface from its remembered opts
---@param slot? table  the consumer's anchored geometry (force) override for `dock.slot` (nil = inherit central)
local function route(managed, kind, layout, meta, rebuild, slot)
    local d = get_dock()
    if managed and d and kind then
        -- FILE the rebuild + open under the (kind, layout) slot key — so opening the SAME kind in another layout
        -- is a SEPARATE entry with its own consumer / surface, and STORE the dock's returned entry key to pass
        -- back to the lifecycle APIs.
        local sk = slot_key(kind, layout)
        pending[sk] = rebuild
        local c = get_consumer(kind, layout) -- one consumer per (kind, layout); its `layout` is fixed at creation
        local km = KIND_META[kind]
        c.name = (meta and meta.title) or (km and km.name) or kind
        c.icon = (meta and meta.icon) or (km and km.icon) or "󰍉"
        c.slot = slot -- ANCHORED force override → do_show feeds it to dock.slot as ctx.rect
        entry_keys[sk] = d.open(c) -- STORE the returned (id, layout) entry key for parked/refresh_leader/dropped
    else
        rebuild()
    end
end

--- Open a fuzzy finder: a centred float with a query input on top, a results list and (with `preview`) a
--- scrollable preview beside it. INSERT prompt: type to filter (fzf), `<C-j>/<C-k>` move, `<C-d>/<C-u>`
--- scroll the preview, `<CR>` confirms, `<C-c>` cancels, `<Esc>`/`<C-f>` → NORMAL. NORMAL list: `j`/`k`
--- move, `<C-d>/<C-u>` scroll preview, `<C-l>`/`<C-h>` panel nav, filter hotkeys, `q` close, `/` → typing.
---
--- Participates in the shared DOCK STACK (lvim-utils.dock) when present: each finder KIND is its own entry
--- (`id = "lvim-picker:<kind>"`, keyed by `opts.key` — else a slug of the title), one visible per layout,
--- cyclable with `<Leader>n`/`<Leader>p`, killable with `<Leader>x`, listed in the `<Leader>m` menu. Opening
--- another kind in the same layout PARKS this one (restorable); re-opening a live kind rebuilds it fresh in
--- place. Without the dock (or a resolvable key) it falls back to the classic replace-in-place open.
---@param opts LvimPickerOpts
function M.open(opts)
    opts = opts or {}
    opts.layout = opts.layout or (config or {}).layout or "area"
    local key = resolve_key(opts)
    -- Effective dock_stack: a per-call `opts.dock_stack` OVERRIDES the plugin's own `config.dock.dock_stack` for
    -- THIS open (a caller plugin opening THROUGH the picker controls docking for its entry). nil ⇒ inherit config.
    local stack = opts.dock_stack
    if stack == nil then
        stack = (config or {}).dock and config.dock.dock_stack
    end
    -- MANAGED only when the dock is present AND a key resolves AND the effective dock_stack is on — the rebuild
    -- then passes that key to `build` (managed: skip close_active, register `live`, do the on_close dock
    -- bookkeeping); un-managed passes nil (the classic `source.close_active` replace-in-place).
    local managed = get_dock() ~= nil and key ~= nil and stack ~= false
    -- The consumer's anchored force override for the stack path: per-call `opts.force[layout]` wins, else own
    -- `config.dock.force[layout]` (empty {} = inherit). build recomputes the SAME for its surface slot either way.
    local eff_force = (opts.force and opts.force[opts.layout])
        or ((config or {}).dock and config.dock.force and config.dock.force[opts.layout])
    route(managed, key, opts.layout, { title = opts.title, icon = opts.icon }, function()
        build(opts, managed and key or nil)
    end, eff_force)
end


--- A ready finder over the listed buffers; confirming switches to the chosen buffer, with a content preview.
---@param opts? table  forwarded to M.open
function M.buffers(opts)
    opts = opts or {}
    opts.key = opts.key or "buffers"
    local items = {}
    for _, b in ipairs(api.nvim_list_bufs()) do
        if vim.bo[b].buflisted then
            local name = api.nvim_buf_get_name(b)
            name = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
            items[#items + 1] = { text = name, bufnr = b }
        end
    end
    --- Preview a listed buffer's content, with a filetype for syntax.
    ---@param bufnr integer
    ---@param name string
    ---@return string[] lines, string filetype
    local function buf_preview(bufnr, name)
        local ft = (bufnr and api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype) or ""
        if ft == "" and name ~= "" and name ~= "[No Name]" then
            ft = vim.filetype.match({ filename = name }) or ""
        end
        if bufnr and api.nvim_buf_is_loaded(bufnr) then
            return api.nvim_buf_get_lines(bufnr, 0, 500, false), ft
        end
        if name ~= "" and name ~= "[No Name]" and vim.fn.filereadable(name) == 1 then
            return vim.fn.readfile(name, "", 500), ft
        end
        return { "[no preview]" }, ""
    end
    M.open(vim.tbl_extend("force", {
        title = "Buffers",
        items = items,
        on_confirm = function(it)
            if it and api.nvim_buf_is_valid(it.bufnr) then
                api.nvim_set_current_buf(it.bufnr)
            end
        end,
        preview = function(it)
            local b = it.bufnr
            local name = b and api.nvim_buf_get_name(b) or ""
            -- the filetype drives the preview's syntax: a loaded buffer's own ft, else match by filename
            local ft = (b and api.nvim_buf_is_loaded(b) and vim.bo[b].filetype) or ""
            if ft == "" and name ~= "" then
                ft = vim.filetype.match({ filename = name }) or ""
            end
            if b and api.nvim_buf_is_loaded(b) then
                return api.nvim_buf_get_lines(b, 0, 500, false), ft
            end
            if name ~= "" and vim.fn.filereadable(name) == 1 then
                return vim.fn.readfile(name, "", 500), ft
            end
            return { "[no preview]" }, ""
        end,
        -- a buffer that is not loaded is read from its file ASYNC (follows the cursor); a loaded one is shown
        -- from memory by `preview` above
        preview_file_of = function(it)
            local b = it.bufnr
            if not b or (api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b)) then
                return nil
            end
            local name = api.nvim_buf_is_valid(b) and api.nvim_buf_get_name(b) or ""
            return name ~= "" and { path = name } or nil
        end,
    }, opts or {}))
end

-- ── file / directory / grep finders ────────────────────────────────────────────
-- The listing commands (file_list_cmd / dir_list_cmd), the preview reader (read_preview) and the async
-- streamer (spawn_stream) are aliased from picker.source at the top of the file.

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

require("lvim-picker.finders")(M, pick_items, filter, normalize, preview_span)

--- The finder CHOOSER — fzf-lua's builtin-menu equivalent: a native lvim-picker finder listing every built-in
--- finder (label + Nerd glyph from `KIND_META`), opened when `:LvimPicker` is called with NO finder. It IS a
--- picker, so it honours `layout` (the chooser AND the finder it opens both land in that layout). The `grep_*`
--- context variants (cword/selection/…) are keymap-oriented, not menu rows, so they are omitted.
---@param layout? string  "area" | "float" | "bottom" (nil = the config default)
local function open_chooser(layout)
    local items = {}
    for _, kind in ipairs(FINDERS) do
        local km = KIND_META[kind]
        if km and not kind:match("^grep_") then
            items[#items + 1] = { text = km.icon .. "  " .. km.name, kind = kind }
        end
    end
    -- the modes (git status / log, processes, docker, …), when the plugin host and the modes plugin are there: asked, then the menu opens
    local ok_modes, modes = pcall(require, "lvim-picker.modes")
    local function show()
        pick_items({
            title = "Pickers",
            items = items,
            -- Un-managed on purpose: the chooser is a one-shot menu, not a workspace. As a managed stack entry it
            -- stayed PARKED in the dock after the pick and resurfaced on every cycle.
            opts = { layout = layout, dock_stack = false },
            on_confirm = function(item)
                if item and item.mode then
                    require("lvim-picker.modes").open(M, item.mode, layout and { layout = layout } or nil)
                    return
                end
                local fn = item and item.kind and M[item.kind]
                if type(fn) == "function" then
                    fn(layout and { layout = layout } or nil)
                end
            end,
        })
    end
    if not ok_modes then
        return show()
    end
    modes.list(function(all)
        for _, m in ipairs(all) do
            items[#items + 1] = { text = "󰒓  " .. (m.title ~= "" and m.title or m.name), kind = "mode", mode = m.name }
        end
        show()
    end)
end

--- Configure lvim-picker: merge `opts` into the live picker config in place (a nested `fuzzy` subtable merges
--- into the fuzzy engine's config), then register the `:LvimPicker` command. Optional — the defaults work
--- without it; every reader `require("lvim-picker.config")` sees the effective values.
---@param opts? table  see lvim-picker.config (+ an optional `fuzzy` subtable → lvim-picker.fuzzy.config)
function M.setup(opts)
    opts = opts and vim.tbl_extend("force", {}, opts) or {}
    if opts.fuzzy ~= nil then
        utils.merge(require("lvim-picker.fuzzy.config"), opts.fuzzy)
        opts.fuzzy = nil
    end
    utils.merge(config, opts)
    M.setup_command()
end

--- Register the `:LvimPicker <finder> [layout]` user command (one finder per `M.<finder>` above).
function M.setup_command()
    vim.api.nvim_create_user_command("LvimPicker", function(o)
        -- A layout token (area|float|bottom) may appear ANYWHERE in the args; the remaining word (if any) is
        -- the finder. No finder → the chooser (fzf-lua's builtin menu). No layout → the config default.
        local finder, layout, arg
        for _, w in ipairs(o.fargs) do
            if not layout and vim.tbl_contains(LAYOUTS, w) then
                layout = w
            elseif not finder then
                finder = w
            elseif not arg then
                arg = w
            end
        end
        -- `:LvimPicker mode <name>` / `:LvimPicker <name>`: an lfz mode (git-log, processes, docker, …)
        local modes = require("lvim-picker.modes")
        if finder == "mode" and arg then
            modes.open(M, arg, layout and { layout = layout } or nil)
            return
        elseif finder and type(M[finder]) ~= "function" then
            -- not a finder of the picker: maybe a mode (asked of the plugin; an unknown name is said by `modes.open`)
            modes.open(M, finder, layout and { layout = layout } or nil)
            return
        end
        if not finder then
            open_chooser(layout)
            return
        end
        local fn = M[finder]
        if type(fn) ~= "function" then
            vim.notify("LvimPicker: unknown finder '" .. tostring(finder) .. "'", vim.log.levels.ERROR)
            return
        end
        fn(layout and { layout = layout } or nil)
    end, {
        nargs = "*",
        complete = function(arg_lead, cmd_line, _)
            local parts = vim.split(cmd_line, "%s+")
            -- first token: a finder OR a layout (`:LvimPicker float` is valid); the second is whichever of the
            -- two the first was not — a layout token may come first, so after one the FINDERS are offered.
            local pool = {}
            -- the names the plugin has told (the asking starts at the first completion)
            local modes = require("lvim-picker.modes")
            modes.list(function() end)
            local mode_names = modes.names()
            local finders = vim.list_extend(vim.deepcopy(FINDERS), mode_names)
            if parts[2] == "mode" and #parts >= 3 then
                pool = mode_names
            elseif #parts <= 2 then
                pool = vim.list_extend(vim.list_extend(vim.deepcopy(finders), { "mode" }), LAYOUTS)
            elseif #parts == 3 then
                pool = vim.tbl_contains(LAYOUTS, parts[2]) and finders or LAYOUTS
            end
            return vim.tbl_filter(function(n)
                return n:find(arg_lead, 1, true) == 1
            end, pool)
        end,
        desc = "LvimPicker — pick a finder (:LvimPicker [<finder>] [area|float|bottom]); no finder opens the chooser",
    })
end

return M
