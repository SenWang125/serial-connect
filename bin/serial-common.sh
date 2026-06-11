#!/bin/bash
# serial-common.sh — shared functions and defaults for serial-connect tools
# Sourced by serial-discover and serial-connect. Not executed directly.

# ── Colours ────────────────────────────────────────────────────────────────────
BOLD=$'\033[1m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'
DIM=$'\033[2m'; RED=$'\033[31m'; NC=$'\033[0m'
# If MATE terminal has allow-bold=false, substitute cyan for bold so headers remain visible
_mate_prof=$(dconf list /org/mate/terminal/profiles/ 2>/dev/null | head -1 | tr -d '/')
if [[ -n "$_mate_prof" ]]; then
    _allow_bold=$(dconf read /org/mate/terminal/profiles/${_mate_prof}/allow-bold 2>/dev/null)
    [[ "$_allow_bold" == "false" ]] && BOLD=''
fi
unset _mate_prof _allow_bold

# ── Config paths ───────────────────────────────────────────────────────────────
# Follows the standard Unix two-layer pattern (git/minicom/OpenOCD model):
#
#   Global install  (scripts in /usr/local/... or /opt/...):
#     System conf:  /etc/serial-boards.conf           — chip table + admin labels
#                   read-only for non-root; admin edits directly or via sudo --label
#     User conf:    ~/.config/serial-connect/boards.conf — per-user labels + SERIAL_TERM
#                   always writable; shadows system conf key-by-key
#
#   Local install   (scripts in ~/...):
#     Single conf:  <script-dir>/serial-boards.conf   — everything in one file
#
# Override: BOARD_CFG=/path serial-connect  (single-file mode, skips layering)
_COMMON_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if [[ -n "${BOARD_CFG:-}" ]]; then
    _SYSTEM_CFG="$BOARD_CFG"
    _LABEL_CFG="$BOARD_CFG"
elif [[ "$_COMMON_DIR" == /usr/* || "$_COMMON_DIR" == /opt/* ]]; then
    # Global install — two-layer
    _SYSTEM_CFG="/etc/serial-boards.conf"
    _LABEL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/serial-connect/boards.conf"
    BOARD_CFG="$_LABEL_CFG"
else
    # Local install — single file next to scripts
    _SYSTEM_CFG="$_COMMON_DIR/serial-boards.conf"
    _LABEL_CFG="$_COMMON_DIR/serial-boards.conf"
    BOARD_CFG="$_SYSTEM_CFG"
fi

# Per-user probe cache to avoid cross-user permission conflicts.
SIG_FILE="/tmp/serial-connect-${USER}.sig"
CACHE_FILE="/tmp/serial-connect-${USER}.cache"

# All defaults live in serial-boards.conf. Structures initialised empty here.
declare -A CHIP_NAMES=() CHIP_BAUD=() CHIP_WILDCARD=() CHIP_BAUD_WILDCARD=() CFG_LABEL CFG_BAUD
declare -a PROBE_BAUDS=()
PROBE_PARALLEL=0 PROBE_READ_MS=100 PROBE_DRAIN_MS=10 REPROBE_DEAD=1 PROBE_READ_SCALE=3
# Per-device probe timeout overrides (devbasename → read_ms).
# Populated by callers before run_probes; inherited by subshells.
declare -A _PROBE_TIMEOUTS=()

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
    else echo "${PROBE_BAUDS[0]}"
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

# ── _prompt_baud ───────────────────────────────────────────────────────────────
# Interactively prompt for a baud rate change; updates the named variable.
# Usage: _prompt_baud VARNAME  (reads/writes the variable named by VARNAME)
_prompt_baud() {
    while true; do
        read -rp "$(baud_prompt "${!1}"): " b || { printf "\n"; exit 0; }
        baud_valid "$b" && { [[ -n "$b" ]] && printf -v "$1" '%s' "$(parse_baud "$b")"; break; }
        echo "  Invalid — examples: 115200  115.2K  1.5M" >&2
    done
}

# ── load_config ────────────────────────────────────────────────────────────────
# Reads system conf (chip table + probe tuning) then user label conf (overrides).
# Populates: CFG_LABEL, CFG_BAUD, CHIP_NAMES, CHIP_BAUD, PROBE_BAUDS, tuning vars.
_load_conf_file() {
    local file="$1" labels_only="${2:-0}"
    [[ -f "$file" ]] || return
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# || -z "${key// /}" ]] && continue
        key="${key// /}"; val="${val%%#*}"; val="${val// /}"
        if (( labels_only )); then
            # User label conf: only process board serial→label entries
            [[ "$key" =~ ^[0-9a-fA-F]{4}: ]] && continue  # skip chip table
            [[ "$key" =~ ^(PROBE_|REPROBE_) ]] && continue # skip probe tuning
        fi
        # Terminal preference
        if [[ "$key" == "SERIAL_TERM" ]]; then
            [[ "$val" =~ ^(tio|screen|minicom|picocom)$ ]] && export SERIAL_TERM="$val"
            continue
        fi
        # Probe tuning scalars
        if [[ "$key" =~ ^(PROBE_(PARALLEL|READ_MS|DRAIN_MS|READ_SCALE)|REPROBE_DEAD)$ ]]; then
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
        # Vendor wildcard: VID:xxxx=NAME or VID:xxxx=NAME:BAUD
        if [[ "$key" =~ ^[0-9a-fA-F]{4}:xxxx$ ]]; then
            local vid="${key%%:*}" wname="${val%%:*}"
            [[ -n "$wname" ]] && CHIP_WILDCARD["$vid"]="$wname"
            if [[ "$val" == *:* ]]; then
                local wcb; wcb=$(parse_baud "${val##*:}")
                (( wcb > 0 )) && CHIP_BAUD_WILDCARD["$vid"]="$wcb"
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
    done < "$file"
}

load_config() {
    _load_conf_file "$_SYSTEM_CFG" 0          # chip table + probe settings + shared labels
    [[ "$_LABEL_CFG" != "$_SYSTEM_CFG" ]] && \
        _load_conf_file "$_LABEL_CFG" 1        # per-user label overrides (labels only)
}

# ── get_baud ───────────────────────────────────────────────────────────────────
# Resolve baud for a device: per-board override > chip default > 115200
get_baud() { local vid="${1%%:*}"; echo "${CFG_BAUD[$2]:-${CHIP_BAUD[$1]:-${CHIP_BAUD_WILDCARD[$vid]:-${PROBE_BAUDS[0]}}}}"; }

# ── _extract_hostname ──────────────────────────────────────────────────────────
# Parse a hostname from a shell prompt or login banner string.
# Usage: _extract_hostname TEXT OUTVAR  (sets OUTVAR; clears it on no match)
# Patterns: user@host:  /  host login:  /  Board: host  /  host:~/path
_extract_hostname() {
    printf -v "$2" '%s' ''
    if   [[ "$1" =~ @([A-Za-z0-9._-]+)[[:space:]]*: ]];       then printf -v "$2" '%s' "${BASH_REMATCH[1]}"
    elif [[ "$1" =~ ([A-Za-z0-9._-]+)[[:space:]]+login: ]];    then printf -v "$2" '%s' "${BASH_REMATCH[1]}"
    elif [[ "$1" =~ [Bb]oard:[[:space:]]*([A-Za-z0-9._-]+) ]]; then printf -v "$2" '%s' "${BASH_REMATCH[1]}"
    elif [[ "$1" =~ ^([A-Za-z0-9._-]+):[~/] ]];               then printf -v "$2" '%s' "${BASH_REMATCH[1]}"
    fi
}

# ── _agent_hostname ────────────────────────────────────────────────────────────
# Extract hostname from serial-agent's status.json prompt_text for DEVNAME.
# Usage: _agent_hostname DEVNAME OUTVAR
_agent_hostname() {
    printf -v "$2" '%s' ''
    local _sjson="/tmp/serial-agent/$1/status.json"
    [[ -f "$_sjson" ]] || return
    local _pt
    _pt=$(grep -o '"prompt_text"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sjson" 2>/dev/null \
        | sed 's/.*"prompt_text"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    [[ -n "$_pt" ]] && _extract_hostname "$_pt" "$2"
}

# ── _agent_is_alive ────────────────────────────────────────────────────────────
# Set OUTVAR to 1 if the serial-agent daemon is running for DEVNAME, else 0.
# Usage: _agent_is_alive DEVNAME OUTVAR
_agent_is_alive() {
    printf -v "$2" '%s' '0'
    local _pf="/tmp/serial-agent/$1/daemon.pid"
    [[ -f "$_pf" ]] || return
    local _pid; _pid=$(cat "$_pf" 2>/dev/null) || return
    [[ -n "$_pid" && -d "/proc/$_pid" ]] && printf -v "$2" '%s' '1'
}

# ── _read_agent_tcp_via ────────────────────────────────────────────────────────
# Read the TCP relay address from serial-agent's status.json.
# Usage: _read_agent_tcp_via STATUS_JSON OUTVAR  (sets OUTVAR to host:port or "")
_read_agent_tcp_via() {
    printf -v "$2" '%s' ''
    [[ -f "$1" ]] || return
    local _v; _v=$(python3 -c "import json,sys; print(json.load(open('$1')).get('via',''))" 2>/dev/null)
    [[ "$_v" == tcp:* ]] && printf -v "$2" '%s' "${_v#tcp:}"
}

# ── probe_tty ──────────────────────────────────────────────────────────────────
# Probe a single tty: send CR, try each baud in PROBE_BAUDS order, detect live.
# Output: STATUS|BAUD|board_id  (STATUS: LIVE OPEN DEAD FAIL)
probe_tty() {
    local dev="$1" cfg_baud="${2:-${PROBE_BAUDS[0]}}"

    local _devname; _devname=$(basename "$dev")
    local _lockfile="/tmp/serial-connect-locks/$_devname"
    local _agent_pidfile="/tmp/serial-agent/$_devname/daemon.pid"
    local _lock_alive=0 _agent_alive=0
    if [[ -f "$_lockfile" ]]; then
        local _lock_pid; _lock_pid=$(awk 'NR==1' "$_lockfile" 2>/dev/null)
        if [[ -n "$_lock_pid" ]] && [[ -d "/proc/$_lock_pid" ]]; then
            _lock_alive=1
        else
            rm -f "$_lockfile" 2>/dev/null || true
        fi
    fi
    _agent_is_alive "$_devname" _agent_alive
    if (( _agent_alive )); then
        local _hostname; _agent_hostname "$_devname" _hostname
        printf 'OPEN|%s|%s\n' "$cfg_baud" "$_hostname"
        return
    fi
    { fuser "$dev" &>/dev/null 2>&1 \
        || sudo -n fuser "$dev" &>/dev/null 2>&1 \
        || (( _lock_alive )); } \
        && { printf 'OPEN|%s|\n' "$cfg_baud"; return; }

    local fd
    exec {fd}<>"$dev" 2>/dev/null || { printf 'FAIL|%s|\n' "$cfg_baud"; return; }
    local saved; saved=$(stty -F "$dev" -g 2>/dev/null)

    # ttyACM: each baud switch sends CDC_SET_LINE_CODING — some devices block ~12s per attempt.
    # Probe at cfg_baud only; watchdog kills it if it blocks.
    local -a try_bauds=()
    if [[ "$dev" =~ /dev/ttyACM ]]; then
        try_bauds=("$cfg_baud")
    else
        [[ "$cfg_baud" != "${PROBE_BAUDS[0]}" ]] && try_bauds+=("$cfg_baud")
        local b
        for b in "${PROBE_BAUDS[@]}"; do
            local dup=0
            for already in "${try_bauds[@]}"; do [[ "$b" == "$already" ]] && dup=1 && break; done
            (( dup )) || try_bauds+=("$b")
        done
    fi

    local _eff_ms="${_PROBE_TIMEOUTS[$(basename "$dev")]:-$PROBE_READ_MS}"
    local _eff_drain_ms=$(( PROBE_DRAIN_MS * _eff_ms / PROBE_READ_MS ))
    local read_t drain_t
    read_t="$(( _eff_ms        / 1000 )).$(printf '%03d' $(( _eff_ms        % 1000 )))"
    drain_t="$(( _eff_drain_ms / 1000 )).$(printf '%03d' $(( _eff_drain_ms % 1000 )))"

    local skip_stty=0
    [[ "$dev" =~ /dev/ttyACM ]] && skip_stty=1

    # ttyACM: switching baud triggers CDC_SET_LINE_CODING which stalls ~12s per
    # attempt, so baud changes are skipped entirely.  But raw mode must still be
    # set: without it the kernel TTY line discipline buffers incoming bytes until
    # a newline arrives (canonical mode), so a login prompt ending in \r without
    # \n is never delivered to read() and the probe returns DEAD even when the
    # board is alive.  Setting raw + drain here, once, is safe — no baud change,
    # no CDC overhead.
    if (( skip_stty )); then
        stty -F "$dev" "$cfg_baud" raw -echo -crtscts min 0 time 0 2>/dev/null
        IFS= read -t "$drain_t" -r -d '' -n 1024 -u $fd _drain 2>/dev/null || true
    fi

    local detected="" captured=""
    for baud in "${try_bauds[@]}"; do
        if (( !skip_stty )); then
            stty -F "$dev" "$baud" raw -echo -crtscts min 0 time 1 2>/dev/null
            IFS= read -t "$drain_t" -r -d '' -n 1024 -u $fd _drain 2>/dev/null || true
        fi
        printf '\r' >&$fd
        local raw=""
        IFS= read -t "$read_t" -r -d '' -n 200 -u $fd raw 2>/dev/null
        local clean; clean=$(printf '%s' "$raw" \
            | sed 's/\x1b\[[0-9;]*[mGKJHFABCDfsuhlrn]//g' \
            | tr -dc '[:print:][:space:]' | tr -s '[:space:]' ' ' \
            | sed 's/^ //; s/ $//')
        local raw_len="${#raw}" clean_len="${#clean}"
        # ttyUSB: wrong baud → ~30% printable by chance; require ≥80% to reject false positives.
        # ttyACM: single baud only, no false-positive risk; require ≥40%.
        local threshold=80; (( skip_stty )) && threshold=40
        if (( clean_len >= 4 && raw_len > 0 && clean_len * 100 >= raw_len * threshold )); then
            detected="$baud"; captured="$clean"; break
        fi
    done

    [[ -n "$saved" ]] && stty -F "$dev" "$saved" 2>/dev/null
    stty -F "$dev" -hupcl 2>/dev/null   # prevent DTR deassert → board SIGHUP
    exec {fd}>&-

    [[ -z "$detected" ]] && { printf 'DEAD|%s|\n' "$cfg_baud"; return; }

    local id; _extract_hostname "$captured" id
    # No fallback to raw captured text — garbage output leaves the board unlabelled.
    printf 'LIVE|%s|%s\n' "$detected" "$id"
}

# ── cache helpers ─────────────────────────────────────────────────────────────
# Shared by serial-discover and serial-connect so running either one updates
# the cache the other reads.
save_cache() {
    local probe_dir="$1"
    local sig=""
    for i in "${!DEVS[@]}"; do sig+="${VIDS[$i]}:${PIDS[$i]}:${SERS[$i]}"$'\n'; done
    printf '%s' "$(printf '%s' "$sig" | sort -u)" > "$SIG_FILE"
    local -A _prev_hn=()
    if [[ -f "$CACHE_FILE" ]]; then
        local _pk _ps _pb _ph
        while IFS='|' read -r _pk _ps _pb _ph _rest; do
            [[ -n "$_pk" && -n "$_ph" ]] && _prev_hn["$_pk"]="$_ph"
        done < "$CACHE_FILE"
    fi
    : > "$CACHE_FILE"
    for i in "${!DEVS[@]}"; do
        local key="${VIDS[$i]}:${PIDS[$i]}:${SERS[$i]}:${IFNS[$i]}"
        local result; result=$(cat "$probe_dir/$(basename "${DEVS[$i]}")" 2>/dev/null || echo "FAIL|")
        local _st _bd _hn
        IFS='|' read -r _st _bd _hn <<< "$result"
        if [[ -z "$_hn" && -n "${_prev_hn[$key]:-}" ]]; then
            result="${_st}|${_bd}|${_prev_hn[$key]}"
        fi
        echo "${key}|${result}" >> "$CACHE_FILE"
    done
}

load_cache() {
    local probe_dir="$1"
    for i in "${!DEVS[@]}"; do
        local key="${VIDS[$i]}:${PIDS[$i]}:${SERS[$i]}:${IFNS[$i]}"
        local cached; cached=$(grep "^${key}|" "$CACHE_FILE" 2>/dev/null | head -1 | cut -d'|' -f2-)
        echo "${cached:-DEAD|}" > "$probe_dir/$(basename "${DEVS[$i]}")"
    done
}

# ── rewrite_labels ────────────────────────────────────────────────────────────
# Update serial→label entries in BOARD_CFG.
# Arg: name of an associative array  serial → new_label.
#   Non-empty value  — add or update the entry, preserving any :BAUD suffix.
#   Empty string     — comment out the existing line.
rewrite_labels() {
    local -n _rl=$1
    [[ ${#_rl[@]} -eq 0 ]] && return 0
    # Always write to user label conf (_LABEL_CFG), creating it if needed
    local _target="$_LABEL_CFG"
    if [[ ! -f "$_target" ]]; then
        mkdir -p "$(dirname "$_target")" 2>/dev/null || true
        printf '# serial-connect — per-user board labels\n# Overrides /etc/serial-boards.conf key-by-key\n' \
            > "$_target" 2>/dev/null || {
            echo "Cannot create $_target — check permissions." >&2; return 1
        }
    fi
    if [[ ! -w "$_target" ]]; then
        echo "Label config not writable: $_target" >&2
        echo "Run: sudo serial-connect --label  (to update system config)" >&2
        return 1
    fi
    # Update BOARD_CFG to point at write target for caller display
    BOARD_CFG="$_target"
    local tmpfile; tmpfile=$(mktemp "${_target}.XXXXXX") || return 1
    local -A _done
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" != *=* ]]; then
            printf '%s\n' "$line"; continue
        fi
        local key="${line%%=*}"; key="${key// /}"
        if [[ -n "${_rl[$key]+x}" ]]; then
            _done[$key]=1
            if [[ -z "${_rl[$key]}" ]]; then
                printf '# %s\n' "$line"
            else
                local v="${line#*=}"; v="${v%%#*}"; v="${v// /}"
                local baud=""; [[ "$v" == *:* ]] && baud=":${v##*:}"
                printf '%s=%s%s\n' "$key" "${_rl[$key]}" "$baud"
            fi
        else
            printf '%s\n' "$line"
        fi
    done < "$_target" > "$tmpfile"
    local first=1 ser
    for ser in "${!_rl[@]}"; do
        [[ -n "${_done[$ser]+x}" || -z "${_rl[$ser]}" ]] && continue
        if (( first )); then
            printf '\n# Added %s\n' "$(date '+%Y-%m-%d')" >> "$tmpfile"
            first=0
        fi
        printf '%s=%s\n' "$ser" "${_rl[$ser]}" >> "$tmpfile"
    done
    mv "$tmpfile" "$_target" || { rm -f "$tmpfile"; return 1; }
}

# ── run_probes ─────────────────────────────────────────────────────────────────
# Launch probe_tty for each device index, respecting PROBE_PARALLEL.
# Results written to $PROBE_DIR/<devname>. Watchdog timeout scales with settings.
run_probes() {
    local -a idxs=("$@")
    local -a pids=()
    local active=0 i
    local _par=$(( PROBE_PARALLEL == 0 ? $(nproc 2>/dev/null || echo 4) : PROBE_PARALLEL ))
    for i in "${idxs[@]}"; do
        if (( active >= _par )); then
            wait -n 2>/dev/null; (( active-- )) || true
        fi
        ( probe_tty "${DEVS[$i]}" "${BAUDS[$i]}" \
            > "$PROBE_DIR/$(basename "${DEVS[$i]}")" ) &
        pids+=($!); (( active++ )) || true
    done
    local _max_read=$PROBE_READ_MS _t
    for _t in "${_PROBE_TIMEOUTS[@]}"; do (( _t > _max_read )) && _max_read=$_t; done
    local wdog_s=$(( (${#PROBE_BAUDS[@]} * (_max_read + PROBE_DRAIN_MS) + 999) / 1000 + 1 ))
    ( sleep "$wdog_s"; kill -9 "${pids[@]}" 2>/dev/null ) &
    local wdog=$!
    wait "${pids[@]}" 2>/dev/null
    kill -9 "$wdog" 2>/dev/null; wait "$wdog" 2>/dev/null
}

# ── enumerate_devices ─────────────────────────────────────────────────────────
# Populate DEVS VIDS PIDS SERS IFNS IFSTRS CHIPS LABELS BAUDS arrays.
enumerate_devices() {
    declare -ga DEVS VIDS PIDS SERS IFNS IFSTRS CHIPS LABELS BAUDS

    local -a dev_list=()
    for dev in $(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | sort -V); do
        [[ -c "$dev" ]] && dev_list+=("$dev")
    done

    # Run all udevadm queries in parallel (-q property is faster than -a)
    local _etmp; _etmp=$(mktemp -d /tmp/serial-enum.XXXXXX)
    local -a _epids=()
    for dev in "${dev_list[@]}"; do
        udevadm info -q property -n "$dev" > "$_etmp/$(basename "$dev")" 2>/dev/null &
        _epids+=($!)
    done
    wait "${_epids[@]}" 2>/dev/null

    local idx=0
    for dev in "${dev_list[@]}"; do
        local vid="" pid="" ser="" ifn=""
        while IFS='=' read -r key val; do
            case "$key" in
                ID_VENDOR_ID)         vid="$val" ;;
                ID_MODEL_ID)          pid="$val" ;;
                ID_SERIAL_SHORT)      ser="$val" ;;
                ID_USB_INTERFACE_NUM) ifn="$val" ;;
            esac
        done < "$_etmp/$(basename "$dev")"
        local vp="${vid}:${pid}"
        DEVS[$idx]="$dev";  VIDS[$idx]="$vid";  PIDS[$idx]="$pid"
        SERS[$idx]="$ser";  IFNS[$idx]="$ifn";  IFSTRS[$idx]=""
        CHIPS[$idx]="${CHIP_NAMES[$vp]:-${CHIP_WILDCARD[${vp%%:*}]:-$vp}}"
        LABELS[$idx]="${CFG_LABEL[$ser]:-}"
        BAUDS[$idx]=$(get_baud "$vp" "$ser")
        (( idx++ )) || true
    done
    rm -rf "$_etmp"
}

# ── port_indices ──────────────────────────────────────────────────────────────
# Populate PORT_IDX[dev]=N and DEVICE_IDX[serial]=N.
# PORT_IDX: 0-based port within each physical device.
# DEVICE_IDX: 0-based device index in first-occurrence (ttyUSBN enumeration) order.
port_indices() {
    declare -gA PORT_IDX DEVICE_IDX
    declare -A _ser_devs
    local i
    for i in "${!DEVS[@]}"; do _ser_devs[${SERS[$i]}]+="${IFNS[$i]}:${DEVS[$i]} "; done
    local ser idx dev dev_count=0
    for ser in "${!_ser_devs[@]}"; do
        idx=0
        while IFS= read -r dev; do
            PORT_IDX[$dev]=$idx; (( idx++ )) || true
        done < <(tr ' ' '\n' <<< "${_ser_devs[$ser]}" \
                 | grep -v '^$' | sort -t: -k1 -n | cut -d: -f2-)
    done
    # Assign device indices in DEVS array order (first-occurrence = lowest ttyUSBN)
    for i in "${!DEVS[@]}"; do
        ser="${SERS[$i]}"
        if [[ -z "${DEVICE_IDX[$ser]+x}" ]]; then
            DEVICE_IDX[$ser]=$dev_count
            (( dev_count++ )) || true
        fi
    done
}

# ── build_board_ids ───────────────────────────────────────────────────────────
# Populate BOARD_ID[serial]: config label > probed hostname (LIVE or OPEN).
# Requires PROBE_DIR, DEVS, SERS, CFG_LABEL.
build_board_ids() {
    declare -gA BOARD_ID=()
    local i ser _r _b cap
    for i in "${!DEVS[@]}"; do
        ser="${SERS[$i]}"
        if [[ -n "${CFG_LABEL[$ser]:-}" ]]; then
            BOARD_ID[$ser]="${CFG_LABEL[$ser]}"
        elif [[ -z "${BOARD_ID[$ser]+x}" ]]; then
            IFS='|' read -r _r _b cap \
                <<< "$(cat "$PROBE_DIR/$(basename "${DEVS[$i]}")" 2>/dev/null || echo 'FAIL||')"
            [[ ( "$_r" == "LIVE" || "$_r" == "OPEN" ) && -n "$cap" ]] && BOARD_ID[$ser]="$cap"
        fi
    done
}

# ── build_active_ser ──────────────────────────────────────────────────────────
# Populate _active_ser[serial]=1 for any serial with at least one LIVE/OPEN port.
# Requires PROBE_DIR, DEVS, SERS.
build_active_ser() {
    declare -gA _active_ser=()
    local i rs
    for i in "${!DEVS[@]}"; do
        IFS='|' read -r rs _ _ \
            <<< "$(cat "$PROBE_DIR/$(basename "${DEVS[$i]}")" 2>/dev/null || echo 'FAIL||')"
        [[ "$rs" == "LIVE" || "$rs" == "OPEN" ]] && _active_ser[${SERS[$i]}]=1
    done
}

# ── display_order ─────────────────────────────────────────────────────────────
# Populate _disp_order array: indices sorted by (first-occurrence serial, interface).
# Keeps multi-port adapters grouped even when another device grabs a ttyUSBN in between.
display_order() {
    declare -gA _fpos=()
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
