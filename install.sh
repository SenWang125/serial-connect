#!/usr/bin/env bash
# install.sh — Install serial-connect tools
#
# Usage:
#   ./install.sh                    # interactive (asks terminal preference)
#   ./install.sh --term tio         # non-interactive: tio (recommended)
#   ./install.sh --term screen      # non-interactive: screen
#   ./install.sh --term minicom     # non-interactive: minicom
#   ./install.sh --term picocom     # non-interactive: picocom
#   ./install.sh /usr/local/bin     # custom install directory
#   sudo ./install.sh /usr/local/bin --term tio

set -euo pipefail

INSTALL_DIR=""
TERM_CHOICE=""

# ── Parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --term)    TERM_CHOICE="$2"; shift 2 ;;
        --term=*)  TERM_CHOICE="${1#--term=}"; shift ;;
        --help|-h) echo "Usage: ./install.sh [INSTALL_DIR] [--term tio|screen|minicom|picocom]"; exit 0 ;;
        *)         INSTALL_DIR="$1"; shift ;;
    esac
done

INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
CONF_DIR="${HOME}/.config"
CONF_FILE="${CONF_DIR}/serial-boards.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ─────────────────────────────────────────────────────────────
bold()   { printf '\033[1m%s\033[0m\n'  "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n'  "$*"; }

# ── Package manager detection ──────────────────────────────────────────────────
pkg_install_cmd() {
    local pkg="$1"
    if   command -v apt-get &>/dev/null; then echo "sudo apt-get install -y $pkg"
    elif command -v dnf     &>/dev/null; then echo "sudo dnf install -y $pkg"
    elif command -v pacman  &>/dev/null; then echo "sudo pacman -S --noconfirm $pkg"
    elif command -v brew    &>/dev/null; then echo "brew install $pkg"
    else echo "# install $pkg  (package manager not detected)"
    fi
}

try_install() {
    local pkg="$1"
    local cmd; cmd="$(pkg_install_cmd "$pkg")"
    echo "  Running: $cmd"
    if eval "$cmd" &>/dev/null; then
        green "  ✓ installed $pkg"; return 0
    else
        yellow "  Could not auto-install. Run manually: $cmd"; return 1
    fi
}

# ── Header ─────────────────────────────────────────────────────────────────────
echo ""
bold "serial-connect installer"
echo "========================"
echo ""

# ── Required dependencies ─────────────────────────────────────────────────────
bold "Checking required dependencies..."
echo ""

ABORT=0

if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
    yellow "  ⚠ bash ${BASH_VERSION} — bash ≥ 5.1 recommended (event-driven wait-state)"
else
    green  "  ✓ bash ${BASH_VERSION}"
fi

if command -v python3 &>/dev/null; then
    green  "  ✓ python3 $(python3 --version 2>&1 | awk '{print $2}')"
else
    red    "  ✗ python3 — REQUIRED (serial-agent is a Python script)"
    echo   "    $(pkg_install_cmd python3)"
    ABORT=1
fi

if command -v fuser &>/dev/null; then
    green  "  ✓ fuser"
else
    yellow "  ⚠ fuser not found — install psmisc for port-ownership detection"
    echo   "    $(pkg_install_cmd psmisc)"
fi

if id -nG | grep -qw dialout; then
    green  "  ✓ dialout group"
else
    yellow "  ⚠ user '$(id -un)' not in dialout group"
    yellow "    Run: sudo usermod -aG dialout \$USER  (then log out/in)"
fi

if [[ $ABORT -ne 0 ]]; then
    echo ""; red "Required dependencies missing — install them and re-run."; exit 1
fi

# ── Terminal emulator selection ────────────────────────────────────────────────
echo ""
bold "Terminal emulator"
echo ""
echo "  serial-connect launches a terminal to connect to a board."
echo "  Which terminal would you like to use as the default?"
echo ""
echo "    1) tio      Modern, auto-reconnects on reset, session sharing (recommended)"
echo "    2) screen   Shareable sessions: screen -x ttyUSBx"
echo "    3) minicom  Classic serial terminal"
echo "    4) picocom  Minimal, lightweight"
echo ""

declare -A TERM_PKGS=([tio]=tio [screen]=screen [minicom]=minicom [picocom]=picocom)

if [[ -z "$TERM_CHOICE" ]]; then
    while true; do
        read -rp "  Choice [1-4, default=1]: " n
        n="${n:-1}"
        case "$n" in
            1) TERM_CHOICE=tio;     break ;;
            2) TERM_CHOICE=screen;  break ;;
            3) TERM_CHOICE=minicom; break ;;
            4) TERM_CHOICE=picocom; break ;;
            *) echo "  Please enter 1, 2, 3, or 4" ;;
        esac
    done
fi

if [[ -z "${TERM_PKGS[$TERM_CHOICE]+x}" ]]; then
    red "Unknown terminal: $TERM_CHOICE. Valid: tio screen minicom picocom"; exit 1
fi

echo ""
if command -v "$TERM_CHOICE" &>/dev/null; then
    green "  ✓ $TERM_CHOICE is already installed"
else
    yellow "  $TERM_CHOICE is not installed — installing..."
    try_install "${TERM_PKGS[$TERM_CHOICE]}" || true
fi

# ── Optional dependencies ──────────────────────────────────────────────────────
echo ""
bold "Optional dependencies"
echo ""

install_optional() {
    local cmd="$1" pkg="$2" desc="$3"
    if command -v "$cmd" &>/dev/null; then
        green "  ✓ $cmd — $desc"
    else
        yellow "  ✗ $cmd — $desc"
        # Only prompt when running interactively
        if [[ -t 0 ]]; then
            read -rp "    Install $pkg now? [y/N]: " yn || yn="n"
            if [[ "${yn,,}" == "y" ]]; then
                try_install "$pkg" || true
            else
                dim "    Skip. Install later: $(pkg_install_cmd "$pkg")"
            fi
        else
            dim "    Install later: $(pkg_install_cmd "$pkg")"
        fi
    fi
    echo ""
}

install_optional inotifywait inotify-tools \
    "instant event notifications — faster wait-state in serial-agent"

install_optional ser2net ser2net \
    "serial multiplexer — run human terminal and agent daemon on the same port"

# ── Copy tools ─────────────────────────────────────────────────────────────────
echo ""
bold "Installing to: $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"

TOOLS=(serial-discover serial-connect serial-agent)
for tool in "${TOOLS[@]}"; do
    src="$SCRIPT_DIR/$tool"
    [[ ! -f "$src" ]] && { red "  Missing source: $src"; exit 1; }
    cp "$src" "$INSTALL_DIR/$tool"
    chmod +x "$INSTALL_DIR/$tool"
    green "  ✓ $tool"
done

# ── Patch terminal default into installed serial-connect ──────────────────────
if [[ "$TERM_CHOICE" != "tio" ]]; then
    sed -i "s|SERIAL_TERM=\"\${SERIAL_TERM:-tio}\"|SERIAL_TERM=\"\${SERIAL_TERM:-${TERM_CHOICE}}\"|" \
        "$INSTALL_DIR/serial-connect"
    dim "  · default terminal set to: $TERM_CHOICE"
    dim "    Override any time: SERIAL_TERM=tio serial-connect"
fi

# ── Config file ────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ ! -f "$CONF_FILE" ]]; then
    cp "$SCRIPT_DIR/examples/serial-boards.conf.example" "$CONF_FILE"
    green "  ✓ ~/.config/serial-boards.conf  (created from example)"
else
    dim   "  · ~/.config/serial-boards.conf  (exists — not modified)"
fi

# ── PATH check ─────────────────────────────────────────────────────────────────
echo ""
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    yellow "Note: $INSTALL_DIR is not in \$PATH."
    yellow "      Add to ~/.bashrc:  export PATH=\"\$HOME/bin:\$PATH\""
    echo ""
fi

# ── Done ───────────────────────────────────────────────────────────────────────
bold "Done. Quick start:"
echo ""
dim  "  serial-discover                 # probe all connected boards"
dim  "  serial-connect                  # pick a board and connect"
dim  "  serial-connect /dev/ttyUSB1     # connect directly (skips menu)"
dim  "  serial-agent auto-label -y      # name boards by USB serial#"
dim  "  serial-agent --help             # full automation CLI"
echo ""
