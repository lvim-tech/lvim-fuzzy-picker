-- The server side, started by drv.lua: nvim --headless --listen SOCK -u NONE -c "luafile srv.lua"
-- (env BENCH_ENGINE, BENCH_CORPUS, BENCH_DIR = the work dir with plugins/ and the corpora,
-- LVIM_PLUGINS_DIR = the directory holding the lvim-* checkouts).
-- Each plugin opens its picker on `cat <corpus>` (the way a files / grep picker runs a command) with its
-- default settings. Hooks note when the list is fully loaded and when the result for a query is ready:
--   B.loaded  = ms from open to the whole list loaded (empty query)
--   B.done[q] = { ms = from the query's keys being sent to its result being ready, hits = matches }
local B = { done = {} }
_G.B = B
local D = assert(vim.env.BENCH_DIR, "BENCH_DIR")
local LUA = assert(vim.env.LVIM_PLUGINS_DIR, "LVIM_PLUGINS_DIR")
local engine, corpus = vim.env.BENCH_ENGINE, vim.env.BENCH_CORPUS
local file = D .. "/" .. corpus .. ".txt"
B.N = tonumber(vim.fn.system({ "sh", "-c", "wc -l < " .. file }))
vim.o.columns, vim.o.lines = 200, 50
vim.o.swapfile = false

local now = vim.uv.hrtime
local t_open, t_query, cur_q
local function mark_loaded()
    if not B.loaded and t_open then
        B.loaded = (now() - t_open) / 1e6
    end
end
local function mark_done(q, hits)
    if q == cur_q and t_query and not B.done[q] then
        B.done[q] = { ms = (now() - t_query) / 1e6, hits = hits }
    end
end

--- Send the keys of `q` (after clearing the prompt) and start the clock.
function B.query(q, clear)
    cur_q = q
    t_query = now()
    vim.api.nvim_input((clear or "") .. q)
end

local A = {}

A["lvim-picker"] = function()
    for name, kind in vim.fs.dir(LUA) do
        if kind == "directory" and name:match("^lvim%-") then
            vim.opt.rtp:append(LUA .. "/" .. name)
        end
    end
    local fuzzy = require("lvim-picker.fuzzy")
    local orig = fuzzy.blob_filter
    fuzzy.blob_filter = function(blob, q, cb, opts)
        return orig(blob, q, function(list, total)
            if q == "" and B.streamed and total == B.N then
                mark_loaded()
            end
            mark_done(q, total)
            return cb(list, total)
        end, opts)
    end
    return function()
        require("lvim-picker").open({
            title = "bench",
            blob_stream = function(feed, done)
                local p = vim.system({ "cat", file }, {
                    stdout = function(_, data)
                        if data then
                            vim.schedule(function()
                                feed(data)
                            end)
                        end
                    end,
                }, function()
                    vim.schedule(function()
                        B.streamed = true
                        done()
                    end)
                end)
                return function()
                    pcall(p.kill, p, 9)
                end
            end,
            blob_item = function(t)
                return { path = t }
            end,
            on_confirm = function() end,
        })
    end, "<C-u>"
end

A["fzf-lua"] = function()
    vim.opt.rtp:append(D .. "/plugins/fzf-lua")
    local log = D .. "/fzf-events." .. vim.fn.getpid()
    vim.fn.writefile({}, log)
    -- fzf's own `result` event: the result list for the current query is complete
    local action = ("execute-silent(printf '%%s\\t%%s\\t%%s\\n' {q} $FZF_MATCH_COUNT $FZF_TOTAL_COUNT >> %s)"):format(log)
    local timer = vim.uv.new_timer()
    local seen = 0
    timer:start(0, 1, function()
        local fh = io.open(log, "r")
        if not fh then
            return
        end
        local lines = {}
        for l in fh:lines() do
            lines[#lines + 1] = l
        end
        fh:close()
        for i = seen + 1, #lines do
            local q, m, t = lines[i]:match("^(.-)\t(%d+)\t(%d+)$")
            if t and tonumber(t) == B.N then
                vim.schedule(function()
                    if q == "" then
                        mark_loaded()
                    end
                    mark_done(q, tonumber(m))
                end)
            end
        end
        seen = #lines
    end)
    return function()
        require("fzf-lua").fzf_exec("cat " .. file, {
            winopts = { preview = { hidden = true } },
            keymap = { fzf = { result = action } },
        })
    end, "<C-u>"
end

A["telescope"] = function()
    vim.opt.rtp:append(D .. "/plugins/telescope.nvim")
    vim.opt.rtp:append(D .. "/plugins/plenary.nvim")
    require("telescope").setup({})
    local pickers, finders = require("telescope.pickers"), require("telescope.finders")
    local conf = require("telescope.config").values
    return function()
        local p = pickers.new({}, {
            prompt_title = "bench",
            finder = finders.new_oneshot_job({ "cat", file }, {}),
            sorter = conf.file_sorter({}),
            previewer = false,
        })
        p:register_completion_callback(function(self)
            local q = self:_get_prompt()
            if q == "" and self.finder.done ~= false and self.stats.processed == B.N then
                mark_loaded()
            end
            if self.stats.processed == B.N then
                mark_done(q, self.manager and self.manager:num_results() or -1)
            end
        end)
        p:find()
    end, "<C-u>"
end

A["snacks"] = function()
    vim.opt.rtp:append(D .. "/plugins/snacks.nvim")
    _G.Snacks = require("snacks")
    Snacks.setup({ picker = { enabled = true } })
    local picker
    local timer = vim.uv.new_timer()
    timer:start(0, 1, vim.schedule_wrap(function()
        if not picker or picker.closed then
            return
        end
        if picker.finder:running() or picker.matcher:running() then
            return
        end
        if picker:count() ~= B.N then
            return
        end
        local q = picker.matcher.pattern or ""
        if q == "" then
            mark_loaded()
        end
        mark_done(q, picker.list:count())
    end))
    return function()
        picker = Snacks.picker.pick({
            title = "bench",
            finder = "proc",
            cmd = "cat",
            args = { file },
            preview = false,
            layout = { preview = false },
        })
    end, "<C-u>"
end

A["mini.pick"] = function()
    vim.opt.rtp:append(D .. "/plugins/mini.pick")
    local MiniPick = require("mini.pick")
    MiniPick.setup({})
    local items_n
    vim.api.nvim_create_autocmd("User", {
        pattern = "MiniPickMatch",
        callback = function()
            if not items_n then
                local it = MiniPick.get_picker_items()
                if it and #it == B.N then
                    items_n = #it
                    mark_loaded()
                end
                return
            end
            local q = table.concat(MiniPick.get_picker_query() or {})
            if q == cur_q and not B.done[q] then
                local m = MiniPick.get_picker_matches()
                mark_done(q, m and m.all_inds and #m.all_inds or -1)
            end
        end,
    })
    return function()
        MiniPick.builtin.cli({ command = { "cat", file } })
    end, "<C-u>"
end

local open, clear = A[engine]()
B.clear = clear
function B.open()
    t_open = now()
    vim.schedule(open) -- a modal picker (mini.pick) must not block the RPC call that opened it
end
