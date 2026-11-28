#!/bin/sh
# What lvim-picker runs through, installed from nothing but git and cargo (no terminal program, no other checkout is needed first):
#   lvim-plugin           the plugin host, and its preview and open plugins (pictures, file facts, opening with the system's program)
#   the modes plugin      the modes (git log, processes, docker, systemd, ssh, …) the picker offers as finders
# With lvim-pack: build = "sh scripts/install.sh".  By hand: sh scripts/install.sh
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
parts="host preview open modes"
boot=$here/../lvim-fuzzy-plugin/scripts/bootstrap.sh
if [ -f "$boot" ]; then
    sh "$boot" $parts
else
    tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/lvim-tech/lvim-fuzzy-plugin/main/scripts/bootstrap.sh -o "$tmp" || { echo "install: cannot fetch bootstrap.sh (no network?)" >&2; rm -f "$tmp"; exit 1; }
    rc=0; sh "$tmp" $parts || rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ] || exit "$rc"
fi
