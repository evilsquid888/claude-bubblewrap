# claude-bubblewrap

OS-level sandbox for running [Claude Code](https://github.com/anthropics/claude-code) with dangerous permissions safely. Two sandbox backends: [bubblewrap](https://github.com/containers/bubblewrap) and [firejail](https://github.com/netblue30/firejail). Both wrap Claude Code in an external jail that holds even if Claude reasons its way around its internal sandbox.

## Why

Claude Code's built-in sandbox is a software guardrail. This is a hardware one. When you run Claude with `--dangerously-skip-permissions`, you're trusting the model not to do anything destructive. This script adds a second layer: even if Claude decides to `rm -rf /` or read your GPG keys, the kernel blocks it.

## How it works

```
┌──────────────────────────────────┐
│  Host system                     │
│                                  │
│  ┌────────────────────────────┐  │
│  │  bwrap / firejail jail     │  │
│  │                            │  │
│  │  ┌──────────────────────┐  │  │
│  │  │  Claude Code         │  │  │
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

## Two sandbox backends

This project provides two scripts with identical security policies but different sandboxing tools:

| | `claude-sandbox.sh` (bubblewrap) | `claude-firejail.sh` (firejail) |
|---|---|---|
| **How it sandboxes** | Builds filesystem from scratch — starts empty, explicitly mounts what's needed | Starts with full filesystem, locks it down with whitelist + read-only |
| **Runs as** | Unprivileged user | Setuid root binary |
| **Code size** | ~2k lines of C | ~100k lines of C |
| **AppArmor setup** | Needs a 4-line profile added manually (see below) | Works out of the box on Ubuntu |
| **If the tool has a bug** | Attacker stays as your user | Attacker gets real root (setuid) |
| **CVE history** | Very few | Multiple privilege escalation CVEs |
| **PID isolation** | Yes (`--unshare-pid`) | No (with `--noprofile`) |
| **Home isolation** | tmpfs overlay — unlisted paths don't exist | Whitelist mode — unlisted paths are hidden |
| **System paths** | Explicit read-only mounts | `--read-only=/` blanket, then selective write-back |
| **Best for** | Maximum security, you control every mount | Quick setup, no kernel config needed |

**Recommendation:** bubblewrap is the safer tool. Firejail is the easier one. If you're sandboxing an AI agent running arbitrary code with dangerous permissions, smaller attack surface matters — use bubblewrap if you can. Use firejail if you can't or don't want to modify AppArmor.

## Requirements

- Linux
- [Claude Code](https://github.com/anthropics/claude-code) (`claude`)
- One of:
  - [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`)
  - [firejail](https://github.com/netblue30/firejail) (`firejail`)

```bash
# Install sandbox tool (pick one)
sudo apt install bubblewrap     # Debian/Ubuntu
sudo apt install firejail       # Debian/Ubuntu

# Install Claude Code
npm install -g @anthropic-ai/claude-code
```

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

Running Claude Code with dangerous permissions **without** this sandbox gives it unrestricted access to your entire filesystem, SSH keys, and credentials. The sandbox significantly reduces that blast radius. The tradeoff — a small increase in kernel attack surface for a large reduction in filesystem exposure — nets out positive.

### Checking if you need this

```bash
# If this returns 1, you need the AppArmor profile above
sysctl kernel.apparmor_restrict_unprivileged_userns
```

If it returns 0 or the sysctl doesn't exist, bwrap will work without changes.

## Usage

```bash
# Bubblewrap version
./claude-sandbox.sh                                     # current directory
./claude-sandbox.sh /path/to/project                    # specific project
./claude-sandbox.sh /path/to/project --print "do X"     # pass args to claude

# Firejail version
./claude-firejail.sh                                    # current directory
./claude-firejail.sh /path/to/project                   # specific project
./claude-firejail.sh /path/to/project --print "do X"    # pass args to claude
```

## Security policy

Both scripts enforce the same filesystem policy:

### Read-write (project + config)

| Path | Why |
|------|-----|
| `$PROJECT_DIR` | The project you're working on |
| `~/.claude`, `~/.claude.json`, `~/.config/claude` | Claude Code config and session state |
| `~/.gitconfig`, `~/.config/git` | Git identity |
| `~/.npm`, `~/.npm-global` | npm cache and global packages |
| `~/.gradle` | Gradle build cache |
| `~/.kanban-code` | Kanban Code app state |
| `~/.local/share/claude-code` | Claude Code local data |

### Read-only (toolchains + system)

| Path | Why |
|------|-----|
| `/usr`, `/lib`, `/lib64`, `/etc`, `/bin`, `/sbin`, `/opt` | System binaries and libraries |
| `~/.ssh`, `~/.aws` | Credentials (read-only, not writable) |
| `~/.nvm`, `~/.fnm`, `~/.cargo/bin`, `~/.rustup`, `~/.pyenv` | Language toolchains |
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
| System paths | Explicit RO mounts | `--read-only=/` blanket |

### Environment variables passed through

- `HOME`, `USER`, `TERM`, `PATH`, `LANG`, `SHELL`
- `AWS_PROFILE`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`
- `ANTHROPIC_API_KEY`

Bubblewrap version also has commented-out `CHROME_DEVEL_SANDBOX` and `PLAYWRIGHT_CHROMIUM_SANDBOX` env vars — uncomment if Chrome crashes inside the sandbox.

## Verifying the sandbox

Run the test script inside the sandbox to confirm isolation is working:

```bash
# Launch a shell in the sandbox instead of claude
bwrap [your args] /bin/bash sandbox-test.sh

# Or run claude-sandbox.sh and paste commands from sandbox-test.sh manually
```

The test checks filesystem write restrictions, sensitive path blocking, network access, and tool availability.

## Customizing

Edit the arrays at the top of either script:

- **`RW_PATHS`** — directories Claude can read and write
- **`RO_PATHS`** — directories Claude can read but not modify
- **`DENY_PATHS`** — directories that are always hidden/blocked

Paths that don't exist are silently skipped.

## Known limitations

- **Network is open** — filesystem restrictions don't prevent data exfiltration. If a prompt injection convinces Claude to `curl` your SSH keys somewhere, the sandbox won't stop it. Consider `--unshare-net` (bwrap) or `--net=none` (firejail) if you don't need network.
- **Linux only** — neither tool works on macOS or Windows. For macOS, consider `sandbox-exec` or Docker.
- **No seccomp** — dangerous syscalls aren't filtered. Could be added with `--seccomp` (bwrap) or firejail's built-in seccomp support.

## License

MIT
