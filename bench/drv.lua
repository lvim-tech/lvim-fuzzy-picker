-- nvim --headless -u NONE -l drv.lua <engine> <corpus> <query>...   (env BENCH_DIR, LVIM_PLUGINS_DIR; see run.sh)
-- Starts a server with srv.lua, opens the picker, waits for the whole list, then for each query clears the
-- prompt and types it, and prints one JSON line: { engine, corpus, query, load_ms, ms, hits }.
local engine, corpus = arg[1], arg[2]
local queries = { unpack(arg, 3) }
local D = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
-- a short path: a unix socket's path is limited to ~108 bytes
local sock = ("%s/lvim-picker-bench.%d"):format(vim.env.XDG_RUNTIME_DIR or "/tmp", vim.fn.getpid())
local job = vim.fn.jobstart({ "nvim", "--headless", "--listen", sock, "-u", "NONE", "-i", "NONE", "-c", "luafile " .. D .. "/srv.lua" }, {
    env = { BENCH_ENGINE = engine, BENCH_CORPUS = corpus, BENCH_DIR = vim.env.BENCH_DIR, LVIM_PLUGINS_DIR = vim.env.LVIM_PLUGINS_DIR },
    on_stderr = function(_, d)
        local s = table.concat(d, "\n")
        if s:match("%S") then
            io.stderr:write("[srv] ", s, "\n")
        end
    end,
})
local ch
vim.wait(10000, function()
    if not vim.uv.fs_stat(sock) then
        return false
    end
    local ok, c = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
    ch = ok and c > 0 and c or nil
    return ch ~= nil
end, 20)
assert(ch and ch > 0, "no server")
local function lua(code)
    return vim.rpcrequest(ch, "nvim_exec_lua", code, {})
end
-- wait until the server's script has run
vim.wait(10000, function()
    local ok, v = pcall(lua, "return _G.B ~= nil")
    return ok and v
end, 20)

local TIMEOUT = 600000
lua("B.open()")
local ok = vim.wait(TIMEOUT, function()
    return lua("return B.loaded") ~= vim.NIL
end, 5)
local load_ms = ok and lua("return B.loaded") or -1
local prev = ""
for _, q in ipairs(queries) do
    -- clear the prompt (one Backspace per character typed before) and let the empty query settle
    if prev ~= "" then
        lua(("B.query(%q, %q)"):format("", ("<BS>"):rep(#prev)))
        vim.wait(TIMEOUT, function()
            return lua('return B.done[""] ~= nil') == true
        end, 5)
        lua('B.done[""] = nil')
    end
    lua(("B.query(%q)"):format(q))
    local done = vim.wait(TIMEOUT, function()
        return lua(("return B.done[%q] ~= nil"):format(q)) == true
    end, 2)
    local r = done and lua(("return B.done[%q]"):format(q)) or { ms = -1, hits = -1 }
    lua(("B.done[%q] = nil"):format(q))
    prev = q
    io.stdout:write(vim.json.encode({ engine = engine, corpus = corpus, query = q, load_ms = load_ms, ms = r.ms, hits = r.hits }), "\n")
end
pcall(vim.rpcnotify, ch, "nvim_command", "qa!")
vim.wait(2000, function()
    return vim.fn.jobwait({ job }, 0)[1] ~= -1
end, 20)
vim.fn.jobstop(job)
