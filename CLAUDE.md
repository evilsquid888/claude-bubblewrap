# CLAUDE.md

## Project overview

OS-level bubblewrap sandbox for running Claude Code with dangerous permissions. Two bash scripts, no build process.

## Files

- `claude-sandbox.sh` — Main script. Builds bwrap arguments and launches Claude Code inside the jail.
- `sandbox-test.sh` — Verification script. Run inside the sandbox to confirm isolation works.
- `TODO.md` — Remaining hardening tasks.

## Architecture

The script constructs a `bwrap` command with three mount tiers:

1. **RW mounts** — project dir + config paths Claude needs to write to
2. **RO mounts** — system paths and toolchains (read-only)
3. **Deny mounts** — sensitive paths overlaid with tmpfs (invisible)

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
# Replace claude with bash to get a shell inside the sandbox
# Then run sandbox-test.sh from within
```

## Common tasks

- **Add a new writable path**: Add to `RW_PATHS` array
- **Add a new read-only path**: Add to `RO_PATHS` array
- **Block a sensitive path**: Add to `DENY_PATHS` array
- **Pass through an env var**: Add a `--setenv` line in the environment section
- **Lock down network**: Uncomment `--unshare-net` on line ~99
