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

The installer asks whether to install for the current user or system-wide:

| Scope | Files | Symlinks | Requires |
|---|---|---|---|
| Local (default) | `~/.serial-connect/` | `~/.local/bin/` | nothing |
| Global | `/usr/local/share/serial-connect/` | `/usr/local/bin/` | sudo |

```bash
./install.sh --local                 # current user only (default)
sudo ./install.sh --global           # all users, system-wide
./install.sh --upgrade               # re-install silently, keep existing choices
./install.sh --term tio              # set default terminal non-interactively
```

**Serial port access (udev rules)**

The installer sets up a udev rule that gives all users access to `/dev/ttyUSB*` and `/dev/ttyACM*` without needing the `dialout` group or a re-login. It also prevents ModemManager from locking ports.

If you don't have sudo (e.g. a guest account), the installer prints the command for an admin to run once:
```bash
sudo cp udev/99-serial-connect.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

**Uninstall:**
```bash
./uninstall.sh                    # stops daemons, removes local install
sudo ./uninstall.sh --global      # stops daemons, removes global install + udev rules
```

**Requirements:** bash ≥ 5.1, python3
**Optional:** `tio`, `screen`, `ser2net`, `inotify-tools`

---

## Shared machine setup

On a machine with multiple users, one user owns the serial-agent daemons and serial ports. Other users can monitor port status and connect via ser2net multiplexing.

**Setup (run as the port owner):**
```bash
# 1. Install globally so all users have the tools
sudo ./install.sh --global

# 2. Start a daemon for each board
serial-agent start /dev/ttyUSB5

# 3. Optional: expose via ser2net so others can attach
serial-agent ser2net-gen | sudo tee /etc/ser2net.yaml
sudo systemctl restart ser2net
```

**Other users** can then:
```bash
serial-connect          # see board status (OPEN = held by another user)
serial-agent list       # see running daemons and board states
```

**Board labels** are stored in two layers:
- `/etc/serial-boards.conf` — chip table + shared labels (admin-managed, read by all users)
- `~/.config/serial-boards.conf` — per-user label overrides (writable without sudo)

Running `serial-connect --label` writes to the per-user conf automatically.

**Diagnose conflicts:**
```bash
serial-connect --doctor   # shows installations, config paths, daemons, lock files
```

---

## serial-connect

Pick a port and connect. Ports are grouped by physical device. Probe results are cached — re-probes only when the device set changes or a new unlabelled board appears.

```
$ serial-connect
Select serial port:

  ·    #   Port       Status    Board             Chip       P#     Baud
────────────────────────────────────────────────────────────────────────────────
  ★    1)  ttyACM0    LIVE      BeagleBone        RPiProbe   0-p0   115.2K

       2)  ttyACM1    dead      XDS110-S62H0161   XDS110     1-p0
  ★    3)  ttyACM2    LIVE      XDS110-S62H0161   XDS110     1-p1   115.2K

  ★    4)  ttyUSB0    LIVE      AM62P5-EVM        FT4232H    2-p0   115.2K
       5)  ttyUSB1    dead      AM62P5-EVM        FT4232H    2-p1
       6)  ttyUSB2    dead      AM62P5-EVM        FT4232H    2-p2
       7)  ttyUSB3    dead      AM62P5-EVM        FT4232H    2-p3

       8)  ttyUSB4    dead      AM62D-EVM         FT4232H    3-p0
  ⊙    9)  ttyUSB5    OPEN      AM62D-EVM         FT4232H    3-p1   115.2K
      10)  ttyUSB6    dead      AM62D-EVM         FT4232H    3-p2
      11)  ttyUSB7    dead      AM62D-EVM         FT4232H    3-p3

  ★   12)  ttyUSB8    LIVE      AM62A7-EVM        FT4232H    4-p0   115.2K
      13)  ttyUSB9    dead      AM62A7-EVM        FT4232H    4-p1
      14)  ttyUSB10   dead      AM62A7-EVM        FT4232H    4-p2
      15)  ttyUSB11   dead      AM62A7-EVM        FT4232H    4-p3

  ★ LIVE    ⊙ OPEN    ✗ FAIL      dead
  use serial-discover             to force a fresh probe
  use serial-discover --gen-udev  for stable port names across reboots
  use serial-discover --tmp-udev  for stable port names current session
  use serial-connect --label      to rename boards

Port [1-15 or P#]:
```

`★ LIVE` — active console detected. `⊙ OPEN` — port held by another process (will offer to force-close). Dead ports are still selectable.

```bash
serial-connect               # interactive menu
serial-connect /dev/ttyUSB1  # direct connect, skip menu
serial-connect --label       # rename boards interactively
serial-connect --help        # show usage
```

Override terminal: `SERIAL_TERM=screen serial-connect`

### Labelling boards

`serial-connect --label` opens an interactive editor to assign human-readable names to connected boards. Labels are saved by USB serial number and persist across reboots and re-enumeration.

```
$ serial-connect --label

Label editor  —  Enter to keep, type a new name to change, - to remove

  ★  FT4232H - ttyUSB0 ttyUSB1 ttyUSB2 ttyUSB3
     Serial Number:  46241800161
     Current Label:  AM62D2-EVM
     Probed Label:   am62dxx-evm
     New Label [AM62D2-EVM]:

  ⊙  XDS110 - ttyACM1 ttyACM2
     Serial Number:  S62H0161
     New Label:

  ✓ Saved 1 change(s)
  Exported to config: ~/.serial-connect/serial-boards.conf
```

- **Current Label** — name already stored in `serial-boards.conf`
- **Probed Label** — hostname captured live from the board's console prompt
- Press **Enter** to keep the current/suggested value; type a new name to change it; type **`-`** to remove an existing label


---

## serial-discover

Probes all `/dev/ttyUSB*` and `/dev/ttyACM*` ports fresh every run. Sends a carriage return, tries each baud rate in order, identifies the board from its console prompt.

```bash
serial-discover              # human display with baud, chip, board name
serial-discover --json                   # all ports as JSON
serial-discover --json | jq '.[] | select(.label=="AM62D2-EVM")' # filter by label
serial-discover --gen-udev   # write /tmp/99-serial-aliases.rules — copy to /etc/udev/rules.d/ to make permanent
serial-discover --tmp-udev   # create /dev/tty<LABEL> symlinks for this session — useful for debugging
                             # or when external tools need a stable /dev path (e.g. minicom -D /dev/ttyMyBoard)
serial-discover --rm-udev    # remove installed rules and session symlinks
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

`~/.serial-connect/serial-boards.conf` (local install) or `/etc/serial-boards.conf` (global install) — open it to see all options with inline docs.

Label boards by USB serial number (stable across reboots and re-enumeration):
```
46241800161=AM62D2-EVM
45241640028=AM62P-EVM:115200
```

Find serial numbers: `serial-discover`
Label boards interactively: `serial-connect --label`
Auto-generate labels from board hostnames: `serial-agent auto-label -y`

---

## Docs

- [`docs/SERIAL_ARCH.md`](docs/SERIAL_ARCH.md) — architecture and design
- [`docs/SERIAL_AGENT_GUIDE.md`](docs/SERIAL_AGENT_GUIDE.md) — automation patterns for agents

---

## License

MIT
