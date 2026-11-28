--- The rows of the finder's list and preview, as pure functions: normalise the caller's items, clip a row to the width with its match spans,
--- draw a list row, find what a pattern matches in the preview, say which pattern marks a grep row. Moved out of init.lua (they hold no state of the
--- finder: what they need comes in as arguments).
---@module "lvim-picker.rows"


local M = {}

--- Normalise the caller's items into `{ text, icon?, _src }`. A string item is its own text; a table item
--- uses `opts.format(item)` (or `item.text`) for the display text and keeps the original as `_src`.
---@param items any[]
---@param format? fun(item: any): string
---@return table[]
function M.normalize(items, format)
    local out = {}
    for i, it in ipairs(items or {}) do
        if type(it) == "string" then
            -- collapse any embedded newlines ONCE here (not later in list_row) so the fuzzy MATCH indices and
            -- the RENDERED row are computed against the SAME single-line string — otherwise a multiline text
            -- shifts the highlighted spans.
            out[i] = { text = (it:gsub("[\r\n]+", " ")), _src = it }
        else
            local t = (format and format(it)) or it.text
            if type(t) ~= "string" then
                t = tostring(t or it)
            end
            -- NOTE: items WITHOUT an explicit `icon` get their ft devicon LAZILY, per VISIBLE row, in the
            -- list render (see the viewport loop) — never here. normalize runs over the WHOLE candidate set
            -- (~2M rows when a huge tree streams in) and the uncached devicon lookup (~3 µs/row) was over
            -- half the per-row ingest cost, for icons only a ~20-row viewport ever shows.
            out[i] = {
                text = (t:gsub("[\r\n]+", " ")),
                icon = it.icon,
                icon_hl = it.icon_hl,
                _src = it,
            }
        end
    end
    return out
end

--- Whether a LOCATION row (a grep hit with `lnum`/`col`) marks the rg PATTERN, or leaves the marking to the
--- fuzzy term matcher. In GREP mode the rows show what rg matched. In FILTER mode (rg frozen, the typed text
--- fuzzy-filters the loaded hits) a non-empty query is what the user is looking at, so the rows light the
--- fuzzy terms — the fzf-lua behaviour; with nothing typed the rg pattern is still the best marking.
---@param state table
---@param opts table
---@param q string?  the typed query (`state.live_query`)
---@return boolean
function M.row_uses_rg_pattern(state, opts, q)
    if not (opts and opts.grep) then
        return true
    end
    return not (state.grep_mode == "filter" and q ~= nil and q ~= "")
end

--- Scroll a row HORIZONTALLY so its match stays on screen, the way fzf does. A grep result is
--- `path:lnum:col:text`, and on a long line the match can sit far past the window's right edge —
--- the row then shows a locator and a stretch of text that says nothing about why it matched.
---
--- The LOCATOR is never cut: it is the part that identifies the hit. Only the text after it is
--- scrolled, with an ellipsis marking what was dropped, and the match spans move with it — a span
--- that scrolls out is dropped rather than left pointing at the wrong characters.
---@param row string
---@param spans { c0: integer, c1: integer }[]
---@param lead integer  byte offset where the row's label starts (past the mark column)
---@param width integer  the list window's width in cells
---@param ellipsis string
---@param fixed? integer  bytes of the label that are its locator (never scrolled); default: a `path:lnum:` prefix
---@param extra? { c0: integer, c1: integer }[]  more spans (e.g. column colours) moved the same way, not steering
---@return string, { c0: integer, c1: integer }[], { c0: integer, c1: integer }[]?
function M.clip_row(row, spans, lead, width, ellipsis, fixed, extra)
    if width <= 0 or #spans == 0 or vim.fn.strdisplaywidth(row) <= width then
        return row, spans, extra
    end
    -- The furthest match decides: if it already fits, nothing is gained by scrolling.
    local last = spans[1]
    for _, sp in ipairs(spans) do
        if sp.c1 > last.c1 then
            last = sp
        end
    end
    if vim.fn.strdisplaywidth(row:sub(1, last.c1)) <= width then
        return row, spans, extra
    end
    -- Everything up to and including `path:lnum:col:` (or the item's own locator) stays put.
    local locator_len = fixed
    if not locator_len then
        local locator = row:sub(lead + 1):match("^[^:]*:%d+:%d+:") or row:sub(lead + 1):match("^[^:]*:%d+:")
        locator_len = locator and #locator or 0
    end
    local keep = lead + locator_len
    if last.c0 <= keep then
        return row, spans, extra
    end
    -- Put the match a third of the way into the room that is left, so its context comes with it.
    local room = width - vim.fn.strdisplaywidth(row:sub(1, keep)) - vim.fn.strdisplaywidth(ellipsis)
    if room <= 8 then
        return row, spans, extra
    end
    local target = math.max(0, math.floor(room / 3))
    local cut = keep
    while cut < last.c0 and vim.fn.strdisplaywidth(row:sub(cut + 1, last.c0)) > target do
        cut = cut + 1
        -- never cut inside a multi-byte character
        while cut < #row and row:byte(cut + 1) >= 0x80 and row:byte(cut + 1) < 0xC0 do
            cut = cut + 1
        end
    end
    if cut <= keep then
        return row, spans, extra
    end
    local out = row:sub(1, keep) .. ellipsis .. row:sub(cut + 1)
    local shift = #ellipsis - (cut - keep)
    local function move(list)
        local moved = {}
        for _, sp in ipairs(list) do
            if sp.c0 >= cut then
                moved[#moved + 1] = vim.tbl_extend("force", sp, { c0 = sp.c0 + shift, c1 = sp.c1 + shift })
            elseif sp.c1 <= keep then
                moved[#moved + 1] = sp
            elseif sp.c1 > cut then -- straddles the cut: keep its visible tail
                moved[#moved + 1] = vim.tbl_extend("force", sp, { c0 = keep + #ellipsis, c1 = sp.c1 + shift })
            end
        end
        return moved
    end
    return out, move(spans), extra and move(extra) or nil
end

--- Build a list ROW for a grid item: `<lead> icon text`, plus the BYTE spans of its matched label characters
--- and the byte length of the leading column. `marked` swaps the leading blank for the mark dot.
---@param it table
---@param marked boolean  the row is marked (multi-select) → show the mark dot in the front column
---@param dot string  the mark glyph
---@return string row, { c0: integer, c1: integer }[] match_spans, integer lead_bytes
function M.list_row(it, marked, dot)
    local lead = marked and dot or " "
    local icon = (it.icon and it.icon ~= "") and (it.icon .. " ") or ""
    -- `it.text` is already single-line (collapsed in `normalize`), so the match spans below (computed on the
    -- SAME string) stay aligned with what is drawn.
    local text = it.text or ""
    local row = lead .. icon .. text
    local spans = {}
    -- EXPLICIT BYTE SPANS WIN. A grep row's real match is the one ripgrep found, at a known
    -- line:col in the TEXT — marking that says why the row is here. The fuzzy display match is
    -- computed over the whole row, path included, so on a location row it lights up scattered
    -- letters of the directory name and buries the thing the reader searched for.
    if it.match_bytes and #it.match_bytes > 0 then
        local base = #lead + #icon
        for _, sp in ipairs(it.match_bytes) do
            spans[#spans + 1] = { c0 = base + sp.c0, c1 = base + sp.c1 }
        end
        return row, spans, #lead
    end
    if it.match and #it.match > 0 then
        local base = #lead + #icon -- byte offset of the label within `row`
        local nch = vim.fn.strchars(text)
        for _, ci in ipairs(it.match) do
            if ci >= 0 and ci < nch then
                -- `it.match` holds codepoint (utf-32) indices; convert each to a BYTE offset via the 0.12
                -- `str_byteindex(str, encoding, index)` signature (the old positional form is deprecated).
                spans[#spans + 1] = {
                    c0 = base + vim.str_byteindex(text, "utf-32", ci),
                    c1 = base + vim.str_byteindex(text, "utf-32", ci + 1),
                }
            end
        end
    end
    return row, spans, #lead
end

--- Every match of `pattern` in `lines`, as byte ranges — the pattern a grep ran (marked in a location row's
--- text and in the preview) or the query a finder is narrowed by. `regex` says how the grep read it: a regex
--- grep (`opts.regex`) tries it as a Vim regex (the two agree on the constructs a reader types at a prompt)
--- and falls back to a literal when it does not compile; the default `--fixed-strings` grep takes it
--- LITERALLY — as a regex, `a.b` would also light up `axb`, characters ripgrep never matched. Either way it
--- follows ripgrep's `--smart-case`: a pattern without an uppercase letter matches case-insensitively, one
--- with any uppercase letter matches exactly. Bounded by construction: the previewed slice is at most
--- `preview_max_lines` long and each line yields at most one range per starting column.
---@param lines string[]
---@param pattern string?
---@param regex boolean?  the pattern is a regex (a regex grep); default a fixed string
---@return { row: integer, c0: integer, c1: integer }[]
function M.preview_matches(lines, pattern, regex)
    if type(pattern) ~= "string" or pattern == "" then
        return {}
    end
    local smart_ci = not pattern:find("%u") -- rg --smart-case: no uppercase letter → case-insensitive
    local out = {}
    if regex then
        local ok, rx = pcall(vim.regex, (smart_ci and "\\c" or "\\C") .. pattern)
        if ok and rx then
            for i, line in ipairs(lines) do
                local from = 0
                while from <= #line do
                    local s0, e0 = rx:match_str(line:sub(from + 1))
                    if s0 == nil or e0 <= s0 then
                        break
                    end
                    out[#out + 1] = { row = i - 1, c0 = from + s0, c1 = from + e0 }
                    from = from + e0
                end
            end
            return out
        end
    end
    local needle = smart_ci and pattern:lower() or pattern
    for i, line in ipairs(lines) do
        local hay = smart_ci and line:lower() or line
        local at = 1
        while true do
            local s0, e0 = hay:find(needle, at, true)
            if s0 == nil then
                break
            end
            out[#out + 1] = { row = i - 1, c0 = s0 - 1, c1 = e0 }
            at = e0 + 1
        end
    end
    return out
end

return M
