# public-install-bootstrap

One script that sets up a new developer workstation: the usual command-line tools, Python and Rust toolchains, AI coding agents (Claude Code, OpenCode, Hermes Agent) already connected to each other, and your OneDrive `work` folder copied to `~/work`.

The script can be run as many times as you like. Each step first checks whether its work is already done and skips it if so. If a run fails partway through, fix the problem and run the script again; it picks up where it left off.

## Quick install

Run this from any Linux box (or WSL2, or macOS with Homebrew):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh)
```

You need `bash`, `curl`, and a user account with `sudo`. Everything else is installed by the script.

### Why `bash <(curl …)` and not `curl … | bash`?

Some steps ask you to sign in: `hermes setup` asks you to choose an AI provider, and `rclone` opens a Microsoft 365 sign-in. Those steps only run when the script's input is your terminal. When the script is piped in with `curl … | bash`, its input is the pipe, so those steps are skipped with a warning. The `bash <(curl …)` form keeps your terminal as the input.

If your shell does not support `<(…)`, download the script first and then run it:

```bash
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh
bash bootstrap.sh
```

### Options

Put options at the end of the command. Put environment variables in front of `bash`.

```bash
# See what would happen without changing anything
bash <(curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh) --dry-run

# Skip the OneDrive step
SKIP_ONEDRIVE=1 bash <(curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh)

# Reinstall the tools that are installed with curl (uv, Rust, Claude Code, Hermes, ...)
FORCE=1 bash <(curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh)
```

## What gets installed

| Step | What | How |
|---|---|---|
| 1 | git, htop, nvtop, tmux, neovim, ripgrep, rclone, C toolchain | system package manager |
| 2 | [uv](https://docs.astral.sh/uv/) | Astral installer |
| 3 | Python 3.14 | `uv python install` |
| 4 | Rust + Cargo | rustup |
| 5 | ruff, ty, ansible | `uv tool install` (each in its own environment) |
| 6 | lazydocker | official install script (Homebrew on macOS) |
| 7 | OpenCode | official install script |
| 8 | Claude Code | official install script |
| 9 | Hermes Agent | official install script, then `hermes setup` |
| 10 | Hermes ↔ Claude Code connection | installs Hermes's `claude-code` skill, adds `claude mcp serve` as an MCP server in `~/.hermes/config.yaml`, checks that Claude Code is logged in |
| 11 | OneDrive `work` folder → `~/work` | `rclone copy` (one-way, never deletes local files) |

At the end, the script prints the version of every tool and runs `hermes doctor`.

Supported package managers: **apt** (Debian/Ubuntu), **dnf** (Fedora/RHEL), **pacman** (Arch), **brew** (macOS).

## After the first run

1. Open a new shell, or run `source ~/.bashrc`, so the new tools are on your `PATH`.
2. If the script warned that Claude Code is not logged in, run `claude` once, sign in, and then run the bootstrap again so it can finish setting up the Hermes connection.
3. If you ran without a terminal (for example over a non-interactive SSH session), finish these steps by hand and then run the bootstrap again:
   - `hermes setup` (choose Anthropic as the provider)
   - `rclone config create onedrive onedrive`

   On a machine without a browser, run `rclone authorize onedrive` on a machine that has one and paste the token it gives you.

## Configuration

Each of these can be overridden with an environment variable:

| Variable | Default | Purpose |
|---|---|---|
| `PYTHON_VERSION` | `3.14` | Python version installed by uv |
| `HERMES_HOME` | `~/.hermes` | Hermes config directory |
| `ONEDRIVE_REMOTE` | `onedrive` | rclone remote name |
| `ONEDRIVE_SRC` | `work` | Folder path inside your OneDrive |
| `ONEDRIVE_DEST` | `~/work` | Local destination |
| `SKIP_ONEDRIVE` | `0` | Set to `1` to skip step 11 |
| `FORCE` | `0` | Set to `1` to reinstall curl-installed tools |
| `*_INSTALL_URL` | upstream installers | Override the installer URL for uv, rustup, Claude Code, Hermes, OpenCode, or lazydocker |

Example: copy a different OneDrive folder.

```bash
ONEDRIVE_SRC="Documents/Projects" bash <(curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh)
```

## Notes

- The script runs third-party installers by downloading them and piping them to a shell. Read `linux-install-bootstrap.sh` before running it on a machine you care about.
- Run it as a normal user with `sudo`, not as root. If you run it as root, the user-level tools are installed for root only.
- The script contains no OneDrive links or tokens. You sign in to your own OneDrive with rclone on each machine.
- Before the script changes `~/.hermes/config.yaml`, it saves a timestamped backup (`config.yaml.bak.<epoch>`).
- The script records which steps it has completed in `~/.local/state/bootstrap-hermes-claude/`.
