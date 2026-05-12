# serial-connect

Serial port management tools for embedded Linux development.

Designed for engineers working with development boards (TI AM62x, Raspberry Pi,
Rockchip, etc.) that expose a Linux console over USB serial. Replaces ad-hoc
`minicom`/`pyserial` workflows with a consistent, automation-friendly toolset.

---

## What's included

| Tool | Purpose |
|------|---------|
| `serial-discover` | Probe all USB serial ports, auto-detect baud, identify boards from console output |
| `serial-connect` | Interactive menu → launch terminal session (tio/screen/minicom) |
| `tio.sh` | Quick tmux+tio session launcher with session sharing |
| `serial-agent` | Background daemon + 25-command CLI for agent/automation use |

---

## Prerequisites

**Required:**
- Linux with `/dev/ttyUSB*` or `/dev/ttyACM*` devices
- `bash` ≥ 5.1 (for `wait -t`)
- `python3` ≥ 3.8
- `tio` — recommended terminal (`sudo apt install tio`)
- User in `dialout` group: `sudo usermod -aG dialout $USER`

**Optional (but recommended):**
- `ser2net` — serial port multiplexer, allows human + agent simultaneous access (`sudo apt install ser2net`)
- `inotify-tools` — instant event notifications instead of polling (`sudo apt install inotify-tools`)
- `screen` — alternative terminal with session sharing (`sudo apt install screen`)

---

## Installation

```bash
git clone https://github.com/youruser/serial-connect.git
cd serial-connect
./install.sh
```

Or install to a custom directory:
```bash
./install.sh /usr/local/bin
```

The install script copies the tools to `~/bin/` (default) and creates a starter
`~/.config/serial-boards.conf` if one doesn't already exist.

---

## Quick start

### 1. Discover connected boards

```bash
serial-discover
```

Probes all USB serial ports, auto-detects baud rate (115200 → 1.5M → 921.6K → ...),
captures the board's hostname from its console output.

```
  ·  Device     Status    Board             Chip      P#   Baud
────────────────────────────────────────────────────────────────
  ★  ttyUSB1    LIVE      am62dxx-evm       FT4232H   p1   115.2K
     ttyUSB0    dead      FT4232H-161       FT4232H   p0
     ttyUSB4    dead      CP210x-0001       CP210x    p0
```

### 2. Connect interactively

```bash
serial-connect
```

Shows a menu of all ports with live status. Select a number to connect.

### 3. Label your boards

Once a board is LIVE and you know what it is, add it to `~/.config/serial-boards.conf`:

```
# Format: USB_SERIAL_NUMBER=BOARD_LABEL
# Find the serial number from the LIVE row in serial-discover
46241800161=MY-BOARD-A
45241640028=MY-BOARD-B
```

Or use auto-label to generate names from the board's own hostname:
```bash
serial-agent auto-label -y
```

### 4. Start the agent daemon (for automation)

```bash
# Direct connection
serial-agent start /dev/ttyUSB1

# Via ser2net (coexists with human tio session)
serial-agent start /dev/ttyUSB1 --tcp localhost:3001
```

---

## Configuration (`~/.config/serial-boards.conf`)

Maps USB adapter serial numbers to board labels. The serial number is the
stable hardware identifier — it follows the physical adapter across reboots
and USB re-enumeration.

```
# SERIAL=LABEL
# SERIAL=LABEL:BAUD    (explicit baud override, e.g. 1500000 for Rockchip boards)

46241800161=MY-AM62-BOARD
0001=OrangePi5Plus:1500000
E663B035979A7725=RPi4B
```

Run `serial-discover` to see USB serial numbers for connected devices.

---

## serial-agent reference

The daemon reads all serial output continuously and exposes it via CLI. Agents
never need to open the serial port directly.

```bash
# Session setup
serial-agent list                              # show running daemons
serial-agent auto-label -y                    # label connected boards
serial-agent connect --board MY-BOARD --wait-shell --setup-terminal

# Sending commands (structured output)
serial-agent send /dev/ttyUSB1 "uname -r" --json
# → {"output":"6.6.0","state":"SHELL","elapsed_ms":50,"exit_code":null}

serial-agent send /dev/ttyUSB1 "make test" --json --exit-code --timeout 120

# State-aware waiting (event-driven, uses inotifywait if available)
serial-agent wait-state /dev/ttyUSB1 SHELL --timeout 90   # wait for boot
serial-agent expect /dev/ttyUSB1 \
    --on "READY=~#" --on "PANIC=Kernel panic" --timeout 120

# Embedded dev operations
serial-agent reboot  /dev/ttyUSB1 --setup-terminal --timeout 120
serial-agent upload  /dev/ttyUSB1 ./my-driver.ko /lib/modules/extra/
serial-agent run     /dev/ttyUSB1 ./test-script.sh --json --timeout 60
serial-agent health  /dev/ttyUSB1    # memory/load/kernel/uptime JSON
```

Full command reference: `serial-agent --help` or see `docs/SERIAL_AGENT_GUIDE.md`.

---

## Coexistence: human + agent on same port

Without ser2net, a human tio session and a background agent daemon share bytes
(data corruption). With ser2net:

```
board → /dev/ttyUSB1 → ser2net:3001
                            ├─→ tio (human session, full stream)
                            └─→ serial-agent daemon (full stream)
```

Setup:
```bash
serial-agent ser2net-gen                     # generates /etc/ser2net.yaml
sudo cp /tmp/ser2net.yaml /etc/ser2net.yaml
sudo systemctl restart ser2net

serial-agent start /dev/ttyUSB1 --tcp localhost:3001
tio.sh 1                                     # human session via TCP
```

---

## Terminal backends

`serial-connect` supports multiple terminal emulators via `$SERIAL_TERM`:

```bash
SERIAL_TERM=tio     serial-connect   # default, modern, auto-reconnects
SERIAL_TERM=screen  serial-connect   # shareable sessions (screen -x ttyUSBx)
SERIAL_TERM=minicom serial-connect   # classic
```

---

## Known limitations

- **`/dev/ttyACM` ports are not probed** — USB CDC ACM devices (XDS110, RPi Debug Probe)
  block the kernel for ~12s per baud attempt when the remote device is inactive.
  They show as OPEN (if held) or dead (if free) and can still be selected manually.

- **Terminal wrapping** — Use `send --no-wrap` or `connect --setup-terminal` to run
  `stty cols 220` on the board and prevent line wrapping in captured output.

- **File upload speed** — Base64 serial transfer (~1 KB/s). Use
  `upload --via-network` when the board has network access (~1 MB/s via wget).

---

## File layout

```
~/.config/serial-boards.conf    ← board labels (edit this)
~/bin/serial-discover            ← port discovery
~/bin/serial-connect             ← interactive terminal launcher
~/bin/tio.sh                     ← tmux+tio session launcher
~/bin/serial-agent               ← daemon + CLI
~/var/serial-agent/ttyUSBx/     ← runtime state (buf.log, status.json, events.log)
/tmp/serial-agent → ~/var/...   ← symlink (auto-created, clears on reboot)
```

---

## Docs

- [`docs/SERIAL_ARCH.md`](docs/SERIAL_ARCH.md) — Architecture and design reference
- [`docs/SERIAL_AGENT_GUIDE.md`](docs/SERIAL_AGENT_GUIDE.md) — Agent automation patterns

---

## License

MIT
