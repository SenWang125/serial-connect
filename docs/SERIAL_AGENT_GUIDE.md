# Serial Agent Guide — Executable Patterns for Automation

> Architecture reference: see `SERIAL_ARCH.md`.
> This document contains EXECUTABLE PATTERNS — copy-paste code for agents.

---

## 0. Prerequisites

```bash
# Label boards first (one-time, do before anything else):
serial-agent auto-label -y

# See what's connected:
serial-agent list                    # show running daemons
serial-discover                      # show all ports with live probe
serial-discover --json               # machine-readable
```

---

## 1. Session Setup (do once per board)

### Bash
```bash
BOARD="${BOARD:?Set BOARD=<label from serial-boards.conf>}"

# One call: discover + start daemon + wait for shell + set 220-col terminal
serial-agent connect --board "$BOARD" --wait-shell --setup-terminal --timeout 90

# Get the device path (for all subsequent commands)
DEV=$(serial-agent discover --board "$BOARD" --live \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['device'] if d else '')")
[[ -z "$DEV" ]] && { echo "Board '$BOARD' not found"; exit 1; }
```

### Python
```python
import subprocess, json, os, sys

board = os.environ.get('BOARD') or sys.exit('Set BOARD= env var')

# Discover and connect (no /dev/ttyUSBx hardcoded)
devs = json.loads(subprocess.check_output(
    ['serial-agent','discover','--board', board,'--live']))
if not devs:
    sys.exit(f"Board '{board}' not found or not live")

d = devs[0]
dev = d['device']                    # /dev/ttyUSBx  (dynamic, not hardcoded)

if not d['daemon_running']:
    subprocess.run(d['start_cmd'].split(), check=True)

subprocess.run(['serial-agent','wait-alive', dev,'--timeout','60'], check=True)
```

---

## 2. Sending Commands

### Basic send (returns structured JSON — ALWAYS USE --json)
```bash
result=$(serial-agent send "$DEV" "uname -r" --json --no-wrap --timeout 5)
output=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['output'])")
state=$(echo  "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
```

### With exit code
```bash
result=$(serial-agent send "$DEV" "modprobe my-driver" --json --exit-code --timeout 10)
exit_code=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['exit_code'] or 0)")
if [[ "$exit_code" != "0" ]]; then echo "FAILED: $exit_code"; fi
```

### Multi-line script (use run, not send)
```bash
result=$(serial-agent run "$DEV" - --json --timeout 30 << 'EOF'
aplay -l
arecord -l
amixer scontents | head -20
echo "AUDIO_STATUS:$?"
EOF
)
echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['output'])"
```

### Python send pattern
```python
def board_run(dev, cmd, timeout=30, exit_code=False, no_wrap=True):
    """Run a command on the board, return (output, exit_code, timed_out)."""
    args = ['serial-agent', 'send', dev, cmd,
            '--json', '--timeout', str(timeout)]
    if exit_code: args.append('--exit-code')
    if no_wrap:   args.append('--no-wrap')
    r = json.loads(subprocess.check_output(args))
    return r['output'], r.get('exit_code'), r.get('timed_out', False)

output, rc, timed_out = board_run(dev, 'uname -r')
```

---

## 3. State Checking (ALWAYS check before sending)

```bash
# Fast state check (reads cached status, no serial traffic)
state=$(serial-agent status "$DEV" | python3 -c "
import sys,json; s=json.load(sys.stdin)
print(s['state'])")

case "$state" in
  SHELL)    : ;;   # ok to send
  RUNNING)  serial-agent wait-state "$DEV" SHELL --timeout 60 ;;
  LOGIN)    serial-agent login "$DEV" ;;
  PASSWORD) serial-agent login "$DEV" ;;
  BOOTING)  serial-agent wait-state "$DEV" SHELL --timeout 120 ;;
  PANIC)    echo "BOARD PANIC — needs reboot"; serial-agent reboot "$DEV" --timeout 120 ;;
  DEAD)     serial-agent alive "$DEV" --timeout 5 || { echo "Board unresponsive"; exit 1; } ;;
  UBOOT)    echo "Board at U-Boot prompt" ;;
esac
```

---

## 4. Event-Driven Waiting (zero-poll, instant notification)

```bash
# Wait for board to reach SHELL after a reboot
serial-agent wait-state "$DEV" SHELL,LOGIN --timeout 120
# Uses inotifywait if available → 0ms latency (no spinning)

# Wait for multiple outcomes (reboot safety net)
serial-agent send "$DEV" "reboot" --no-wait
result=$(serial-agent expect "$DEV" \
  --on "READY=~#" \
  --on "PANIC=Kernel panic" \
  --on "UBOOT==>" \
  --on "LOGIN=login:" \
  --timeout 120)
matched=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['matched'])")
echo "Board came back as: $matched"   # READY / PANIC / UBOOT / LOGIN
```

---

## 5. Reboot and Recovery

```bash
# Standard TI board reboot (no password, root login)
serial-agent reboot "$DEV" --setup-terminal --timeout 120

# Reboot with explicit login (if password required)
serial-agent reboot "$DEV" --user root --password "" --setup-terminal --timeout 120

# After unexpected reboot (board went DEAD during test)
serial-agent wait-state "$DEV" SHELL,LOGIN --timeout 90
serial-agent login "$DEV"                             # handles LOGIN state if needed
```

---

## 6. File Transfer (no network needed)

```bash
# Upload kernel module
serial-agent upload "$DEV" ./my-driver.ko /lib/modules/$(uname -r)/extra/
serial-agent send "$DEV" "depmod -a" --wait '#' --timeout 10

# Upload DTB overlay
serial-agent upload "$DEV" ./k3-am625-sk-audio.dtbo /boot/overlays/
serial-agent send "$DEV" "sync" --wait '#' --timeout 5

# Upload and run a test script
serial-agent upload "$DEV" ./run_tests.sh /tmp/
serial-agent send "$DEV" "chmod +x /tmp/run_tests.sh && /tmp/run_tests.sh" \
  --json --no-wrap --timeout 120
```

**Limits:** base64 transfer is ~1 KB/s over serial. For files > 500 KB, prefer network when available.

---

## 7. Board Health Check

```bash
health=$(serial-agent health "$DEV")
echo "$health" | python3 -c "
import sys,json
h = json.load(sys.stdin)
print(f\"State: {h['state']}\")
print(f\"Kernel: {h.get('uname','?')}\")
print(f\"Uptime: {h.get('uptime_sec','?')}s\")
print(f\"Memory: {h.get('mem_pct_used','?')}% used\")
print(f\"Load: {h.get('load','?')}\")
"
```

---

## 8. Multi-Board Operations

```bash
# Send to all boards with running daemons simultaneously
serial-agent send --all "uname -r" --json

# Send to specific boards by label pattern
for board in AM62D2-EVM AM62LP-SK; do
  dev=$(serial-agent discover --board "$board" --live \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['device'] if d else '')")
  [[ -n "$dev" ]] && serial-agent send "$dev" "uname -r" --json --no-wrap &
done
wait
```

---

## 9. Embedded Dev Workflow (kernel module test)

```bash
#!/bin/bash
# Full kernel module test cycle — no hardcoded device paths

BOARD="${BOARD:?}" MODULE_KO="${1:?Usage: $0 module.ko}"

# Setup
serial-agent connect --board "$BOARD" --wait-shell --setup-terminal --timeout 90
DEV=$(serial-agent discover --board "$BOARD" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['device'])")

# Health check
serial-agent health "$DEV" | python3 -c "
import sys,json; h=json.load(sys.stdin)
assert h['state']=='SHELL', f\"Not at shell: {h['state']}\""

# Upload and load
serial-agent upload "$DEV" "$MODULE_KO" /tmp/
MODNAME=$(basename "${MODULE_KO%.ko}")
serial-agent send "$DEV" "insmod /tmp/${MODNAME}.ko" --json --exit-code --timeout 10

# Check dmesg
serial-agent send "$DEV" "dmesg | tail -20" --capture --no-wrap --timeout 5

# Cleanup
serial-agent send "$DEV" "rmmod $MODNAME" --json --exit-code --timeout 5
```

---

## 10. Speed Reference

| Operation | Typical latency | Notes |
|-----------|----------------|-------|
| `send --json` (live board) | ~50ms | Board responds to CR immediately |
| `wait-state` (board at SHELL) | ~0ms | inotifywait, event-driven |
| `wait-state` (board booting) | boot time | TI AM62x: ~30-60s |
| `alive` (SHELL state, recent) | ~0ms | Reads cached status, no serial I/O |
| `alive` (DEAD, needs probe) | 0.1-5s | Sends CR, waits for response |
| `discover --live` | ~1.5-2s | 9 baud × 0.1s per dead port |
| `connect --wait-shell` | 0.5s + wait | Discover+start+wait combined |
| `upload` (10KB file) | ~10s | base64 over serial, ~1KB/s |
| `health` | ~150ms | 5 board queries combined |

**Avoid:** `time.sleep(N)` for fixed waits. Use `wait-state` or `expect` instead.

---

## 11. Error Handling Patterns

```bash
# Timeout → report and abort
result=$(serial-agent send "$DEV" "$cmd" --json --timeout 30)
if $(echo "$result" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin)['timed_out'] else 1)"); then
    echo "TIMEOUT after 30s — board may be hung"
    serial-agent events "$DEV" --lines 10   # see what happened
    exit 1
fi

# Board went DEAD mid-test
if ! serial-agent alive "$DEV" --timeout 5; then
    echo "Board unresponsive — check power, attempt reboot"
    serial-agent reboot "$DEV" --timeout 120 || exit 1
fi

# Board at unexpected LOGIN after reboot
state=$(serial-agent status "$DEV" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
[[ "$state" == "LOGIN" ]] && serial-agent login "$DEV"

# Inspect what board saw
serial-agent read "$DEV" --lines 30 --no-timestamps   # last 30 lines, clean
serial-agent events "$DEV"                             # state transitions
```

---

## 12. Quick Reference Card

```
# One-liners for agents
serial-agent list                              # what daemons are running?
serial-agent connect --board "$BOARD" --wait-shell  # connect to a board
serial-agent send "$DEV" "CMD" --json          # run command, get JSON
serial-agent run "$DEV" script.sh --json       # run script, get JSON
serial-agent reboot "$DEV" --setup-terminal   # reboot and come back
serial-agent upload "$DEV" file.ko /tmp/      # transfer file
serial-agent health "$DEV"                    # board vitals
serial-agent events "$DEV"                    # what happened recently
serial-agent wait-state "$DEV" SHELL          # block until shell ready
serial-agent stop "$DEV"                      # kill daemon (fuses all holders)

# Environment overrides
SERIAL_AGENT_DIR=/custom/path serial-agent ... # custom state directory
BOARD=AM62D2-EVM serial-agent connect ...      # specify board
```
