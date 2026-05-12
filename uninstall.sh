#!/usr/bin/env bash
# uninstall.sh — Remove serial-connect tools
#
# Usage:
#   ./uninstall.sh                 # removes ~/.serial-connect/ entirely (default)
#   ./uninstall.sh /usr/local/bin  # custom install directory — removes files only

set -euo pipefail

INSTALL_DIR="${1:-$HOME/.serial-connect}"
BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'

echo ""
printf "${BOLD}serial-connect uninstaller${NC}\n"
echo "=========================="
echo ""

if [[ "$INSTALL_DIR" == "$HOME/.serial-connect" && -d "$INSTALL_DIR" ]]; then
    # Default install: remove the whole directory (scripts + conf in one place)
    rm -rf "$INSTALL_DIR"
    printf "  ${GREEN}✓${NC} removed %s\n" "$INSTALL_DIR"
else
    # Custom install dir: remove known files individually
    for f in serial-common.sh serial-discover serial-connect serial-agent serial-boards.conf; do
        fp="$INSTALL_DIR/$f"
        if [[ -f "$fp" ]]; then
            rm -f "$fp"
            printf "  ${GREEN}✓${NC} removed %s\n" "$fp"
        else
            printf "  ${YELLOW}·${NC} not found: %s\n" "$fp"
        fi
    done
fi

echo ""
printf "${BOLD}Done.${NC}\n"
echo ""
