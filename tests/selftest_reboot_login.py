#!/usr/bin/env python3
"""Red/green selftest: `serial-agent reboot` must not fire into a login prompt.

A console parked at `login:` consumes the reboot command as a username, so the
board never reboots and the console is left at `Password:` — which reads as the
serial transport corrupting input.  No hardware required.  Exit 0 = GREEN.
"""
import os, sys
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = next(p for p in (os.path.join(HERE, 'serial-agent'),
                         os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
             if os.path.exists(p))
sa = SourceFileLoader('sa', AGENT).load_module()

fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond:
        fails.append(name)

print('1. login state is classified before the reboot command is sent')
act = getattr(sa, '_reboot_login_action', None)
check('_reboot_login_action exists', callable(act))
if callable(act):
    for st, want in (({'state': 'LOGIN'},                        'login'),
                     ({'state': 'PASSWORD'},                     'login'),
                     ({'state': 'QUIET', 'quiet_from': 'LOGIN'}, 'login'),
                     ({'state': 'QUIET', 'quiet_from': 'PASSWORD'}, 'login'),
                     ({'state': 'SHELL'},                        'send'),
                     ({'state': 'RUNNING'},                      'send'),
                     ({'state': 'UBOOT'},                        'send'),
                     ({},                                        'send')):
        got = act(st)
        check(f'{st} -> {got}', got == want)

print('2. cmd_reboot consults it BEFORE writing to input.fifo')
src = open(AGENT).read()
body = src[src.index('def cmd_reboot('):]
body = body[:body.index('\ndef ', 1)]
i_guard = body.find('_reboot_login_action')
i_write = body.find('input.fifo')
check('guard present in cmd_reboot', i_guard != -1)
check('guard precedes the fifo write', i_guard != -1 and i_write != -1 and i_guard < i_write)

print('3. a board that never went down is reported, whatever state it is in')
check("warning is not restricted to SHELL/RUNNING",
      "('SHELL', 'RUNNING')" not in body)

sys.exit(1 if fails else 0)
