-- lvim-picker.scope: what a grep FILTER reads in each result (`path:lnum[:col]:text`).
--
-- In FILTER mode (rg frozen, the typed query fuzzy-narrows the loaded hits) the query used to run over the
-- WHOLE row — path included — so a word that sat only in a file NAME kept rows whose line never said it, and
-- the preview's focused line then had nothing to show. The scope says which part the filter reads:
--   • "line" (default) — the line's text after the locator: every row left holds the query on its own line;
--   • "path"           — the file path only;
--   • "file"           — the whole file: a row stays when its FILE contains every query term (exact,
--                        smart-case — a fuzzy subsequence over a whole file would match almost anything).
-- `<C-s>` (config `keys.grep_scope`) cycles them; the title and the footer show the current one.
--
-- "line" / "path" filter a DERIVED native blob holding just that part of each row, in the same order — so a
-- result's index is the same in both and the row is rendered from the original. It is built once per scope
-- and rebuilt only when the pool grew.
--
---@module "lvim-picker.scope"

local engine = require("lvim-fuzzy")

local M = {}

M.ORDER = { "line", "path", "file" }

--- The next scope in the cycle.
---@param s string
---@return string
function M.next(s)
    for i, v in ipairs(M.ORDER) do
        if v == s then
            return M.ORDER[i % #M.ORDER + 1]
        end
    end
    return M.ORDER[1]
end

--- Split a grep row into its locator (`path:lnum:` or `path:lnum:col:`) and the line's text.
---@param text string
---@return string? path, string? locator, string? body
function M.split(text)
    local loc = text:match("^[^:]+:%d+:%d+:") or text:match("^[^:]+:%d+:")
    if not loc then
        return nil
    end
    return text:match("^([^:]+):"), loc, text:sub(#loc + 1)
end

--- The part of a row a scope reads ("line" → the text, "path" → the path); the whole row when it is not a
--- grep row.
---@param text string
---@param scope string
---@return string
function M.part(text, scope)
    local path, _, body = M.split(text)
    if not path then
        return text
    end
    return scope == "path" and path or body
end

--- A native blob holding `part(row, scope)` for every row of `blob`, same order (nil when blobs are absent).
---@param blob LvimFuzzyBlob
---@param scope "line"|"path"
---@return LvimFuzzyBlob?, integer
function M.derive(blob, scope)
    local n = engine.blob_count(blob)
    local d = engine.blob_new and engine.blob_new()
    if not d then
        return nil, n
    end
    local chunk, size = {}, 0
    for i = 1, n do
        -- a newline inside a part would split one candidate into two and shift every index after it
        local p = M.part(engine.blob_text(blob, i) or "", scope):gsub("\n", " ")
        chunk[#chunk + 1] = p
        size = size + #p
        if size > 65536 then
            engine.blob_append(d, table.concat(chunk, "\n") .. "\n")
            chunk, size = {}, 0
        end
    end
    if #chunk > 0 then
        engine.blob_append(d, table.concat(chunk, "\n") .. "\n")
    end
    engine.blob_flush(d)
    return d, n
end

--- Literal smart-case terms of a query (fzf markers stripped, negations and `|` dropped).
---@param query string
---@return { text: string, ci: boolean }[]
function M.terms(query)
    local out = {}
    for tok in (query or ""):gmatch("%S+") do
        if tok ~= "|" and tok:sub(1, 1) ~= "!" then
            local t = tok:gsub("^['^]+", ""):gsub("[$']+$", "")
            if t ~= "" then
                out[#out + 1] = { text = t, ci = not t:find("%u") }
            end
        end
    end
    return out
end

local file_cache = {}

--- A file's text (read once; nil for unreadable, binary or > 2 MiB files).
---@param path string
---@return string|false
local function file_text(path)
    local c = file_cache[path]
    if c ~= nil then
        return c
    end
    local st = vim.uv.fs_stat(path)
    local text = false
    if st and st.type == "file" and st.size <= 2 * 1024 * 1024 then
        local fh = io.open(path, "rb")
        if fh then
            local data = fh:read("*a") or ""
            fh:close()
            if not data:sub(1, 8192):find("\0", 1, true) then
                text = data
            end
        end
    end
    file_cache[path] = text
    return text
end

--- Whether `path`'s content holds every term.
---@param path string
---@param terms { text: string, ci: boolean }[]
---@return boolean
function M.file_has(path, terms)
    local text = file_text(path)
    if not text then
        return false
    end
    local lower
    for _, t in ipairs(terms) do
        local hay = text
        if t.ci then
            lower = lower or text:lower()
            hay = lower
        end
        if not hay:find(t.ci and t.text:lower() or t.text, 1, true) then
            return false
        end
    end
    return true
end

--- The "file" scope: every row of `blob` whose FILE holds the query, in source order (capped at `max`).
---@param blob LvimFuzzyBlob
---@param query string
---@param max integer
---@return { idx: integer, text: string }[], integer total
function M.file_filter(blob, query, max)
    local terms = M.terms(query)
    local n = engine.blob_count(blob)
    local out, total, verdict = {}, 0, {}
    for i = 1, n do
        local text = engine.blob_text(blob, i) or ""
        local path = M.split(text)
        local keep
        if #terms == 0 then
            keep = true
        elseif path then
            keep = verdict[path]
            if keep == nil then
                keep = M.file_has(path, terms)
                verdict[path] = keep
            end
        else
            keep = false
        end
        if keep then
            total = total + 1
            if #out < max then
                out[#out + 1] = { idx = i, text = text }
            end
        end
    end
    return out, total
end

--- Drop the cached file texts (a new grep run may have edited files since).
function M.reset()
    file_cache = {}
end

return M
