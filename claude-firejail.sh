#!/usr/bin/env bash
# claude-firejail.sh — External firejail sandbox for Claude Code
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
#   ./claude-firejail.sh                    # run in current project dir
#   ./claude-firejail.sh /path/to/project   # specify project dir
#   ./claude-firejail.sh /path/to/project --print "do something"  # pass args to claude

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
    "$HOME/.gitconfig"
    "$HOME/.config/git"
    "$HOME/.npm-global"
    "$HOME/.npm"
    "$HOME/.local/share/claude-code"
    "$HOME/.local/share/claude"
    "$HOME/.gradle"
    "$HOME/.kanban-code"
)

# Paths Claude gets read-only access to
RO_PATHS=(
    "$HOME/.ssh"
    "$HOME/.aws"
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

# Paths explicitly denied
DENY_PATHS=(
    "$HOME/.gnupg/private-keys-v1.d"
    "$HOME/.password-store"
    "$HOME/.vault-token"
    "$HOME/.kube"
)

# ── Preflight checks ──────────────────────────────────────────────
if ! command -v firejail &>/dev/null; then
    echo "ERROR: firejail not installed."
    echo "  Ubuntu/Debian: sudo apt install firejail"
    echo "  Fedora/RHEL:   sudo dnf install firejail"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "ERROR: claude not found in PATH."
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

# Resolve claude binary — follow symlinks so firejail can find the real executable
CLAUDE_BIN="$(readlink -f "$(command -v claude)")"

# ── Build firejail arguments ─────────────────────────────────────
FJ_ARGS=()

# No custom firejail profile — build everything from flags
FJ_ARGS+=(--noprofile)

# ── Security hardening ───────────────────────────────────────────
FJ_ARGS+=(--caps.drop=all)          # drop all Linux capabilities
FJ_ARGS+=(--nonewprivs)             # prevent privilege escalation via setuid
FJ_ARGS+=(--noroot)                 # disable root inside sandbox
FJ_ARGS+=(--seccomp)                # enable seccomp syscall filtering

# Private /dev — minimal device access (null, zero, urandom, tty, pts, shm).
# Uncomment for tighter security. Leave commented if you run headed browsers
# (Chrome needs /dev/dri/* for GPU rendering).
# FJ_ARGS+=(--private-dev)

# Network: fully open (no restrictions)
# To lock down network, replace with: FJ_ARGS+=(--net=none)

# Start with entire filesystem read-only, then whitelist writable paths.
# With --noprofile, firejail leaves everything writable by default.
FJ_ARGS+=(--read-only=/)

# Block sensitive paths (blacklist always wins in firejail)
for path in "${DENY_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        FJ_ARGS+=(--blacklist="$path")
    fi
done

# Read-write paths — whitelist makes them visible under $HOME (everything
# else under $HOME becomes invisible). --read-write re-enables writes
# since --read-only=/ made everything read-only.
# --noblacklist prevents firejail's built-in blacklists from blocking them.
for path in "${RW_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        FJ_ARGS+=(--noblacklist="$path")
        FJ_ARGS+=(--whitelist="$path")
        FJ_ARGS+=(--read-write="$path")
    fi
done

# Read-only paths — whitelist to make visible, then mark read-only
for path in "${RO_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        FJ_ARGS+=(--noblacklist="$path")
        FJ_ARGS+=(--whitelist="$path")
        FJ_ARGS+=(--read-only="$path")
    fi
done

# Add JAVA_HOME and ANDROID_HOME as read-only if set
if [[ -n "${JAVA_HOME:-}" && -e "$JAVA_HOME" ]]; then
    FJ_ARGS+=(--noblacklist="$JAVA_HOME")
    FJ_ARGS+=(--whitelist="$JAVA_HOME")
    FJ_ARGS+=(--read-only="$JAVA_HOME")
fi
if [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" && -e "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}" ]]; then
    SDK_PATH="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
    FJ_ARGS+=(--noblacklist="$SDK_PATH")
    FJ_ARGS+=(--whitelist="$SDK_PATH")
    FJ_ARGS+=(--read-only="$SDK_PATH")
fi

# SSH agent forwarding — needed for git operations over SSH
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    SSH_AGENT_DIR="$(dirname "$SSH_AUTH_SOCK")"
    FJ_ARGS+=(--whitelist="$SSH_AGENT_DIR")
    FJ_ARGS+=(--read-write="$SSH_AGENT_DIR")
    FJ_ARGS+=(--env=SSH_AUTH_SOCK="$SSH_AUTH_SOCK")
fi

# Private writable /tmp — mounts a fresh tmpfs on /tmp.
# Needed because --read-only=/ makes /tmp read-only and --read-write=/tmp
# doesn't work (root-owned). --private-tmp gives a clean writable tmpfs.
FJ_ARGS+=(--private-tmp)

# Set working directory
cd "$PROJECT_DIR"

# Pass through environment variables
FJ_ARGS+=(--env=TERM="${TERM:-xterm-256color}")
FJ_ARGS+=(--env=PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/$(ls "$HOME/.nvm/versions/node/" 2>/dev/null | tail -1)/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin")
FJ_ARGS+=(--env=LANG="${LANG:-en_US.UTF-8}")
FJ_ARGS+=(--env=SHELL="/bin/bash")

# AWS env vars
[[ -n "${AWS_PROFILE:-}" ]]          && FJ_ARGS+=(--env=AWS_PROFILE="$AWS_PROFILE")
[[ -n "${AWS_REGION:-}" ]]           && FJ_ARGS+=(--env=AWS_REGION="$AWS_REGION")
[[ -n "${AWS_DEFAULT_REGION:-}" ]]   && FJ_ARGS+=(--env=AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION")
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]    && FJ_ARGS+=(--env=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID")
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && FJ_ARGS+=(--env=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY")
[[ -n "${AWS_SESSION_TOKEN:-}" ]]    && FJ_ARGS+=(--env=AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN")

# Java/Android env vars
[[ -n "${JAVA_HOME:-}" ]]            && FJ_ARGS+=(--env=JAVA_HOME="$JAVA_HOME")
[[ -n "${ANDROID_HOME:-}" ]]         && FJ_ARGS+=(--env=ANDROID_HOME="$ANDROID_HOME")
[[ -n "${ANDROID_SDK_ROOT:-}" ]]     && FJ_ARGS+=(--env=ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT")

# Anthropic env vars
[[ -n "${ANTHROPIC_API_KEY:-}" ]]    && FJ_ARGS+=(--env=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")

# ── Summary ────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Claude Code — External Firejail Sandbox            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Project:  $(basename "$PROJECT_DIR")"
echo "║  Network:  OPEN (no restrictions)"
echo "║  FS Write: project + ~/.claude"
echo "║  /tmp:     private (not shared with host)"
echo "║  FS Read:  system paths (read-only)"
echo "║  Blocked:  gnupg private keys, password store, kube"
echo "║  Seccomp:  enabled (syscall filtering)"
echo "║  Caps:     all dropped"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Launch ─────────────────────────────────────────────────────────
exec firejail "${FJ_ARGS[@]}" "$CLAUDE_BIN" --dangerously-skip-permissions "$@"
