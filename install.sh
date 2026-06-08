#!/usr/bin/env bash
# install.sh — Install serial-connect tools
#
# Usage:
#   ./install.sh                    # interactive
#   ./install.sh --local            # current user only (default)
#   sudo ./install.sh --global      # all users (/usr/local/bin)
#   ./install.sh --term tio         # set default terminal non-interactively
#   ./install.sh --upgrade          # re-install without prompts (keeps existing choices)

set -euo pipefail

INSTALL_DIR=""
TERM_CHOICE=""
GLOBAL=0
SCOPE_SET=0
UPGRADE=0

# ── Parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --global)  GLOBAL=1; SCOPE_SET=1; shift ;;
        --local)   GLOBAL=0; SCOPE_SET=1; shift ;;
        --upgrade) UPGRADE=1; SCOPE_SET=1; shift ;;
        --term)    TERM_CHOICE="$2"; shift 2 ;;
        --term=*)  TERM_CHOICE="${1#--term=}"; shift ;;
        --help|-h)
            echo "Usage: ./install.sh [--local|--global|--upgrade] [--term tio|screen|minicom|picocom]"
            exit 0 ;;
        *)         INSTALL_DIR="$1"; shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ─────────────────────────────────────────────────────────────
bold()   { printf '\033[1m%s\033[0m\n'  "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n'  "$*"; }

echo ""
bold "serial-connect installer"
echo "========================"
echo ""

# ── Upgrade: detect existing install and re-use its scope ─────────────────────
if (( UPGRADE )); then
    if [[ -d /usr/local/share/serial-connect ]]; then
        GLOBAL=1
    else
        GLOBAL=0
    fi
fi

# ── Scope prompt ───────────────────────────────────────────────────────────────
if [[ -t 0 && $SCOPE_SET -eq 0 ]]; then
    bold "Install scope"
    echo ""
    echo "  1) Current user only  (~/.local/bin, no sudo needed)  [default]"
    echo "  2) All users          (/usr/local/bin, requires sudo)"
    echo ""
    read -rp "  Choice [1/2]: " _scope || _scope="1"
    [[ "${_scope:-1}" == "2" ]] && GLOBAL=1
fi

if (( GLOBAL )); then
    (( EUID == 0 )) || { red "Global install requires sudo. Re-run: sudo ./install.sh --global"; exit 1; }
    INSTALL_DIR="${INSTALL_DIR:-/usr/local/share/serial-connect}"
    LINK_DIR="/usr/local/bin"
    CONF_FILE="/etc/serial-boards.conf"
else
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.serial-connect}"
    LINK_DIR="$HOME/.local/bin"
    CONF_FILE="${INSTALL_DIR}/serial-boards.conf"
fi

# ── Sudo availability ──────────────────────────────────────────────────────────
HAS_SUDO=0
if (( EUID == 0 )); then
    HAS_SUDO=1
elif sudo -n true 2>/dev/null; then
    HAS_SUDO=1
fi

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
    if eval "$cmd" &>/dev/null; then
        green "  ✓ installed $pkg"; return 0
    else
        return 1
    fi
}

# ── Conflict detection ─────────────────────────────────────────────────────────
echo ""
bold "Checking for existing installations..."
echo ""

_found_conflict=0
while IFS= read -r _existing; do
    [[ -z "$_existing" ]] && continue
    _existing_dir="$(dirname "$_existing")"
    # Skip if it points to our own install target
    [[ "$_existing_dir" == "$LINK_DIR" ]] && continue
    [[ "$(readlink -f "$_existing" 2>/dev/null)" == "$INSTALL_DIR/"* ]] && continue
    yellow "  ⚠ Found existing installation: $_existing"
    _found_conflict=1
done < <(for _t in serial-connect serial-discover serial-agent; do command -v "$_t" 2>/dev/null || true; done | sort -u)

if (( _found_conflict )); then
    echo ""
    if [[ -t 0 && $UPGRADE -eq 0 ]]; then
        read -rp "  Remove conflicting installations? [Y/n]: " _rm || _rm="y"
        if [[ "${_rm,,}" != "n" ]]; then
            for _tool in serial-connect serial-discover serial-agent; do
                _ep=$(command -v "$_tool" 2>/dev/null || true)
                [[ -z "$_ep" ]] && continue
                [[ "$(dirname "$_ep")" == "$LINK_DIR" ]] && continue
                rm -f "$_ep" && dim "  · removed $_ep"
            done
            hash -r 2>/dev/null || true
        fi
    else
        dim "  · skipping removal (non-interactive or --upgrade)"
    fi
fi

# ── Required dependencies ──────────────────────────────────────────────────────
echo ""
bold "Checking required dependencies..."
echo ""

ABORT=0

if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
    yellow "  ⚠ bash ${BASH_VERSION} — bash ≥ 5.1 recommended"
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
    dim    "    $(pkg_install_cmd psmisc)"
fi

if [[ $ABORT -ne 0 ]]; then
    echo ""; red "Required dependencies missing — install them and re-run."; exit 1
fi

# ── Serial port access (udev rules) ───────────────────────────────────────────
echo ""
bold "Serial port access"
echo ""

UDEV_DEST="/etc/udev/rules.d/99-serial-connect.rules"
UDEV_SRC="$SCRIPT_DIR/udev/99-serial-connect.rules"

if [[ -f "$UDEV_DEST" ]]; then
    green "  ✓ udev rules already installed"
elif [[ ! -f "$UDEV_SRC" ]]; then
    yellow "  ⚠ udev rules source not found — skipping"
elif (( HAS_SUDO )); then
    if sudo cp "$UDEV_SRC" "$UDEV_DEST" \
        && sudo udevadm control --reload-rules \
        && sudo udevadm trigger 2>/dev/null; then
        green "  ✓ udev rules installed — all users can access serial ports, no re-login needed"
    else
        yellow "  ⚠ udev rules install failed"
        dim    "    Run manually: sudo cp $UDEV_SRC $UDEV_DEST"
        dim    "                  sudo udevadm control --reload-rules"
    fi
else
    yellow "  ⚠ no sudo access — ask an admin to run:"
    dim    "    sudo cp $UDEV_SRC $UDEV_DEST"
    dim    "    sudo udevadm control --reload-rules && sudo udevadm trigger"
fi

# ── Terminal emulator selection ────────────────────────────────────────────────
echo ""
bold "Terminal emulators"
echo ""

# Detect current default from existing conf
_current_term="tio"
if [[ -f "$CONF_FILE" ]]; then
    _ct=$(grep '^SERIAL_TERM=' "$CONF_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ' || true)
    if [[ "$_ct" =~ ^(tio|screen|minicom|picocom)$ ]]; then _current_term="$_ct"; fi
fi

if (( !UPGRADE )); then
echo "  Select which terminals to install (comma-separated, e.g. 1,2)."
echo "  The first choice becomes the default for serial-connect."
echo "  tio + screen is recommended: tio for daily use, screen for sharing."
echo ""
echo "    1) tio      Modern, auto-reconnects on reset              (recommended)"
echo "    2) screen   Shareable sessions: screen -x ttyUSBx          (recommended)"
echo "    3) minicom  Classic serial terminal"
echo "    4) picocom  Minimal, lightweight"
echo ""
fi  # end !UPGRADE display block

declare -A TERM_PKGS=([tio]=tio [screen]=screen [minicom]=minicom [picocom]=picocom)
declare -a TERMS_TO_INSTALL=()
declare -a MISSING_PKGS=()

if [[ -n "$TERM_CHOICE" ]]; then
    IFS=',' read -ra _choices <<< "$TERM_CHOICE"
    for c in "${_choices[@]}"; do
        c="${c// /}"
        [[ -z "${TERM_PKGS[$c]+x}" ]] && { red "Unknown terminal: $c. Valid: tio screen minicom picocom"; exit 1; }
        TERMS_TO_INSTALL+=("$c")
    done
elif (( UPGRADE )); then
    TERMS_TO_INSTALL=("$_current_term")
elif [[ -t 0 ]]; then
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
    declare -a _dedup=(); declare -A _seen=()
    for t in "${TERMS_TO_INSTALL[@]}"; do
        [[ -z "${_seen[$t]+x}" ]] && _dedup+=("$t") && _seen[$t]=1
    done
    TERMS_TO_INSTALL=("${_dedup[@]}")
else
    TERMS_TO_INSTALL=(tio)
fi

TERM_CHOICE="${TERMS_TO_INSTALL[0]}"

echo ""
for t in "${TERMS_TO_INSTALL[@]}"; do
    if command -v "$t" &>/dev/null; then
        green "  ✓ $t already installed"
    elif (( HAS_SUDO )); then
        yellow "  $t not installed — installing..."
        try_install "${TERM_PKGS[$t]}" || {
            yellow "  ⚠ could not install $t"
            MISSING_PKGS+=("${TERM_PKGS[$t]}")
        }
    else
        dim "  $t not installed (no sudo — install later: $(pkg_install_cmd "${TERM_PKGS[$t]}"))"
        MISSING_PKGS+=("${TERM_PKGS[$t]}")
    fi
done

# ── Optional dependencies ──────────────────────────────────────────────────────
echo ""
bold "Optional dependencies"
echo ""

check_optional() {
    local cmd="$1" pkg="$2" desc="$3"
    if command -v "$cmd" &>/dev/null; then
        green "  ✓ $cmd — $desc"
    elif (( HAS_SUDO )); then
        yellow "  $cmd not installed — installing..."
        try_install "$pkg" || {
            dim "  Install later: $(pkg_install_cmd "$pkg")"
            MISSING_PKGS+=("$pkg")
        }
    else
        dim "  $cmd not installed — install later: $(pkg_install_cmd "$pkg")"
        MISSING_PKGS+=("$pkg")
    fi
}

check_optional inotifywait inotify-tools \
    "instant event notifications — faster wait-state in serial-agent"

check_optional ser2net ser2net \
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

# System conf: created once; never overwritten to preserve user edits
if [[ ! -f "$CONF_FILE" ]]; then
    cp "$SCRIPT_DIR/bin/serial-boards.conf" "$CONF_FILE"
    green "  ✓ serial-boards.conf  (created at $CONF_FILE)"
else
    dim   "  · serial-boards.conf  (exists — not modified)"
fi

# Write terminal preference to conf
if grep -q "^SERIAL_TERM=" "$CONF_FILE" 2>/dev/null; then
    sed -i "s|^SERIAL_TERM=.*|SERIAL_TERM=${TERM_CHOICE}|" "$CONF_FILE"
elif [[ -f "$CONF_FILE" ]]; then
    printf '\nSERIAL_TERM=%s\n' "$TERM_CHOICE" >> "$CONF_FILE"
fi
dim "  · default terminal: $TERM_CHOICE"

# ── Symlink CLI tools ──────────────────────────────────────────────────────────
mkdir -p "$LINK_DIR"
echo ""
bold "Linking into: $LINK_DIR"
echo ""
for tool in serial-discover serial-connect serial-agent; do
    ln -sf "$INSTALL_DIR/$tool" "$LINK_DIR/$tool"
    green "  ✓ $tool → $LINK_DIR/$tool"
done

# Add to PATH if needed (bash + zsh)
if [[ ":$PATH:" != *":$LINK_DIR:"* ]]; then
    if (( GLOBAL )); then
        if [[ ! -f /etc/profile.d/serial-connect.sh ]]; then
            printf 'export PATH="%s:$PATH"\n' "$LINK_DIR" > /etc/profile.d/serial-connect.sh
            green "  ✓ added $LINK_DIR to /etc/profile.d/serial-connect.sh (all users)"
        fi
    else
        LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""
        for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
            [[ -f "$_rc" ]] || continue
            grep -qxF "$LINE" "$_rc" 2>/dev/null || echo "$LINE" >> "$_rc"
        done
        # Create ~/.zshrc stub if zsh is the user's shell and no rc exists
        if [[ "$SHELL" == */zsh && ! -f "$HOME/.zshrc" ]]; then
            echo "$LINE" > "$HOME/.zshrc"
        fi
        green "  ✓ added $LINK_DIR to shell rc"
        dim   "    Run: source ~/.bashrc  or open a new terminal"
    fi
fi

# ── Restart running serial-agent daemons ──────────────────────────────────────
_agent_bin="$INSTALL_DIR/serial-agent"
if [[ -x "$_agent_bin" ]]; then
    _running=$(python3 -c "
import os, pathlib
base = pathlib.Path.home() / 'var' / 'serial-agent'
if base.exists():
    for d in sorted(base.iterdir()):
        pf = d / 'daemon.pid'
        if pf.exists():
            try:
                pid = int(pf.read_text().strip())
                os.kill(pid, 0)
                print(d.name)
            except: pass
" 2>/dev/null || true)
    if [[ -n "$_running" ]]; then
        echo ""
        bold "Restarting running daemons to pick up new code..."
        echo ""
        while IFS= read -r _dev; do
            if "$_agent_bin" stop "/dev/$_dev" &>/dev/null \
               && "$_agent_bin" start "/dev/$_dev" &>/dev/null; then
                green "  ✓ restarted /dev/$_dev"
            else
                yellow "  ⚠ could not restart /dev/$_dev — restart manually: serial-agent stop/start /dev/$_dev"
            fi
        done <<< "$_running"
    fi
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
bold "Done. Quick start:"
echo ""
dim  "  serial-discover                 # probe all connected boards"
dim  "  serial-connect                  # pick a board and connect"
dim  "  serial-connect /dev/ttyUSB1     # connect directly"
dim  "  serial-agent auto-label -y      # name boards by USB serial#"
dim  "  serial-agent --help             # full automation CLI"

if (( ${#MISSING_PKGS[@]} > 0 )); then
    echo ""
    yellow "  Optional packages not installed (no sudo access):"
    for pkg in "${MISSING_PKGS[@]}"; do
        dim "    $(pkg_install_cmd "$pkg")"
    done
fi
echo ""
