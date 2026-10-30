# AI agent bubblewrap

OS-level sandbox for running Claude Code, Pi, Qwen Code, Grok, OpenCode, and DSH TUI with broad tool permissions while limiting filesystem access. Both the Bubblewrap and Firejail launchers support all six agents.

The installed commands are `claudejail`, `pijail`, `qwenjail`, `grokjail`, `opencodejail`, and `dshjail`. Each uses the current directory as its writable project unless the first argument is another directory.

## Why

An agent's built-in permission prompts are a software guardrail. This is an OS-level one. When you run an agent with `--dangerously-skip-permissions`, `--yolo`, or `--auto`, you're trusting the model not to do anything destructive. These launchers add a second layer: even if the agent decides to `rm -rf ~` or read your GPG keys, the kernel blocks it.

## How it works

```
┌──────────────────────────────────┐
│  Host system                     │
│                                  │
│  ┌────────────────────────────┐  │
│  │  bwrap / firejail jail     │  │
│  │                            │  │
│  │  ┌──────────────────────┐  │  │
│  │  │  AI coding agent     │  │  │
│  │  │  (dangerous perms)   │  │  │
│  │  └──────────────────────┘  │  │
│  │                            │  │
│  │  Can see:                  │  │
│  │   RW: project dir, config  │  │
│  │   RO: system, toolchains   │  │
│  │   Blocked: secrets         │  │
│  └────────────────────────────┘  │
│                                  │
│  Invisible from inside:          │
│   ~/Documents, ~/Downloads,      │
│   other projects, GPG keys,      │
│   password store, kube config    │
└──────────────────────────────────┘
```

## Agent support

| Command | Agent state (read-write) | Default agent arguments |
|---|---|---|
| `claudejail` | `~/.claude`, `~/.claude.json`, `~/.config/claude`, `~/.local/share/claude`, `~/.local/share/claude-code` | `--dangerously-skip-permissions` |
| `pijail` | `~/.pi` | none (Pi tools run directly) |
| `qwenjail` | `~/.qwen` | `--yolo` |
| `grokjail` | `~/.grok` | `--yolo` |
| `opencodejail` | `~/.config/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.cache/opencode` (plus `~/.opencode` read-only) | `--standalone --auto` |
| `dshjail` | `~/.dsh`, `$DSH_HOME` (if set), `~/.dsh-tui` | none (runs `dsh-tui`) |

DSH state directories are created before launch so first-run profile setup and UI settings persist. `AI_JAIL_AGENT=dsh` (or `dsh-tui`) also selects this launcher. DSH's configured permission settings apply; the launcher adds no approval flags.

OpenCode gets `--standalone` because by default it talks to a background service on the host. That service would execute tools **outside** the jail, defeating the sandbox. `--auto` is OpenCode's equivalent of skipping permission prompts.

With bubblewrap, NVIDIA, DRI, and nvhost devices are passed through into the private `/dev` when present (firejail leaves the host `/dev` visible), so agents may connect to local model servers or launch GPU-backed local tooling. Network access, including localhost, remains open.

## Two sandbox backends

This project provides two launchers with the same filesystem policy but different sandboxing tools. `claude-sandbox.sh` is a legacy Claude-only bubblewrap script kept for backward compatibility.

| | `agent-sandbox.sh` (bubblewrap) | `claude-firejail.sh` (firejail) |
|---|---|---|
| **How it sandboxes** | Builds filesystem from scratch — starts empty, explicitly mounts what's needed | Starts with full filesystem, locks it down with whitelist + read-only |
| **Runs as** | Unprivileged user | Setuid root binary |
| **Code size** | ~2k lines of C | ~100k lines of C |
| **AppArmor setup** | Needs a 4-line profile added manually (see below) | Works out of the box on Ubuntu |
| **If the tool has a bug** | Attacker stays as your user | Attacker gets real root (setuid) |
| **CVE history** | Very few | Multiple privilege escalation CVEs |
| **PID isolation** | Yes (`--unshare-pid`) | No (with `--noprofile`) |
| **Syscall/capability hardening** | None beyond user namespace | `--seccomp`, `--caps.drop=all`, `--nonewprivs`, `--noroot` |
| **Home isolation** | tmpfs overlay — unlisted paths don't exist | Whitelist mode — unlisted paths are hidden |
| **System paths** | Explicit read-only mounts | `--read-only=/` blanket, then selective write-back |
| **Best for** | Maximum security, you control every mount | Quick setup, no kernel config needed |

**Recommendation:** bubblewrap is the safer tool. Firejail is the easier one. If you're sandboxing an AI agent running arbitrary code with dangerous permissions, smaller attack surface matters — use bubblewrap if you can. Use firejail if you can't or don't want to modify AppArmor.

## Requirements

- Linux
- One or more supported agent CLIs: `claude`, `pi`, `qwen`, `grok`, `opencode`, or `dsh-tui` (with `dsh` and `pnpm` available for profile setup)
- One of:
  - [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`)
  - [firejail](https://github.com/netblue30/firejail) (`firejail`)

```bash
# Install sandbox tool (pick one)
sudo apt install bubblewrap     # Debian/Ubuntu
sudo apt install firejail       # Debian/Ubuntu

# Install command aliases for the current user
./install.sh              # bubblewrap backend
./install.sh firejail     # firejail backend (use where bwrap is blocked by AppArmor)
```

The installer copies the chosen launcher to `~/.local/lib/ai-agent-jail/` and symlinks the `*jail` commands into `~/.local/bin`. Override these with `AI_JAIL_INSTALL_DIR` and `AI_JAIL_BIN_DIR`. Re-run it after pulling changes or to switch backends.

## AppArmor setup (bubblewrap only)

Modern Ubuntu kernels block unprivileged user namespaces via AppArmor by default. Since bubblewrap requires user namespaces to function, you need to add an AppArmor profile that allows `bwrap` specifically. Without this, you'll get `bwrap: setting up uid map: Permission denied`.

Firejail does **not** need this — Ubuntu ships an AppArmor profile for it.

Create the profile:

```bash
sudo tee /etc/apparmor.d/bwrap <<'EOF'
abi <abi/4.0>,
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/bwrap
```

This grants **only** `/usr/bin/bwrap` permission to create user namespaces. All other programs remain blocked. The global `apparmor_restrict_unprivileged_userns=1` setting stays on.

### What this enables and the security tradeoff

User namespaces let a process become "root" inside an isolated namespace. Normally AppArmor blocks this because kernel subsystems reachable from within a namespace (mount, netfilter, eBPF) have historically been the entry point for privilege escalation CVEs (e.g. CVE-2022-0185, CVE-2023-32233, CVE-2024-1086). By allowing bwrap to create namespaces, you're expanding the kernel attack surface — but only for bwrap, not for every binary on the system.

The practical risk is low: exploiting this requires an attacker who already has local code execution on your machine **and** an unpatched kernel namespace vulnerability. If an attacker already has local access as your user, they can already read your files, steal your keys, and persist in your shell profile. The namespace path just adds a theoretical route to root on top of that.

Running an agent with dangerous permissions **without** this sandbox gives it unrestricted access to your entire filesystem, SSH keys, and credentials. The sandbox significantly reduces that blast radius. The tradeoff — a small increase in kernel attack surface for a large reduction in filesystem exposure — nets out positive.

### Checking if you need this

```bash
# If this returns 1, you need the AppArmor profile above
sysctl kernel.apparmor_restrict_unprivileged_userns
```

If it returns 0 or the sysctl doesn't exist, bwrap will work without changes.

## Usage

```bash
# Installed launchers (same commands for either backend)
pijail                         # Pi in the current project
qwenjail                       # Qwen Code in the current project
grokjail                       # Grok in the current project
opencodejail                   # OpenCode in the current project
dshjail                        # DSH TUI in the current project
claudejail                     # Claude Code in the current project

pijail /path/to/project        # explicit project directory
qwenjail --model local-model   # arguments are passed to the agent
dshjail /path/to/project --resume  # resume DSH TUI in an explicit project

# Repository launchers (without installation)
AI_JAIL_AGENT=pi ./agent-sandbox.sh
AI_JAIL_AGENT=dsh ./agent-sandbox.sh
./claude-sandbox.sh            # backward-compatible Claude launcher

# Firejail version (claude by default, any agent via AI_JAIL_AGENT)
./claude-firejail.sh                                    # Claude in current directory
./claude-firejail.sh /path/to/project                   # specific project
./claude-firejail.sh /path/to/project --print "do X"    # pass args to the agent
AI_JAIL_AGENT=opencode ./claude-firejail.sh             # OpenCode under firejail
```

## Security policy

Both launchers enforce the same filesystem policy:

### Read-write (project + config)

| Path | Why |
|------|-----|
| `$PROJECT_DIR` | The project you're working on |
| Selected agent's state (see [Agent support](#agent-support)) | Config, auth, and session state |
| `~/.gitconfig`, `~/.config/git` | Git identity |
| `~/.npm`, `~/.npm-global` | npm cache and global packages |
| `~/.gradle` | Gradle build cache |
| `~/.kanban-code` | Kanban Code app state (bubblewrap only) |

### Read-only (toolchains + system)

| Path | Why |
|------|-----|
| `/usr`, `/lib`, `/lib64`, `/etc`, `/bin`, `/sbin`, `/opt` | System binaries and libraries (firejail: all of `/` read-only) |
| `~/.ssh`, `~/.aws`, `~/.config/gh` | Credentials (read-only, not writable) |
| `~/.nvm`, `~/.fnm`, `~/.cargo/bin`, `~/.rustup`, `~/.pyenv`, `~/.config/nvm`, `~/.config/pip` | Language toolchains and their config |
| `~/.local/bin`, `~/.local/lib` | User-installed tools |
| `~/.config/tmux`, `~/.tmux` | Tmux plugins (e.g. hooks for Claude Code integration) |
| `$JAVA_HOME`, `$ANDROID_HOME` | JDK and Android SDK (if set) |

### Blocked (deny-listed)

| Path | Why |
|------|-----|
| `~/.gnupg/private-keys-v1.d` | GPG private keys |
| `~/.password-store` | pass password manager |
| `~/.vault-token` | HashiCorp Vault tokens |
| `~/.kube` | Kubernetes config and credentials |

### Other isolation

| Feature | bubblewrap | firejail |
|---------|-----------|----------|
| Network | Open | Open |
| `/tmp` | Private tmpfs | Private (whitelist mode) |
| `/dev/shm` | Bind-mounted from host | Available by default |
| `$HOME` | tmpfs overlay (unlisted paths don't exist) | Whitelist (unlisted paths hidden) |
| PID namespace | Isolated (`--unshare-pid`) | Not isolated |
| Parent death | Sandbox killed (`--die-with-parent`) | Process outlives parent |
| Seccomp / capabilities | Not filtered | Seccomp filter, all capabilities dropped |
| SSH agent | Socket dir forwarded if `SSH_AUTH_SOCK` is set | Socket dir forwarded if `SSH_AUTH_SOCK` is set |
| System paths | Explicit RO mounts | `--read-only=/` blanket |

### Environment variables

**Bubblewrap** inherits the full host environment and explicitly sets `HOME`, `USER`, `TERM`, `PATH`, `LANG`, and `SHELL`. Provider API keys, local model endpoints, and other agent settings work without extra configuration. The legacy `claude-sandbox.sh` has commented-out `CHROME_DEVEL_SANDBOX` and `PLAYWRIGHT_CHROMIUM_SANDBOX` lines to uncomment if Chrome crashes inside the sandbox.

**Firejail** passes through only an explicit list, and only when set:

- `TERM`, `PATH`, `LANG`, `SHELL`, `SSH_AUTH_SOCK`
- `AWS_PROFILE`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENROUTER_API_KEY`

To expose another variable under firejail, add an `--env=` line in `claude-firejail.sh`.

## Verifying the sandbox

Run the test script inside the sandbox to confirm isolation is working:

```bash
# Temporarily change AGENT_COMMAND to bash in the launcher, start it, then:
bash sandbox-test.sh

# Or ask a jailed agent to run sandbox-test.sh and report the output
```

The test checks filesystem write restrictions, sensitive path blocking, network access, and tool availability.

Launcher selection and arguments can be tested without loading any model or consuming VRAM:

```bash
./test-launchers.sh
```

## Customizing

Edit the arrays in `agent-sandbox.sh` and/or `claude-firejail.sh`:

- **`RW_PATHS`** — paths the agent can read and write
- **`RO_PATHS`** — paths the agent can read but not modify
- **`DENY_PATHS`** — paths that are always hidden/blocked

Per-agent state lives in the agent `case` statement (`AGENT_RW_PATHS`, `AGENT_RO_PATHS`, `DEFAULT_AGENT_ARGS`). To add an agent, add a `case` arm to both launchers, then add its command to `install.sh` and `test-launchers.sh`.

Paths that don't exist are silently skipped. Re-run `./install.sh` after editing so the installed copy picks up the change.

## Known limitations

- **Network is open** — filesystem restrictions don't prevent data exfiltration. If a prompt injection convinces the agent to `curl` your SSH keys somewhere, the sandbox won't stop it. Consider `--unshare-net` (bwrap) or `--net=none` (firejail) if you don't need network.
- **Linux only** — neither tool works on macOS or Windows. For macOS, consider `sandbox-exec` or Docker.
- **Credentials are readable** — `~/.ssh`, `~/.aws`, and `~/.config/gh` are mounted read-only so git and cloud tools work, which means the agent can read them. Remove them from `RO_PATHS` if you don't need them.
- **No seccomp under bubblewrap** — dangerous syscalls aren't filtered. Could be added with `bwrap --seccomp`; the firejail launcher already enables firejail's seccomp filter.

## License

MIT
