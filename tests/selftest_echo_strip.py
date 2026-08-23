#!/usr/bin/env python3
"""Red/green selftest: a wait pattern must not match the command's own echo.

`send DEV 'echo DONE' --wait DONE` returned instantly on the echoed command
line, before the board had answered, so the reply was empty or truncated. Cost
two round trips during hardware testing. No hardware required. Exit 0 = GREEN.
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
    if not cond: fails.append(name)

ef = getattr(sa, '_echo_free', None)
check('_echo_free exists', callable(ef))
if callable(ef):
    cases = [
        # (raw new text, command sent, what must survive, what must be gone)
        ("root@am62dxx-evm:~# echo DONE\nDONE\n", "echo DONE", "DONE", "echo DONE"),
        # the wrapped echo the board actually produces, split mid-command
        ("root@x:~# echo MARK\nER_END\nMARKER_END\n", "echo MARKER_END",
         "MARKER_END", None),
        # real output identical to a word inside the command must survive
        ("root@x:~# grep running /sys/state\nrunning\n", "grep running /sys/state",
         "running", None),
        # no echo at all (async output) must pass through untouched
        ("[  12.3] kernel: hello\n", "echo DONE", "kernel: hello", None),
        # empty command must not change anything
        ("anything\n", "", "anything", None),
    ]
    for raw, cmd, must_keep, must_drop in cases:
        out = ef(raw, cmd)
        ok = must_keep in out
        if must_drop is not None:
            ok = ok and must_drop not in out
        check(f'cmd={cmd[:22]!r} keeps {must_keep!r}' +
              (f', drops echo' if must_drop else ''), ok)

    # the whole point: the marker must not be found in the echo alone
    only_echo = ef("root@x:~# echo DONE\n", "echo DONE")
    check('a lone echo line yields nothing to match', 'DONE' not in only_echo)

src = open(AGENT).read()
b = src[src.index('def _wait_pattern('):]
b = b[:b.index('\ndef ', 1)]
check('_wait_pattern accepts the command it is waiting on', 'echo_of' in b)
check('_wait_pattern strips the echo before matching', '_echo_free(' in b)
# the call site lives in the send implementation, wherever that is
check('the send path passes the command through',
      src.count('echo_of=cmd') >= 1)

sys.exit(1 if fails else 0)
