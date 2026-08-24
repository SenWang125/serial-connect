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

### Changing baud on an already-running daemon

A running daemon owns the real device — `--baud` on `serial-agent start` only
applies at first start. To reprogram an already-running daemon's baud live
(no restart, no dropped connection):

```bash
serial-agent setbaud "$DEV" 1500000
```

`serial-connect` prompts for this automatically when you type a baud at the
`Baud [...]:` prompt that differs from what the live daemon is actually
holding — you'll see `⚠ Existing session on /dev/ttyX is running at X; you
asked for Y` followed by a `Reprogram the live session to Y? [y/N]:`
confirmation (it never reprograms a shared session silently). Answering `N`
keeps the existing baud and proceeds with that instead of a value that would
never reach the hardware. The check first cross-validates `status.json`'s own
`pid` field against the daemon `_agent_is_alive` just confirmed live, so a
stale status.json left behind by a crashed prior instance is never mistaken
for the current session's real baud.

Without this, the requested baud used to be silently
dropped: `tio -b <baud>` only has real effect when it opens the device
directly, and a running daemon always routes tio through a `socat` PTY
bridge instead (PTYs have no UART clock — the flag is a no-op there).

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

**Sending to a login prompt is the classic silent failure.** `login` takes the command
as a username, asks for a password, prints `Login incorrect`, and after 60s times out and
respawns getty. The command never runs, the password prompt echoes nothing, and every
`--wait`/`--until` pattern misses — which reads as *the board dropping input characters*,
not as a login prompt. Shortening the command does not help; length was never the variable.

`send`, `run` and `watch --send` now auto-login at LOGIN/PASSWORD by default and say so on
stderr. `--no-login` opts out; `--login` additionally waits through BOOTING for the prompt.
A bare `watch` never auto-logs-in, so `--until 'login:'` still works for boot capture.

`--login` is not the same flag on every subcommand — on `send`/`run`/`watch` it adds the
BOOTING wait; on `reboot` it is a documented no-op (auto-login is already the default there).

The state check below is still the explicit form, and is what a polling loop should use —
poll `wait-state SHELL`, not a command whose output you expect to see.

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

### `watch` — real-time push (PREFER THIS over send-then-sleep)

`watch` subscribes to the daemon's **`output.fifo`** push channel, so it returns
the *instant* a pattern appears — the read blocks in the kernel until the next
serial byte arrives (measured ~0.2 ms inject→match, vs the 50–200 ms floor of the
file-polling path). `--send` fires a command **after** the read side is already
open, so no early output is lost. This is the one-shot replacement for the
`send X; sleep N; read` anti-pattern.

```bash
# Fused send + wait-for-result in ONE call (no blind sleep):
serial-agent watch "$DEV" --send 'modprobe snd_soc_foo' \
  --until 'card0|Error|FAIL' --timeout 20
# → {"matched":"u0","output":"...","elapsed_ms":840}   (exit 0 match / 1 timeout)

# Named outcomes (matched KEY is reported), e.g. a reboot safety net:
serial-agent watch "$DEV" --send 'reboot' \
  --on READY='~#' --on PANIC='Kernel panic' --on UBOOT='=>' \
  --timeout 120

# Live human-friendly stream (the raw push channel, cat-able):
cat ~/var/serial-agent/$(basename "$DEV")/output.fifo

# NOTE: output.fifo is single-consumer (a second reader steals bytes). For shared
# observation use tio / the TCP relay. One `watch` per device at a time.
```

### `expect` / `wait-state` — file-polling fallback

Use when you did NOT pre-open a watch (matching output already on the console),
or on a daemon too old to have `output.fifo`. Reads `stream.log`; event-driven if
`inotifywait` is installed (`sudo pacman -S inotify-tools`), else polls 50–200 ms.

```bash
# Wait for board to reach SHELL after a reboot
serial-agent wait-state "$DEV" SHELL,LOGIN --timeout 120

# Wait for multiple outcomes against output already flowing
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
| `watch` (inject→match) | **~0.2ms** | push via output.fifo, kernel-blocking read |
| `send --json` (live board) | ~50ms | Board responds to CR immediately |
| `expect`/`wait-state` (inotify) | ~0-5ms | event-driven if `inotify-tools` installed |
| `expect`/`wait-state` (no inotify) | 50-200ms | file-polling fallback — install inotify-tools |
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

## 12. Self-Test (pre-commit gate)

```bash
serial-agent test        # 57 assertions on a virtual pty pair, no hardware, ~20s
echo $?                  # 0 = green
serial-agent test -v     # add daemon stdout + relay detail
```

Requires `socat`. Runs a real daemon over a socat pty loopback and injects board output:
daemon start + port hold, startup CR probe, injected prompt → state, `send` capture, TCP
relay client, `human_session` vs `stop --force`, clean exit, plus the QUIET/FROZEN/PANIC
probe matrix. State goes to a temp `SERIAL_AGENT_DIR`, so `~/var/serial-agent/` is
untouched. Run it before every commit.

---

## 13. Other Subcommands

```bash
serial-agent path "$DEV"                                # print the device's state dir
serial-agent wait-alive "$DEV" --timeout 60             # block until SHELL, LOGIN or PASSWORD
serial-agent tail "$DEV" --no-timestamps --timeout 30   # last 20 buf.log lines, then follow
serial-agent boot "$DEV" --capture-file /tmp/boot.log --json
serial-agent ops "$DEV" --lines 50 --json               # per-op history
serial-agent attach "$DEV"                              # exec serial-connect on this device (human terminal)
serial-agent clean "$DEV"                               # delete state dir (refuses while a daemon runs)
```

- `tail` prints the last 20 lines of `buf.log`, then follows it until the daemon exits,
  `--timeout SECS` expires (0 = no limit), or Ctrl-C. **No line-count flag** — `--lines`
  and `-n` are both rejected; use `read --lines N` for a fixed backlog.
- `boot` needs a running daemon (exit 2 without one) and does NOT send `reboot`: trigger the
  reset yourself (power, relay, sysrq) or pass `--reset-cmd reboot`. Waits for SHELL/LOGIN/UBOOT
  (`up`, exit 0), FROZEN/PANIC (`frozen`) or timeout (both exit 1); writes the full boot slice to
  `--capture-file` (default `/tmp/serial-connect-boot/ttyUSBx.boot.log`) and prints a digest
  (`--digest-lines`, default 30).
- `ops` prints `ops.log` — one JSON record per operation (`alive`, `boot`, `send`, `watch`,
  `connect`, `reboot`) with `cmd`, `timeout`, `elapsed_ms`, `state`, `exit_code`, `timed_out`.
  This is the post-mortem for "did that command actually run?".
- `clean` with no device sweeps every state dir, skipping any with a live daemon.

---

## 14. Quick Reference Card

```
# One-liners for agents
serial-agent list                              # what daemons are running?
serial-agent connect --board "$BOARD" --wait-shell  # connect to a board
serial-agent send "$DEV" "CMD" --json          # run command, get JSON
serial-agent watch "$DEV" --send 'CMD' --until 'DONE|FAIL' --timeout 20  # push: fused send+wait, ~0.2ms match
cat ~/var/serial-agent/$(basename "$DEV")/output.fifo   # live raw stream (single consumer)
serial-agent run "$DEV" script.sh --json       # run script, get JSON
serial-agent reboot "$DEV" --setup-terminal   # reboot and come back
serial-agent upload "$DEV" file.ko /tmp/      # transfer file
serial-agent health "$DEV"                    # board vitals
serial-agent events "$DEV"                    # what happened recently
serial-agent wait-state "$DEV" SHELL          # block until shell ready
serial-agent stop "$DEV"                      # kill daemon (fuses all holders)
serial-agent ops "$DEV"                       # per-op history (cmd, elapsed_ms, timed_out)
serial-agent boot "$DEV" --json               # capture an externally-triggered boot
serial-agent path "$DEV"                      # state dir for this device
serial-agent test                             # 57-assertion self-test, no hardware (~20s)

# Environment overrides
SERIAL_AGENT_DIR=/custom/path serial-agent ...  # custom state directory
BOARD=AM62D2-EVM serial-agent connect ...       # specify board
SERIAL_SER2NET_CONF=/path/ser2net.yaml serial-agent start ...  # non-standard ser2net config
# start auto-routes through ser2net when configured; --no-ser2net forces direct
```
