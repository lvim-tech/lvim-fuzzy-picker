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
-- The search itself is the engine's (lvim-fuzzy-core reads the part of each row a scope names, and reads the
-- files for "file"); this module only names the scopes and splits a row for the highlight.
--
---@module "lvim-picker.scope"

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

--- Literal smart-case terms of a query (fzf markers stripped, negations and `|` dropped) — what the "file"
--- scope highlights on a row's line. Smart case in any script.
---@param query string
---@return { text: string, ci: boolean }[]
function M.terms(query)
    local out = {}
    for tok in (query or ""):gmatch("%S+") do
        if tok ~= "|" and tok:sub(1, 1) ~= "!" then
            local t = tok:gsub("^['^]+", ""):gsub("[$']+$", "")
            if t ~= "" then
                out[#out + 1] = { text = t, ci = vim.fn.tolower(t) == t }
            end
        end
    end
    return out
end

return M
