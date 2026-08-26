#!/usr/bin/env bash
# Red/green selftest: serial-common.sh must not answer an unparseable baud with
# a valid one.
#
# parse_baud() used to return PROBE_BAUDS[0] for any text it could not parse.
# That made every "(( b > 0 ))" guard in the config reader unable to fail, and
# turned a typo in serial-boards.conf into a silent 115200 that is
# indistinguishable from a deliberate choice. The board this was found on runs
# its console at 1500000, so the whole boot log arrived as noise.
#
# Also covers the board-serial branch's "(( b > 9600 ))" floor, which silently
# dropped a legitimate 9600 pin.
#
# No hardware required. Exit 0 = GREEN.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SERIAL_COMMON_UNDER_TEST:-}"
[[ -n "$SRC" ]] || for c in "$HERE/serial-common.sh" "$HERE/../bin/serial-common.sh"; do
    [[ -f "$c" ]] && { SRC="$c"; break; }
done
[[ -f "$SRC" ]] || { echo "  no serial-common.sh to test"; exit 1; }

conf=$(mktemp); trap 'rm -f "$conf"' EXIT
cat > "$conf" <<'CONF'
PROBE_BAUDS=115200,1500000
0001=PinnedGarbage:1.5MB
0002=PinnedSlow:9600
0003=PinnedFast:1.5M
CONF

PROBE_BAUDS=(115200)
# shellcheck disable=SC1090
source "$SRC" 2>/dev/null || { echo "  cannot source $SRC"; exit 1; }

fails=0
ck() { if eval "$2"; then echo "  [ok]   $1"; else echo "  [FAIL] $1"; fails=$((fails+1)); fi; }

out=$(parse_baud "1.5MB" 2>/dev/null); rc=$?
ck "parse_baud rejects '1.5MB' with a non-zero status" "[ $rc -ne 0 ]"
ck "parse_baud prints nothing for '1.5MB'"             "[ -z \"$out\" ]"
out=$(parse_baud "" 2>/dev/null); rc=$?
ck "parse_baud rejects an empty string"                "[ $rc -ne 0 ]"

ck "parse_baud 1.5M   = 1500000" "[ \"\$(parse_baud 1.5M)\"   = 1500000 ]"
ck "parse_baud 115.2K = 115200"  "[ \"\$(parse_baud 115.2K)\" = 115200  ]"
ck "parse_baud 9600   = 9600"    "[ \"\$(parse_baud 9600)\"   = 9600    ]"

declare -A CFG_BAUD=() CFG_LABEL=() CHIP_BAUD=() CHIP_BAUD_WILDCARD=() \
           CHIP_NAMES=() CHIP_WILDCARD=()
_load_conf_file "$conf" 0 2>/dev/null
ck "a 9600 pin survives the config reader"   "[ \"\${CFG_BAUD[0002]:-unset}\" = 9600 ]"
ck "a 1.5M pin survives the config reader"   "[ \"\${CFG_BAUD[0003]:-unset}\" = 1500000 ]"
ck "an unparseable pin leaves CFG_BAUD unset" "[ \"\${CFG_BAUD[0001]:-unset}\" = unset ]"

msg=$(_load_conf_file "$conf" 0 2>&1 >/dev/null)
ck "the reader says which value it dropped"  "grep -q '1.5MB' <<< \"\$msg\""

echo "  $fails failure(s)"
[ $fails -eq 0 ]
