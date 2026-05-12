# serial-connect

Serial port tools for embedded Linux development — discover boards, connect interactively, and automate via CLI.

## Install

```bash
git clone https://github.com/SenWang125/serial-connect.git
cd serial-connect
./install.sh          # interactive: asks terminal preference, installs deps
```

Non-interactive:
```bash
./install.sh --term tio          # recommended
./install.sh --term tio,screen   # install multiple
./install.sh /usr/local/bin --term tio
```

Scripts install to `~/.serial-connect/` by default. Add to PATH once:
```bash
echo 'export PATH="$HOME/.serial-connect:$PATH"' >> ~/.bashrc
```

Uninstall:
```bash
./uninstall.sh           # removes ~/.serial-connect/ entirely
./uninstall.sh --purge   # also remove serial-boards.conf
```

**Requirements:** bash ≥ 5.1, python3, user in `dialout` group

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

Select a port number to connect. Ports are grouped by physical device.
`★ LIVE` ports have an active console; `⊙ OPEN` ports are held by another process (prompts to force-close).

Override terminal: `SERIAL_TERM=screen serial-connect`

---

## Tools

### `serial-discover`
Probes all USB serial ports, auto-detects baud rate, captures board hostname. Always fresh — no cache.

### `serial-connect`
Interactive menu with cached probe results. Re-probes only on topology change or unknown boards.

### `serial-agent`
Background daemon + CLI for automation. Maintains a ring buffer of serial output; agents query it without touching the port directly.

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

`serial-boards.conf` lives in the same directory as the scripts (`~/.serial-connect/serial-boards.conf` by default). The file is self-documented — open it to see all options. Key things to edit:

**Label your boards** (USB serial number → name, stable across reboots):
```
46241800161=AM62D2-EVM
45241640028=AM62P-EVM:115200
```

**Tune discovery speed:**
```
PROBE_READ_MS=50     # halve response wait → halve worst-case probe time
PROBE_PARALLEL=8     # cap parallel probes if USB bus gets congested
```

Find serial numbers with `serial-discover`, or auto-generate labels:
```bash
serial-agent auto-label -y
```

---

## Docs

- [`docs/SERIAL_ARCH.md`](docs/SERIAL_ARCH.md) — Architecture and design reference
- [`docs/SERIAL_AGENT_GUIDE.md`](docs/SERIAL_AGENT_GUIDE.md) — Automation patterns for agents

---

## License

MIT
