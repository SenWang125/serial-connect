#!/usr/bin/env bash
# Red/green selftest for the serial-connect <-> serial-agent conflict surface.
# No hardware, no board, no daemon required.  Exit 0 = GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_BIN="$HERE"; [[ -f "$HERE/serial-common.sh" ]] || SC_BIN="$HERE/../bin"
source "$SC_BIN/serial-common.sh" 2>/dev/null || true
fails=0
ok(){ printf '  PASS  %s\n' "$1"; }
no(){ printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }

echo "1. GAP marker must return the cursor to column 0 (raw-mode terminals)"
if grep -q "f'\\\\r\\\\n<<serial-agent GAP" "$SC_BIN/serial-agent"; then
    ok "marker emits CRLF"
else
    no "marker emits bare LF — renders indented in tio/raw mode"
fi

echo "2. _agent_is_alive must not report a recycled PID as a live daemon"
tdev="ttySELFTEST-conflict"
tdir="$HOME/var/serial-agent/$tdev"
mkdir -p "$tdir"
sleep 300 & victim=$!            # a live PID that is NOT a serial-agent
echo "$victim" > "$tdir/daemon.pid"
live=0; _agent_is_alive "$tdev" live
if (( live == 0 )); then ok "non-agent PID rejected"
else no "non-agent PID $victim reported as a live daemon"; fi
kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
rm -rf "$tdir"

echo "3. serial-connect must probe the relay before bridging, not trust status.json"
if grep -q '/dev/tcp/' "$SC_BIN/serial-connect"; then
    ok "relay reachability probed"
else
    no "no relay probe — socat can bridge tio onto a dead port"
fi

echo "4. diagnostic hints must name a tool that exists on this host"
if grep -q 'nc -z' "$SC_BIN/serial-connect"; then
    command -v nc >/dev/null && ok "nc hint valid (nc installed)" \
                             || no "hint says 'nc -z' but nc is not installed"
else
    ok "no unavailable-tool hint"
fi

echo
if (( fails )); then echo "RED  ($fails failing)"; exit 1; fi
echo "GREEN (4/4)"; exit 0
