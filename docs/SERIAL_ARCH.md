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

serial-connect  ────────────────────────────────────────────────────────────► human terminal (tio)
  • interactive menu with live probe
  • cache: /tmp/serial-connect-USER.{sig,cache} — avoids reprobing on each run
  • selective re-probe: only unrecognized boards checked each run
  • auto-starts serial-agent --idle-timeout 0 (always-on) if not running
  • connects tio via socat PTY bridge to daemon's built-in relay
  • daemon PERSISTS after serial-connect exits — not stopped on session end
  • HUPCL cleared before probe + sudo -n fuser for root-owned sessions

tio.sh [N|/dev/ttyXXX] [baud]  ────────────────────────────────────────────► tmux session
  • named tmux session per device (reattaches if exists)
  • tio with unix socket: /tmp/ttyUSBx.sock  ← socat can share it

serial-agent built-in TCP relay  (automatic, no configuration needed)
  • daemon binds 127.0.0.1 port on startup (RELAY_BASE_PORT range if set, else ephemeral)
  • fans bytes to all TCP clients (full stream to each)
  • status.json 'relay' field: "host:port" — serial-connect reads this to locate the relay
  • serial-connect bridges to tio via socat PTY (tio v2.7 has no tcp: device support)
  • multiple socat clients can share the relay simultaneously (read-only observation)

ser2net  (optional, for multi-user / network access)
  • holds physical serial port exclusively, fans to TCP clients
  • takes precedence over built-in relay when configured
  • config: /etc/ser2net.yaml  (generate with: serial-agent ser2net-gen)

serial-agent daemon ──────────────────────────────────────────────────────► ~/var/serial-agent/DEVICE/
  • connects via TCP (ser2net) or direct to /dev/ttyUSBx
  • reads ALL serial output continuously into ring buffer
  • state machine (see below)
  • events.log: state transition log (capped at 200 lines)
  • input FIFO: /dev/ttyUSBx write path → daemon reads → sends to serial
  • TIOCSWINSZ: sets 220×50 terminal size to prevent board line-wrapping
  • HUPCL cleared: prevents DTR deassert killing board sessions
  • output FIFO: mirrors every raw serial chunk (drop-safe, O_WRONLY|O_NONBLOCK)
    → `watch` consumers get push results with no polling latency (~0.2ms)

serial-agent CLI  ←──────────────────────────────────────────────────────── agent / scripts
  • reads from ~/var/serial-agent/ files (no serial port access)
  • writes commands to input.fifo (non-blocking O_NONBLOCK with retry)
  • `watch`: reads output.fifo (kernel-blocking), matches regex, returns on hit;
    --send fires the command with the read side already open (no early loss)
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
    output.fifo                     Push channel: daemon mirrors every raw serial
                                    chunk here; `watch` (or `cat`) reads it for
                                    real-time (~0.2ms) results. Single-consumer,
                                    drop-safe (non-blocking write, never stalls
                                    the serial reader).

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

## Coexistence (tio + serial-agent)

**Design principle: daemon = always-on observer; tio = transparent window.**

The daemon holds the physical port continuously (always-on mode, `--idle-timeout 0`).
tio connects via a socat PTY bridge to the daemon's built-in TCP relay.  The daemon
runs before tio opens and after tio exits — it is never stopped by serial-connect.

```
board → /dev/ttyUSB1 ← serial-agent daemon (always-on, holds fd)
                              │ TCP relay 127.0.0.1:PORT
                              ├─→ socat PTY /tmp/ttyUSB1-USER-PID-pty  (tio opens this)
                              └─→ any other TCP client (read-only observer)
```

**Startup probe:** When the daemon first opens the physical port, it sends a bare CR
0.5 s after connection if no output has been received.  This wakes an idle board from
UNKNOWN → SHELL before the human even connects.  The probe is NOT suppressed by an
active human session — a single CR is harmless and necessary to bootstrap state.

**Session lifecycle:**
1. serial-connect checks for daemon; if absent, starts one (`--idle-timeout 0`)
2. Daemon opens physical port immediately; startup probe fires within 0.5 s
3. serial-connect starts socat → PTY appears → tio opens it → human session active
4. human_session file written; heartbeat refreshes it every 60 s
5. On exit: heartbeat killed → socat killed → lock/human_session released → **daemon left running**
6. Next serial-connect session: daemon already running, state already known — instant connect

**Optional — ser2net (multi-user / network access):**
```
board → /dev/ttyUSB1 ← ser2net:3001
                              ├─→ tio tcp:localhost:3001         (human, full stream)
                              └─→ serial-agent daemon TCP        (agent, full stream)
```
Generate ser2net config: `serial-agent ser2net-gen --output /tmp/ser2net.yaml`
Install: `sudo cp /tmp/ser2net.yaml /etc/ser2net.yaml && sudo systemctl restart ser2net`

**Auto-leverage:** when ser2net is configured for a device, ALL entry points route
through it automatically — `connect`/`discover` propose it, and `start` now detects it
too (config-based; explicit `--tcp` overrides, `--no-ser2net` forces direct). Everything
downstream (buffer, state machine, `send`, `expect`, and the `watch`/`output.fifo` push
channel) works identically over the ser2net TCP transport as over a direct port, because
the daemon's read loop feeds `_append` the same way regardless of source. Detection reads
`/etc/ser2net.yaml`|`.conf`, or `$SERIAL_SER2NET_CONF` if set (non-root installs / tests).

---

## Known Limitations

| Issue | Cause | Workaround |
|-------|-------|------------|
| ttyACM not probed | USB `CDC_SET_LINE_CODING` blocks 12s/baud in kernel D-state | Shows OPEN (fuser) or DEAD; select manually in serial-connect |
| Terminal line wrapping | Board's shell has narrow default terminal | Use `--no-wrap` flag OR `connect --setup-terminal` (runs `stty cols 220`) |
| `--exit-code` with `exit` cmd | `exit` kills shell before EXITCODE echo can run | Use `run DEVICE script.sh` instead |
| Stale daemons after crash | D-state processes can't be SIGKILL'd quickly | `serial-agent stop DEVICE` now uses fuser to kill all holders |
| Devices without USB serial# | Bash 5.2 rejects empty string as array subscript | Synthetic key derived from device basename (e.g. `ttyUSB24`) |
| Old daemon (--idle-timeout 10) | Daemon started before always-on fix | `serial-agent stop DEVICE && serial-agent start DEVICE --idle-timeout 0` |

---

## File Roles (quick reference)

| File | Role | Modified by |
|------|------|-------------|
| `/etc/serial-boards.conf` | System conf: chip table + probe settings + board labels | Admin / `sudo` |
| `~/.config/serial-connect/boards.conf` | Per-user label overrides (shadows system conf key-by-key) | User / `auto-label` / `--label` |
| `/usr/local/share/serial-connect/serial-*` | Installed scripts (global) | `sudo cp` |
| `~/bin/serial-*.old` | Local development copies (not active) | Manual edit |
| `~/var/serial-agent/*/` | Runtime state (buf, status, events, human_session) | serial-agent daemon / serial-connect |
| `~/var/serial-agent/*/output.fifo` | Push channel for `watch` (real-time results); single-consumer, drop-safe | serial-agent daemon (write) / `watch`,`cat` (read) |
| `/tmp/serial-agent` | Symlink → ~/var/serial-agent | `serial-agent start` |
| `/tmp/serial-connect-USER.{sig,cache}` | Per-user probe cache | `serial-connect` |
| `/tmp/serial-connect-locks/DEVNAME` | Active session lock (PID + USER) | serial-connect `_lock_acquire` |

---

*Last updated: 2026-07-25 — output.fifo push channel + `watch` command (real-time,
~0.2ms results); `expect` reads stream.log (ring-truncation fix); `start` auto-leverages
ser2net when configured (`--no-ser2net` / `$SERIAL_SER2NET_CONF`)*
