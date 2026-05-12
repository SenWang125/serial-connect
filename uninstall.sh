#!/usr/bin/env bash
# uninstall.sh — Remove serial-connect tools
#
# Usage:
#   ./uninstall.sh                 # removes from ~/.serial-connect (default)
#   ./uninstall.sh /usr/local/bin  # custom install directory
#   ./uninstall.sh --purge         # also remove ~/.config/serial-boards.conf

set -euo pipefail

INSTALL_DIR="${1:-$HOME/.serial-connect}"
PURGE=0
for arg in "$@"; do
    [[ "$arg" == "--purge" ]] && PURGE=1
done

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'

echo ""
printf "${BOLD}serial-connect uninstaller${NC}\n"
echo "=========================="
echo ""

TOOLS=(serial-discover serial-connect serial-agent)
# If install dir is the default named directory, remove it wholesale
if [[ "$INSTALL_DIR" == "$HOME/.serial-connect" && -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    printf "  ${GREEN}✓${NC} removed directory %s\n" "$INSTALL_DIR"
else
    for tool in "${TOOLS[@]}"; do
        f="$INSTALL_DIR/$tool"
        if [[ -f "$f" ]]; then
            rm -f "$f"
            printf "  ${GREEN}✓${NC} removed %s\n" "$f"
        else
            printf "  ${YELLOW}·${NC} not found: %s\n" "$f"
        fi
    done
fi

if (( PURGE )); then
    conf="${HOME}/.config/serial-boards.conf"
    if [[ -f "$conf" ]]; then
        rm -f "$conf"
        printf "  ${GREEN}✓${NC} removed %s\n" "$conf"
    fi
fi

echo ""
printf "${BOLD}Done.${NC}\n"
if (( !PURGE )); then
    printf "  ${YELLOW}Note:${NC} ~/.config/serial-boards.conf kept. Re-run with --purge to remove it.\n"
fi
echo ""
