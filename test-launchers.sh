#!/usr/bin/env bash
# Tests launcher selection and argument construction without starting an agent.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
TEST_BIN="$TEST_ROOT/bin"
TEST_PROJECT="$TEST_HOME/project"
mkdir -p "$TEST_HOME/.pi" "$TEST_HOME/.qwen" "$TEST_HOME/.grok" \
    "$TEST_HOME/.claude" "$TEST_HOME/.local/bin" "$TEST_PROJECT" "$TEST_BIN"

for command in claude pi qwen grok; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$TEST_BIN/$command"
    chmod +x "$TEST_BIN/$command"
done

cat >"$TEST_BIN/bwrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$TEST_BIN/bwrap"

for command in claudejail pijail qwenjail grokjail; do
    ln -s "$REPO_DIR/agent-sandbox.sh" "$TEST_BIN/$command"
done

run_case() {
    local launcher="$1"
    local agent_binary="$2"
    local default_flag="$3"
    local output

    output="$(HOME="$TEST_HOME" PATH="$TEST_BIN:/usr/bin:/bin" \
        "$TEST_BIN/$launcher" "$TEST_PROJECT" --test-argument)"

    grep -Fxq -- "$TEST_PROJECT" <<<"$output"
    grep -Fxq -- "$TEST_BIN/$agent_binary" <<<"$output"
    grep -Fxq -- "--test-argument" <<<"$output"
    if [[ -n "$default_flag" ]]; then
        grep -Fxq -- "$default_flag" <<<"$output"
    fi
    echo "PASS: $launcher"
}

run_case claudejail claude --dangerously-skip-permissions
run_case pijail pi ""
run_case qwenjail qwen --yolo
run_case grokjail grok --yolo
