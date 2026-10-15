#!/usr/bin/env bash
#
# linux-install-bootstrap.sh
#
# Idempotent workstation bootstrap. Every step checks current state first and
# is skipped if already done, so the script is safe to re-run.
#
#   1. System packages ... git, htop, nvtop, tmux, neovim, ripgrep, rclone (+ C toolchain,
#                          + qemu-guest-agent on Proxmox/QEMU VMs)
#   2. uv .................. Astral installer
#   3. Python 3.14 ......... managed by uv
#   4. Rust + Cargo ........ rustup (cargo ships with the Rust toolchain)
#   5. Python CLI tools .... ruff, ty, ansible (isolated via `uv tool`)
#   6. lazydocker
#   7. OpenCode
#   8. Claude Code
#   9. Hermes Agent
#  10. Hermes <-> Claude Code integration (skill + MCP server + auth check)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/CITYLOGIX/public-install-bootstrap/main/linux-install-bootstrap.sh | bash
#   curl -fsSL <url> | bash -s -- --dry-run   # show what would happen, change nothing
#   curl -fsSL <url> | FORCE=1 bash           # reinstall curl-installed tools
#   bash linux-install-bootstrap.sh [--dry-run]   # from a local copy
#
# When piped into bash, stdin is the script itself, so interactive steps read
# from /dev/tty instead (see have_tty).
#
# Supported: Linux (apt, dnf, pacman), macOS (Homebrew), WSL2.
# Requires bash 3.2+ (works with the stock macOS bash).
 
set -Eeuo pipefail
 
# ---------------------------------------------------------------------------
# Config (override any of these via environment variables)
# ---------------------------------------------------------------------------
PYTHON_VERSION="${PYTHON_VERSION:-3.14}"
 
CLAUDE_INSTALL_URL="${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}"
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
UV_INSTALL_URL="${UV_INSTALL_URL:-https://astral.sh/uv/install.sh}"
RUSTUP_INSTALL_URL="${RUSTUP_INSTALL_URL:-https://sh.rustup.rs}"
OPENCODE_INSTALL_URL="${OPENCODE_INSTALL_URL:-https://opencode.ai/install}"
LAZYDOCKER_INSTALL_URL="${LAZYDOCKER_INSTALL_URL:-https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh}"
 
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CONFIG="$HERMES_HOME/config.yaml"
HERMES_SKILL_NAME="claude-code"
MCP_SERVER_NAME="claude-code"
 
STATE_DIR="$HOME/.local/state/bootstrap-hermes-claude"
FORCE="${FORCE:-0}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
 
# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_SKIP=$'\e[36m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_OFF=$'\e[0m'
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
else
  C_OK=""; C_SKIP=""; C_WARN=""; C_ERR=""; C_OFF=""; C_BOLD=""; C_DIM=""
fi
 
log()  { printf '%s[ OK ]%s %s\n'  "$C_OK"   "$C_OFF" "$*"; }
skip() { printf '%s[SKIP]%s %s\n'  "$C_SKIP" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n'  "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }
info() { printf '\n[....] %s\n' "$*"; }
 
run() {
  if (( DRY_RUN )); then printf '[DRY ] %s\n' "$*"; else "$@"; fi
}
 
have() { command -v "$1" >/dev/null 2>&1; }

# True when a terminal is available for prompts, even if stdin is a pipe
# (as with `curl ... | bash`). Interactive commands must then read </dev/tty.
have_tty() { [[ -t 0 ]] || { [[ -e /dev/tty ]] && (exec </dev/tty) 2>/dev/null; }; }
 
trap 'die "Error on line $LINENO: $BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Progress display
# ---------------------------------------------------------------------------
# step() draws the overall progress bar; spin() animates a long, quiet command
# and sends its output to $LOG_FILE. The animation is only used when stdout is
# a terminal (set NO_SPINNER=1 to disable it); otherwise output streams as-is.
TOTAL_STEPS=10
STEP=0
LOG_FILE="${TMPDIR:-/tmp}/linux-install-bootstrap.$(date +%Y%m%d-%H%M%S).log"
SPIN=0
[[ -t 1 && "${NO_SPINNER:-0}" != "1" ]] && SPIN=1
SPIN_PID=""
SUDO_KEEPALIVE_PID=""

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
    BAR_FULL="█"; BAR_EMPTY="░"; SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); MARK_OK="✔"; MARK_ERR="✘" ;;
  *)
    BAR_FULL="#"; BAR_EMPTY="-"; SPIN_FRAMES=('|' '/' '-' '\'); MARK_OK="+"; MARK_ERR="x" ;;
esac

# step <title>: numbered automatically, in the order main() calls the steps.
step() {
  STEP=$((STEP + 1))
  local width=24 filled bar="" j
  filled=$(( STEP * width / TOTAL_STEPS ))
  for (( j = 0; j < width; j++ )); do
    if (( j < filled )); then bar+="$BAR_FULL"; else bar+="$BAR_EMPTY"; fi
  done
  printf '\n%s%s%s %s%2d/%d%s  %s%s%s\n' \
    "$C_OK" "$bar" "$C_OFF" "$C_DIM" "$STEP" "$TOTAL_STEPS" "$C_OFF" "$C_BOLD" "$*" "$C_OFF"
}

# spin <label> <command...>: run command with a spinner; returns its exit code.
# The command gets </dev/null, so never use this for anything that prompts.
spin() {
  local label="$1"; shift
  if (( DRY_RUN )); then printf '[DRY ] %s\n' "$*"; return 0; fi
  if (( ! SPIN )); then
    info "$label"
    "$@"
    return
  fi
  local start=$SECONDS rc=0 i=0 cols shown
  cols="$(tput cols 2>/dev/null || echo 80)"
  shown="$label"
  (( ${#shown} > cols - 16 )) && shown="${shown:0:$((cols - 19))}..."
  printf '\n=== %s\n$ %s\n' "$label" "$*" >>"$LOG_FILE"
  "$@" </dev/null >>"$LOG_FILE" 2>&1 &
  SPIN_PID=$!
  printf '\e[?25l'
  while kill -0 "$SPIN_PID" 2>/dev/null; do
    printf '\r  %s%s%s %s %s(%ds)%s' "$C_SKIP" "${SPIN_FRAMES[i % ${#SPIN_FRAMES[@]}]}" "$C_OFF" \
      "$shown" "$C_DIM" $((SECONDS - start)) "$C_OFF"
    i=$((i + 1))
    sleep 0.1
  done
  wait "$SPIN_PID" || rc=$?
  SPIN_PID=""
  printf '\r\e[K\e[?25h'
  if (( rc == 0 )); then
    printf '  %s%s%s %s %s(%ds)%s\n' "$C_OK" "$MARK_OK" "$C_OFF" "$label" "$C_DIM" $((SECONDS - start)) "$C_OFF"
  else
    printf '  %s%s%s %s %s(exit %d)%s\n' "$C_ERR" "$MARK_ERR" "$C_OFF" "$label" "$C_DIM" "$rc" "$C_OFF" >&2
  fi
  return "$rc"
}

# spin_or_die <label> <command...>: like spin, but shows the log tail and exits on failure.
spin_or_die() {
  local label="$1"
  spin "$@" && return 0
  if (( SPIN )); then
    printf '%s--- last 20 lines of %s ---%s\n' "$C_DIM" "$LOG_FILE" "$C_OFF" >&2
    tail -n 20 "$LOG_FILE" >&2
  fi
  if (( SPIN )); then die "$label failed. Full log: $LOG_FILE"; else die "$label failed."; fi
}

cleanup() {
  [[ -n "$SPIN_PID" ]] && kill "$SPIN_PID" 2>/dev/null
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  (( SPIN )) && printf '\e[?25h'
  return 0
}
trap cleanup EXIT
trap 'cleanup; printf "\n"; die "Interrupted."' INT TERM

# Ask for the sudo password once, up front, and keep the credential fresh so
# package installs can run behind the spinner without prompting.
sudo_keepalive() {
  [[ -n "$SUDO" ]] && (( ! DRY_RUN )) || return 0
  sudo -n true 2>/dev/null || {
    have_tty || die "sudo needs a password but there is no terminal. Run from an interactive shell."
    info "Administrator access is needed to install system packages"
    sudo -v </dev/tty || die "sudo authentication failed."
  }
  ( trap - ERR; set +e
    while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
}
 
# Make freshly installed binaries visible in this shell without a re-login.
refresh_path() {
  local d
  for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.opencode/bin" \
           "$HOME/.claude/local" "$HOME/.hermes/bin" "$HOME/bin"; do
    [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
  done
  export PATH
  hash -r
}
 
mark_done() { (( DRY_RUN )) || { mkdir -p "$STATE_DIR"; date -u +%FT%TZ > "$STATE_DIR/$1"; }; }
 
# curl_install <name> <binary> <url> [args passed to the installer shell...]
# Skips if <binary> is on PATH (unless FORCE=1), otherwise runs `curl | sh`.
curl_install() {
  local name="$1" bin="$2" url="$3"; shift 3
  refresh_path
  if have "$bin" && [[ "$FORCE" != "1" ]]; then
    skip "$name already installed ($(command -v "$bin"))"
    return
  fi
  if (( DRY_RUN )); then
    printf '[DRY ] curl -fsSL %s | bash -s -- %s\n' "$url" "$*"
    return
  fi
  if [[ "${INSTALLER_INTERACTIVE:-0}" == "1" ]]; then
    info "Installing $name"
    curl --proto '=https' --tlsv1.2 -fsSL "$url" | bash -s -- "$@"
  else
    spin_or_die "Installing $name" bash -c \
      'set -o pipefail; curl --proto =https --tlsv1.2 -fsSL "$1" | bash -s -- "${@:2}"' _ "$url" "$@"
  fi
  refresh_path
  have "$bin" || die "$name install finished but '$bin' is not on PATH."
  log "$name installed"
  mark_done "$bin"
}
 
# uv_tool <binary> <uv tool install args...>
uv_tool() {
  local bin="$1"; shift
  if have "$bin" && [[ "$FORCE" != "1" ]]; then
    skip "$bin already installed ($(command -v "$bin"))"
    return
  fi
  spin_or_die "Installing $bin" uv tool install --force "$@"
  refresh_path
  (( DRY_RUN )) || { have "$bin" || die "'$bin' not on PATH after uv tool install."; log "$bin installed"; }
}
 
# ---------------------------------------------------------------------------
# Package manager detection
# ---------------------------------------------------------------------------
PM=""
SUDO=""
detect_pm() {
  if   [[ "$(uname -s)" == "Darwin" ]]; then
    have brew || die "Homebrew is required on macOS: https://brew.sh"
    PM=brew
  elif have apt-get; then PM=apt
  elif have dnf;     then PM=dnf
  elif have pacman;  then PM=pacman
  else die "No supported package manager found (apt, dnf, pacman, brew)."
  fi
  if [[ "$PM" != "brew" && $EUID -ne 0 ]]; then
    have sudo || die "sudo is required to install system packages."
    SUDO=sudo
  fi
}
 
pm_install() {
  (( $# )) || return 0
  case "$PM" in
    brew)   spin_or_die "brew install $*" brew install "$@" ;;
    apt)    spin_or_die "Updating package lists" $SUDO apt-get update -qq
            spin_or_die "apt install $*" $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
              apt-get install -y "$@" ;;
    dnf)    spin_or_die "dnf install $*" $SUDO dnf install -y "$@" ;;
    pacman) spin_or_die "pacman -S $*" $SUDO pacman -S --needed --noconfirm "$@" ;;
  esac
}
 
# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  info "Preflight checks"
  [[ $EUID -eq 0 ]] && warn "Running as root. User tools will be installed for root only. Prefer a normal user with sudo."
  case "$(uname -s)" in
    Linux|Darwin) ;;
    *) die "Unsupported OS: $(uname -s). Use Linux, macOS or WSL2." ;;
  esac
  # git is installed in step 1, so only curl is a hard prerequisite.
  local missing=() bin
  for bin in curl bash; do have "$bin" || missing+=("$bin"); done
  (( ${#missing[@]} )) && die "Missing prerequisites: ${missing[*]}"
  detect_pm
  refresh_path
  log "Preflight passed (package manager: $PM)"
  sudo_keepalive
}
 
# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
# Each entry is "binary:package". Package names are identical on apt, dnf,
# pacman and brew for these tools.
SYSTEM_PACKAGES=(
  "git:git"
  "htop:htop"
  "nvtop:nvtop"
  "tmux:tmux"
  "nvim:neovim"
  "rg:ripgrep"
  "rclone:rclone"
)
 
# Proxmox VMs are QEMU/KVM guests. The virtio port only exists when "QEMU Guest
# Agent" is enabled in the VM options; DMI catches it when it is not.
QEMU_GA_PORT="/dev/virtio-ports/org.qemu.guest_agent.0"
is_qemu_vm() {
  [[ -e "$QEMU_GA_PORT" ]] && return 0
  local f
  for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_vendor; do
    [[ -r "$f" ]] && grep -qiE 'qemu|proxmox' "$f" && return 0
  done
  return 1
}

# qemu-ga lives in /usr/sbin, which is often not on a normal user's PATH.
qemu_agent_installed() { [[ -x /usr/sbin/qemu-ga || -x /usr/bin/qemu-ga ]]; }

ensure_qemu_agent_running() {
  if (( DRY_RUN )); then printf '[DRY ] %s systemctl start qemu-guest-agent\n' "$SUDO"; return; fi
  have systemctl || { warn "No systemd; start qemu-guest-agent manually."; return; }
  if systemctl is-active --quiet qemu-guest-agent; then
    skip "qemu-guest-agent already running"
  # The unit is bound to the virtio port. Without it, `systemctl start` blocks
  # for the device timeout (90s) and then fails, so do not even try.
  elif [[ ! -e "$QEMU_GA_PORT" ]]; then
    warn "qemu-guest-agent is installed, but this VM has no guest-agent channel yet."
    warn "In Proxmox: VM > Options > QEMU Guest Agent > Enabled, then fully stop and start the VM (a reboot from inside is not enough). The agent then starts on its own."
  else
    # Debian/Ubuntu ship a static unit (started by udev), so `enable` may fail; that is fine.
    $SUDO systemctl enable qemu-guest-agent >/dev/null 2>&1 || true
    local t=""; have timeout && t="timeout 30"
    if spin "Starting qemu-guest-agent" $SUDO $t systemctl start qemu-guest-agent; then
      log "qemu-guest-agent running"
    else
      warn "qemu-guest-agent did not start. Check: sudo systemctl status qemu-guest-agent"
    fi
  fi
}

install_system_packages() {
  step "System packages"
  local entry bin pkg todo=()
  for entry in "${SYSTEM_PACKAGES[@]}"; do
    bin="${entry%%:*}"; pkg="${entry#*:}"
    # On macOS /usr/bin/git is a stub until Xcode CLT is installed, so for git
    # require that it actually runs, not just that it is on PATH.
    if have "$bin" && { [[ "$bin" != "git" ]] || git --version >/dev/null 2>&1; }; then
      skip "$pkg already installed"
    else
      todo+=("$pkg")
    fi
  done
 
  # C linker/toolchain: Rust crates need it to build.
  if ! have cc; then
    case "$PM" in
      apt)    todo+=(build-essential) ;;
      dnf)    todo+=(gcc make) ;;
      pacman) todo+=(base-devel) ;;
      brew)   warn "No C compiler found. Run: xcode-select --install" ;;
    esac
  fi

  # Proxmox / QEMU VM: the guest agent lets Proxmox show the VM's IPs and shut
  # it down or snapshot it cleanly.
  local qemu_vm=0
  if [[ "$PM" != "brew" ]] && is_qemu_vm; then
    qemu_vm=1
    if qemu_agent_installed; then
      skip "qemu-guest-agent already installed (Proxmox/QEMU VM detected)"
    else
      info "Proxmox/QEMU VM detected, adding qemu-guest-agent"
      todo+=(qemu-guest-agent)
    fi
  fi
 
  if (( ${#todo[@]} )); then
    info "Installing: ${todo[*]}"
    pm_install "${todo[@]}"
    (( DRY_RUN )) || log "System packages installed"
  fi

  (( qemu_vm )) && ensure_qemu_agent_running
 
  if (( ! DRY_RUN )) && [[ "$PM" == "apt" ]] && have nvim; then
    local v; v="$(nvim --version | head -1)"
    # Use `if`, not `&& &&`: as the function's last statement a false test
    # would become its return status and trip `set -e`.
    if [[ "$v" =~ v0\.([0-9]+) ]] && (( BASH_REMATCH[1] < 10 )); then
      warn "Distro neovim is old ($v). Many plugins need 0.10+. Consider the official AppImage or PPA."
    fi
  fi
}
 
# ---------------------------------------------------------------------------
# 2-5. uv, Python, Rust, Python CLI tools
# ---------------------------------------------------------------------------
install_uv() {
  step "uv"
  if have uv && [[ "$FORCE" != "1" ]]; then
    skip "uv already installed ($(uv --version))"
    return
  fi
  if (( DRY_RUN )); then printf '[DRY ] curl -LsSf %s | sh\n' "$UV_INSTALL_URL"; return; fi
  spin_or_die "Installing uv" bash -c 'set -o pipefail; curl -LsSf "$1" | sh' _ "$UV_INSTALL_URL"
  refresh_path
  have uv || die "uv not on PATH after install."
  log "uv installed ($(uv --version))"
}
 
install_python() {
  step "Python $PYTHON_VERSION"
  if (( ! DRY_RUN )) && uv python find "$PYTHON_VERSION" >/dev/null 2>&1; then
    skip "Python $PYTHON_VERSION already available ($(uv python find "$PYTHON_VERSION"))"
    return
  fi
  spin_or_die "Installing Python $PYTHON_VERSION" uv python install "$PYTHON_VERSION"
  (( DRY_RUN )) || log "Python $PYTHON_VERSION installed ($(uv python find "$PYTHON_VERSION"))"
}
 
install_rust() {
  step "Rust + Cargo"
  curl_install "Rust (rustup)" rustup "$RUSTUP_INSTALL_URL" -y --profile default
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  if (( ! DRY_RUN )); then
    have rustc && have cargo || die "rustc/cargo missing after rustup install."
    log "Toolchain: $(rustc --version) / $(cargo --version)"
  fi
}
 
install_python_tools() {
  step "ruff, ty, ansible"
  uv_tool ruff    ruff
  uv_tool ty      ty
  # ansible-core provides the CLIs; the `ansible` package adds the community collections.
  uv_tool ansible ansible-core --with ansible
}
 
# ---------------------------------------------------------------------------
# 6-7. lazydocker, OpenCode
# ---------------------------------------------------------------------------
install_lazydocker() {
  step "lazydocker"
  if [[ "$PM" == "brew" ]]; then
    if have lazydocker; then skip "lazydocker already installed"; else pm_install lazydocker; fi
  else
    curl_install lazydocker lazydocker "$LAZYDOCKER_INSTALL_URL"
  fi
  have docker || warn "Docker is not installed. lazydocker needs a Docker daemon to be useful."
}
 
install_opencode() {
  step "OpenCode"
  curl_install OpenCode opencode "$OPENCODE_INSTALL_URL"
}
 
# ---------------------------------------------------------------------------
# 8-9. Claude Code, Hermes
# ---------------------------------------------------------------------------
install_claude_code() {
  step "Claude Code"
  curl_install "Claude Code" claude "$CLAUDE_INSTALL_URL"
}
 
install_hermes() {
  step "Hermes Agent"
  # Its installer may prompt, so it runs in the foreground without the spinner.
  INSTALLER_INTERACTIVE=1 curl_install "Hermes Agent" hermes "$HERMES_INSTALL_URL"
 
  # First-run setup (provider, model, memory dir). Interactive, so only on a TTY.
  if [[ -f "$HERMES_CONFIG" ]]; then
    skip "Hermes already configured ($HERMES_CONFIG exists)"
  elif have_tty; then
    info "Running 'hermes setup' (interactive: pick Anthropic as provider)"
    run hermes setup </dev/tty
  else
    warn "No TTY and no $HERMES_CONFIG. Run 'hermes setup' manually afterwards."
  fi
}
 
# ---------------------------------------------------------------------------
# 10. Hermes <-> Claude Code
# ---------------------------------------------------------------------------
ensure_claude_skill() {
  if [[ -d "$HERMES_HOME/skills" ]] && \
     find "$HERMES_HOME/skills" -type d -name "$HERMES_SKILL_NAME" 2>/dev/null | grep -q .; then
    skip "Hermes '$HERMES_SKILL_NAME' skill already present"
    return
  fi
  info "Hermes '$HERMES_SKILL_NAME' skill not found, attempting install"
  if (( DRY_RUN )); then
    printf '[DRY ] hermes skills install %s\n' "$HERMES_SKILL_NAME"
  elif spin "Installing Hermes '$HERMES_SKILL_NAME' skill" hermes skills install "$HERMES_SKILL_NAME"; then
    log "Installed Hermes '$HERMES_SKILL_NAME' skill"
  else
    warn "Could not install the skill automatically. Check with: hermes skills search claude"
  fi
}
 
ensure_mcp_server() {
  # Registers Claude Code (`claude mcp serve`) as an MCP server in Hermes.
  if (( DRY_RUN )); then
    printf '[DRY ] add mcp_servers.%s -> claude mcp serve in %s\n' "$MCP_SERVER_NAME" "$HERMES_CONFIG"
    return
  fi
  mkdir -p "$HERMES_HOME"
  touch "$HERMES_CONFIG"
  local claude_bin
  claude_bin="$(command -v claude)" || die "claude not on PATH; cannot register MCP server."
 
  # Preferred: structured YAML edit with PyYAML via uv (no system Python needed).
  local result
  if result="$(uv run --quiet --no-project --python "$PYTHON_VERSION" --with pyyaml \
                 python - "$HERMES_CONFIG" "$MCP_SERVER_NAME" "$claude_bin" <<'PY'
import sys, yaml, shutil, time
path, name, claude = sys.argv[1:4]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
servers = cfg.get("mcp_servers") or {}
cfg["mcp_servers"] = servers
if name in servers:
    print("exists"); sys.exit(0)
shutil.copy2(path, f"{path}.bak.{int(time.time())}")
servers[name] = {"command": claude, "args": ["mcp", "serve"]}
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
print("added")
PY
  )"; then
    if [[ "$result" == "exists" ]]; then
      skip "MCP server '$MCP_SERVER_NAME' already in $HERMES_CONFIG"
    else
      log "Registered Claude Code MCP server in $HERMES_CONFIG (backup saved)"
    fi
    return
  fi
 
  # Fallback: text append, only when unambiguous.
  if grep -Eq "^[[:space:]]+${MCP_SERVER_NAME}:" "$HERMES_CONFIG"; then
    skip "MCP server '$MCP_SERVER_NAME' already in $HERMES_CONFIG"
  elif grep -Eq '^mcp_servers:' "$HERMES_CONFIG"; then
    warn "mcp_servers block exists and YAML edit failed. Add manually under mcp_servers:"
    printf '  %s:\n    command: %s\n    args: ["mcp", "serve"]\n' "$MCP_SERVER_NAME" "$claude_bin" >&2
  else
    cp "$HERMES_CONFIG" "$HERMES_CONFIG.bak.$(date +%s)"
    cat >> "$HERMES_CONFIG" <<EOF
 
mcp_servers:
  ${MCP_SERVER_NAME}:
    command: ${claude_bin}
    args: ["mcp", "serve"]
EOF
    log "Registered Claude Code MCP server in $HERMES_CONFIG (backup saved)"
  fi
}
 
check_claude_auth() {
  (( DRY_RUN )) && return
  local t=""; have timeout && t="timeout 60"
  if spin "Checking Claude Code login" sh -c "$t claude -p 'reply with OK' </dev/null >/dev/null 2>&1"; then
    skip "Claude Code is authenticated"
  else
    warn "Claude Code is not authenticated yet. Run 'claude' once and log in, then re-run this script."
  fi
}
 
setup_integration() {
  step "Hermes <-> Claude Code integration"
  refresh_path
  (( DRY_RUN )) || { have claude && have hermes; } || die "Both claude and hermes must be installed first."
  have tmux || warn "tmux missing. Hermes needs it to drive Claude Code interactively (print mode still works)."
  ensure_claude_skill
  ensure_mcp_server
  check_claude_auth
  mark_done integration
}
 
# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
verify() {
  (( DRY_RUN )) && { info "Dry run complete. No changes made."; return; }
  info "Verification"
  local b v
  for b in git claude hermes opencode uv python"$PYTHON_VERSION" rustc cargo ruff ty ansible \
           lazydocker htop nvtop tmux nvim rg rclone; do
    if [[ "$b" == python* ]]; then
      v="$(uv python find "$PYTHON_VERSION" 2>/dev/null || echo 'MISSING')"
    elif have "$b"; then
      v="$("$b" --version 2>/dev/null | head -1 || true)"; v="${v:-installed}"
    else
      v="MISSING"
    fi
    printf '  %-12s %s\n' "$b" "$v"
  done
  have hermes && { hermes doctor || warn "'hermes doctor' reported issues (see above)."; }
  echo
  log "Bootstrap complete. Open a new shell (or 'source ~/.bashrc') to pick up PATH changes."
  (( SPIN )) && [[ -f "$LOG_FILE" ]] && printf '%sInstaller output was saved to %s%s\n' "$C_DIM" "$LOG_FILE" "$C_OFF"
  return 0
}
 
main() {
  preflight
  install_system_packages
  install_uv
  install_python
  install_rust
  install_python_tools
  install_lazydocker
  install_opencode
  install_claude_code
  install_hermes
  setup_integration
  verify
}
 
main "$@"
 