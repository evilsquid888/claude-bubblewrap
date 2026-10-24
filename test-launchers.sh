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

for command in claude pi qwen grok opencode dsh-tui; do
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

# Exercise the actual installer for each backend in temporary directories.
for backend in bwrap firejail; do
    AI_JAIL_INSTALL_DIR="$TEST_ROOT/$backend-install" \
        AI_JAIL_BIN_DIR="$TEST_BIN/$backend-launchers" \
        bash "$REPO_DIR/install.sh" "$backend" >/dev/null
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
        firejail)
            project_line="--whitelist=$TEST_PROJECT"
            grep -Fxq -- "--env=PATH=$TEST_BIN:/usr/bin:/bin" <<<"$output"
            ;;
    esac
    grep -Fxq -- "$project_line" <<<"$output"
    grep -Fxq -- "$TEST_BIN/$agent_binary" <<<"$output"
    grep -Fxq -- "--test-argument" <<<"$output"
    if [[ "$agent_binary" == dsh-tui ]]; then
        local state_path
        for state_path in "$TEST_HOME/.dsh" "${DSH_HOME:-$TEST_HOME/.dsh}" "$TEST_HOME/.dsh-tui"; do
            [[ -d "$state_path" ]]
            case "$backend" in
                bwrap)
                    # Verify the mount is writable, including on first launch.
                    [[ "$output" == *$'--bind\n'"$state_path"$'\n'"$state_path"$'\n'* ]]
                    ;;
                firejail) grep -Fxq -- "--read-write=$state_path" <<<"$output" ;;
            esac
        done
        [[ "$(tail -n 1 <<<"$output")" == --test-argument ]]
    fi
    # Default flags must follow the user's arguments: opencode rejects
    # `opencode --standalone --auto run "..."` but accepts them after `run`.
    local user_line default_line
    user_line="$(grep -Fxn -- "--test-argument" <<<"$output" | cut -d: -f1)"
    for default_flag in "$@"; do
        default_line="$(grep -Fxn -- "$default_flag" <<<"$output" | cut -d: -f1)"
        [ -n "$default_line" ] || { echo "FAIL: $backend $launcher missing $default_flag" >&2; return 1; }
        [ "$default_line" -gt "$user_line" ] || {
            echo "FAIL: $backend $launcher places $default_flag before user arguments" >&2
            return 1
        }
    done
    echo "PASS: $backend $launcher"
}

for backend in bwrap firejail; do
    run_case "$backend" claudejail   claude   --dangerously-skip-permissions
    run_case "$backend" pijail       pi
    run_case "$backend" qwenjail     qwen     --yolo
    run_case "$backend" grokjail     grok     --yolo
    run_case "$backend" opencodejail opencode --standalone --auto
    run_case "$backend" dshjail      dsh-tui
    DSH_HOME="$TEST_HOME/custom-dsh-$backend" run_case "$backend" dshjail dsh-tui
    AI_JAIL_AGENT=dsh run_case "$backend" pijail dsh-tui
    AI_JAIL_AGENT=dsh-tui run_case "$backend" pijail dsh-tui
done
