# CLAUDE.md

## Project overview

OS-level sandbox for running Claude Code, Pi, Qwen Code, Grok, OpenCode, and DSH TUI with broad tool permissions. Bash scripts only; no build process.

## Files

- `agent-sandbox.sh` — Main Bubblewrap script. Selects an agent from its invocation name or `AI_JAIL_AGENT`.
- `claude-firejail.sh` — Firejail equivalent of `agent-sandbox.sh`. Same agent selection, same commands.
- `claude-sandbox.sh` — Backward-compatible Claude-only Bubblewrap launcher.
- `install.sh` — Installs `claudejail`, `pijail`, `qwenjail`, `grokjail`, `opencodejail`, and `dshjail` for the current user (`bwrap` default, or `firejail`).
- `test-launchers.sh` — Mock launch tests for both backends that do not start models.
- `sandbox-test.sh` — Verification script. Run inside the sandbox to confirm isolation works.
- `TODO.md` — Remaining hardening tasks.

## Architecture

The main script constructs a `bwrap` command with three mount tiers:

1. **RW mounts** — project dir + config paths Claude needs to write to
2. **RO mounts** — system paths and toolchains (read-only)
3. **Deny mounts** — sensitive paths overlaid with tmpfs (invisible)

Agent-specific state is selected in the top-level `case` statement (`AGENT_RW_PATHS`, optional `AGENT_RO_PATHS`, `DEFAULT_AGENT_ARGS`). To add an agent, add a `case` arm in both `agent-sandbox.sh` and `claude-firejail.sh`, then add the command to `install.sh` and `test-launchers.sh`. NVIDIA, DRI, and nvhost device nodes are passed through after the private `/dev` is created.

Mount ordering matters: `--tmpfs $HOME` must come before all home-relative bind mounts, otherwise the tmpfs wipes them. System (non-home) mounts go before the tmpfs. Home-relative RO mounts go after, then home-relative RW mounts layer on top.

## Editing guidelines

- Keep `RW_PATHS`, `RO_PATHS`, and `DENY_PATHS` arrays as the single source of truth for filesystem policy.
- Paths that don't exist are skipped via `-e` checks — no need to guard additions.
- When adding new RW/RO paths, put them in the appropriate array. The mount loop handles the rest.
- `set -euo pipefail` is enforced — don't leave unquoted variables or unchecked commands.
- Test changes by running `sandbox-test.sh` inside the sandbox.

## Testing

There is no automated test runner. To verify:

```bash
./test-launchers.sh

# Replace claude with bash to get a shell inside the sandbox
# Then run sandbox-test.sh from within
```

## Common tasks

- **Add a new writable path**: Add to `RW_PATHS` array
- **Add a new read-only path**: Add to `RO_PATHS` array
- **Block a sensitive path**: Add to `DENY_PATHS` array
- **Pass through an env var**: Add a `--setenv` line in the environment section
- **Lock down network**: Uncomment `--unshare-net` on line ~99
