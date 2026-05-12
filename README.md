# serial-connect

Serial port tools for embedded Linux development — discover boards, connect interactively, and automate via CLI.

## Repo layout

```
serial-connect/
├── bin/                    ← all tools and config (deployed together)
│   ├── serial-common.sh    shared functions, sourced by the other scripts
│   ├── serial-discover     probe all USB serial ports, show live boards
│   ├── serial-connect      interactive menu — pick a port and connect
│   ├── serial-agent        background daemon + CLI for automation
│   └── serial-boards.conf  configuration: chip table, probe settings, board labels
├── docs/
│   ├── SERIAL_ARCH.md
│   └── SERIAL_AGENT_GUIDE.md
├── install.sh
└── uninstall.sh
```

## Install

```bash
git clone https://github.com/SenWang125/serial-connect.git
cd serial-connect
./install.sh
```

All files deploy to `~/.serial-connect/` (isolated, named folder). The three CLI tools are symlinked into `~/.local/bin/` which is already in PATH on modern Linux — no PATH changes needed.

Non-interactive install:
```bash
./install.sh --term tio              # recommended
./install.sh --term tio,screen       # install multiple terminals
sudo ./install.sh /usr/local/bin --term tio   # system-wide
```

Uninstall:
```bash
./uninstall.sh    # removes ~/.serial-connect/ and symlinks in ~/.local/bin/
```

**Requirements:** bash ≥ 5.1, python3, user in `dialout` group
**Optional:** `tio` (recommended), `screen` (shareable sessions), `ser2net` (human+agent on same port), `inotify-tools` (faster event notifications)

---

## Usage

```
$ serial-connect
```

```
Select serial port:

  ·     #  Device     Status    Board             Chip      P#   Baud
────────────────────────────────────────────────────────────────────
       1)  ttyACM0    dead      XDS110-S62H0161   XDS110    p0
       2)  ttyACM1    dead      XDS110-S62H0161   XDS110    p1

       3)  ttyUSB0    dead      am62dxx-evm       FT4232H   p0
  ★    4)  ttyUSB1    LIVE      am62dxx-evm       FT4232H   p1   115.2K
       5)  ttyUSB3    dead      am62dxx-evm       FT4232H   p2
       6)  ttyUSB4    dead      am62dxx-evm       FT4232H   p3

       7)  ttyUSB2    dead      CP210x-0001       CP210x    p0

  ★    8)  ttyUSB5    LIVE      am62pxx-evm       FT4232H   p0   115.2K

  ★ LIVE    ⊙ OPEN    ✗ FAIL      dead

Port [1-8]:
```

Ports are grouped by physical device. `★ LIVE` means an active console was detected. `⊙ OPEN` means another process holds the port (serial-connect will offer to force-close it). Override the terminal: `SERIAL_TERM=screen serial-connect`

---

## Tools

### `serial-discover`
Probes all USB serial ports fresh every run. Auto-detects baud rate, captures board hostname from the console.

```bash
serial-discover              # human display
serial-discover --json       # machine-readable output for agents
serial-discover --gen-udev   # generate udev rules for stable port names
```

### `serial-connect`
Interactive menu with cached probe results. Re-probes only on topology change or when a new unlabelled board appears.

### `serial-agent`
Background daemon + CLI for automation. Reads serial output into a ring buffer — agents query it without touching the port directly.

```bash
serial-agent connect --board AM62D2-EVM --wait-shell
serial-agent send /dev/ttyUSB1 "uname -r" --json     # → {"output":"6.6.0","elapsed_ms":50}
serial-agent reboot /dev/ttyUSB1 --setup-terminal
serial-agent upload /dev/ttyUSB1 ./driver.ko /tmp/
serial-agent health /dev/ttyUSB1
serial-agent list
```

---

## Configuration

`serial-boards.conf` lives alongside the scripts in `~/.serial-connect/`. Open it — every setting is documented inline.

**Label your boards** (find serial numbers with `serial-discover`):
```
46241800161=AM62D2-EVM
45241640028=AM62P-EVM:115200
```

Or auto-generate labels from board hostnames:
```bash
serial-agent auto-label -y
```

**Tune discovery speed** — edit these values directly in the conf:
```
PROBE_READ_MS=50       # halve response wait → halve worst-case probe time
PROBE_PARALLEL=8       # cap parallel probes if USB bus gets congested
```

---

## Docs

- [`docs/SERIAL_ARCH.md`](docs/SERIAL_ARCH.md) — architecture and design
- [`docs/SERIAL_AGENT_GUIDE.md`](docs/SERIAL_AGENT_GUIDE.md) — automation patterns for agents

---

## License

MIT
