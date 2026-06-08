#!/usr/bin/env bash
# uninstall.sh — Remove serial-connect tools
#
# Usage:
#   ./uninstall.sh                   # removes local install (~/.serial-connect/)
#   sudo ./uninstall.sh --global     # removes global install from /usr/local/

set -euo pipefail

GLOBAL=0
INSTALL_DIR=""
for arg in "$@"; do
    case "$arg" in
        --global) GLOBAL=1 ;;
        *)        INSTALL_DIR="$arg" ;;
    esac
done

if (( GLOBAL )); then
    (( EUID == 0 )) || { echo "Global uninstall requires sudo."; exit 1; }
    INSTALL_DIR="${INSTALL_DIR:-/usr/local/share/serial-connect}"
    LINK_DIR="/usr/local/bin"
    CONF_FILE="/etc/serial-boards.conf"
    UDEV_FILE="/etc/udev/rules.d/99-serial-connect.rules"
else
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.serial-connect}"
    LINK_DIR="$HOME/.local/bin"
    CONF_FILE=""
    UDEV_FILE="/etc/udev/rules.d/99-serial-connect.rules"
fi
BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'

echo ""
printf "${BOLD}serial-connect uninstaller${NC}\n"
echo "=========================="
echo ""

# ── Stop running daemons first ─────────────────────────────────────────────────
_agent="${LINK_DIR}/serial-agent"
[[ ! -x "$_agent" ]] && _agent="${INSTALL_DIR}/serial-agent"
if [[ -x "$_agent" ]]; then
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
" 2>/dev/null)
    if [[ -n "$_running" ]]; then
        while IFS= read -r _dev; do
            "$_agent" stop "/dev/$_dev" &>/dev/null || true
            printf "  ${GREEN}✓${NC} stopped daemon /dev/%s\n" "$_dev"
        done <<< "$_running"
    fi
fi

# ── Remove install dir ─────────────────────────────────────────────────────────
if (( GLOBAL )); then
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" && printf "  ${GREEN}✓${NC} removed %s\n" "$INSTALL_DIR"
    [[ -n "$CONF_FILE" && -f "$CONF_FILE" ]] && rm -f "$CONF_FILE" && printf "  ${GREEN}✓${NC} removed %s\n" "$CONF_FILE"
    [[ -f /etc/profile.d/serial-connect.sh ]] && rm -f /etc/profile.d/serial-connect.sh \
        && printf "  ${GREEN}✓${NC} removed /etc/profile.d/serial-connect.sh\n"
elif [[ "$INSTALL_DIR" == "$HOME/.serial-connect" && -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    printf "  ${GREEN}✓${NC} removed %s\n" "$INSTALL_DIR"
else
    for f in serial-common.sh serial-discover serial-connect serial-agent serial-boards.conf; do
        fp="$INSTALL_DIR/$f"
        [[ -f "$fp" ]] && rm -f "$fp" && printf "  ${GREEN}✓${NC} removed %s\n" "$fp"
    done
fi

# ── Remove udev rules ──────────────────────────────────────────────────────────
if [[ -f "$UDEV_FILE" ]]; then
    if (( EUID == 0 )); then
        rm -f "$UDEV_FILE"
        udevadm control --reload-rules 2>/dev/null || true
        printf "  ${GREEN}✓${NC} removed udev rules\n"
    elif sudo rm -f "$UDEV_FILE" && sudo udevadm control --reload-rules 2>/dev/null; then
        printf "  ${GREEN}✓${NC} removed udev rules\n"
    else
        printf "  ${YELLOW}⚠${NC} could not remove %s — run: sudo rm %s\n" "$UDEV_FILE" "$UDEV_FILE"
    fi
fi

# ── Remove symlinks ────────────────────────────────────────────────────────────
for tool in serial-discover serial-connect serial-agent; do
    link="$LINK_DIR/$tool"
    [[ -L "$link" ]] && rm -f "$link" && printf "  ${GREEN}✓${NC} removed symlink %s\n" "$link"
done

# ── Clean PATH from shell rc files ────────────────────────────────────────────
if (( !GLOBAL )); then
    LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""
    for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [[ -f "$_rc" ]] || continue
        if grep -qxF "$LINE" "$_rc" 2>/dev/null; then
            grep -vxF "$LINE" "$_rc" > "$_rc.tmp" && mv "$_rc.tmp" "$_rc"
            printf "  ${GREEN}✓${NC} removed PATH entry from %s\n" "$_rc"
        fi
    done
fi

echo ""
printf "${BOLD}Done.${NC}\n"
echo ""
