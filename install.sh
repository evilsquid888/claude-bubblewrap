#!/usr/bin/env bash
# Install the bubblewrap launcher and command symlinks for the current user.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_DIR="${AI_JAIL_INSTALL_DIR:-$HOME/.local/lib/ai-agent-jail}"
BIN_DIR="${AI_JAIL_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
install -m 0755 "$SCRIPT_DIR/agent-sandbox.sh" "$INSTALL_DIR/agent-sandbox.sh"

for command in claudejail pijail qwenjail grokjail; do
    ln -sfn "$INSTALL_DIR/agent-sandbox.sh" "$BIN_DIR/$command"
done

echo "Installed: $BIN_DIR/{claudejail,pijail,qwenjail,grokjail}"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Add $BIN_DIR to PATH before using the commands." ;;
esac
