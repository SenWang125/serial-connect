#!/usr/bin/env python3
"""Red/green selftest: the three predicates cmd_reboot learned must be available
to every other caller that writes to the console or judges success by a state.

cmd_reboot now asks: is there a login in front of me / which prompt dialect is
this / did anything actually happen. cmd_boot, alive, upload, health, read and
the raw fifo writers could not ask, so each repeats one of the same three bugs.
No hardware required.  Exit 0 = GREEN.
"""
import os, sys
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = next(p for p in (os.path.join(HERE, 'serial-agent'),
                         os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
             if os.path.exists(p))
sa = SourceFileLoader('sa', AGENT).load_module()
src = open(AGENT).read()

fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond: fails.append(name)

def body_of(fn):
    b = src[src.index(f'def {fn}('):]
    return b[:b.index('\ndef ', 1)]

print('1. a boot that captured nothing is not a boot')
bo = getattr(sa, '_boot_outcome', None)
check('_boot_outcome exists', callable(bo))
if callable(bo):
    for st, reached, nlines, want in (
            ('UBOOT', True,  0,  'nothing'),   # already at prompt, never reset
            ('SHELL', True,  0,  'nothing'),   # ALREADY fast path, never reset
            ('SHELL', True,  400,'up'),
            ('LOGIN', True,  400,'up'),
            ('UBOOT', True,  400,'up'),
            ('PANIC', True,  400,'frozen'),
            ('FROZEN',True,  400,'frozen'),
            ('?',     False, 0,  'timeout')):
        got = bo(st, reached, nlines)
        check(f'state={st} reached={reached} lines={nlines} -> {got}', got == want)
    check('_boot_capture uses it', '_boot_outcome(' in body_of('_boot_capture'))

print()
print('2. U-Boot is a console, not a dead board')
iu = getattr(sa, '_is_uboot', None)
check('_is_uboot exists', callable(iu))
if callable(iu):
    for st, want in (({'state': 'UBOOT'}, True),
                     ({'state': 'QUIET', 'quiet_from': 'UBOOT'}, True),
                     ({'state': 'SHELL'}, False),
                     ({'state': 'QUIET', 'quiet_from': 'LOGIN'}, False),
                     ({}, False)):
        check(f'{st} -> {iu(st)}', iu(st) == want)
    check('cmd_alive asks it',      '_is_uboot(' in body_of('cmd_alive'))
    check('_wait_pattern asks it',  '_is_uboot(' in body_of('_wait_pattern'))

print()
print('3. every console writer asks whether a login is in front of it')
for fn in ('cmd_boot', 'cmd_upload'):
    check(f'{fn} guards the console', '_maybe_auto_login(' in body_of(fn))
check('cmd_boot translates the reset command for the dialect',
      '_reboot_cmd(' in body_of('cmd_boot'))

print()
print('4. a fifo write that never left the host is not a send')
for fn in ('cmd_watch', 'cmd_boot'):
    b = body_of(fn)
    has_flag = 'sent' in b and 'not accepting input' in b
    check(f'{fn} reports a failed fifo write', has_flag)

print()
print('5. exit 0 must mean something happened')
check('cmd_health does not exit 0 having gathered nothing',
      'sys.exit(0 if' in body_of('cmd_health') or '_health_exit' in body_of('cmd_health'))
check('cmd_read does not exit 0 with no log at all',
      "sys.exit(0)" not in body_of('cmd_read').split('no buffer')[0])

sys.exit(1 if fails else 0)
