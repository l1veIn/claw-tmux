#!/usr/bin/env bash
# claw-tmux installer
# Usage: curl -fsSL https://raw.githubusercontent.com/l1veIn/claw-tmux/main/install.sh | bash

set -euo pipefail

REPO="https://github.com/l1veIn/claw-tmux.git"
INSTALL_DIR="${CLAW_TMUX_INSTALL_DIR:-$HOME/.claw-tmux-src}"
BIN_DIR="${CLAW_TMUX_BIN_DIR:-/usr/local/bin}"
BIN_NAME="claw-tmux"

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m✓\033[0m $*"; }
error() { echo -e "\033[1;31m✗\033[0m $*" >&2; }

# ── Preflight ──

command -v git >/dev/null 2>&1 || { error "git is required"; exit 1; }
command -v tmux >/dev/null 2>&1 || { error "tmux is required (3.2+)"; exit 1; }
command -v jq >/dev/null 2>&1 || { error "jq is required"; exit 1; }

# Check tmux version >= 3.2
tmux_ver=$(tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1)
tmux_major=$(echo "$tmux_ver" | cut -d. -f1)
tmux_minor=$(echo "$tmux_ver" | cut -d. -f2)
if [[ "$tmux_major" -lt 3 ]] || { [[ "$tmux_major" -eq 3 ]] && [[ "$tmux_minor" -lt 2 ]]; }; then
  error "tmux $tmux_ver found, but 3.2+ is required (for silence-action support)"
  exit 1
fi

# ── Install or Update ──

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Updating claw-tmux..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  info "Installing claw-tmux..."
  rm -rf "$INSTALL_DIR"
  git clone "$REPO" "$INSTALL_DIR"
fi

# ── Make executable ──

chmod +x "$INSTALL_DIR/claw-tmux"
chmod +x "$INSTALL_DIR/lib/notify.sh"
chmod +x "$INSTALL_DIR/lib/get-session.sh"

# ── Symlink to PATH ──

if [[ -w "$BIN_DIR" ]]; then
  ln -sf "$INSTALL_DIR/claw-tmux" "$BIN_DIR/$BIN_NAME"
else
  info "Need sudo to link to $BIN_DIR"
  sudo ln -sf "$INSTALL_DIR/claw-tmux" "$BIN_DIR/$BIN_NAME"
fi

# ── Verify ──

echo ""
ok "claw-tmux $(claw-tmux version 2>/dev/null | awk '{print $2}') installed"
ok "Location: $(which claw-tmux)"
echo ""
echo "  Run 'claw-tmux --help' to get started."
echo "  Update anytime: curl -fsSL https://raw.githubusercontent.com/l1veIn/claw-tmux/main/install.sh | bash"
