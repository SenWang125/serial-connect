#!/usr/bin/env bash
# Run every no-hardware selftest. Exit 0 = all GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
for t in "$HERE"/selftest_*.py "$HERE"/selftest_*.sh; do
    [[ -e "$t" ]] || continue
    echo "── $(basename "$t")"
    case "$t" in *.py) python3 "$t" ;; *) bash "$t" ;; esac
    rc=$?
    (( rc == 0 )) || { echo "  ^ RED (exit $rc)"; fails=$((fails+1)); }
done
# The built-in gate is the other half: 57 assertions on a virtual pty pair.
# One command must run both, or one of them stops being run.
AGENT="$HERE/serial-agent"; [[ -x "$AGENT" ]] || AGENT="$HERE/../bin/serial-agent"
echo "── serial-agent test (built-in, 57 assertions)"
_gate_out=$(timeout 120 "$AGENT" test 2>&1); _gate_rc=$?   # rc of the gate, not of a pipe
echo "$_gate_out" | tail -1
(( _gate_rc == 0 )) || { echo "  ^ RED (exit $_gate_rc)"; fails=$((fails+1)); }

(( fails )) && { echo "RED: $fails gate(s) failed"; exit 1; }
echo "GREEN: all gates passed"
