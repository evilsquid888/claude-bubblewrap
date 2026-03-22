# Claude Sandbox TODOs

## High Priority

- [ ] Move `~/.ssh` from RW_PATHS to RO_PATHS — prevents reading/modifying private keys
- [ ] Move `~/.aws` from RW_PATHS to RO_PATHS (or remove and use scoped IAM env vars instead)
- [ ] Use private `/tmp` — remove `/tmp` from RW_PATHS, always use `--tmpfs /tmp` so host processes can't see sandbox files
- [ ] Fix mount ordering — RO home paths (`~/.nvm`, `~/.cargo/bin`, etc.) are mounted before `--tmpfs "$HOME"` wipes them. Re-mount all home-relative RO paths after the tmpfs overlay

## Medium Priority

- [ ] Add `--unshare-ipc` and `--unshare-uts` for shared memory and hostname isolation
- [ ] Move `~/.gitconfig` from RW_PATHS to RO_PATHS
- [ ] Consider seccomp filtering (`--seccomp`) for dangerous syscall blocking

## Notes

- Network is intentionally open — filesystem restrictions alone don't prevent data exfiltration
- The biggest risk is open network + readable credentials (SSH/AWS) enabling exfiltration via prompt injection
