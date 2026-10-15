#!/usr/bin/env bash
#
# bootstrap-hermes-claude.sh
#
# Idempotent workstation bootstrap. Every step checks current state first and
# is skipped if already done, so the script is safe to re-run.
#
#   1. System packages ... git, htop, nvtop, tmux, neovim, ripgrep, rclone (+ C toolchain)
#   2. uv .................. Astral installer
#   3. Python 3.14 ......... managed by uv
#   4. Rust + Cargo ........ rustup (cargo ships with the Rust toolchain)
#   5. Python CLI tools .... ruff, ty, ansible (isolated via `uv tool`)
#   6. lazydocker
#   7. OpenCode
#   8. Claude Code
#   9. Hermes Agent
#  10. Hermes <-> Claude Code integration (skill + MCP server + auth check)
#  11. OneDrive folder pulled to ~/work (rclone, one-way, never deletes locally)
#
# Usage:
#   ./bootstrap-hermes-claude.sh            # normal run
#   ./bootstrap-hermes-claude.sh --dry-run  # show what would happen, change nothing
#   FORCE=1 ./bootstrap-hermes-claude.sh    # reinstall curl-installed tools
#   SKIP_ONEDRIVE=1 ./bootstrap-hermes-claude.sh
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
 
# OneDrive for Business. The folder is resolved by path inside your own
# OneDrive rather than by sharing link, so the script contains no access token.
ONEDRIVE_REMOTE="${ONEDRIVE_REMOTE:-onedrive}"   # rclone remote name
ONEDRIVE_SRC="${ONEDRIVE_SRC:-work}"             # folder path inside OneDrive
ONEDRIVE_DEST="${ONEDRIVE_DEST:-$HOME/work}"     # local destination
SKIP_ONEDRIVE="${SKIP_ONEDRIVE:-0}"
 
STATE_DIR="$HOME/.local/state/bootstrap-hermes-claude"
FORCE="${FORCE:-0}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
 
# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_SKIP=$'\e[36m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_OFF=$'\e[0m'
else
  C_OK=""; C_SKIP=""; C_WARN=""; C_ERR=""; C_OFF=""
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
 
trap 'die "Error on line $LINENO: $BASH_COMMAND"' ERR
 
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
  info "Installing $name"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" | bash -s -- "$@"
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
  run uv tool install --force "$@"
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
    brew)   run brew install "$@" ;;
    apt)    run $SUDO apt-get update -qq
            run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    run $SUDO dnf install -y "$@" ;;
    pacman) run $SUDO pacman -S --needed --noconfirm "$@" ;;
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
 
install_system_packages() {
  info "Step 1/11: System packages"
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
 
  if (( ${#todo[@]} )); then
    info "Installing: ${todo[*]}"
    pm_install "${todo[@]}"
    (( DRY_RUN )) || log "System packages installed"
  fi
 
  if (( ! DRY_RUN )) && [[ "$PM" == "apt" ]] && have nvim; then
    local v; v="$(nvim --version | head -1)"
    [[ "$v" =~ v0\.([0-9]+) ]] && (( BASH_REMATCH[1] < 10 )) && \
      warn "Distro neovim is old ($v). Many plugins need 0.10+. Consider the official AppImage or PPA."
  fi
}
 
# ---------------------------------------------------------------------------
# 2-5. uv, Python, Rust, Python CLI tools
# ---------------------------------------------------------------------------
install_uv() {
  info "Step 2/11: uv"
  if have uv && [[ "$FORCE" != "1" ]]; then
    skip "uv already installed ($(uv --version))"
    return
  fi
  if (( DRY_RUN )); then printf '[DRY ] curl -LsSf %s | sh\n' "$UV_INSTALL_URL"; return; fi
  curl -LsSf "$UV_INSTALL_URL" | sh
  refresh_path
  have uv || die "uv not on PATH after install."
  log "uv installed ($(uv --version))"
}
 
install_python() {
  info "Step 3/11: Python $PYTHON_VERSION"
  if (( ! DRY_RUN )) && uv python find "$PYTHON_VERSION" >/dev/null 2>&1; then
    skip "Python $PYTHON_VERSION already available ($(uv python find "$PYTHON_VERSION"))"
    return
  fi
  run uv python install "$PYTHON_VERSION"
  (( DRY_RUN )) || log "Python $PYTHON_VERSION installed ($(uv python find "$PYTHON_VERSION"))"
}
 
install_rust() {
  info "Step 4/11: Rust + Cargo"
  curl_install "Rust (rustup)" rustup "$RUSTUP_INSTALL_URL" -y --profile default
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  if (( ! DRY_RUN )); then
    have rustc && have cargo || die "rustc/cargo missing after rustup install."
    log "Toolchain: $(rustc --version) / $(cargo --version)"
  fi
}
 
install_python_tools() {
  info "Step 5/11: ruff, ty, ansible"
  uv_tool ruff    ruff
  uv_tool ty      ty
  # ansible-core provides the CLIs; the `ansible` package adds the community collections.
  uv_tool ansible ansible-core --with ansible
}
 
# ---------------------------------------------------------------------------
# 6-7. lazydocker, OpenCode
# ---------------------------------------------------------------------------
install_lazydocker() {
  info "Step 6/11: lazydocker"
  if [[ "$PM" == "brew" ]]; then
    if have lazydocker; then skip "lazydocker already installed"; else pm_install lazydocker; fi
  else
    curl_install lazydocker lazydocker "$LAZYDOCKER_INSTALL_URL"
  fi
  have docker || warn "Docker is not installed. lazydocker needs a Docker daemon to be useful."
}
 
install_opencode() {
  info "Step 7/11: OpenCode"
  curl_install OpenCode opencode "$OPENCODE_INSTALL_URL"
}
 
# ---------------------------------------------------------------------------
# 8-9. Claude Code, Hermes
# ---------------------------------------------------------------------------
install_claude_code() {
  info "Step 8/11: Claude Code"
  curl_install "Claude Code" claude "$CLAUDE_INSTALL_URL"
}
 
install_hermes() {
  info "Step 9/11: Hermes Agent"
  curl_install "Hermes Agent" hermes "$HERMES_INSTALL_URL"
 
  # First-run setup (provider, model, memory dir). Interactive, so only on a TTY.
  if [[ -f "$HERMES_CONFIG" ]]; then
    skip "Hermes already configured ($HERMES_CONFIG exists)"
  elif [[ -t 0 ]]; then
    info "Running 'hermes setup' (interactive: pick Anthropic as provider)"
    run hermes setup
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
  elif hermes skills install "$HERMES_SKILL_NAME" >/dev/null 2>&1; then
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
  if $t claude -p "reply with OK" >/dev/null 2>&1; then
    skip "Claude Code is authenticated"
  else
    warn "Claude Code is not authenticated yet. Run 'claude' once and log in, then re-run this script."
  fi
}
 
setup_integration() {
  info "Step 10/11: Hermes <-> Claude Code integration"
  refresh_path
  (( DRY_RUN )) || { have claude && have hermes; } || die "Both claude and hermes must be installed first."
  have tmux || warn "tmux missing. Hermes needs it to drive Claude Code interactively (print mode still works)."
  ensure_claude_skill
  ensure_mcp_server
  check_claude_auth
  mark_done integration
}
 
# ---------------------------------------------------------------------------
# 11. OneDrive -> ~/work
# ---------------------------------------------------------------------------
sync_onedrive() {
  info "Step 11/11: OneDrive '$ONEDRIVE_SRC' -> $ONEDRIVE_DEST"
  if [[ "$SKIP_ONEDRIVE" == "1" ]]; then skip "SKIP_ONEDRIVE=1"; return; fi
  (( DRY_RUN )) && { printf '[DRY ] rclone copy %s:%s %s\n' "$ONEDRIVE_REMOTE" "$ONEDRIVE_SRC" "$ONEDRIVE_DEST"; return; }
  have rclone || die "rclone is required for the OneDrive pull."
 
  # a) Remote configured?
  if rclone listremotes | grep -qx "${ONEDRIVE_REMOTE}:"; then
    skip "rclone remote '$ONEDRIVE_REMOTE' already configured"
  elif [[ -t 0 ]]; then
    info "Configuring rclone remote '$ONEDRIVE_REMOTE'. A browser window opens for Microsoft 365 sign-in."
    info "Headless machine? Run 'rclone authorize onedrive' on a machine with a browser and paste the token."
    rclone config create "$ONEDRIVE_REMOTE" onedrive
  else
    warn "No TTY to sign in to OneDrive. Run 'rclone config create $ONEDRIVE_REMOTE onedrive' then re-run."
    return
  fi
 
  # b) Source folder exists?
  if ! rclone lsf "${ONEDRIVE_REMOTE}:${ONEDRIVE_SRC}" --max-depth 1 >/dev/null 2>&1; then
    warn "Folder '$ONEDRIVE_SRC' not found in OneDrive. Top-level folders are:"
    rclone lsd "${ONEDRIVE_REMOTE}:" >&2 || true
    warn "Re-run with ONEDRIVE_SRC='<path>' set to the right folder."
    return
  fi
 
  # c) Pull. `copy` only transfers new/changed files and never deletes local
  #    files, so re-running is cheap and safe.
  mkdir -p "$ONEDRIVE_DEST"
  rclone copy "${ONEDRIVE_REMOTE}:${ONEDRIVE_SRC}" "$ONEDRIVE_DEST" \
    --transfers 8 --checkers 16 --stats-one-line --stats 10s -v 2>&1 | grep -Ev '^\s*$' || true
  log "OneDrive folder up to date in $ONEDRIVE_DEST ($(find "$ONEDRIVE_DEST" -type f | wc -l | tr -d ' ') files)"
  mark_done onedrive
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
  sync_onedrive
  verify
}
 
main "$@"
 