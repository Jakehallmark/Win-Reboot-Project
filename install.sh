#!/usr/bin/env bash
set -euo pipefail

# Win-Reboot-Project Bootstrap Installer
# Run with: curl -fsSL https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/install.sh | bash

REPO_URL="https://github.com/Jakehallmark/Win-Reboot-Project.git"
INSTALL_DIR="$HOME/Win-Reboot-Project"
BRANCH="main"

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

check_requirements() {
  local missing=()
  
  for cmd in git bash; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required commands: ${missing[*]}. Please install them first."
  fi
}

clone_or_update() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    msg "Found existing installation at $INSTALL_DIR"
    msg "Updating from GitHub..."
    cd "$INSTALL_DIR"
    git fetch origin >/dev/null 2>&1 || warn "Failed to fetch updates"
    git reset --hard "origin/$BRANCH" >/dev/null 2>&1 || warn "Failed to update"
  else
    msg "Installing Win-Reboot-Project to $INSTALL_DIR"
    if [[ -d "$INSTALL_DIR" ]]; then
      warn "Directory exists but is not a git repo. Backing up to ${INSTALL_DIR}.backup"
      mv "$INSTALL_DIR" "${INSTALL_DIR}.backup.$(date +%s)"
    fi
    git clone -q "$REPO_URL" "$INSTALL_DIR" || err "Failed to clone repository"
    cd "$INSTALL_DIR"
  fi
  
  msg "Ensuring scripts are executable..."
  chmod +x scripts/*.sh 2>/dev/null || true
}

main() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║         Win-Reboot-Project Bootstrap Installer                ║
╚═══════════════════════════════════════════════════════════════╝

This will download Win-Reboot-Project and launch the interactive setup.

EOF

  check_requirements
  clone_or_update
  
  msg "Installation complete!"
  msg "Location: $INSTALL_DIR"
  echo ""
  msg "Launching interactive setup..."
  sleep 1
  
  # Redirect stdin from terminal to allow interactive prompts
  exec "$INSTALL_DIR/scripts/interactive_setup.sh" < /dev/tty
}

main "$@"
