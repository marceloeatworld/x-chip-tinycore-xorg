#!/bin/bash
set -euo pipefail

# Fetch source-side dependencies expected next to this repo. This does not flash
# anything; it only clones or updates the helper repositories used by the build
# and flashing scripts.

HERE=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(cd "$HERE/.." && pwd)

clone_or_fetch() {
    local url=$1 dest=$2
    if [ -d "$dest/.git" ]; then
        echo ">> updating $dest"
        git -C "$dest" fetch --all --prune
    elif [ -e "$dest" ]; then
        echo "ERROR: $dest exists but is not a git checkout" >&2
        exit 1
    else
        echo ">> cloning $url -> $dest"
        git clone "$url" "$dest"
    fi
}

command -v git >/dev/null || { echo "need git" >&2; exit 1; }

clone_or_fetch https://github.com/macromorgan/chip-debroot.git "$BASE/chip-debroot"
clone_or_fetch https://github.com/nextthingco/x-chip-tools.git "$BASE/x-chip-tools"

if [ ! -f "$BASE/chip-debroot/deb_files/usr/local/share/keymaps/pocketchip.kmap" ] && [ ! -f "$BASE/pocketchip.kmap" ]; then
    cat >&2 <<EOF
WARN: PocketCHIP keymap is missing.

The build can continue only if you provide a PocketCHIP console keymap:

  KEYMAP_SOURCE=/path/to/pocketchip.kmap make container-build

or place it at one of:

  $BASE/chip-debroot/deb_files/usr/local/share/keymaps/pocketchip.kmap
  $BASE/pocketchip.kmap
EOF
fi

echo ">> dependency check complete"
