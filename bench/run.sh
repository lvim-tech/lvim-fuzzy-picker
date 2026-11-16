#!/usr/bin/env bash
# lvim-picker against fzf-lua, snacks.picker, mini.pick, telescope and tv.nvim, each as a whole plugin.
#
#   bench/run.sh [SOURCE_TREE]
#
# Every plugin runs in its own headless Neovim with its default settings and opens its picker on
# `cat <corpus>` (the way a files / grep picker runs a command). The time is taken from opening the
# picker to the whole list loaded, and from typing a query (as keys) to its result being ready.
# Corpora: up to 1 000 000 paths under $HOME (fd) and up to 300 000 ripgrep lines of SOURCE_TREE
# (default: the directory above this plugin). Results: $BENCH_DIR/results.jsonl, a table on stdout.
# Needs: nvim, git, fd, rg, fzf, cargo (builds television into the cache dir), and the lvim-* checkouts
# beside this one (or $LVIM_PLUGINS_DIR).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
export LVIM_PLUGINS_DIR="${LVIM_PLUGINS_DIR:-$(dirname "$(dirname "$HERE")")}"
export BENCH_DIR="${BENCH_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lvim-picker-bench}"
SRC="${1:-$LVIM_PLUGINS_DIR}"
mkdir -p "$BENCH_DIR/plugins"

# the other pickers, at the commits the published numbers were taken with
clone() { # repo commit
    local dir="$BENCH_DIR/plugins/${1#*/}"
    [ -d "$dir" ] || git clone -q https://github.com/$1 "$dir"
    git -C "$dir" -c advice.detachedHead=false checkout -q "$2"
}
clone ibhagwan/fzf-lua 82ddfe6
clone folke/snacks.nvim 882c996
clone echasnovski/mini.pick 406d413
clone nvim-telescope/telescope.nvim 1e1bab7
clone nvim-lua/plenary.nvim 74b06c6
clone alexpasmantier/tv.nvim 4b156a2
[ -x "$BENCH_DIR/tvbin/bin/tv" ] || cargo install -q --root "$BENCH_DIR/tvbin" television --version 0.15.9 --locked

[ -s "$BENCH_DIR/files.txt" ] || fd --type f --hidden --no-ignore --exclude .git . "$HOME" 2>/dev/null | head -1000000 > "$BENCH_DIR/files.txt"
[ -s "$BENCH_DIR/grep.txt" ] || rg --no-heading --line-number --column -S 'e' "$SRC" 2>/dev/null | cut -c1-400 | head -300000 > "$BENCH_DIR/grep.txt"

out="$BENCH_DIR/results.jsonl"
: > "$out"
for c in files grep; do
    if [ $c = files ]; then Q=(hel lvim config initlua); else Q=(err function return); fi
    for e in lvim-picker fzf-lua tv.nvim snacks mini.pick telescope; do
        timeout 1800 nvim --headless -u NONE -l "$HERE/drv.lua" $e $c "${Q[@]}" 2>/dev/null | grep '^{' >> "$out" || true
    done
done

# one row per plugin and corpus: load, each query, mean of the queries (ms)
nvim --headless -u NONE -l - "$out" <<'LUA'
local rows, order = {}, {}
for l in io.lines(arg[1]) do
    local r = vim.json.decode(l)
    local k = r.corpus .. " " .. r.engine
    if not rows[k] then
        rows[k] = { corpus = r.corpus, engine = r.engine, load = r.load_ms, q = {} }
        order[#order + 1] = k
    end
    table.insert(rows[k].q, ("%s %.1f"):format(r.query, r.ms))
    rows[k].sum = (rows[k].sum or 0) + r.ms
end
for _, k in ipairs(order) do
    local r = rows[k]
    io.write(("%-6s %-12s load %8.1f   %s   mean %.1f\n"):format(r.corpus, r.engine, r.load, table.concat(r.q, "  "), r.sum / #r.q))
end
LUA
