# serial-connect

Three CLI tools for working with USB serial ports on embedded Linux development boards.

- **serial-discover** — probe all connected boards, detect baud rate, show live status
- **serial-connect** — pick a port from a menu and open a terminal session
- **serial-agent**   — background daemon for scripted/automated board interaction

---

## Install

```bash
git clone https://github.com/SenWang125/serial-connect.git
cd serial-connect
./install.sh
```

Files go to `~/.serial-connect/`. The three tools are symlinked into `~/.local/bin/` which is in PATH on modern Linux — no extra setup needed.

```bash
./install.sh --term tio              # set default terminal (recommended)
./install.sh --term tio,screen       # install multiple
sudo ./install.sh /usr/local/bin     # system-wide
```

Uninstall:
```bash
./uninstall.sh    # removes ~/.serial-connect/ and the symlinks
```

**Requirements:** bash ≥ 5.1, python3, user in `dialout` group
**Optional:** `tio`, `screen`, `ser2net`, `inotify-tools`

---

## serial-connect

Pick a port and connect. Ports are grouped by physical device. Probe results are cached — re-probes only when the device set changes or a new unlabelled board appears.

```
$ serial-connect
Select serial port:

  ·     #  Device     Status    Board             Chip      P#   Baud
────────────────────────────────────────────────────────────────────
       1)  ttyACM0    dead      XDS110-S62H0161   XDS110    p0
       2)  ttyACM1    dead      XDS110-S62H0161   XDS110    p1

       3)  ttyUSB0    dead      am62dxx-evm       FT4232H   p0
  ★   4)  ttyUSB1    LIVE      am62dxx-evm       FT4232H   p1   115.2K
       5)  ttyUSB3    dead      am62dxx-evm       FT4232H   p2
       6)  ttyUSB4    dead      am62dxx-evm       FT4232H   p3

       7)  ttyUSB2    dead      CP210x-0001       CP210x    p0

  ★   8)  ttyUSB5    LIVE      am62pxx-evm       FT4232H   p0   115.2K
       9)  ttyUSB6    dead      am62pxx-evm       FT4232H   p1
      10)  ttyUSB7    dead      am62pxx-evm       FT4232H   p2
      11)  ttyUSB8    dead      am62pxx-evm       FT4232H   p3

      12)  ttyUSB9    dead      am62dxx-evm       FT4232H   p0
  ★   13)  ttyUSB10   LIVE      am62dxx-evm       FT4232H   p1   115.2K
      14)  ttyUSB11   dead      am62dxx-evm       FT4232H   p2
      15)  ttyUSB12   dead      am62dxx-evm       FT4232H   p3

  ★   16)  ttyUSB13   LIVE      am62axx-evm       FT4232H   p0   115.2K
      17)  ttyUSB14   dead      am62axx-evm       FT4232H   p1
      18)  ttyUSB15   dead      am62axx-evm       FT4232H   p2
      19)  ttyUSB16   dead      am62axx-evm       FT4232H   p3

  ★ LIVE    ⊙ OPEN    ✗ FAIL      dead
  Run serial-discover to force a fresh probe
  Run serial-discover --gen-udev to fix port numbering across reboots

Port [1-19]:
```

`★ LIVE` — active console detected. `⊙ OPEN` — port held by another process (will offer to force-close). Dead ports are still selectable.

Override terminal: `SERIAL_TERM=screen serial-connect`
Direct connect (skip menu): `serial-connect /dev/ttyUSB1`

---

## serial-discover

Probes all `/dev/ttyUSB*` and `/dev/ttyACM*` ports fresh every run. Sends a carriage return, tries each baud rate in order, identifies the board from its console prompt.

```bash
serial-discover              # human display with baud, chip, board name
serial-discover --json       # JSON output for scripts and agents
serial-discover --gen-udev   # generate udev rules for stable port names across reboots
```

---

## serial-agent

Background daemon that reads serial output continuously into a ring buffer. Scripts and agents query the buffer or send commands without fighting over the port with an interactive terminal.

```bash
serial-agent connect --board AM62D2-EVM --wait-shell   # start daemon, wait for shell prompt
serial-agent send /dev/ttyUSB1 "uname -r" --json       # → {"output":"6.6.0","elapsed_ms":50}
serial-agent reboot /dev/ttyUSB1 --setup-terminal      # reboot and wait for shell
serial-agent upload /dev/ttyUSB1 ./driver.ko /tmp/     # file transfer over serial
serial-agent health /dev/ttyUSB1                        # memory, load, kernel info as JSON
serial-agent list                                       # show running daemons
```

Run `serial-agent --help` for the full command list.

---

## Configuration

`~/.serial-connect/serial-boards.conf` — open it to see all options with inline docs.

Label boards by USB serial number (stable across reboots and re-enumeration):
```
46241800161=AM62D2-EVM
45241640028=AM62P-EVM:115200
```

Find serial numbers: `serial-discover`
Auto-generate labels from board hostnames: `serial-agent auto-label -y`

---

## Docs

- [`docs/SERIAL_ARCH.md`](docs/SERIAL_ARCH.md) — architecture and design
- [`docs/SERIAL_AGENT_GUIDE.md`](docs/SERIAL_AGENT_GUIDE.md) — automation patterns for agents

---

## License

MIT
