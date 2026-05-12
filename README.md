# serial-connect

Serial port tools for embedded Linux development — discover boards, connect interactively, and automate via CLI.

## Install

```bash
git clone https://github.com/senwang125/serial-connect.git
cd serial-connect
./install.sh          # interactive: asks terminal preference, installs deps
```

Or non-interactive:
```bash
./install.sh --term tio          # recommended
./install.sh --term screen       # shareable sessions
./install.sh /usr/local/bin --term minicom
```

**Requirements:** bash ≥ 5.1, python3, user in `dialout` group
**Optional:** `tio` (recommended terminal), `ser2net` (human+agent coexistence), `inotify-tools` (faster event notifications)

---

## Quick start

```bash
serial-discover              # probe all USB serial ports, show live boards
serial-connect               # pick a board from a menu and connect
serial-connect /dev/ttyUSB1  # connect directly (skips menu)
```

Label your boards by USB serial number (stable across reboots):
```bash
serial-agent auto-label -y   # auto-generates labels from board hostnames
# or edit ~/.config/serial-boards.conf manually:
#   46241800161=MY-BOARD
```

---

## Tools

### `serial-discover`
Probes all `/dev/ttyUSB*` and `/dev/ttyACM*` ports. Auto-detects baud rate (115.2K → 1.5M → 921.6K → ...), captures the board's hostname from its console output.

```
  ★  ttyUSB1    LIVE    am62dxx-evm       FT4232H   p1   115.2K
     ttyUSB0    dead    FT4232H-161       FT4232H   p0
     ttyUSB4    dead    CP210x-0001       CP210x    p0
```

### `serial-connect`
Interactive menu showing all ports with live/dead/open status. Select a number to connect via your configured terminal (tio/screen/minicom).

- Caches probe results — re-probes only when topology changes or unknown boards appear
- Groups ports by physical device (stable even if ttyUSBN order changes after reboot)
- Override terminal: `SERIAL_TERM=screen serial-connect`

### `serial-agent`
Background daemon + CLI for automation. Reads all serial output continuously into a ring buffer. Agents query the buffer without touching the serial port directly.

```bash
serial-agent connect --board MY-BOARD --wait-shell  # discover + start + wait
serial-agent send /dev/ttyUSB1 "uname -r" --json    # → {"output":"6.6.0","elapsed_ms":50}
serial-agent reboot /dev/ttyUSB1 --setup-terminal   # reboot + wait for shell
serial-agent upload /dev/ttyUSB1 ./driver.ko /tmp/  # file transfer (no network needed)
serial-agent health /dev/ttyUSB1                    # memory/load/kernel JSON
serial-agent list                                    # show running daemons
```

State machine: `SHELL` → `RUNNING` → `SHELL`  |  `BOOTING` → `LOGIN` → `SHELL`  |  `PANIC` → reboot

---

## Human + agent on the same port

Without `ser2net`, a human terminal and a background daemon split the byte stream. With `ser2net`:

```bash
serial-agent ser2net-gen && sudo cp /tmp/ser2net.yaml /etc/ser2net.yaml
sudo systemctl restart ser2net

serial-agent start /dev/ttyUSB1 --tcp localhost:3001  # daemon via ser2net
serial-connect                                         # human session via TCP
```

---

## Configuration

`~/.config/serial-boards.conf` maps USB adapter serial numbers to board labels:

```
# SERIAL=LABEL  or  SERIAL=LABEL:BAUD
46241800161=MY-AM62-BOARD
0001=OrangePi5Plus:1500000
```

The USB serial number is the key — it follows the hardware across reboots.
Find serial numbers with: `serial-discover` (shown in the Board column for unknown boards).

---

## Docs

- [`docs/SERIAL_ARCH.md`](docs/SERIAL_ARCH.md) — Architecture and design reference
- [`docs/SERIAL_AGENT_GUIDE.md`](docs/SERIAL_AGENT_GUIDE.md) — Automation patterns for agents

---

## License

MIT
