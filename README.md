# public-install-bootstrap

One command sets up a CityLogix developer workstation: command-line tools, Python and Rust toolchains, and AI coding agents (Claude Code, OpenCode, Hermes Agent) already connected to each other. It also copies your OneDrive `work` folder to `~/work`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | bash
```

This works on any Linux box (Ubuntu/Debian, Fedora/RHEL, Arch), on WSL2, and on macOS with Homebrew. You only need `curl` and a user account with `sudo`; the script installs everything else.

The install will:

- ask for your `sudo` password to install system packages
- run `hermes setup`, where you choose **Anthropic** as the provider
- open a Microsoft 365 sign-in so rclone can reach your OneDrive

You can run the install again at any time. Each step checks whether its work is already done and skips it if so. If a run stops partway through, fix the problem it reports and run the same command again.

### Options

```bash
# Preview: show every action, change nothing
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | bash -s -- --dry-run

# Skip the OneDrive step
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | SKIP_ONEDRIVE=1 bash

# Reinstall uv, Rust, Claude Code, Hermes, OpenCode and lazydocker
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | FORCE=1 bash
```

To read the script before running it:

```bash
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## After installing

1. Open a new shell, or run `source ~/.bashrc`, so the new tools are on your `PATH`.
2. If the script warns that Claude Code is not logged in, run `claude`, sign in, then run the install command again to finish connecting Hermes to Claude Code.

## What gets installed

| Step | What |
|---|---|
| 1 | git, htop, nvtop, tmux, neovim, ripgrep, rclone, C compiler |
| 2 | [uv](https://docs.astral.sh/uv/) |
| 3 | Python 3.14 (installed by uv) |
| 4 | Rust + Cargo (installed by rustup) |
| 5 | ruff, ty, ansible (installed with `uv tool`, each in its own environment) |
| 6 | lazydocker |
| 7 | OpenCode |
| 8 | Claude Code |
| 9 | Hermes Agent, then `hermes setup` |
| 10 | Connects Hermes to Claude Code: installs Hermes's `claude-code` skill, adds `claude mcp serve` as an MCP server in `~/.hermes/config.yaml`, checks that Claude Code is logged in |
| 11 | Copies OneDrive `work` to `~/work` with `rclone copy` (one-way; never deletes local files) |

At the end, the script prints every tool's version and runs `hermes doctor`.

## Configuration

Set these variables in front of `bash` in the install command, for example `curl … | ONEDRIVE_SRC="Documents/Projects" bash`.

| Variable | Default | Purpose |
|---|---|---|
| `ONEDRIVE_SRC` | `work` | Folder in your OneDrive to copy |
| `ONEDRIVE_DEST` | `~/work` | Local folder to copy it into |
| `ONEDRIVE_REMOTE` | `onedrive` | Name of the rclone remote |
| `SKIP_ONEDRIVE` | `0` | Set to `1` to skip step 11 |
| `FORCE` | `0` | Set to `1` to reinstall the tools installed with curl |
| `PYTHON_VERSION` | `3.14` | Python version installed by uv |
| `HERMES_HOME` | `~/.hermes` | Hermes config directory |
| `*_INSTALL_URL` | the official installers | Use a different installer URL for uv, rustup, Claude Code, Hermes, OpenCode or lazydocker |

## Troubleshooting

- **No terminal (CI, `ssh host 'curl … | bash'`):** the prompt steps are skipped with a warning. Afterwards, log in with a terminal and run `hermes setup` and `rclone config create onedrive onedrive`, then run the install again.
- **Server without a browser:** to set up OneDrive, run `rclone authorize onedrive` on a machine that has a browser, and paste the token it prints into the server's prompt.
- **`Folder 'work' not found in OneDrive`:** the script lists your top-level OneDrive folders. Run the install again with `ONEDRIVE_SRC` set to the right one.
- **Running as root:** this works, but user-level tools end up in root's home folder. Run it as a normal user with `sudo`.

## Notes

- The script runs each tool's official installer (curl piped to a shell). It contains no OneDrive links or tokens: you sign in to your own OneDrive on each machine.
- Before it edits `~/.hermes/config.yaml`, the script saves a timestamped backup next to it.
- It records which steps it has completed in `~/.local/state/bootstrap-hermes-claude/`.
