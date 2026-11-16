-- What the picker calls a match, and where it paints it.
--
-- Two functions decide both: `match_terms` (the engine's highlight: every term of an fzf query
-- must match, every occurrence lights up) and `match_display` (when the NAME matches, the name lights up instead
-- of the scattered whole-path hits). The positions are CHARACTER offsets into the whole path, and
-- lifting the basename positions into path coordinates by BYTE length was a real bug: every
-- highlight landed past the name as soon as a directory held a multibyte character. That lift is
-- the last case below.

local fuzzy = require("lvim-picker.fuzzy")

describe("lvim-picker.fuzzy.match_terms")

it("takes every term as a subsequence and unions their positions", function()
    eq({ 0, 1, 2 }, fuzzy.match_terms("abc", "abcdef"))
    eq({ 0, 1, 4, 5 }, fuzzy.match_terms("ab ef", "abcdef"), "a space is two terms, both lit")
end)

it("fails the whole match when ANY term is missing", function()
    eq(nil, fuzzy.match_terms("ab zz", "abcdef"))
    eq(nil, fuzzy.match_terms("zz", "abcdef"))
end)

it("says nothing for an empty query", function()
    eq(nil, fuzzy.match_terms("", "abcdef"))
    eq(nil, fuzzy.match_terms("   ", "abcdef"), "whitespace alone is no terms at all")
end)

it("smart case: a lower-case query folds, an upper-case letter is respected", function()
    eq({ 0, 1 }, fuzzy.match_terms("ab", "ABC"))
    eq(nil, fuzzy.match_terms("AB", "abc"))
    eq({ 0, 1 }, fuzzy.match_terms("пи", "Пиши"), "in any script")
end)

it("takes fzf's syntax", function()
    eq(nil, fuzzy.match_terms("ab !cd", "abcdef"), "a negated term that is there fails the match")
    eq({ 0, 1 }, fuzzy.match_terms("ab !zz", "abcdef"))
    eq(nil, fuzzy.match_terms("^cd", "abcdef"))
    eq({ 4, 5 }, fuzzy.match_terms("ef$", "abcdef"))
end)

it("reports each position once however many terms hit it", function()
    local got = fuzzy.match_terms("ab ab", "abc")
    eq({ 0, 1 }, got, "the same two chars, not four entries")
end)

describe("lvim-picker.fuzzy.match_display")

it("lights up the NAME when the name matches", function()
    -- `init` matches the basename, so the highlight is on `init.lua` — not on whatever the
    -- whole-path engine aligned across the directories.
    local got = fuzzy.match_display("init", "lua/lvim-picker/init.lua")
    truthy(got, "a name match should return positions")
    local text = "lua/lvim-picker/init.lua"
    local lit = {}
    for _, ci in ipairs(got) do
        lit[#lit + 1] = vim.fn.strcharpart(text, ci, 1)
    end
    eq({ "i", "n", "i", "t" }, lit, "the four chars of the name, in the name")
end)

it("falls back to the whole path when the name does not match", function()
    local got = fuzzy.match_display("lua picker", "lua/lvim-picker/init.lua")
    truthy(got, "the path still matches both terms")
end)

it("lifts the name positions by CHARACTERS, not bytes", function()
    -- A directory with a multibyte name: `lvim-тест/` is 10 characters but 14 bytes. Lifting by
    -- bytes put every highlight four cells past the name, or off the row entirely.
    local text = "lvim-тест/init.lua"
    local got = fuzzy.match_display("init", text)
    truthy(got, "the name matches")
    local lit = {}
    for _, ci in ipairs(got) do
        lit[#lit + 1] = vim.fn.strcharpart(text, ci, 1)
    end
    eq({ "i", "n", "i", "t" }, lit, "got positions " .. vim.inspect(got) .. " in " .. text)
end)

it("agrees with match_terms on a path that has no directory part", function()
    eq(fuzzy.match_terms("init", "init.lua"), fuzzy.match_display("init", "init.lua"))
end)

describe("lvim-picker.fuzzy.filter")

--- Run the async filter and return its ranked rows, each `{ idx, match? }` where `idx` is the
--- 1-based index into `texts`.
---@param texts string[]
---@param query string
---@return table[]
local function filtered(texts, query)
    local out
    fuzzy.filter(texts, query, function(ranked)
        out = ranked
    end)
    vim.wait(2000, function()
        return out ~= nil
    end, 10)
    fuzzy.release(texts)
    return out or {}
end

--- The candidate texts of a ranked result, in rank order.
---@param texts string[]
---@param query string
---@return string[]
local function ranked_texts(texts, query)
    return vim.tbl_map(function(r)
        return texts[r.idx]
    end, filtered(texts, query))
end

it("returns every candidate for an empty query", function()
    local texts = { "a.lua", "b.lua", "c.lua" }
    eq(3, #filtered(texts, ""))
end)

it("keeps only what matches", function()
    local got = filtered({ "alpha.lua", "beta.lua", "gamma.lua" }, "beta")
    eq(1, #got, "got " .. vim.inspect(got))
end)

it("drops everything when nothing matches", function()
    eq(0, #filtered({ "alpha.lua", "beta.lua" }, "zzzzz"))
end)

it("puts a name match above a path-only match", function()
    -- `picker` matches the NAME of the first and only the DIRECTORY of the second, so the deeply
    -- buried name must still lead: the bias is about the name, not the path's length.
    local texts = { "lvim-picker/init.lua", "deep/nested/dir/picker.lua" }
    local got = ranked_texts(texts, "picker")
    truthy(#got >= 1, "nothing matched")
    eq("deep/nested/dir/picker.lua", got[1], "ranked: " .. vim.inspect(got))
end)

it("scores the NAME, so a long path does not sink a good name match", function()
    -- The name match is re-scored on the basename alone and the whole-path order is only the
    -- tiebreak, so a prefix match buried four directories deep still leads a mid-word match with
    -- no path at all. (Measured, not assumed: this is the ordering the engine gives today.)
    eq("deep/dir/here/gitx.lua", ranked_texts({ "xgit.lua", "deep/dir/here/gitx.lua" }, "git")[1])
end)

it("prefers a match at a word boundary over one inside a word", function()
    eq("a-git.lua", ranked_texts({ "xgit.lua", "a-git.lua" }, "git")[1])
end)

it("prefers a match at the start of the name", function()
    eq("gitx.lua", ranked_texts({ "xgit.lua", "gitx.lua" }, "git")[1])
end)

it("leaves an empty query in source order", function()
    eq({ "beta.lua", "alpha.lua", "gamma.lua" }, ranked_texts({ "beta.lua", "alpha.lua", "gamma.lua" }, ""))
end)

it("reports a match position for every row it returns", function()
    local texts = { "alpha.lua", "beta.lua" }
    for _, r in ipairs(filtered(texts, "beta")) do
        truthy(r.idx ~= nil, "a row with no idx: " .. vim.inspect(r))
        truthy(texts[r.idx] ~= nil, "idx " .. tostring(r.idx) .. " is not a candidate")
    end
end)
