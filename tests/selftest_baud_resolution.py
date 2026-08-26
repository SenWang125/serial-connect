#!/usr/bin/env python3
"""Red/green selftest: a baud that could not be resolved must not read as 115200.

Three separate places answered "I do not know what rate this is" with a valid
rate, and the three compounded into an unreadable console:

  * parse_baud() returned PROBE_BAUDS[0] for anything it could not parse, so a
    typo in serial-boards.conf became a silent 115200 and every "(( b > 0 ))"
    guard downstream was unable to fail.
  * _BAUD_CONST mapped a rate this platform's termios does not define onto
    B115200, so a request for 1500000 could be answered with 115200.
  * `serial-agent start` took its rate from an argparse default of 115200,
    which outranked the board's pin in serial-boards.conf.

The board this was found on has baudrate=1500000 in its U-Boot environment and
a kernel console to match, so the whole boot log arrived as noise and looked
like a transport fault.

Also covers: auto-login must stand down while a human tio session holds the
console, because typing a username underneath someone lands as stray bytes in
their terminal and reads as the link dropping input.

No hardware required. Exit 0 = GREEN.
"""
import importlib.util, os, sys, tempfile, termios
from importlib.machinery import SourceFileLoader
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.environ.get('SERIAL_AGENT_UNDER_TEST') or next(
    p for p in (os.path.join(HERE, 'serial-agent'),
                os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
    if os.path.exists(p))

spec = importlib.util.spec_from_loader('sa_under_test',
                                       SourceFileLoader('sa_under_test', AGENT))
m = importlib.util.module_from_spec(spec)
sys.modules['sa_under_test'] = m
spec.loader.exec_module(m)
src = Path(AGENT).read_text()

fails = []
_MISSING = object()


def sym(name):
    """A symbol the fixed code defines. Missing counts as a failure, not a crash,
    so a run against pre-fix code reports every defect instead of the first."""
    return getattr(m, name, _MISSING)


def ck(name, cond):
    print(f"  [{'ok' if cond else 'FAIL'}] {name}")
    if not cond:
        fails.append(name)


# ── the rate table must not substitute one rate for another ───────────────────
for rate in (1000000, 1500000):
    have = getattr(termios, f'B{rate}', None)
    if have is None:
        ck(f'{rate} absent from termios is absent from the table',
           rate not in m._BAUD_CONST)
    else:
        ck(f'{rate} maps to B{rate}, not B115200',
           m._BAUD_CONST.get(rate) == have and m._BAUD_CONST.get(rate) != termios.B115200)

_bc = sym('_baud_const')
if _bc is _MISSING:
    ck('an unsupported rate raises rather than falling back (_baud_const absent)', False)
else:
    try:
        _bc(12345)
        ck('an unsupported rate raises rather than falling back', False)
    except SystemExit:
        ck('an unsupported rate raises rather than falling back', True)
    except Exception as e:
        ck(f'an unsupported rate raises SystemExit (got {type(e).__name__})', False)

# ── a typo is not a rate ──────────────────────────────────────────────────────
_pb = sym('_parse_baud')
if _pb is _MISSING:
    ck('_parse_baud exists', False)
else:
    ck("_parse_baud('1.5MB') is None", _pb('1.5MB') is None)
    ck("_parse_baud('') is None", _pb('') is None)
    ck("_parse_baud('1.5M')   == 1500000", _pb('1.5M') == 1500000)
    ck("_parse_baud('115.2K') == 115200", _pb('115.2K') == 115200)
    ck("_parse_baud('9600')   == 9600", _pb('9600') == 9600)

# ── the config is consulted, in serial-common.sh's own precedence order ───────
_cb = sym('_conf_baud')
if _cb is _MISSING:
    ck('_conf_baud exists', False)
with tempfile.TemporaryDirectory() as d:
    cfg = Path(d) / 'serial-boards.conf'
    cfg.write_text('ABC123=Board:1.5M\n'
                   '1a86:7523=CH340:9600\n'
                   '0403:xxxx=FTDI:230400\n')
    os.environ['BOARD_CFG'] = str(cfg)
    real = getattr(m, '_dev_usb_ids', None)
    try:
        m._dev_usb_ids = lambda dev: ('ABC123', '1a86:7523')
        ck('per-board pin outranks the chip table', (_cb('/dev/x') if _cb is not _MISSING else 'unresolved') == 1500000)
        m._dev_usb_ids = lambda dev: ('unknown', '1a86:7523')
        ck('chip table is used when the board is not pinned', (_cb('/dev/x') if _cb is not _MISSING else 'unresolved') == 9600)
        m._dev_usb_ids = lambda dev: ('unknown', '0403:6001')
        ck('vendor wildcard is the last resort', (_cb('/dev/x') if _cb is not _MISSING else 'unresolved') == 230400)
        m._dev_usb_ids = lambda dev: ('unknown', 'ffff:ffff')
        ck('a board the config does not mention resolves to None',
           (_cb('/dev/x') if _cb is not _MISSING else 'unresolved') is None)
        m._dev_usb_ids = lambda dev: (None, None)
        ck('an adapter that cannot be identified resolves to None, not a rate',
           (_cb('/dev/x') if _cb is not _MISSING else 'unresolved') is None)
    finally:
        if real is not None:
            m._dev_usb_ids = real
        os.environ.pop('BOARD_CFG', None)

# ── the argparse default must not outrank the config ──────────────────────────
ck("'start --baud' no longer defaults to 115200",
   "sp.add_argument('--baud', type=int, default=115200)" not in src)
ck('cmd_connect no longer starts a daemon at a hardcoded 115200',
   'argparse.Namespace(device=_d, baud=115200' not in src)
ck('cmd_start resolves the configured rate when --baud is omitted',
   '_conf_baud(args.device)' in src)

# ── do not type into a console someone is using ───────────────────────────────
body = src.split('def _maybe_auto_login')[1][:1500] if 'def _maybe_auto_login' in src else ''
ck('auto-login stands down while a human session is active',
   '_human_session_active' in body)

print(f'  {len(fails)} failure(s)')
sys.exit(1 if fails else 0)
