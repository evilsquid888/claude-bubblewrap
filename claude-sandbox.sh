#!/usr/bin/env bash
# claude-sandbox.sh — External bubblewrap jail for Claude Code
# 
# Belt-and-suspenders approach: wraps Claude Code in an OS-level
# sandbox OUTSIDE of Claude's own built-in sandbox. Even if Claude
# reasons its way around its internal sandbox, this outer jail holds.
#
# Policy:
#   - Network: fully open (no restrictions)
#   - Filesystem: project dir + explicit config paths only
#   - Everything else: invisible or read-only
#
# Usage:
#   ./claude-sandbox.sh                    # run in current project dir
#   ./claude-sandbox.sh /path/to/project   # specify project dir
#   ./claude-sandbox.sh /path/to/project --print "do something"  # pass args to claude

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Project directory: first arg if it's a directory, otherwise $PWD
if [[ -n "${1:-}" && -d "$1" ]]; then
    PROJECT_DIR="$(realpath "$1")"
    shift
else
    PROJECT_DIR="$(pwd)"
fi

# Paths Claude gets read-write access to
RW_PATHS=(
    "$PROJECT_DIR"
    "$HOME/.claude"
    "$HOME/.claude.json"
    "$HOME/.config/claude"
    "$HOME/.aws"
    "$HOME/.ssh"
    "$HOME/.gitconfig"
    "$HOME/.config/git"
    "$HOME/.npm-global"
    "$HOME/.npm"
    "$HOME/.local/share/claude-code"
    "/tmp"
)

# Paths Claude gets read-only access to (system stuff it needs to function)
RO_PATHS=(
    "/usr"
    "/lib"
    "/lib64"
    "/etc"
    "/bin"
    "/sbin"
    "/opt"
    "$HOME/.nvm"
    "$HOME/.fnm"
    "$HOME/.local/bin"
    "$HOME/.local/lib"
    "$HOME/.cargo/bin"
    "$HOME/.rustup"
    "$HOME/.pyenv"
    "$HOME/.config/pip"
    "$HOME/.config/nvm"
)

# Paths explicitly denied (even if they'd be caught by omission)
# These are the crown jewels you never want leaked
DENY_PATHS=(
    "$HOME/.gnupg/private-keys-v1.d"
    "$HOME/.password-store"
    "$HOME/.vault-token"
    "$HOME/.kube"
)

# ── Preflight checks ──────────────────────────────────────────────
if ! command -v bwrap &>/dev/null; then
    echo "ERROR: bubblewrap not installed."
    echo "  Ubuntu/Debian: sudo apt install bubblewrap"
    echo "  Fedora/RHEL:   sudo dnf install bubblewrap"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "ERROR: claude not found in PATH."
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

CLAUDE_BIN="$(command -v claude)"

# ── Build bwrap arguments ─────────────────────────────────────────
BWRAP_ARGS=()

# Process isolation
BWRAP_ARGS+=(--unshare-pid)      # isolate process namespace
BWRAP_ARGS+=(--die-with-parent)  # kill sandbox if parent dies

# NOTE: we do NOT --unshare-net because you want full network access
# If you ever want to lock down network, uncomment:
# BWRAP_ARGS+=(--unshare-net)

# Essential virtual filesystems
BWRAP_ARGS+=(--proc /proc)
BWRAP_ARGS+=(--dev /dev)
BWRAP_ARGS+=(--tmpfs /run)

# Read-only system mounts (non-home paths only; home-relative come after tmpfs)
for path in "${RO_PATHS[@]}"; do
    if [[ -e "$path" && "$path" != "$HOME"* ]]; then
        BWRAP_ARGS+=(--ro-bind "$path" "$path")
    fi
done

# Read-write mounts for non-home paths
for path in "${RW_PATHS[@]}"; do
    if [[ "$path" == "/tmp" ]]; then
        BWRAP_ARGS+=(--tmpfs /tmp)
    elif [[ -e "$path" && "$path" != "$HOME"* ]]; then
        BWRAP_ARGS+=(--bind "$path" "$path")
    fi
done

# Create home dir structure FIRST (so claude doesn't error on missing $HOME)
# This MUST come before all home-relative bind mounts, otherwise tmpfs wipes them.
BWRAP_ARGS+=(--tmpfs "$HOME")

# Layer read-only home-relative paths on top of the tmpfs home
for path in "${RO_PATHS[@]}"; do
    if [[ -e "$path" && "$path" == "$HOME"* ]]; then
        BWRAP_ARGS+=(--ro-bind "$path" "$path")
    fi
done

# Layer read-write home-relative paths on top of the tmpfs home
for path in "${RW_PATHS[@]}"; do
    if [[ -e "$path" && "$path" == "$HOME"* ]]; then
        BWRAP_ARGS+=(--bind "$path" "$path")
    fi
done

# Also bind the project dir (may be outside $HOME)
BWRAP_ARGS+=(--bind "$PROJECT_DIR" "$PROJECT_DIR")

# Block sensitive paths (overlay deny on top of everything)
for path in "${DENY_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        BWRAP_ARGS+=(--tmpfs "$path")
    fi
done

# Set working directory
BWRAP_ARGS+=(--chdir "$PROJECT_DIR")

# Pass through essential environment
BWRAP_ARGS+=(--setenv HOME "$HOME")
BWRAP_ARGS+=(--setenv USER "${USER:-$(whoami)}")
BWRAP_ARGS+=(--setenv TERM "${TERM:-xterm-256color}")
BWRAP_ARGS+=(--setenv PATH "$HOME/.local/bin:$HOME/.nvm/versions/node/$(ls $HOME/.nvm/versions/node/ 2>/dev/null | tail -1)/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin")
BWRAP_ARGS+=(--setenv LANG "${LANG:-en_US.UTF-8}")
BWRAP_ARGS+=(--setenv SHELL "/bin/bash")

# Pass through AWS env vars if set
[[ -n "${AWS_PROFILE:-}" ]]         && BWRAP_ARGS+=(--setenv AWS_PROFILE "$AWS_PROFILE")
[[ -n "${AWS_REGION:-}" ]]          && BWRAP_ARGS+=(--setenv AWS_REGION "$AWS_REGION")
[[ -n "${AWS_DEFAULT_REGION:-}" ]]  && BWRAP_ARGS+=(--setenv AWS_DEFAULT_REGION "$AWS_DEFAULT_REGION")
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]   && BWRAP_ARGS+=(--setenv AWS_ACCESS_KEY_ID "$AWS_ACCESS_KEY_ID")
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && BWRAP_ARGS+=(--setenv AWS_SECRET_ACCESS_KEY "$AWS_SECRET_ACCESS_KEY")
[[ -n "${AWS_SESSION_TOKEN:-}" ]]   && BWRAP_ARGS+=(--setenv AWS_SESSION_TOKEN "$AWS_SESSION_TOKEN")

# Pass through any ANTHROPIC env vars
[[ -n "${ANTHROPIC_API_KEY:-}" ]]   && BWRAP_ARGS+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")

# ── Summary ────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Claude Code — External Bubblewrap Sandbox          ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Project:  $(basename "$PROJECT_DIR")"
echo "║  Network:  OPEN (no restrictions)"
echo "║  FS Write: project + ~/.aws ~/.ssh ~/.claude /tmp"
echo "║  FS Read:  system paths (read-only)"
echo "║  Blocked:  gnupg private keys, password store, kube"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Launch ─────────────────────────────────────────────────────────
exec bwrap "${BWRAP_ARGS[@]}" "$CLAUDE_BIN" "$@"
