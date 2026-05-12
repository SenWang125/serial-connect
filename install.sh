#!/usr/bin/env bash
# install.sh — Install serial-connect tools
#
# Usage:
#   ./install.sh              # installs to ~/bin (default)
#   ./install.sh /usr/local/bin
#   sudo ./install.sh /usr/local/bin

set -euo pipefail

INSTALL_DIR="${1:-$HOME/bin}"
CONF_DIR="${HOME}/.config"
CONF_FILE="${CONF_DIR}/serial-boards.conf"

# ── Helpers ────────────────────────────────────────────────────────────────────
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n'  "$*"; }

# ── Preflight checks ───────────────────────────────────────────────────────────
echo ""
echo "serial-connect installer"
echo "========================"
echo ""

# Check bash version (need ≥ 5.1 for wait -t)
bash_major=${BASH_VERSINFO[0]}
bash_minor=${BASH_VERSINFO[1]}
if (( bash_major < 5 || (bash_major == 5 && bash_minor < 1) )); then
    yellow "Warning: bash ${BASH_VERSION} detected. bash ≥ 5.1 recommended (for wait -t)."
fi

# Check python3
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found. Install python3 and re-run." >&2
    exit 1
fi

# Check dialout group
if ! id -nG | grep -qw dialout; then
    yellow "Warning: user '$(id -un)' is not in the 'dialout' group."
    yellow "         Run: sudo usermod -aG dialout \$USER  (then log out/in)"
fi

# ── Install directory ──────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

TOOLS=(serial-discover serial-connect tio.sh serial-agent)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing to: $INSTALL_DIR"
echo ""

for tool in "${TOOLS[@]}"; do
    src="$SCRIPT_DIR/$tool"
    dst="$INSTALL_DIR/$tool"
    if [[ ! -f "$src" ]]; then
        echo "  Missing: $src" >&2; exit 1
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    green "  ✓ $tool"
done

# ── Config file ────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ ! -f "$CONF_FILE" ]]; then
    cp "$SCRIPT_DIR/examples/serial-boards.conf.example" "$CONF_FILE"
    green "  ✓ ~/.config/serial-boards.conf  (created from example)"
else
    dim   "  · ~/.config/serial-boards.conf  (already exists, not modified)"
fi

# ── PATH check ─────────────────────────────────────────────────────────────────
echo ""
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    yellow "Note: $INSTALL_DIR is not in your PATH."
    yellow "      Add to ~/.bashrc or ~/.profile:"
    yellow "        export PATH=\"\$HOME/bin:\$PATH\""
fi

# ── Optional tool checks ───────────────────────────────────────────────────────
echo ""
echo "Optional tools:"

check_tool() {
    local cmd="$1" pkg="$2" note="$3"
    if command -v "$cmd" &>/dev/null; then
        green "  ✓ $cmd"
    else
        yellow "  ✗ $cmd  (install: sudo apt install $pkg)  — $note"
    fi
}

check_tool tio          tio              "recommended terminal emulator"
check_tool screen       screen           "shareable sessions (screen -x)"
check_tool inotifywait  inotify-tools    "instant event notifications (faster wait-state)"
check_tool ser2net      ser2net          "serial port multiplexer (human+agent coexistence)"
check_tool fuser        psmisc           "port ownership detection"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "Installation complete."
echo ""
echo "Quick start:"
dim  "  serial-discover           # see all connected boards"
dim  "  serial-connect            # interactive terminal menu"
dim  "  serial-agent auto-label   # label boards from serial numbers"
echo ""
