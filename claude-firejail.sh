#!/usr/bin/env bash
# claude-firejail.sh — External firejail sandbox for AI coding agents
# (Claude Code, Pi, Qwen Code, Grok, OpenCode, DSH TUI)
#
# Belt-and-suspenders approach: wraps the agent in an OS-level sandbox
# OUTSIDE of its own built-in permission system. Even if the agent
# reasons its way around its internal guardrails, this outer jail holds.
#
# The agent is selected by the name the script is invoked as
# (claudejail, pijail, qwenjail, grokjail, opencodejail, dshjail) or by AI_JAIL_AGENT.
#
# Policy:
#   - Network: fully open (no restrictions)
#   - Filesystem: project dir + explicit config paths only
#   - Everything else: invisible or read-only
#
# Usage:
#   ./claude-firejail.sh                    # run in current project dir
#   ./claude-firejail.sh /path/to/project   # specify project dir
#   ./claude-firejail.sh /path/to/project --print "do something"  # pass args to the agent

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Project directory: first arg if it's a directory, otherwise $PWD
if [[ -n "${1:-}" && -d "$1" ]]; then
    PROJECT_DIR="$(realpath "$1")"
    shift
else
    PROJECT_DIR="$(pwd)"
fi

# ── Agent selection ────────────────────────────────────────────────
# Invoke through one of the supported names (claudejail, pijail, qwenjail,
# grokjail, opencodejail, dshjail), or set AI_JAIL_AGENT to claude, pi, qwen,
# grok, opencode, or dsh.
INVOKED_AS="${0##*/}"
AGENT="${AI_JAIL_AGENT:-}"

if [[ -z "$AGENT" ]]; then
    case "$INVOKED_AS" in
        claudejail|claude-firejail.sh) AGENT="claude" ;;
        pijail)                        AGENT="pi" ;;
        qwenjail)                      AGENT="qwen" ;;
        grokjail)                      AGENT="grok" ;;
        opencodejail)                  AGENT="opencode" ;;
        dshjail)                       AGENT="dsh" ;;
        *)
            echo "ERROR: invoke as claudejail, pijail, qwenjail, grokjail, opencodejail, or dshjail." >&2
            echo "  Alternatively: AI_JAIL_AGENT=pi $INVOKED_AS" >&2
            exit 2
            ;;
    esac
fi

AGENT_RO_PATHS=()
case "$AGENT" in
    claude)
        AGENT_LABEL="Claude Code"
        AGENT_COMMAND="claude"
        AGENT_RW_PATHS=(
            "$HOME/.claude"
            "$HOME/.claude.json"
            "$HOME/.config/claude"
            "$HOME/.local/share/claude-code"
            "$HOME/.local/share/claude"
        )
        DEFAULT_AGENT_ARGS=(--dangerously-skip-permissions)
        ;;
    pi)
        AGENT_LABEL="Pi"
        AGENT_COMMAND="pi"
        AGENT_RW_PATHS=("$HOME/.pi")
        # Pi's built-in coding tools do not use a separate approval flag.
        DEFAULT_AGENT_ARGS=()
        ;;
    qwen)
        AGENT_LABEL="Qwen Code"
        AGENT_COMMAND="qwen"
        AGENT_RW_PATHS=("$HOME/.qwen")
        DEFAULT_AGENT_ARGS=(--yolo)
        ;;
    grok)
        AGENT_LABEL="Grok"
        AGENT_COMMAND="grok"
        AGENT_RW_PATHS=("$HOME/.grok")
        DEFAULT_AGENT_ARGS=(--yolo)
        ;;
    opencode)
        AGENT_LABEL="OpenCode"
        AGENT_COMMAND="opencode"
        AGENT_RW_PATHS=(
            "$HOME/.config/opencode"
            "$HOME/.local/share/opencode"
            "$HOME/.local/state/opencode"
            "$HOME/.cache/opencode"
        )
        AGENT_RO_PATHS=("$HOME/.opencode")   # install location of the binary
        # --standalone: run the server inside the jail. Without it, opencode talks
        #   to a background service on the HOST, which would run tools outside the jail.
        # --auto: auto-approve permissions (opencode's --dangerously-skip-permissions)
        DEFAULT_AGENT_ARGS=(--standalone --auto)
        ;;
    dsh|dsh-tui)
        AGENT_LABEL="DSH TUI"
        AGENT_COMMAND="dsh-tui"
        AGENT_RW_PATHS=("$HOME/.dsh" "${DSH_HOME:-$HOME/.dsh}" "$HOME/.dsh-tui")
        DEFAULT_AGENT_ARGS=()
        ;;
    *)
        echo "ERROR: unsupported AI_JAIL_AGENT: $AGENT" >&2
        exit 2
        ;;
esac

# Paths the agent gets read-write access to
RW_PATHS=(
    "$PROJECT_DIR"
    ${AGENT_RW_PATHS[@]+"${AGENT_RW_PATHS[@]}"}
    "$HOME/.gitconfig"
    "$HOME/.config/git"
    "$HOME/.npm-global"
    "$HOME/.npm"
    "$HOME/.gradle"
)

# Paths the agent gets read-only access to
RO_PATHS=(
    "$HOME/.ssh"
    "$HOME/.aws"
    "$HOME/.config/gh"
    "$HOME/.nvm"
    "$HOME/.fnm"
    "$HOME/.local/bin"
    "$HOME/.local/lib"
    "$HOME/.cargo/bin"
    "$HOME/.rustup"
    "$HOME/.pyenv"
    "$HOME/.config/pip"
    "$HOME/.config/nvm"
    "$HOME/.config/tmux"
    "$HOME/.tmux"
    ${AGENT_RO_PATHS[@]+"${AGENT_RO_PATHS[@]}"}
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

if ! command -v "$AGENT_COMMAND" &>/dev/null; then
    echo "ERROR: $AGENT_COMMAND not found in PATH." >&2
    exit 1
fi

# Resolve agent binary — follow symlinks so firejail can find the real executable
AGENT_BIN="$(readlink -f "$(command -v "$AGENT_COMMAND")")"

# Persist first-run profile setup and UI state instead of hiding new paths.
if [[ "$AGENT_COMMAND" == dsh-tui ]]; then
    mkdir -p -- "${AGENT_RW_PATHS[@]}"
fi

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
# Keep the active toolchain and companion CLIs (e.g. dsh and pnpm) available.
FJ_ARGS+=(--env=PATH="$PATH")
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

# Model provider API keys (passed through only if set)
for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY; do
    [[ -n "${!var:-}" ]] && FJ_ARGS+=(--env="$var=${!var}")
done

# ── Summary ────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
printf "║  %-52s║\n" "$AGENT_LABEL — External Firejail Sandbox"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Agent:    $AGENT_COMMAND ${DEFAULT_AGENT_ARGS[*]:-}"
echo "║  Project:  $(basename "$PROJECT_DIR")"
echo "║  Network:  OPEN (no restrictions)"
echo "║  FS Write: project + agent config dirs"
echo "║  /tmp:     private (not shared with host)"
echo "║  FS Read:  system paths (read-only)"
echo "║  Blocked:  gnupg private keys, password store, kube"
echo "║  Seccomp:  enabled (syscall filtering)"
echo "║  Caps:     all dropped"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Launch ─────────────────────────────────────────────────────────
exec firejail "${FJ_ARGS[@]}" "$AGENT_BIN" "$@" ${DEFAULT_AGENT_ARGS[@]+"${DEFAULT_AGENT_ARGS[@]}"}
