#!/usr/bin/env bash
# agent-sandbox.sh — External bubblewrap jail for AI coding agents
#
# Invoke through one of the supported names (claudejail, pijail, qwenjail,
# grokjail), or set AI_JAIL_AGENT to claude, pi, qwen, or grok.

set -euo pipefail

INVOKED_AS="${0##*/}"
AGENT="${AI_JAIL_AGENT:-}"

if [[ -z "$AGENT" ]]; then
    case "$INVOKED_AS" in
        claudejail|claude-sandbox.sh) AGENT="claude" ;;
        pijail)                       AGENT="pi" ;;
        qwenjail)                     AGENT="qwen" ;;
        grokjail)                     AGENT="grok" ;;
        *)
            echo "ERROR: invoke as claudejail, pijail, qwenjail, or grokjail." >&2
            echo "  Alternatively: AI_JAIL_AGENT=pi $INVOKED_AS" >&2
            exit 2
            ;;
    esac
fi

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
    *)
        echo "ERROR: unsupported AI_JAIL_AGENT: $AGENT" >&2
        exit 2
        ;;
esac

# First argument may select a project. Otherwise jail the current directory.
if [[ -n "${1:-}" && -d "$1" ]]; then
    PROJECT_DIR="$(realpath "$1")"
    shift
else
    PROJECT_DIR="$(pwd -P)"
fi

RW_PATHS=(
    "$PROJECT_DIR"
    "${AGENT_RW_PATHS[@]}"
    "$HOME/.gitconfig"
    "$HOME/.config/git"
    "$HOME/.npm-global"
    "$HOME/.npm"
    "$HOME/.gradle"
    "$HOME/.kanban-code"
)

RO_PATHS=(
    "/usr"
    "/lib"
    "/lib64"
    "/etc"
    "/bin"
    "/sbin"
    "/opt"
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
    "${JAVA_HOME:-/nonexistent}"
    "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}"
)

DENY_PATHS=(
    "$HOME/.gnupg/private-keys-v1.d"
    "$HOME/.password-store"
    "$HOME/.vault-token"
    "$HOME/.kube"
)

if ! command -v bwrap &>/dev/null; then
    echo "ERROR: bubblewrap not installed." >&2
    echo "  Ubuntu/Debian: sudo apt install bubblewrap" >&2
    echo "  Fedora/RHEL:   sudo dnf install bubblewrap" >&2
    exit 1
fi

if ! command -v "$AGENT_COMMAND" &>/dev/null; then
    echo "ERROR: $AGENT_COMMAND not found in PATH." >&2
    exit 1
fi

# Resolve the host binary before replacing HOME with a private tmpfs.
AGENT_BIN="$(readlink -f "$(command -v "$AGENT_COMMAND")")"

BWRAP_ARGS=(
    --unshare-pid
    --die-with-parent
    --proc /proc
    --tmpfs /run
)

# Preserve direct local-model GPU access. Missing device families are skipped.
shopt -s nullglob
GPU_CANDIDATES=(/dev/nvidia* /dev/dri /dev/nvhost*)
shopt -u nullglob
GPU_PATHS=()
for path in "${GPU_CANDIDATES[@]}"; do
    [[ -e "$path" ]] && GPU_PATHS+=("$path")
done

# Stage selected host devices before replacing /dev, then copy them into the
# jail's private /dev and hide the staging mounts afterward.
if (( ${#GPU_PATHS[@]} > 0 )); then
    BWRAP_ARGS+=(--dir /run/host-dev)
    for index in "${!GPU_PATHS[@]}"; do
        BWRAP_ARGS+=(--dev-bind "${GPU_PATHS[$index]}" "/run/host-dev/$index")
    done
fi
BWRAP_ARGS+=(--dev /dev)
BWRAP_ARGS+=(--dev-bind /dev/shm /dev/shm)
for index in "${!GPU_PATHS[@]}"; do
    BWRAP_ARGS+=(--dev-bind "/run/host-dev/$index" "${GPU_PATHS[$index]}")
done
if (( ${#GPU_PATHS[@]} > 0 )); then
    BWRAP_ARGS+=(--tmpfs /run/host-dev)
fi

for path in "${RO_PATHS[@]}"; do
    if [[ -e "$path" && "$path" != "$HOME" && "$path" != "$HOME"/* ]]; then
        BWRAP_ARGS+=(--ro-bind "$path" "$path")
    fi
done

BWRAP_ARGS+=(--tmpfs /tmp)

for path in "${RW_PATHS[@]}"; do
    if [[ -e "$path" && "$path" != "$HOME" && "$path" != "$HOME"/* ]]; then
        BWRAP_ARGS+=(--bind "$path" "$path")
    fi
done

# Mount order is intentional: private HOME first, then selected paths on top.
BWRAP_ARGS+=(--tmpfs "$HOME")

for path in "${RO_PATHS[@]}"; do
    if [[ -e "$path" && ( "$path" == "$HOME" || "$path" == "$HOME"/* ) ]]; then
        BWRAP_ARGS+=(--ro-bind "$path" "$path")
    fi
done

for path in "${RW_PATHS[@]}"; do
    if [[ -e "$path" && ( "$path" == "$HOME" || "$path" == "$HOME"/* ) ]]; then
        BWRAP_ARGS+=(--bind "$path" "$path")
    fi
done

# Ensure the project is writable even when it is also beneath HOME.
BWRAP_ARGS+=(--bind "$PROJECT_DIR" "$PROJECT_DIR")

for path in "${DENY_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        BWRAP_ARGS+=(--tmpfs "$path")
    fi
done

BWRAP_ARGS+=(--chdir "$PROJECT_DIR")

if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    SSH_AGENT_DIR="$(dirname "$SSH_AUTH_SOCK")"
    BWRAP_ARGS+=(--bind "$SSH_AGENT_DIR" "$SSH_AGENT_DIR")
    BWRAP_ARGS+=(--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK")
fi

BWRAP_ARGS+=(--setenv HOME "$HOME")
BWRAP_ARGS+=(--setenv USER "${USER:-$(whoami)}")
BWRAP_ARGS+=(--setenv TERM "${TERM:-xterm-256color}")
BWRAP_ARGS+=(--setenv PATH "$PATH")
BWRAP_ARGS+=(--setenv LANG "${LANG:-en_US.UTF-8}")
BWRAP_ARGS+=(--setenv SHELL "${SHELL:-/bin/bash}")

echo "╔══════════════════════════════════════════════════════╗"
printf '║  %-50s║\n' "$AGENT_LABEL — External Bubblewrap Sandbox"
echo "╠══════════════════════════════════════════════════════╣"
printf '║  Project:  %s\n' "$(basename "$PROJECT_DIR")"
echo "║  Network:  OPEN (local and remote endpoints work)"
echo "║  GPU:      NVIDIA/DRI devices passed through if present"
echo "║  FS Write: project + agent state"
echo "║  /tmp:     private tmpfs"
echo "║  Blocked:  other home files and sensitive stores"
echo "╚══════════════════════════════════════════════════════╝"
echo

exec bwrap "${BWRAP_ARGS[@]}" "$AGENT_BIN" "${DEFAULT_AGENT_ARGS[@]}" "$@"
