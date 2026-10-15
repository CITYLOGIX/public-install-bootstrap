# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `linux-install-bootstrap.sh`, that sets up a developer workstation: system packages, uv + Python, Rust, Python CLI tools (ruff, ty, ansible), lazydocker, OpenCode, Claude Code, Hermes Agent, and Hermes ↔ Claude Code integration. It targets Linux (apt/dnf/pacman), macOS (Homebrew) and WSL2, and must stay compatible with bash 3.2 (stock macOS bash). Avoid bash 4+ features such as associative arrays, `mapfile`, and `${var,,}`.

The state dir is still named after the old script name: `~/.local/state/bootstrap-hermes-claude`. Keep this in mind if you rename anything.

The directory is not a git repository.

## Commands

```bash
bash -n linux-install-bootstrap.sh              # syntax check
shellcheck linux-install-bootstrap.sh           # lint (if shellcheck is installed)
./linux-install-bootstrap.sh --dry-run          # print every action, change nothing
FORCE=1 ./linux-install-bootstrap.sh            # reinstall curl-installed tools
```

There are no tests. Use `--dry-run` to check a change. Dry runs skip the spinner and every `(( ! DRY_RUN ))` branch, so to test those, source the script without its final `main "$@"` line (`grep -v '^main "\$@"'`), stub functions such as `have`, `is_qemu_vm` and `systemctl`, and call a single step function. Use `script -qec …` to get a pseudo-TTY for the spinner. Every setting in the "Config" block (install URLs, `PYTHON_VERSION`, `HERMES_HOME`) can be overridden with an environment variable.

## Design invariants

- **Idempotent and re-runnable.** Each step checks current state first and calls `skip` if the work is already done. New steps must follow the same pattern.
- **Dry-run must be honored everywhere.** Wrap commands that change state in `run …`, or guard them with `(( DRY_RUN ))` and print a `[DRY ]` line instead. The helpers `curl_install`, `uv_tool` and `pm_install` already handle this.
- **Install helpers:**
  - `curl_install <name> <bin> <url> [installer args]`: skips if `<bin>` is on PATH (unless `FORCE=1`), pipes the installer to bash, then calls `refresh_path` and checks that the binary exists.
  - `uv_tool <bin> <uv tool install args>`: installs a Python CLI in isolation.
  - `pm_install`: dispatches on `$PM` (`brew`/`apt`/`dnf`/`pacman`) and adds `$SUDO` when the user is not root.
- **PATH:** `refresh_path` prepends the known user bin directories (`~/.local/bin`, `~/.cargo/bin`, `~/.opencode/bin`, `~/.claude/local`, `~/.hermes/bin`, `~/bin`) so that later steps can find tools installed earlier in the same run. If you add an installer that writes to a new location, add that directory here.
- **Error handling:** the script runs under `set -Eeuo pipefail` with an `ERR` trap that calls `die`. Commands that are allowed to fail need `|| true` or an `if` guard. Use `log`/`skip`/`warn`/`die`/`info` for all output.
- **Interactive steps** (`hermes setup`) are gated on `have_tty` and must redirect `</dev/tty`. The documented install is `curl … | bash`, so stdin is the script itself, not the terminal. When no terminal is available, the script calls `warn` with the manual command to run and continues. Non-interactive commands that might read stdin (for example `claude -p`) get `</dev/null`. Keep `main "$@"` as the last line so the whole script has been parsed before anything runs.
- **Line endings:** shell scripts must use LF; `.gitattributes` enforces this. A file saved with CRLF fails with `$'\r': command not found`.
- **Steps and progress display:** each step function starts with `step "<title>"`, which numbers the steps automatically (in the order `main()` calls them) and draws the progress bar. When you add or remove a step, update `TOTAL_STEPS`, the header comment list and `main()`.
- **Spinner:** run long, non-interactive commands with `spin_or_die "<label>" cmd…` (fatal on failure, prints the tail of `$LOG_FILE`) or `spin` (returns the exit code, for use in `if`). Both handle dry-run. They run the command in the background with `</dev/null` and output sent to `$LOG_FILE`, so never use them for anything that prompts. `hermes setup` and the Hermes installer (`INSTALLER_INTERACTIVE=1 curl_install …`) run in the foreground. The spinner is off when stdout is not a TTY, or when `NO_SPINNER=1`.
- **sudo:** `sudo_keepalive` (called from preflight) asks for the password once on `/dev/tty` and refreshes it in the background, so `$SUDO` commands can run behind the spinner.
- **Proxmox/QEMU VMs:** `is_qemu_vm` (virtio guest-agent port or DMI vendor) adds `qemu-guest-agent` to step 1, and `ensure_qemu_agent_running` starts it.
- **`&&` chains under `set -e`:** never end a function with `test && action`. When the test is false, the function returns 1 and the script aborts. Use `if`. This is how the neovim version check broke step 1.
- **System packages:** `SYSTEM_PACKAGES` holds `binary:package` pairs, which assumes the package name is the same on every package manager. Packages whose names differ per manager are handled in their own `case "$PM"` block, as `install_system_packages` does for the C toolchain.
- **`verify()`:** checks a hard-coded list of binaries. Add any newly installed tool to that list.

## Hermes ↔ Claude Code integration (step 10)

`ensure_mcp_server` registers `claude mcp serve` under `mcp_servers.claude-code` in `~/.hermes/config.yaml`. It edits the YAML through an inline Python heredoc run with `uv run --no-project --with pyyaml`, so it does not need a system Python. It writes a timestamped `.bak` file before making changes. If that edit fails, it falls back to appending text, but only when no `mcp_servers:` block exists yet. `check_claude_auth` uses `claude -p` to check whether Claude Code is logged in, and only warns if it is not.
