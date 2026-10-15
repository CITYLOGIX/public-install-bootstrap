# public-install-bootstrap

One command sets up a CityLogix developer workstation. You choose which of three groups to install:

| Group | What it installs |
|---|---|
| **Utils** | git, htop, nvtop, tmux, neovim, ripgrep, rclone, lazydocker; on a Proxmox/QEMU VM, also `qemu-guest-agent` (installed and started) |
| **Coding** | C compiler/build tools, [uv](https://docs.astral.sh/uv/), Python 3.14 (installed by uv), Rust + Cargo (installed by rustup), ruff, ty, ansible (each installed with `uv tool` in its own environment) |
| **Agentic** | OpenCode, Claude Code (updated if older than 2.1.280), Hermes Agent (then `hermes setup`), and the Hermes ↔ Claude Code connection: Hermes's `claude-code` skill, `claude mcp serve` added as an MCP server in `~/.hermes/config.yaml`, the [`claude-subscription-directsdk`](https://github.com/NousResearch/hermes-official-plugins) plugin with **Claude Opus 5.5** (`claude-opus-5-5[1m]`) set as Hermes's default model, and a check that Claude Code is logged in |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | bash
```

This works on any Linux box (Ubuntu/Debian, Fedora/RHEL, Arch), on WSL2, and on macOS with Homebrew. You only need `curl` and a user account with `sudo`.

The script starts by asking about each group:

```text
  Utils  git, htop, nvtop, tmux, neovim, ripgrep, rclone, lazydocker (+ qemu-guest-agent on Proxmox VMs)
  Install Utils? [Y/n]
  Coding  C compiler, uv, Python 3.14, Rust + Cargo, ruff, ty, ansible
  Install Coding? [Y/n]
  Agentic  OpenCode, Claude Code, Hermes Agent (Claude subscription plugin, default Opus), Hermes <-> Claude Code integration
  Install Agentic? [Y/n]
```

Press Enter to accept a group or type `n` to skip it. After that, the only interruptions are:

- your `sudo` password, asked once, and only if a group you chose needs it
- `hermes setup` (Agentic only). Pick any provider; the script then switches Hermes's default to Claude Opus through your Claude subscription

The groups install in the order Utils → Coding → Agentic. A progress bar shows the current step, and long installs show a spinner with the elapsed time. Their full output is saved to a log file in `/tmp`; the path is printed at the end. If something fails, the last lines of that log are printed.

You can run the install again at any time, for example to add a group you skipped. Each step checks whether its work is already done and skips it if so.

### Options

```bash
# Install every group without asking
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | bash -s -- --yes

# Pre-answer some or all groups (1/0 or y/n); you are only asked about the rest
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | INSTALL_UTILS=1 INSTALL_CODING=0 INSTALL_AGENTIC=1 bash

# Preview: show every action, change nothing
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | bash -s -- --dry-run

# Reinstall the tools installed with curl (uv, Rust, lazydocker, OpenCode, Claude Code, Hermes)
curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | FORCE=1 bash
```

With no terminal to ask in (for example in CI), every group defaults to **yes**. Use the `INSTALL_*` variables to skip groups there.

To read the script before running it:

```bash
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## After installing

1. Open a new shell, or run `source ~/.bashrc`, so the new tools are on your `PATH`.
2. If the script warns that Claude Code is not logged in, run `claude auth login`, then run the install again. Hermes reaches Claude Opus through the logged-in Claude Code CLI on your Pro/Max subscription, with no API key. On a server without a browser, `claude auth login` prints a URL to open on another device.

At the end, the script prints the version of every tool in the groups you chose, and runs `hermes doctor` if you chose Agentic.

## Configuration

Set these variables in front of `bash` in the install command, for example `curl … | NO_SPINNER=1 bash`.

| Variable | Default | Purpose |
|---|---|---|
| `INSTALL_UTILS`, `INSTALL_CODING`, `INSTALL_AGENTIC` | ask | `1`/`y` to install the group, `0`/`n` to skip it, without being asked |
| `FORCE` | `0` | Set to `1` to reinstall the tools installed with curl |
| `PYTHON_VERSION` | `3.14` | Python version installed by uv |
| `HERMES_HOME` | `~/.hermes` | Hermes config directory |
| `HERMES_MODEL` | `claude-opus-5-5[1m]` | Hermes default model (for example `claude-sonnet-5-5[1m]`) |
| `HERMES_PROVIDER` | `claude-subscription-directsdk-experimental` | Hermes default provider |
| `HERMES_PLUGIN` | `claude-subscription-directsdk` | Hermes plugin installed for that provider |
| `NO_SPINNER` | `0` | Set to `1` to show installer output live instead of the spinner |
| `*_INSTALL_URL` | the official installers | Use a different installer URL for uv, rustup, Claude Code, Hermes, OpenCode or lazydocker |

## Troubleshooting

- **Agentic without Utils:** git is still installed, because the agent installers need it. tmux is not; Hermes warns that it needs tmux to drive Claude Code interactively. Run the install again and choose Utils to add it.
- **Agentic without Coding:** the Hermes config is edited with a simple text append instead of a YAML-aware edit. If `~/.hermes/config.yaml` already has an `mcp_servers:` section, the script prints the lines to add by hand.
- **Hermes plugin install fails:** `claude-subscription-directsdk` needs Hermes 0.21.4 or newer. Run `hermes update`, then run the install again.
- **Hermes refuses the Claude subscription provider:** the plugin rejects `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` and similar variables inherited from your shell (the script warns if any are set). Remove them from your shell profile.
- **Changing the model later:** run `hermes model`, or rerun the install with `HERMES_MODEL=…`. The script only rewrites `model:` in `~/.hermes/config.yaml` when it differs, and saves a backup first.
- **No terminal (CI, `ssh host 'curl … | bash'`):** `hermes setup` is skipped with a warning. Afterwards, log in with a terminal, run `hermes setup`, then run the install again.
- **Proxmox VM, agent installed but not running:** the agent needs the VM's guest-agent channel. In Proxmox, go to the VM's **Options → QEMU Guest Agent**, enable it, then fully stop and start the VM (a reboot from inside the VM is not enough).
- **Running as root:** this works, but user-level tools end up in root's home folder. Run it as a normal user with `sudo`.

## Notes

- The script runs each tool's official installer (curl piped to a shell). It contains no credentials.
- Before it edits `~/.hermes/config.yaml`, the script saves a timestamped backup next to it.
- It records which steps it has completed in `~/.local/state/bootstrap-hermes-claude/`.
