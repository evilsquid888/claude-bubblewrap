#!/usr/bin/env bash
# Tests launcher selection and argument construction for both backends
# without starting an agent.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
TEST_BIN="$TEST_ROOT/bin"
TEST_PROJECT="$TEST_HOME/project"
mkdir -p "$TEST_HOME/.pi" "$TEST_HOME/.qwen" "$TEST_HOME/.grok" \
    "$TEST_HOME/.claude" "$TEST_HOME/.config/opencode" "$TEST_HOME/.opencode" \
    "$TEST_HOME/.local/bin" "$TEST_PROJECT" "$TEST_BIN"

for command in claude pi qwen grok opencode; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$TEST_BIN/$command"
    chmod +x "$TEST_BIN/$command"
done

# Mock sandbox tools: print the constructed argument list, one per line.
for tool in bwrap firejail; do
    cat >"$TEST_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
    chmod +x "$TEST_BIN/$tool"
done

# One symlink set per backend, mirroring what install.sh creates.
mkdir -p "$TEST_BIN/bwrap-launchers" "$TEST_BIN/firejail-launchers"
for command in claudejail pijail qwenjail grokjail opencodejail; do
    ln -s "$REPO_DIR/agent-sandbox.sh"   "$TEST_BIN/bwrap-launchers/$command"
    ln -s "$REPO_DIR/claude-firejail.sh" "$TEST_BIN/firejail-launchers/$command"
done

run_case() {
    local backend="$1"
    local launcher="$2"
    local agent_binary="$3"
    shift 3
    local output project_line

    output="$(HOME="$TEST_HOME" PATH="$TEST_BIN:/usr/bin:/bin" \
        "$TEST_BIN/$backend-launchers/$launcher" "$TEST_PROJECT" --test-argument)"

    case "$backend" in
        bwrap)    project_line="$TEST_PROJECT" ;;
        firejail) project_line="--whitelist=$TEST_PROJECT" ;;
    esac
    grep -Fxq -- "$project_line" <<<"$output"
    grep -Fxq -- "$TEST_BIN/$agent_binary" <<<"$output"
    grep -Fxq -- "--test-argument" <<<"$output"
    for default_flag in "$@"; do
        grep -Fxq -- "$default_flag" <<<"$output"
    done
    echo "PASS: $backend $launcher"
}

for backend in bwrap firejail; do
    run_case "$backend" claudejail   claude   --dangerously-skip-permissions
    run_case "$backend" pijail       pi
    run_case "$backend" qwenjail     qwen     --yolo
    run_case "$backend" grokjail     grok     --yolo
    run_case "$backend" opencodejail opencode --standalone --auto
done
