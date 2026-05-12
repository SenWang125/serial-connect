#!/bin/bash
# tio.sh — Serial console using tio in a named tmux session
# Usage: tio.sh <ttyUSBn | /dev/ttyXXX> [baud]
# Examples:
#   tio.sh 1              → /dev/ttyUSB1 @ 115200 (baud from serial-boards.conf if set)
#   tio.sh /dev/ttyUSB1
#   tio.sh 1 1500000

BOARD_CFG="${HOME}/.config/serial-boards.conf"

# ── Resolve device and baud ────────────────────────────────────────────────────
if [[ "$1" =~ ^[0-9]+$ ]]; then
    device="/dev/ttyUSB${1}"
elif [[ -n "$1" ]]; then
    device="$1"
else
    echo "Usage: tio.sh <ttyUSBn | /dev/ttyXXX> [baud]" >&2
    exit 1
fi

[[ ! -c "$device" ]] && { echo "Not a device: $device" >&2; exit 1; }

# Look up baud from serial-boards.conf (SERIAL=LABEL[:BAUD] keyed by USB serial)
baud="${2:-115200}"
if [[ -z "$2" && -f "$BOARD_CFG" ]]; then
    udev_ser=$(udevadm info -a "$device" 2>/dev/null \
        | awk -F'"' '/ATTRS\{serial\}/{print $2; exit}')
    if [[ -n "$udev_ser" ]]; then
        cfg_val=$(grep "^${udev_ser}=" "$BOARD_CFG" 2>/dev/null | head -1 | cut -d= -f2-)
        extra="${cfg_val##*:}"
        if [[ "$cfg_val" == *:* && "$extra" =~ ^[0-9]+$ && "$extra" -gt 9600 ]]; then
            baud="$extra"
        fi
    fi
fi

# ── Session name and socket path ───────────────────────────────────────────────
devname=$(basename "$device")
session="$devname"
socket="/tmp/${devname}.sock"

# ── Clear HUPCL to prevent board SIGHUP when tio closes the fd ────────────────
stty -F "$device" -hupcl 2>/dev/null

# ── Attach or create tmux session ─────────────────────────────────────────────
if tmux has-session -t "$session" 2>/dev/null; then
    echo "Resuming tmux session '$session'"
    echo "  Share (2nd window):    tmux attach-session -t $session"
    echo "  Agent/script access:   socat - UNIX-CONNECT:$socket"
    tmux attach-session -t "$session"
else
    echo "Creating new tmux session '$session' for $device @ ${baud}"
    echo "  Detach:  Ctrl-B D"
    echo "  Quit:    Ctrl-T Q  (inside tio)"
    echo "  Share:   tmux attach-session -t $session  (from another terminal)"
    echo "  Agent:   socat - UNIX-CONNECT:$socket"
    tmux new-session -d -s "$session"
    tmux send-keys -t "$session" \
        "tio -b $baud -S 'unix:$socket' '$device'" C-m
    tmux attach-session -t "$session"
fi
