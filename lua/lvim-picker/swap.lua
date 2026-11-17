-- lvim-picker.swap: one backend swap (tint list ⇄ fzf TUI) at a time.
--
-- A HELD swap key repeats. Between closing one backend and opening the other, focus rests in a window where
-- the picker has not bound the key, so each repeat landed on Neovim's own `<C-]>` (jump to the tag under the
-- cursor → "E349: No identifier under cursor"), and a repeat that reached a backend started a second swap
-- while the first was still running, which tore the finder down. So while a swap runs (and for a moment after
-- the new backend opens) further swaps are ignored and the swap keys do nothing anywhere. A global mapping the
-- user has for those keys is saved and put back afterwards.
--
---@module "lvim-picker.swap"

local M = {}

local MODES = { "n", "i", "t", "x" }
-- how long the swap keys stay inert after the swap starts: covers the teardown, the new backend opening and
-- (for fzf) its process starting
local SETTLE_MS = 400

local busy = false

--- Run `fn` (the swap) unless one is already running; `keys` are the swap keys to make inert meanwhile.
---@param keys string[]
---@param fn fun()
---@return boolean ran  false when a swap was already running (this request is dropped)
function M.run(keys, fn)
    if busy then
        return false
    end
    busy = true
    local saved = {}
    for _, lhs in ipairs(keys) do
        for _, mode in ipairs(MODES) do
            local prev = vim.fn.maparg(lhs, mode, false, true)
            if prev and not vim.tbl_isempty(prev) and prev.buffer == 0 then
                saved[#saved + 1] = { mode = mode, map = prev }
            end
            vim.keymap.set(mode, lhs, "<Nop>", { desc = "lvim-picker: backend swap in progress" })
        end
    end
    vim.defer_fn(function()
        for _, lhs in ipairs(keys) do
            for _, mode in ipairs(MODES) do
                pcall(vim.keymap.del, mode, lhs)
            end
        end
        for _, s in ipairs(saved) do
            pcall(vim.fn.mapset, s.mode, false, s.map)
        end
        busy = false
    end, SETTLE_MS)
    local ok, err = pcall(fn)
    if not ok then
        vim.notify("lvim-picker: backend swap failed: " .. tostring(err), vim.log.levels.WARN)
    end
    return true
end

--- Whether a swap is running now.
---@return boolean
function M.busy()
    return busy
end

return M
