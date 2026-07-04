#!/usr/bin/env bash
#
# install.sh — put `jdebug` on your PATH by symlinking this kit's CLI into a bin
# directory. The CLI resolves symlinks, so it finds the rest of the kit (lib/,
# capture/, observe/, ui/) relative to its real location here.
#
# Usage:
#   ./install.sh                 # symlink into ~/.local/bin (or $PREFIX)
#   ./install.sh --prefix ~/bin  # into a bin dir of your choice
#   ./install.sh --uninstall     # remove the symlink
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$KIT/jdebug"
PREFIX="${PREFIX:-$HOME/.local/bin}"
ACTION=install
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)    PREFIX="$2"; shift 2 ;;
        --uninstall) ACTION=uninstall; shift ;;
        -h|--help)   sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

LINK="$PREFIX/jdebug"

if [[ "$ACTION" == uninstall ]]; then
    if [[ -L "$LINK" ]]; then rm -f "$LINK"; echo "removed $LINK"; else echo "nothing at $LINK"; fi
    exit 0
fi

[[ -x "$CLI" ]] || { echo "error: CLI not found/executable: $CLI" >&2; exit 1; }
mkdir -p "$PREFIX"
ln -sf "$CLI" "$LINK"
echo "installed: $LINK -> $CLI"

case ":$PATH:" in
    *":$PREFIX:"*) echo "run: jdebug --help" ;;
    *) echo "note: $PREFIX is not on your PATH. Add it:"
       echo "  echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc   # or ~/.bashrc" ;;
esac
