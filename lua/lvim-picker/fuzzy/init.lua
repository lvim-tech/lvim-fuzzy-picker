-- lvim-picker.fuzzy: shared fuzzy MATCHING engine: rank a list of strings against a query. The engine is
-- lvim-fuzzy — lvim-fuzzy-core in-process through FFI, the same engine as the terminal finder, so a query
-- ranks the same in both. The query goes to the engine WHOLE, in fzf's syntax (spaces = AND, `'x`, `^x`,
-- `x$`, `!x`, `a | b`, smart case).
-- The candidate set is PREPARED once per pool (one packed upload, cached by array reference + length) and
-- a stream-grown pool APPENDS only its new tail into the live context (incremental, O(new) — never a whole
-- re-prepare); every keystroke is then a single match call (narrowed natively from the previous result
-- while the query only grows).
-- Match POSITIONS for highlighting come from the engine too (`highlights`), only for the top `max_results`
-- rows actually returned, never the whole set.
-- Used by the picker and by the native cmdline-completion integration (lvim-msgarea), so both share one
-- engine/ranking.
--
---@module "lvim-picker.fuzzy"

local config = require("lvim-picker.fuzzy.config")
local engine = require("lvim-fuzzy")

local M = {}

-- ─── result ordering (config.sort) ──────────────────────────────────────
-- A composable sort applied AFTER the fuzzy ranking. Each criterion compares two items
-- `{ text, is_dir, ext, rank }` and returns a number (<0 = a first, 0 = equal). `sort` (in config)
-- is a single preset name, a LIST of names applied in priority order, or a custom boolean comparator. The
-- fuzzy `rank` is always the final tiebreak, so the order is total + deterministic.

---@type table<string, fun(a: table, b: table): integer>
local CRITERIA = {
    score = function(a, b)
        return a.rank - b.rank
    end,
    dirs_first = function(a, b)
        return (a.is_dir and 0 or 1) - (b.is_dir and 0 or 1)
    end,
    files_first = function(a, b)
        return (a.is_dir and 1 or 0) - (b.is_dir and 1 or 0)
    end,
    ext = function(a, b)
        return a.ext < b.ext and -1 or (a.ext > b.ext and 1 or 0)
    end,
    length = function(a, b)
        return #a.text - #b.text
    end,
    alpha = function(a, b)
        return a.text < b.text and -1 or (a.text > b.text and 1 or 0)
    end,
}

--- Build a `table.sort` boolean comparator from the `sort` spec (a name, a list of names, or a function).
---@param spec string|string[]|fun(a: table, b: table): boolean|nil
---@return fun(a: table, b: table): boolean
local function comparator(spec)
    if type(spec) == "function" then
        return spec
    end
    local names = type(spec) == "table" and spec or { spec or "score" }
    local fns = {}
    for _, n in ipairs(names) do
        if CRITERIA[n] then
            fns[#fns + 1] = CRITERIA[n]
        end
    end
    return function(a, b)
        for _, f in ipairs(fns) do
            local r = f(a, b)
            if r ~= 0 then
                return r < 0
            end
        end
        return a.rank < b.rank -- deterministic final tiebreak
    end
end

--- Reorder `ranked` (in fuzzy order) per `config.sort`. Decorates each entry with `text`/`is_dir`/`ext`/`rank`
--- for the criteria, sorts, and returns the reordered list (the original fields are carried through). `text_of`
--- yields each entry's candidate text — from a shared `texts[r.idx]` array (the static path) or an inline
--- `r.text` (the blob path).
---@generic T : { idx: integer }
---@param ranked T[]
---@param text_of fun(r: T): string
---@return T[]
local function apply_sort(ranked, text_of)
    local spec = (config or {}).sort or "score"
    if spec == "score" then
        return ranked -- already in best-match order
    end
    local decorated = {}
    for rank, r in ipairs(ranked) do
        local t = text_of(r)
        r.text = t
        r.rank = rank
        r.is_dir = t:sub(-1) == "/"
        r.ext = t:match("%.([%w_%-]+)/?$") or ""
        decorated[rank] = r
    end
    table.sort(decorated, comparator(spec))
    return decorated
end

-- Single-slot cache of the PREPARED lvim-fuzzy context, keyed by the candidate array reference + its length
-- (the exact contract of the picker's `_texts_cache`: the query changes on every keystroke but the candidate
-- set does NOT, so the context is rebuilt only when the pool actually changes — appended by a stream feed
-- (same reference, grown length), replaced by a refresh, or narrowed by a filter (new reference)). Over a
-- stable pool a keystroke is therefore ONE match call against the ready context, never a re-upload. A pool
-- that GREW in place feeds ONLY the new tail into the live context (`engine.append` — O(new), sub-ms
-- even at 1.5M) instead of re-preparing the whole set (~130–200 ms per growth there); the context is still
-- built lazily on the first real query, so a stream that finishes before typing pays one prepare, and typing
-- WHILE it feeds pays only appends. Append is the same as a whole prepare (lvim-fuzzy guarantee).
---@type { texts: string[], len: integer, ctx: LvimFuzzyContext }?
local _ctx_cache

local uv = vim.uv

-- BOUNDED MARSHALING. Feeding a streamed pool (up to ~2M paths) into the native matcher is O(pool) Lua↔C
-- string work — a single whole prepare / large append blocks the UI for 50–80 ms at scale (measured). So we
-- never marshal the whole outstanding tail in one call: `ensure_ctx` moves at most `marshal_cap` candidates
-- per call (a ≈5–8 ms slice) and a background timer keeps feeding the rest in equal slices across event-loop
-- ticks until the native context catches up to the pool, then runs ONE final match of the last query so the
-- results reflect the full set. The match always runs against whatever is marshaled so far (which grows), so
-- results appear and refine progressively during the stream instead of the UI freezing.
---@type uv.uv_timer_t?
local _marshal_timer
---@type string?
local _last_query -- last non-empty query + its callback, replayed once when the background marshal catches up
---@type fun(ranked: { idx: integer, match?: integer[] }[])?
local _last_cb
---@type LvimFuzzyOpts?
local _last_opts

--- Stop and release the background catch-up timer (if running).
local function stop_marshal()
    if _marshal_timer then
        _marshal_timer:stop()
        if not _marshal_timer:is_closing() then
            _marshal_timer:close()
        end
        _marshal_timer = nil
    end
end

--- Marshal ONE bounded slice of the outstanding tail (`c.len+1 .. min(pool, c.len+cap)`) into the live native
--- context via `engine.append`, advancing `c.len`. Returns true once the context has caught up to the pool.
---@param c { texts: string[], len: integer, ctx: LvimFuzzyContext }
---@return boolean caught_up
local function marshal_slice(c)
    local n = #c.texts
    local cap = (config or {}).marshal_cap or 32768
    local upto = math.min(n, c.len + cap)
    local tail = {}
    for i = c.len + 1, upto do
        tail[i - c.len] = c.texts[i]
    end
    engine.append(c.ctx, tail)
    c.len = upto
    return c.len >= n
end

--- Arm the background catch-up: keep marshaling bounded slices into the native context, across event-loop
--- ticks (so it never blocks), until it reaches the pool. While the pool is still GROWING it only APPENDS —
--- it never re-runs the query (matching during the stream is driven by the `stream_refresh_ms` re-render, which
--- lets each match complete; a match kicked off on every momentary catch-up would supersede the in-flight one
--- forever, so nothing would ever settle). Only once the pool holds STEADY for a couple of ticks — i.e. the
--- stream has finished — does it replay the last query ONCE, over the now-complete context, for full-set
--- results. Idempotent: a marshal already in flight keeps running against the (still growing) pool.
---@param texts string[]
local function arm_marshal(texts)
    if _marshal_timer then
        return
    end
    local settled = 0 -- consecutive ticks the context has fully covered a pool that stopped growing
    local timer = uv.new_timer()
    if not timer then
        return
    end
    _marshal_timer = timer
    timer:start(
        40,
        40,
        vim.schedule_wrap(function()
            -- A blocked main thread can queue several ticks of this timer that then drain together; once the
            -- timer has been stopped (or replaced by a fresh arm), ignore those stale queued callbacks so they
            -- do not each kick off a match.
            if _marshal_timer ~= timer then
                return
            end
            local c = _ctx_cache
            if not (c and c.texts == texts) then -- pool replaced / released → abandon this catch-up
                stop_marshal()
                return
            end
            if c.len < #texts then
                marshal_slice(c) -- still behind the stream → feed one bounded slice, do NOT match
                settled = 0
                return
            end
            settled = settled + 1
            if settled >= 2 then -- pool has held steady ⇒ stream finished → one final full-context match
                stop_marshal()
                if _last_query and _last_query ~= "" and _last_cb then
                    M.filter(texts, _last_query, _last_cb, _last_opts)
                end
            end
        end)
    )
end

--- The prepared lvim-fuzzy context for `texts`, building (and caching) it when the pool is new or changed,
--- and APPENDING only the new tail when the same pool grew in place (the stream-feed contract). Marshaling is
--- BOUNDED (see above): a huge pool is prepared/appended a slice at a time, the background timer feeding the
--- rest, so this never blocks — the returned context may cover only the pool's head until the marshal catches
--- up (a growing prefix, which is exactly what a live-streaming finder should search).
---@param texts string[]
---@return LvimFuzzyContext
local function ensure_ctx(texts)
    local n = #texts
    local c = _ctx_cache
    if c and c.texts == texts then
        if c.len >= n then
            return c.ctx
        end
        -- The pool GREW in place (stream feed — same array ref, larger length): extend the live context with
        -- a bounded slice of the new tail now, and let the background timer feed the rest.
        if not marshal_slice(c) then
            arm_marshal(texts) -- tail remains → catch up in the background
        end
        return c.ctx
    end
    -- New / replaced pool: prepare only the first `marshal_cap` now (bounded — a whole prepare over millions
    -- would block); the background timer appends the rest. The replaced pool's native context is freed now.
    stop_marshal()
    if c then
        engine.free(c.ctx)
    end
    local cap = (config or {}).marshal_cap or 32768
    local upto = math.min(n, cap)
    local head = {}
    for i = 1, upto do
        head[i] = texts[i]
    end
    local ctx = engine.prepare(head)
    _ctx_cache = { texts = texts, len = upto, ctx = ctx }
    if upto < n then
        arm_marshal(texts)
    end
    return ctx
end

--- Whether a query has anything to search for ("" and whitespace alone are the whole pool, unranked).
---@param query string
---@return boolean
local function has_query(query)
    return tostring(query or ""):find("%S") ~= nil
end

--- The BASENAME match of `text` for `query`: 0-based character positions OFFSET into full-path coordinates
--- so a highlight lands on the name in the whole path — or nil when the query does not match the basename
--- (the segment after the last "/") on its own. Tested on the name ALONE, so a candidate whose NAME matches
--- counts even when the whole-path engine aligned across the directory (e.g. `blame.lua` "matches" `vgit.lua`
--- only via the dir `git` + the `.lua` extension → nil here). Shared by the ranking bias AND the display
--- highlight so they always agree on "name match". This is a PATH concern, hence here, never in the engine.
---@param query string
---@param text string
---@param opts? LvimFuzzyOpts
---@return integer[]|nil
local function basename_positions(query, text, opts)
    local slash = text:find("/[^/]*$") -- 1-based BYTE index of the last "/" (nil = no directory part)
    local base = text:sub((slash or 0) + 1)
    local bm = engine.highlights(base, query, opts) -- 0-based CHAR positions within the basename, or nil
    if not bm then
        return nil
    end
    -- the lift into path coordinates is the CHAR count of the directory part (its byte length overshoots as
    -- soon as the path holds a multibyte character)
    if slash then
        local off = vim.fn.strchars(text:sub(1, slash))
        for k, ci in ipairs(bm) do
            bm[k] = ci + off
        end
    end
    return bm
end

--- Order the NAME-match rows by how well the query matches the NAME itself — NOT the whole path. Without this
--- the bucket keeps the engine's whole-path order, so a contiguous name match (`vgit.lua`) buried in a long
--- path loses to a SCATTERED name match (`lvim-git.txt`) whose short path merely scored higher end-to-end. The
--- basenames are re-scored by the engine; the whole-path order is the stable tiebreak among equal name scores.
---@param named table[]  the name-match rows (reordered in place)
---@param query string
---@param text_of fun(r: table): string  a row's full path
---@param opts? LvimFuzzyOpts
local function order_by_name(named, query, text_of, opts)
    if #named < 2 then
        return
    end
    local bases = {}
    for i, r in ipairs(named) do
        local text = text_of(r)
        local slash = text:find("/[^/]*$")
        bases[i] = text:sub((slash or 0) + 1)
    end
    local score = {}
    for _, e in ipairs(engine.filter(bases, query, opts) or {}) do
        score[e.index] = e.score
    end
    local order = {}
    for i, r in ipairs(named) do
        order[i] = { r = r, s = score[i] or -math.huge, i = i }
    end
    table.sort(order, function(a, b)
        if a.s ~= b.s then
            return a.s > b.s -- best NAME score first (contiguity wins)
        end
        return a.i < b.i -- stable: keep the whole-path order among equal name scores
    end)
    for i, o in ipairs(order) do
        named[i] = o.r
    end
end

--- Bias ENGINE-ranked rows toward FILENAME matches (`config.filename_match`). ORTHOGONAL to the engine's
--- contiguity scoring: within either bucket the engine order is preserved, so a contiguous name still beats a
--- scattered one. `pos_of(r, m)` receives a name match's basename positions (to light up the NAME).
---   "boost" (default): name matches first, then the path-only matches (still shown, below).
---   "strict":          only name matches kept.
---   "off":             no bias — whole-path fuzzy (fzf parity).
---@param out table[]  engine-ranked rows
---@param query string
---@param text_of fun(r: table): string
---@param pos_of? fun(r: table, m: integer[])
---@param opts? LvimFuzzyOpts
---@return table[]
local function filename_bias(out, query, text_of, pos_of, opts)
    local mode = (config or {}).filename_match or "boost"
    if mode == "off" or #out == 0 or not has_query(query) then
        return out
    end
    local named, rest = {}, {}
    for _, r in ipairs(out) do
        local m = basename_positions(query, text_of(r) or "", opts)
        if m then
            if pos_of then
                pos_of(r, m)
            end
            named[#named + 1] = r
        else
            rest[#rest + 1] = r
        end
    end
    order_by_name(named, query, text_of, opts)
    if mode == "strict" then
        return named
    end
    for _, r in ipairs(rest) do
        named[#named + 1] = r
    end
    return named
end

--- Rank `texts` against `query`. `cb` receives a list of `{ idx, match? }` in ranked order — `idx` is the
--- 1-based index into `texts`, `match` the 0-based matched-char indices (for highlighting; absent on an
--- empty query). Empty query = the first `max_results` in source order, no match. The query goes to the
--- engine WHOLE, in fzf's syntax (spaces = AND, `'x`, `^x`, `x$`, `!x`, `a | b`); `cb` fires on a later tick.
--- `opts` (optional) overrides the engine's search options, e.g. `{ extended = false }` for a completion
--- where the typed text is one literal word.
---@param texts string[]
---@param query string
---@param cb fun(ranked: { idx: integer, match?: integer[] }[])
---@param opts? LvimFuzzyOpts
function M.filter(texts, query, cb, opts)
    -- Hard cap on materialised results (config.max_results): the engine still SEARCHES all candidates, but
    -- only the top `max` are handed back. (lvim-fuzzy applies its own `max_results` too — the effective cap is
    -- the smaller of the two.)
    local max = (config or {}).max_results or 1000
    -- every path delivers through here so the config sort (dirs_first / ext / …) is applied uniformly
    local function deliver(ranked)
        cb(apply_sort(ranked, function(r)
            return texts[r.idx]
        end))
    end
    if not has_query(query) then
        _last_query, _last_cb = nil, nil -- an empty query needs no full-pool replay when the marshal catches up
        local out = {}
        for i = 1, math.min(#texts, max) do -- first `max` in source order (no matching on an empty query)
            out[i] = { idx = i }
        end
        deliver(out)
        return
    end
    -- Remember this query so the background marshal can replay it once the native context reaches the full pool
    -- (see arm_marshal) — otherwise a query typed mid-stream would keep showing head-only results until the
    -- next keystroke. `cb` is the finder's gen-guarded refilter callback, so a stale replay is dropped safely.
    _last_query, _last_cb, _last_opts = query, cb, opts
    -- Positions are computed for the returned top rows only (≤ max_results), never over the whole set.
    engine.match_async(query, ensure_ctx(texts), function(results, cnt)
        local out = {}
        for k = 1, math.min(cnt, max) do
            local idx = results[k].index
            out[k] = { idx = idx, match = engine.highlights(texts[idx], query, opts) }
        end
        deliver(filename_bias(out, query, function(r)
            return texts[r.idx]
        end, function(r, m)
            r.match = m
        end, opts))
    end, opts)
end

--- Drop the cached prepared context. A finder calls this on close so the packed candidate blob (large at
--- huge-tree scale) does not linger in this module until the next search replaces it — `engine.free` also
--- releases the NATIVE side eagerly, so ~60–100 MB of prepared context is reclaimed on close instead
--- of lingering until another search re-prepares.
--- With `texts` given, only the context prepared for THAT candidate array is dropped — a finder closing while
--- another is live must not free the live one's context (the cache is one module-level slot).
---@param texts? string[]
function M.release(texts)
    if texts ~= nil and _ctx_cache and _ctx_cache.texts ~= texts then
        return
    end
    stop_marshal() -- cancel any background catch-up before the context it feeds is freed
    _last_query, _last_cb = nil, nil
    if _ctx_cache then
        engine.free(_ctx_cache.ctx)
        _ctx_cache = nil
    end
end

--- The candidate array the cached context was prepared for (nil when none) — a seam for tests.
---@return string[]?
function M._ctx_texts()
    return _ctx_cache and _ctx_cache.texts or nil
end

-- ─── blob-ingest streaming (GAP-5) ───────────────────────────────────────────
-- A streaming finder over a HUGE tree (millions of paths) hands the producer's raw stdout bytes straight to
-- the native matcher instead of materialising every path as a Lua string/table (which is what caused the
-- string-intern + GC pauses of a ~2M-candidate pool). The candidate POOL lives entirely native; only the
-- ranked top-K rows are ever materialised on the Lua side. These thin wrappers expose the engine's blob API
-- to the picker's `build()` and layer the config sort + result cap on top of the raw match — the blob analog
-- of `M.filter`. All gated on `M.has_blob()`.

--- Whether the native library is loaded (blob ingestion comes with it). When false, the finders keep the
--- per-string streaming path.
---@return boolean
function M.has_blob()
    return engine.has_blob()
end

--- Create a blob-ingest context (nil when unavailable — the caller then uses the per-string path).
---@return LvimFuzzyBlob?
function M.blob_new()
    return engine.blob_new()
end

--- Ingest a raw stdout chunk into `blob`; returns the new candidate count.
---@param blob LvimFuzzyBlob
---@param data string
---@return integer
function M.blob_append(blob, data)
    return engine.blob_append(blob, data)
end

--- Flush the trailing partial line at end of stream; returns the candidate count.
---@param blob LvimFuzzyBlob
---@return integer
function M.blob_flush(blob)
    return engine.blob_flush(blob)
end

--- The text of candidate `idx` (1-based) of `blob`.
---@param blob LvimFuzzyBlob
---@param idx integer
---@return string?
function M.blob_text(blob, idx)
    return engine.blob_text(blob, idx)
end

--- The current candidate count of `blob`.
---@param blob LvimFuzzyBlob
---@return integer
function M.blob_count(blob)
    return engine.blob_count(blob)
end

--- Free a blob context (native memory reclaimed).
---@param blob LvimFuzzyBlob?
function M.blob_free(blob)
    engine.blob_free(blob)
end

--- The matched-char indices of `text` for a query (0-based characters: the alignment plus every other
--- occurrence of each term), or nil when it does not match. The one place the picker's highlight and its
--- filtering agree on what "matched" means — both are the engine's.
---@param query string
---@param text string
---@return integer[]|nil
function M.match_terms(query, text)
    if not has_query(query) then
        return nil
    end
    return engine.highlights(text, query)
end

--- Rank `blob` against `query` and hand the ranked results (`{ idx, text }`, `idx` = the 1-based NATIVE
--- candidate index, `text` materialised for rendering / sorting) to `cb`, plus `total` = the TRUE number of
--- candidates that matched (before the `max_results` cap; the whole pool for an empty query). Applies
--- `config.max_results`, the filename bias and the config sort. `opts.scope` = what a grep result is searched
--- by ("line" / "path" / "file", see lvim-picker.scope). Match POSITIONS are NOT computed here — the caller
--- lights up its VISIBLE rows only.
---@param blob LvimFuzzyBlob
---@param query string
---@param cb fun(list: { idx: integer, text: string }[], total: integer)
---@param opts? LvimFuzzyOpts
function M.blob_filter(blob, query, cb, opts)
    local max = (config or {}).max_results or 1000
    engine.blob_match(blob, has_query(query) and query or "", function(results, cnt, total)
        local ranked = {}
        for k = 1, math.min(cnt, max) do
            local idx = results[k].index
            ranked[k] = { idx = idx, text = engine.blob_text(blob, idx) or "" }
        end
        -- The filename bias reads a path: a grep row searched by its line or its file is not one.
        local scoped = opts and opts.scope and opts.scope ~= "all"
        if not scoped then
            local n = #ranked
            ranked = filename_bias(ranked, query, function(r)
                return r.text
            end)
            if #ranked < n then -- "strict" dropped the path-only rows
                total = #ranked
            end
        end
        cb(
            apply_sort(ranked, function(r)
                return r.text
            end),
            total
        )
    end, opts)
end

--- Match positions for DISPLAY highlighting. When `filename_match` is on and `text`'s NAME matches the query,
--- the highlight is the BASENAME positions (so the name lights up, agreeing with the ranking bias); otherwise
--- the whole-path positions.
---@param query string
---@param text string
---@return integer[]|nil
function M.match_display(query, text)
    if ((config or {}).filename_match or "boost") ~= "off" and has_query(query) then
        local bp = basename_positions(query, text)
        if bp then
            return bp
        end
    end
    return M.match_terms(query, text)
end

return M
