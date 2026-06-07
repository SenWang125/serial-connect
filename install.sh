#!/usr/bin/env bash
# install.sh — Install serial-connect tools
#
# Installs all files into ~/.serial-connect/ and symlinks the three CLI tools
# into ~/.local/bin/ (already in PATH on modern Linux — no PATH changes needed).
#
# Usage:
#   ./install.sh                         # interactive (asks terminal preference)
#   ./install.sh --term tio              # non-interactive: tio (recommended)
#   ./install.sh --term screen           # non-interactive: screen
#   ./install.sh --term minicom          # non-interactive: minicom
#   ./install.sh --term picocom          # non-interactive: picocom
#   sudo ./install.sh --global           # system-wide (all users, requires sudo)

set -euo pipefail

INSTALL_DIR=""
TERM_CHOICE=""
GLOBAL=0

# ── Parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --global)  GLOBAL=1; shift ;;
        --term)    TERM_CHOICE="$2"; shift 2 ;;
        --term=*)  TERM_CHOICE="${1#--term=}"; shift ;;
        --help|-h) echo "Usage: ./install.sh [--global] [--term tio|screen|minicom|picocom]"; exit 0 ;;
        *)         INSTALL_DIR="$1"; shift ;;
    esac
done

if (( GLOBAL )); then
    (( EUID == 0 )) || { echo "Global install requires sudo."; exit 1; }
    INSTALL_DIR="${INSTALL_DIR:-/usr/local/share/serial-connect}"
    LINK_DIR="/usr/local/bin"
    CONF_FILE="/etc/serial-boards.conf"
else
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.serial-connect}"
    LINK_DIR="$HOME/.local/bin"
    CONF_FILE="${INSTALL_DIR}/serial-boards.conf"
fi
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
    yellow "  ⚠ user '$(id -un)' not in dialout group (needed to access /dev/ttyUSB* without sudo)"
    if [[ -t 0 ]]; then
        read -rp "    Add to dialout now? [Y/n]: " yn || yn="y"
        if [[ "${yn,,}" != "n" ]]; then
            if sudo usermod -aG dialout "$USER"; then
                green "  ✓ added to dialout — re-login required for it to take effect"
            else
                yellow "    Could not add automatically. Run: sudo usermod -aG dialout \$USER"
            fi
        fi
    else
        yellow "    Run: sudo usermod -aG dialout \$USER  (then log out/in)"
    fi
fi

if [[ $ABORT -ne 0 ]]; then
    echo ""; red "Required dependencies missing — install them and re-run."; exit 1
fi

# ── Terminal emulator selection ────────────────────────────────────────────────
# Supports --term as comma-separated list: --term tio,screen
# tio is the default terminal for serial-connect; others are also installed.

echo ""
bold "Terminal emulators"
echo ""
echo "  Select which terminals to install (comma-separated, e.g. 1,2)."
echo "  The first choice becomes the default for serial-connect."
echo "  tio + screen is recommended: tio for daily use, screen for sharing."
echo ""
echo "    1) tio      Modern, auto-reconnects on reset              (recommended)"
echo "    2) screen   Shareable sessions: screen -x ttyUSBx          (recommended)"
echo "    3) minicom  Classic serial terminal"
echo "    4) picocom  Minimal, lightweight"
echo ""

declare -A TERM_PKGS=([tio]=tio [screen]=screen [minicom]=minicom [picocom]=picocom)
TERM_ORDER=(tio screen minicom picocom)
declare -a TERMS_TO_INSTALL=()

if [[ -n "$TERM_CHOICE" ]]; then
    # Non-interactive: parse comma-separated --term list
    IFS=',' read -ra _choices <<< "$TERM_CHOICE"
    for c in "${_choices[@]}"; do
        c="${c// /}"
        [[ -z "${TERM_PKGS[$c]+x}" ]] && { red "Unknown terminal: $c. Valid: tio screen minicom picocom"; exit 1; }
        TERMS_TO_INSTALL+=("$c")
    done
elif [[ -t 0 ]]; then
    # Interactive: multi-select
    while true; do
        read -rp "  Choice [1-4, comma-separated, default=1,2]: " input
        input="${input:-1,2}"
        TERMS_TO_INSTALL=()
        valid=1
        IFS=',' read -ra nums <<< "$input"
        for n in "${nums[@]}"; do
            n="${n// /}"
            case "$n" in
                1) TERMS_TO_INSTALL+=(tio) ;;
                2) TERMS_TO_INSTALL+=(screen) ;;
                3) TERMS_TO_INSTALL+=(minicom) ;;
                4) TERMS_TO_INSTALL+=(picocom) ;;
                *) echo "  Invalid choice: $n — enter numbers 1-4 separated by commas"; valid=0; break ;;
            esac
        done
        [[ $valid -eq 1 && ${#TERMS_TO_INSTALL[@]} -gt 0 ]] && break
    done
    # Deduplicate
    declare -a _dedup=()
    declare -A _seen=()
    for t in "${TERMS_TO_INSTALL[@]}"; do
        [[ -z "${_seen[$t]+x}" ]] && _dedup+=("$t") && _seen[$t]=1
    done
    TERMS_TO_INSTALL=("${_dedup[@]}")
else
    # Non-interactive with no --term: default to tio
    TERMS_TO_INSTALL=(tio)
fi

# The first entry is the default for serial-connect
TERM_CHOICE="${TERMS_TO_INSTALL[0]}"

echo ""
for t in "${TERMS_TO_INSTALL[@]}"; do
    if command -v "$t" &>/dev/null; then
        green "  ✓ $t already installed"
    else
        yellow "  $t not installed — installing..."
        try_install "${TERM_PKGS[$t]}" || true
    fi
done

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

TOOLS=(serial-common.sh serial-discover serial-connect serial-agent)
for tool in "${TOOLS[@]}"; do
    src="$SCRIPT_DIR/bin/$tool"
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

# ── Config file (lives alongside the scripts) ──────────────────────────────────
if [[ ! -f "$CONF_FILE" ]]; then
    cp "$SCRIPT_DIR/bin/serial-boards.conf" "$CONF_FILE"
    green "  ✓ serial-boards.conf  (created)"
else
    dim   "  · serial-boards.conf  (exists — not modified)"
fi

# ── Symlink CLI tools ──────────────────────────────────────────────────────────
mkdir -p "$LINK_DIR"
echo ""
bold "Linking into: $LINK_DIR"
echo ""
for tool in serial-discover serial-connect serial-agent; do
    ln -sf "$INSTALL_DIR/$tool" "$LINK_DIR/$tool"
    green "  ✓ $tool → $LINK_DIR/$tool"
done
if [[ ":$PATH:" != *":$LINK_DIR:"* ]]; then
    if (( GLOBAL )); then
        echo ""
        yellow "Note: $LINK_DIR is not yet in \$PATH for all users."
        yellow "      Add to /etc/environment or /etc/profile.d/serial-connect.sh"
    else
        LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""
        grep -qxF "$LINE" "$HOME/.bashrc" 2>/dev/null || echo "$LINE" >> "$HOME/.bashrc"
        green "  ✓ added $LINK_DIR to ~/.bashrc"
        dim   "    Run: source ~/.bashrc  (or open a new terminal)"
    fi
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
