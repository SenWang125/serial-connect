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
(( fails )) && { echo "RED: $fails selftest(s) failed"; exit 1; }
echo "GREEN: all selftests passed"
