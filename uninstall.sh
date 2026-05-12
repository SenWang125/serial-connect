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
    rm -rf "$INSTALL_DIR"
    printf "  ${GREEN}✓${NC} removed %s\n" "$INSTALL_DIR"
else
    for f in serial-common.sh serial-discover serial-connect serial-agent serial-boards.conf; do
        fp="$INSTALL_DIR/$f"
        [[ -f "$fp" ]] && rm -f "$fp" && printf "  ${GREEN}✓${NC} removed %s\n" "$fp"
    done
fi

# Remove symlinks from ~/.local/bin
for tool in serial-discover serial-connect serial-agent; do
    link="$HOME/.local/bin/$tool"
    [[ -L "$link" ]] && rm -f "$link" && printf "  ${GREEN}✓${NC} removed symlink %s\n" "$link"
done

echo ""
printf "${BOLD}Done.${NC}\n"
echo ""
