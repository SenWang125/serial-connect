#!/usr/bin/env python3
"""Red/green selftest: a kernel log line is not a shell prompt.

RE_SHELL is `[\\$#>]\\s*$`, so any kernel message ending in '>' -- an email
address in angle brackets is enough -- was recorded as the shell prompt and set
the state to SHELL. Seen on a real board: `serial-agent list` displayed a
pps_core boot line as the prompt for nearly four hours, and the console was
actually sitting at a login prompt. No hardware required. Exit 0 = GREEN.
"""
import os, shutil, sys
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = next(p for p in (os.path.join(HERE, 'serial-agent'),
                         os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
             if os.path.exists(p))
sa = SourceFileLoader('sa', AGENT).load_module()

DEV = '/dev/ttySELFTEST-prompt'
fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond: fails.append(name)

def feed(text, start='BOOTING'):
    d = sa.Daemon(DEV, None, 115200, 500, 0)
    d.state = d._prev_state = start
    d._update_state(text)
    return d.state, d.prompt_text

try:
    # the exact line from the board
    KERN = ('[    0.540800] pps_core: Software ver. 5.3.6 - '
            'Copyright 2005-2007 Rodolfo Giometti <giometti@linux.it>\n')
    st, pt = feed(KERN)
    check(f'kernel line ending in ">" is not SHELL (got {st})', st != 'SHELL')
    check('kernel line is not stored as the prompt', 'pps_core' not in pt)

    for line in ('[ 9812.391023] sof-audio-of-ti-c7x: buf=786432 addr=0xc0300000>\n',
                 '[   14.336963] bridge: filtering via arp/ip/ip6tables <foo@bar>\n'):
        st, _ = feed(line)
        check(f'kernel line not SHELL: {line[:34]!r}', st != 'SHELL')

    # real prompts must still be detected
    st, pt = feed('root@am62dxx-evm:~# ')
    check('real shell prompt still detected', st == 'SHELL' and pt == 'root@am62dxx-evm:~#')
    st, pt = feed('# ')
    check('bare root prompt still detected', st == 'SHELL')
    st, _ = feed('=> ', start='BOOTING')
    check('U-Boot prompt still detected', st == 'UBOOT')
    st, _ = feed('am62dxx-evm login: ')
    check('login prompt still detected', st == 'LOGIN')
finally:
    shutil.rmtree(sa.devdir(DEV), ignore_errors=True)

sys.exit(1 if fails else 0)
