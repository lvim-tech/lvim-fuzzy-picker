#!/bin/sh
# What lvim-picker runs through, installed from nothing but git and cargo (no terminal program, no other checkout is needed first):
#   lvim-plugin           the plugin host, and its preview and open plugins (pictures, file facts, opening with the system's program)
#   lvim-fuzzy-cli        the modes of lfz (git log, processes, docker, systemd, ssh, …) the picker offers as finders
# With lvim-pack: build = "sh scripts/install.sh".  By hand: sh scripts/install.sh
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
parts="host preview open cli"
boot=$here/../lvim-fuzzy-plugin/scripts/bootstrap.sh
if [ -f "$boot" ]; then
    sh "$boot" $parts
else
    curl -fsSL https://raw.githubusercontent.com/lvim-tech/lvim-fuzzy-plugin/main/scripts/bootstrap.sh | sh -s -- $parts
fi
