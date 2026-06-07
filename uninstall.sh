#!/usr/bin/env bash
# uninstall.sh — Remove serial-connect tools
#
# Usage:
#   ./uninstall.sh           # removes ~/.serial-connect/ entirely (default)
#   sudo ./uninstall.sh --global  # removes global install from /usr/local/

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
else
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.serial-connect}"
    LINK_DIR="$HOME/.local/bin"
    CONF_FILE=""
fi
BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'

echo ""
printf "${BOLD}serial-connect uninstaller${NC}\n"
echo "=========================="
echo ""

if (( GLOBAL )); then
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" && printf "  ${GREEN}✓${NC} removed %s\n" "$INSTALL_DIR"
    [[ -n "$CONF_FILE" && -f "$CONF_FILE" ]] && rm -f "$CONF_FILE" && printf "  ${GREEN}✓${NC} removed %s\n" "$CONF_FILE"
elif [[ "$INSTALL_DIR" == "$HOME/.serial-connect" && -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    printf "  ${GREEN}✓${NC} removed %s\n" "$INSTALL_DIR"
else
    for f in serial-common.sh serial-discover serial-connect serial-agent serial-boards.conf; do
        fp="$INSTALL_DIR/$f"
        [[ -f "$fp" ]] && rm -f "$fp" && printf "  ${GREEN}✓${NC} removed %s\n" "$fp"
    done
fi

# Remove symlinks
for tool in serial-discover serial-connect serial-agent; do
    link="$LINK_DIR/$tool"
    [[ -L "$link" ]] && rm -f "$link" && printf "  ${GREEN}✓${NC} removed symlink %s\n" "$link"
done

echo ""
printf "${BOLD}Done.${NC}\n"
echo ""
