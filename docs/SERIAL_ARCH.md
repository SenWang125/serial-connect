# Serial Tools — Architecture Reference

> **THIS IS AN ARCHITECTURE/DESIGN DOCUMENT.**
> Agents: read this to understand the system design, not to execute workflows.
> For executable patterns and command usage, see `serial-agent --help` or `SERIAL_AGENT_GUIDE.md`.

---

## Component Map

```
~/.config/serial-boards.conf        ← USER CONFIG: USB serial# → board label
           │
           ▼
serial-discover  ──────────────────────────────────────────────────────────►  stdout (table or --json)
  • probes /dev/ttyUSB* /dev/ttyACM* in parallel
  • multi-baud detection (115.2K first, then 1.5M, 921.6K, ...)
  • 80% printable ratio to reject wrong-baud false positives
  • ttyACM skipped (USB CDC_SET_LINE_CODING blocks for ~12s)
  • BOARD_ID propagated: one LIVE port names ALL ports of same USB serial

serial-connect  ────────────────────────────────────────────────────────────► human terminal
  • interactive menu (tio / screen / minicom / picocom via $SERIAL_TERM)
  • cache: /tmp/serial-connect.{sig,cache} — avoids reprobing on each run
  • selective re-probe: only unrecognized boards checked each run
  • auto-detects ser2net TCP (reads serial-agent status.json) → tio tcp:...
  • HUPCL cleared before probe + sudo -n fuser for root-owned sessions

tio.sh [N|/dev/ttyXXX] [baud]  ────────────────────────────────────────────► tmux session
  • named tmux session per device (reattaches if exists)
  • tio with unix socket: /tmp/ttyUSBx.sock  ← socat can share it

ser2net  (optional, recommended for coexistence)
  • holds physical serial port exclusively
  • fans bytes to multiple TCP clients (human tio + agent daemon both get FULL stream)
  • without ser2net: human and agent split bytes (data corruption)
  • config: /etc/ser2net.yaml  (generate with: serial-agent ser2net-gen)

serial-agent daemon ──────────────────────────────────────────────────────► ~/var/serial-agent/DEVICE/
  • connects via TCP (ser2net) or direct to /dev/ttyUSBx
  • reads ALL serial output continuously into ring buffer
  • state machine (see below)
  • events.log: state transition log (capped at 200 lines)
  • input FIFO: /dev/ttyUSBx write path → daemon reads → sends to serial
  • TIOCSWINSZ: sets 220×50 terminal size to prevent board line-wrapping
  • HUPCL cleared: prevents DTR deassert killing board sessions

serial-agent CLI  ←──────────────────────────────────────────────────────── agent / scripts
  • reads from ~/var/serial-agent/ files (no serial port access)
  • writes commands to FIFO (non-blocking O_NONBLOCK with retry)
```

---

## Storage Layout

```
~/.config/serial-boards.conf       USB serial# → board label (+optional baud)
                                    Key: unique, stable across replug and reboot

~/var/serial-agent/                 Real data (disk, not tmpfs)
  ttyUSBx/
    daemon.pid                      Running daemon PID
    daemon.log                      Daemon stderr/stdout
    buf.log                         Ring buffer (last 500 lines, timestamped)
    status.json                     Current state machine snapshot
    events.log                      State transitions (capped 200 lines)
    input.fifo                      Write commands here → daemon sends to board

/tmp/serial-agent  →  ~/var/serial-agent   symlink (auto-created, clears on reboot)
/tmp/serial-connect.{sig,cache}            serial-connect probe cache (session-scoped)
/tmp/ttyUSBx.sock                          tio unix socket (shared access point)
```

---

## State Machine (serial-agent daemon)

```
                ┌─────────────────────────────────────────┐
                │              UNKNOWN                    │  initial state, no data yet
                └───────────────┬────────────────────────-┘
                                │ first output
                    ┌───────────┴──────────┬──────────────────┐
                    ▼                      ▼                    ▼
                BOOTING              DEAD (30s)              SHELL/UBOOT
            [  0.123] timestamps   no output                prompt detected
                    │                      │                    │
                    ▼                      ▼                    ▼
               LOGIN/SHELL            DEAD stays            RUNNING
             (kernel done)        until output resumes   (output, no prompt)
                    │                                          │
               LOGIN ──→ send user ──→ PASSWORD ──→ SHELL ◄──┘
               PANIC: "Kernel panic" / BUG: / OOPS:  → board needs reboot
               UBOOT: "=>" or "u-boot#"               → U-Boot prompt
```

**Detection logic (priority order):**
1. PANIC (Kernel panic/BUG/OOPS) — checked first, critical
2. UBOOT (`=>` prompt)
3. LOGIN (`login:` / `Username:`)
4. PASSWORD (`Password:` / `passwd:`)
5. SHELL (user@host:path# or bare #/$/>)
6. BOOTING (kernel timestamp `[  0.123456]`)
7. DEAD (no output for 30s)
8. RUNNING (has output, no prompt for 3s)
9. UNKNOWN (no data yet)

ANSI escape codes stripped before all regex matching (handles colored prompts).

---

## Identification Strategy (no hardcoding)

**Why USB serial# as the key:**

```
/dev/ttyUSBx  → volatile (changes on replug, reboot, USB hub changes)
am62dxx-evm   → rootfs hostname (changes with OS image update)
46241800161   → USB adapter serial# (permanent, soldered into chip)  ← USE THIS
AM62D2-EVM    → user label in serial-boards.conf (maps serial# → name)
```

**Discovery flow (agents):**
```
serial-agent auto-label  →  serial-boards.conf populated
serial-agent discover --board "$BOARD_LABEL" --live  →  JSON with device path + start_cmd
$start_cmd  →  daemon running
serial-agent send/run/health...
```

---

## Baud Rate Handling

- Default: 115200 for all chips (override per-board in serial-boards.conf: `SERIAL=LABEL:1500000`)
- Probe order: 115200 → 1.5M → 921.6K → 460.8K → 230.4K → 57.6K → 38.4K → 19.2K → 9.6K
- Detection: 80% of received bytes must be printable (rejects wrong-baud garbage)
- Display: `baud_display(1500000)` → `1.5M`, `115200` → `115.2K`
- Parse: `parse_baud("1.5M")` → 1500000, `parse_baud("115.2K")` → 115200

---

## Ser2net Coexistence

**Without ser2net (WRONG — bytes split):**
```
board → /dev/ttyUSB1 ← tio (gets some bytes)
                     ← serial-agent daemon (gets other bytes)  ← DATA CORRUPTION
```

**With ser2net (CORRECT — full stream to each):**
```
board → /dev/ttyUSB1 ← ser2net:3001
                              ├─→ tio tcp:localhost:3001         (human, full stream)
                              └─→ serial-agent daemon TCP        (agent, full stream)
```

Generate ser2net config: `serial-agent ser2net-gen --output /tmp/ser2net.yaml`
Install: `sudo cp /tmp/ser2net.yaml /etc/ser2net.yaml && sudo systemctl restart ser2net`

---

## Known Limitations

| Issue | Cause | Workaround |
|-------|-------|------------|
| ttyACM not probed | USB `CDC_SET_LINE_CODING` blocks 12s/baud in kernel D-state | Shows OPEN (fuser) or DEAD; select manually in serial-connect |
| Terminal line wrapping | Board's shell has narrow default terminal | Use `--no-wrap` flag OR `connect --setup-terminal` (runs `stty cols 220`) |
| `--exit-code` with `exit` cmd | `exit` kills shell before EXITCODE echo can run | Use `run DEVICE script.sh` instead |
| Stale daemons after crash | D-state processes can't be SIGKILL'd quickly | `serial-agent stop DEVICE` now uses fuser to kill all holders |
| Root-owned minicom invisible to fuser | `/proc/N/fd/` not readable by other users | `sudo -n fuser` fallback added |
| UBOOT/PANIC detection untested | No live board in final test session | Regex added; state machine logic is correct |

---

## File Roles (quick reference)

| File | Role | Modified by |
|------|------|-------------|
| `~/.config/serial-boards.conf` | Board labels + baud overrides | User / `auto-label` |
| `~/bin/serial-discover` | Port discovery + probing | Never auto-modified |
| `~/bin/serial-connect` | Human interactive terminal launcher | Never auto-modified |
| `~/bin/tio.sh` | Tmux+tio session launcher | Never auto-modified |
| `~/bin/serial-agent` | Agent daemon + CLI | Never auto-modified |
| `~/var/serial-agent/*/` | Runtime state (buf, status, events) | serial-agent daemon |
| `/tmp/serial-agent` | Symlink → ~/var/serial-agent | `serial-agent start` |
| `/tmp/serial-connect.*` | Probe cache | `serial-connect` |

---

*Last updated from chat history: 2026-05-10*
