# claude-bubblewrap

OS-level sandbox for running [Claude Code](https://github.com/anthropics/claude-code) with dangerous permissions safely. Uses [bubblewrap](https://github.com/containers/bubblewrap) to wrap Claude Code in an external jail that holds even if Claude reasons its way around its internal sandbox.

## Why

Claude Code's built-in sandbox is a software guardrail. This is a hardware one. When you run Claude with `--dangerously-skip-permissions`, you're trusting the model not to do anything destructive. This script adds a second layer: even if Claude decides to `rm -rf /` or read your GPG keys, the kernel blocks it.

## How it works

```
┌──────────────────────────────────┐
│  Host system                     │
│                                  │
│  ┌────────────────────────────┐  │
│  │  bubblewrap jail           │  │
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

## Requirements

- Linux (bubblewrap is Linux-only)
- [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`)
- [Claude Code](https://github.com/anthropics/claude-code) (`claude`)

```bash
# Install bubblewrap
sudo apt install bubblewrap    # Debian/Ubuntu
sudo dnf install bubblewrap    # Fedora/RHEL

# Install Claude Code
npm install -g @anthropic-ai/claude-code
```

## AppArmor setup (Ubuntu/Debian)

Modern Ubuntu kernels block unprivileged user namespaces via AppArmor by default. Since bubblewrap requires user namespaces to function, you need to add an AppArmor profile that allows `bwrap` specifically. Without this, you'll get `bwrap: setting up uid map: Permission denied`.

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
# Run in current directory
./claude-sandbox.sh

# Run in a specific project
./claude-sandbox.sh /path/to/project

# Pass arguments to claude
./claude-sandbox.sh /path/to/project --print "do something"
./claude-sandbox.sh . --resume
```

## Security policy

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
| `$JAVA_HOME`, `$ANDROID_HOME` | JDK and Android SDK (if set) |

### Blocked (deny-listed)

| Path | Why |
|------|-----|
| `~/.gnupg/private-keys-v1.d` | GPG private keys |
| `~/.password-store` | pass password manager |
| `~/.vault-token` | HashiCorp Vault tokens |
| `~/.kube` | Kubernetes config and credentials |

### Other isolation

| Feature | Setting |
|---------|---------|
| Network | Open (no restrictions) |
| `/tmp` | Private tmpfs (not shared with host) |
| `/dev/shm` | Bind-mounted from host (required by Chrome/Playwright) |
| `$HOME` | tmpfs overlay (only listed paths visible) |
| PID namespace | Isolated (`--unshare-pid`) |
| Parent death | Sandbox killed (`--die-with-parent`) |
| Chrome sandbox | Kept enabled by default — disable via env vars if Chrome crashes (see script comments) |

### Environment variables passed through

- `HOME`, `USER`, `TERM`, `PATH`, `LANG`, `SHELL`
- `AWS_PROFILE`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`
- `ANTHROPIC_API_KEY`
- `CHROME_DEVEL_SANDBOX`, `PLAYWRIGHT_CHROMIUM_SANDBOX` (commented out by default — uncomment if Chrome crashes)

## Verifying the sandbox

Run the test script inside the sandbox to confirm isolation is working:

```bash
# Launch a shell in the sandbox instead of claude
bwrap [your args] /bin/bash sandbox-test.sh

# Or run claude-sandbox.sh and paste commands from sandbox-test.sh manually
```

The test checks filesystem write restrictions, sensitive path blocking, network access, and tool availability.

## Customizing

Edit the arrays at the top of `claude-sandbox.sh`:

- **`RW_PATHS`** — directories Claude can read and write
- **`RO_PATHS`** — directories Claude can read but not modify
- **`DENY_PATHS`** — directories that are always hidden (overlaid with tmpfs)

Paths that don't exist are silently skipped.

## Known limitations

- **Network is open** — filesystem restrictions don't prevent data exfiltration. If a prompt injection convinces Claude to `curl` your SSH keys somewhere, the sandbox won't stop it. Consider `--unshare-net` if you don't need network.
- **Linux only** — bubblewrap doesn't work on macOS or Windows. For macOS, consider `sandbox-exec` or Docker.
- **No seccomp** — dangerous syscalls aren't filtered. Could be added with `--seccomp`.

## License

MIT
