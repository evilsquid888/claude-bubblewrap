#!/usr/bin/env bash
# Install a jail launcher and command symlinks for the current user.
#
# Usage:
#   ./install.sh            # bubblewrap backend (agent-sandbox.sh)
#   ./install.sh firejail   # firejail backend (claude-firejail.sh)
#
# Both backends support the same commands: claudejail, pijail, qwenjail,
# grokjail, opencodejail, dshjail. Use firejail where bwrap is blocked by AppArmor.
set -euo pipefail

BACKEND="${1:-bwrap}"
case "$BACKEND" in
    bwrap|bubblewrap) SRC="agent-sandbox.sh";   TARGET="agent-sandbox.sh" ;;
    firejail)         SRC="claude-firejail.sh"; TARGET="agent-firejail.sh" ;;
    *) echo "Usage: $0 [bwrap|firejail]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_DIR="${AI_JAIL_INSTALL_DIR:-$HOME/.local/lib/ai-agent-jail}"
BIN_DIR="${AI_JAIL_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
install -m 0755 "$SCRIPT_DIR/$SRC" "$INSTALL_DIR/$TARGET"

for command in claudejail pijail qwenjail grokjail opencodejail dshjail; do
    ln -sfn "$INSTALL_DIR/$TARGET" "$BIN_DIR/$command"
done

echo "Installed ($BACKEND): $BIN_DIR/{claudejail,pijail,qwenjail,grokjail,opencodejail,dshjail}"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Add $BIN_DIR to PATH before using the commands." ;;
esac
