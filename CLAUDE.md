# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `linux-install-bootstrap.sh`, that sets up a developer workstation: system packages, uv + Python, Rust, Python CLI tools (ruff, ty, ansible), lazydocker, OpenCode, Claude Code, Hermes Agent, Hermes ↔ Claude Code integration, and a one-way OneDrive pull into `~/work`. It targets Linux (apt/dnf/pacman), macOS (Homebrew) and WSL2, and must stay compatible with bash 3.2 (stock macOS bash). Avoid bash 4+ features such as associative arrays, `mapfile`, and `${var,,}`.

The state dir is still named after the old script name: `~/.local/state/bootstrap-hermes-claude`. Keep this in mind if you rename anything.

The directory is not a git repository.

## Commands

```bash
bash -n linux-install-bootstrap.sh              # syntax check
shellcheck linux-install-bootstrap.sh           # lint (if shellcheck is installed)
./linux-install-bootstrap.sh --dry-run          # print every action, change nothing
FORCE=1 ./linux-install-bootstrap.sh            # reinstall curl-installed tools
SKIP_ONEDRIVE=1 ./linux-install-bootstrap.sh    # skip the rclone/OneDrive step
```

There are no tests. Use `--dry-run` to check a change. Every setting in the "Config" block (install URLs, `PYTHON_VERSION`, `HERMES_HOME`, `ONEDRIVE_*`) can be overridden with an environment variable.

## Design invariants

- **Idempotent and re-runnable.** Each step checks current state first and calls `skip` if the work is already done. New steps must follow the same pattern.
- **Dry-run must be honored everywhere.** Wrap commands that change state in `run …`, or guard them with `(( DRY_RUN ))` and print a `[DRY ]` line instead. The helpers `curl_install`, `uv_tool` and `pm_install` already handle this.
- **Install helpers:**
  - `curl_install <name> <bin> <url> [installer args]`: skips if `<bin>` is on PATH (unless `FORCE=1`), pipes the installer to bash, then calls `refresh_path` and checks that the binary exists.
  - `uv_tool <bin> <uv tool install args>`: installs a Python CLI in isolation.
  - `pm_install`: dispatches on `$PM` (`brew`/`apt`/`dnf`/`pacman`) and adds `$SUDO` when the user is not root.
- **PATH:** `refresh_path` prepends the known user bin directories (`~/.local/bin`, `~/.cargo/bin`, `~/.opencode/bin`, `~/.claude/local`, `~/.hermes/bin`, `~/bin`) so that later steps can find tools installed earlier in the same run. If you add an installer that writes to a new location, add that directory here.
- **Error handling:** the script runs under `set -Eeuo pipefail` with an `ERR` trap that calls `die`. Commands that are allowed to fail need `|| true` or an `if` guard. Use `log`/`skip`/`warn`/`die`/`info` for all output.
- **Interactive steps** (`hermes setup`, `rclone config create`) are gated on `have_tty` and must redirect `</dev/tty`. The documented install is `curl … | bash`, so stdin is the script itself, not the terminal. When no terminal is available, the script calls `warn` with the manual command to run and continues. Non-interactive commands that might read stdin (for example `claude -p`) get `</dev/null`. Keep `main "$@"` as the last line so the whole script has been parsed before anything runs.
- **Line endings:** shell scripts must use LF; `.gitattributes` enforces this. A file saved with CRLF fails with `$'\r': command not found`.
- **Step numbering:** `info` messages use "Step N/11". Update every one of them when you add or remove a step, and also update the header comment list and `main()`.
- **System packages:** `SYSTEM_PACKAGES` holds `binary:package` pairs, which assumes the package name is the same on every package manager. Packages whose names differ per manager are handled in their own `case "$PM"` block, as `install_system_packages` does for the C toolchain.
- **`verify()`:** checks a hard-coded list of binaries. Add any newly installed tool to that list.

## Hermes ↔ Claude Code integration (step 10)

`ensure_mcp_server` registers `claude mcp serve` under `mcp_servers.claude-code` in `~/.hermes/config.yaml`. It edits the YAML through an inline Python heredoc run with `uv run --no-project --with pyyaml`, so it does not need a system Python. It writes a timestamped `.bak` file before making changes. If that edit fails, it falls back to appending text, but only when no `mcp_servers:` block exists yet. `check_claude_auth` uses `claude -p` to check whether Claude Code is logged in, and only warns if it is not.

## OneDrive step (step 11)

The folder is located by its path inside the user's own OneDrive through an rclone remote, never by a sharing link, so the script contains no tokens. The step uses `rclone copy`, which only adds or updates files and never deletes local ones. Do not change it to `sync`.
