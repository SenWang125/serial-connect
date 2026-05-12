#!/bin/bash
# serial-common.sh — shared functions and defaults for serial-connect tools
# Sourced by serial-discover and serial-connect. Not executed directly.

# ── Colours ────────────────────────────────────────────────────────────────────
BOLD=$'\033[1m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'
DIM=$'\033[2m'; RED=$'\033[31m'; NC=$'\033[0m'

# ── Config path ────────────────────────────────────────────────────────────────
# Defaults to serial-boards.conf in the same directory as the sourcing script.
# Override at runtime: BOARD_CFG=/path/to/serial-boards.conf serial-connect
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_CFG="${BOARD_CFG:-$_COMMON_DIR/serial-boards.conf}"

# Chip tables and probe defaults are defined in serial-boards.conf.
declare -A CHIP_NAMES=() CHIP_BAUD=() CFG_LABEL CFG_BAUD
declare -a PROBE_BAUDS=()
PROBE_PARALLEL=0 PROBE_READ_MS=100 PROBE_DRAIN_MS=10

# ── parse_baud ─────────────────────────────────────────────────────────────────
# Convert human-readable baud string to integer: 1.5M→1500000, 115.2K→115200
parse_baud() {
    local s="${1^^}"; s="${s//[[:space:]]/}"
    local int frac flen fi
    if [[ "$s" =~ ^([0-9]+)(\.([0-9]*))?M$ ]]; then
        int="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]:-0}"
        flen=${#frac}; fi=0
        (( flen > 0 )) && fi=$(( frac * 1000000 / (10 ** flen) ))
        echo $(( int * 1000000 + fi ))
    elif [[ "$s" =~ ^([0-9]+)(\.([0-9]*))?K$ ]]; then
        int="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]:-0}"
        flen=${#frac}; fi=0
        (( flen > 0 )) && fi=$(( frac * 1000 / (10 ** flen) ))
        echo $(( int * 1000 + fi ))
    elif [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"
    else echo "115200"
    fi
}

# ── baud_display ───────────────────────────────────────────────────────────────
# Format integer baud as human-readable: 1500000→1.5M, 115200→115.2K, 9600→9600
baud_display() {
    local b="$1" int frac
    if (( b >= 1000000 )); then
        int=$(( b / 1000000 )); frac=$(( (b % 1000000) / 100000 ))
        [[ $frac -gt 0 ]] && echo "${int}.${frac}M" || echo "${int}M"
    elif (( b >= 10000 && b % 100 == 0 )); then
        int=$(( b / 1000 )); frac=$(( (b % 1000) / 100 ))
        [[ $frac -gt 0 ]] && echo "${int}.${frac}K" || echo "${int}K"
    else
        echo "$b"
    fi
}

# ── load_config ────────────────────────────────────────────────────────────────
# Reads BOARD_CFG and populates:
#   CFG_LABEL[serial]  — board label from SERIAL=LABEL
#   CFG_BAUD[serial]   — per-board baud from SERIAL=LABEL:BAUD
#   CHIP_NAMES[vid:pid] — chip name from VID:PID=NAME
#   CHIP_BAUD[vid:pid]  — chip default baud from VID:PID=NAME:BAUD
#   PROBE_BAUDS, PROBE_PARALLEL, PROBE_READ_MS, PROBE_DRAIN_MS — tuning
load_config() {
    [[ -f "$BOARD_CFG" ]] || return
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# || -z "${key// /}" ]] && continue
        key="${key// /}"; val="${val%%#*}"; val="${val// /}"
        # Probe tuning scalars
        if [[ "$key" =~ ^PROBE_(PARALLEL|READ_MS|DRAIN_MS)$ ]]; then
            [[ "$val" =~ ^[0-9]+$ ]] && printf -v "$key" '%s' "$val"
            continue
        fi
        # Probe baud list
        if [[ "$key" == "PROBE_BAUDS" ]]; then
            PROBE_BAUDS=()
            local _b _braw
            IFS=',' read -ra _blist <<< "$val"
            for _b in "${_blist[@]}"; do
                _b="${_b// /}"
                _braw=$(parse_baud "$_b")
                (( _braw > 0 )) && PROBE_BAUDS+=("$_braw")
            done
            continue
        fi
        # Chip table entry: VID:PID=NAME or VID:PID=NAME:BAUD
        if [[ "$key" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
            local chip_name="${val%%:*}"
            [[ -n "$chip_name" ]] && CHIP_NAMES["$key"]="$chip_name"
            if [[ "$val" == *:* ]]; then
                local cb; cb=$(parse_baud "${val##*:}")
                (( cb > 0 )) && CHIP_BAUD["$key"]="$cb"
            fi
            continue
        fi
        # Board serial→label (and optional baud)
        local label="${val%%:*}" extra="${val##*:}"
        CFG_LABEL["$key"]="$label"
        if [[ "$val" == *:* && -n "$extra" ]]; then
            local b; b=$(parse_baud "$extra")
            (( b > 9600 )) && CFG_BAUD["$key"]="$b"
        fi
    done < "$BOARD_CFG"
}

# ── get_baud ───────────────────────────────────────────────────────────────────
# Resolve baud for a device: per-board override > chip default > 115200
get_baud() { echo "${CFG_BAUD[$2]:-${CHIP_BAUD[$1]:-115200}}"; }

# ── probe_tty ──────────────────────────────────────────────────────────────────
# Probe a single tty: send CR, try each baud in PROBE_BAUDS order, detect live.
# Output: STATUS|BAUD|board_id  (STATUS: LIVE OPEN DEAD FAIL)
probe_tty() {
    local dev="$1" cfg_baud="${2:-115200}"

    { fuser "$dev" &>/dev/null 2>&1 || sudo -n fuser "$dev" &>/dev/null 2>&1; } \
        && { printf 'OPEN|%s|\n' "$cfg_baud"; return; }

    # ttyACM: baud switch triggers USB CDC_SET_LINE_CODING, blocks ~12s — skip
    [[ "$dev" =~ /dev/ttyACM ]] && { printf 'DEAD|%s|\n' "$cfg_baud"; return; }

    local fd
    exec {fd}<>"$dev" 2>/dev/null || { printf 'FAIL|%s|\n' "$cfg_baud"; return; }
    local saved; saved=$(stty -F "$dev" -g 2>/dev/null)

    # Build ordered baud list: per-board cfg_baud first (if not already first),
    # then PROBE_BAUDS in order (deduped).
    local -a try_bauds=()
    [[ "$cfg_baud" != "${PROBE_BAUDS[0]}" ]] && try_bauds+=("$cfg_baud")
    local b
    for b in "${PROBE_BAUDS[@]}"; do
        local dup=0
        for already in "${try_bauds[@]}"; do [[ "$b" == "$already" ]] && dup=1 && break; done
        (( dup )) || try_bauds+=("$b")
    done

    local read_t drain_t
    read_t="$(( PROBE_READ_MS  / 1000 )).$(printf '%03d' $(( PROBE_READ_MS  % 1000 )))"
    drain_t="$(( PROBE_DRAIN_MS / 1000 )).$(printf '%03d' $(( PROBE_DRAIN_MS % 1000 )))"

    local detected="" captured=""
    for baud in "${try_bauds[@]}"; do
        stty -F "$dev" "$baud" raw -echo min 0 time 1 2>/dev/null
        # Drain bytes buffered at prior baud before reading — prevents false positives
        # where a 115200 response sitting in the tty buffer appears valid at 1500000.
        IFS= read -t "$drain_t" -r -d '' -n 1024 -u $fd _drain 2>/dev/null || true
        printf '\r' >&$fd
        local raw=""
        IFS= read -t "$read_t" -r -d '' -n 200 -u $fd raw 2>/dev/null
        local clean; clean=$(printf '%s' "$raw" \
            | tr -dc '[:print:][:space:]' | tr -s '[:space:]' ' ' \
            | sed 's/^ //; s/ $//')
        local raw_len="${#raw}" clean_len="${#clean}"
        # Correct baud → ≥95% printable; wrong baud → ~30% by chance. Require ≥80%.
        if (( clean_len >= 4 && raw_len > 0 && clean_len * 100 >= raw_len * 80 )); then
            detected="$baud"; captured="$clean"; break
        fi
    done

    [[ -n "$saved" ]] && stty -F "$dev" "$saved" 2>/dev/null
    stty -F "$dev" -hupcl 2>/dev/null   # prevent DTR deassert → board SIGHUP
    exec {fd}>&-

    [[ -z "$detected" ]] && { printf 'DEAD|%s|\n' "$cfg_baud"; return; }

    local id=""
    if   [[ "$captured" =~ @([A-Za-z0-9._-]+)[[:space:]]*: ]];       then id="${BASH_REMATCH[1]}"
    elif [[ "$captured" =~ ([A-Za-z0-9._-]+)[[:space:]]+login: ]];    then id="${BASH_REMATCH[1]}"
    elif [[ "$captured" =~ [Bb]oard:[[:space:]]*([A-Za-z0-9._-]+) ]]; then id="${BASH_REMATCH[1]}"
    else id="${captured:0:30}"
    fi
    printf 'LIVE|%s|%s\n' "$detected" "$id"
}

# ── run_probes ─────────────────────────────────────────────────────────────────
# Launch probe_tty for each device index, respecting PROBE_PARALLEL.
# Results written to $PROBE_DIR/<devname>. Watchdog timeout scales with settings.
run_probes() {
    local -a idxs=("$@")
    local -a pids=()
    local active=0 i
    for i in "${idxs[@]}"; do
        if (( PROBE_PARALLEL > 0 && active >= PROBE_PARALLEL )); then
            wait -n 2>/dev/null; (( active-- )) || true
        fi
        ( probe_tty "${DEVS[$i]}" "${BAUDS[$i]}" \
            > "$PROBE_DIR/$(basename "${DEVS[$i]}")" ) &
        pids+=($!); (( active++ )) || true
    done
    local wdog_s=$(( (${#PROBE_BAUDS[@]} * (PROBE_READ_MS + PROBE_DRAIN_MS) + 999) / 1000 + 1 ))
    ( sleep "$wdog_s"; kill -9 "${pids[@]}" 2>/dev/null ) &
    local wdog=$!
    wait "${pids[@]}" 2>/dev/null
    kill -9 "$wdog" 2>/dev/null; wait "$wdog" 2>/dev/null
}

# ── enumerate_devices ─────────────────────────────────────────────────────────
# Populate DEVS VIDS PIDS SERS IFNS IFSTRS CHIPS LABELS BAUDS arrays.
enumerate_devices() {
    declare -ga DEVS VIDS PIDS SERS IFNS IFSTRS CHIPS LABELS BAUDS
    local idx=0
    for dev in $(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | sort -V); do
        [[ -c "$dev" ]] || continue
        local info; info=$(udevadm info -a "$dev" 2>/dev/null)
        local vid pid ser ifn ifstr
        vid=$(awk   -F'"' '/ATTRS\{idVendor\}/{print $2; exit}'         <<< "$info")
        pid=$(awk   -F'"' '/ATTRS\{idProduct\}/{print $2; exit}'        <<< "$info")
        ser=$(awk   -F'"' '/ATTRS\{serial\}/{print $2; exit}'           <<< "$info")
        ifn=$(awk   -F'"' '/ATTRS\{bInterfaceNumber\}/{print $2; exit}' <<< "$info")
        ifstr=$(awk -F'"' '/ATTRS\{interface\}/{print $2; exit}'        <<< "$info")
        local vp="${vid}:${pid}"
        DEVS[$idx]="$dev";  VIDS[$idx]="$vid";  PIDS[$idx]="$pid"
        SERS[$idx]="$ser";  IFNS[$idx]="$ifn";  IFSTRS[$idx]="$ifstr"
        CHIPS[$idx]="${CHIP_NAMES[$vp]:-${vp}}"
        LABELS[$idx]="${CFG_LABEL[$ser]:-}"
        BAUDS[$idx]=$(get_baud "$vp" "$ser")
        (( idx++ )) || true
    done
}

# ── port_indices ──────────────────────────────────────────────────────────────
# Populate PORT_IDX[dev]=N — sequential 0-based index within each physical device.
port_indices() {
    declare -gA PORT_IDX
    declare -A _ser_devs
    local i
    for i in "${!DEVS[@]}"; do _ser_devs[${SERS[$i]}]+="${IFNS[$i]}:${DEVS[$i]} "; done
    local ser idx dev
    for ser in "${!_ser_devs[@]}"; do
        idx=0
        while IFS= read -r dev; do
            PORT_IDX[$dev]=$idx; (( idx++ )) || true
        done < <(tr ' ' '\n' <<< "${_ser_devs[$ser]}" \
                 | grep -v '^$' | sort -t: -k1 -n | cut -d: -f2-)
    done
}

# ── display_order ─────────────────────────────────────────────────────────────
# Populate _disp_order array: indices sorted by (first-occurrence serial, interface).
# Keeps multi-port adapters grouped even when another device grabs a ttyUSBN in between.
display_order() {
    declare -gA _fpos
    local i
    for i in "${!DEVS[@]}"; do
        [[ -z "${_fpos[${SERS[$i]}]+x}" ]] && _fpos[${SERS[$i]}]=$i
    done
    declare -ga _disp_order=()
    while IFS=: read -r _ _ i; do _disp_order+=("$i"); done < <(
        for i in "${!DEVS[@]}"; do
            printf "%05d:%04d:%d\n" \
                "${_fpos[${SERS[$i]}]}" \
                "$(( 10#${IFNS[$i]:-0} ))" \
                "$i"
        done | sort)
}
