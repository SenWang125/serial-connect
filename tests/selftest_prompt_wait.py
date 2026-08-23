#!/usr/bin/env python3
"""Red/green selftest: deciding "is this waiting for a prompt?" by string
equality misses every pattern that merely contains the prompt regex.

_wait_pattern's fast path fired only when the pattern was EXACTLY
`[\\$#>]\\s*$` or contained "SHELL". cmd_login waits on
`Password|[\\$#>]\\s*$`, so it never fired -- and since a prompt has no
trailing newline it never reaches buf.log either. Measured on a real board:
`send 'root'` recorded elapsed_ms 10026 timed_out=true while the login had in
fact succeeded. Ten seconds burned on every login. Exit 0 = GREEN.
"""
import os, re, sys
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

sp = getattr(sa, '_seeks_prompt', None)
check('_seeks_prompt exists', callable(sp))
if callable(sp):
    for pattern, want, why in (
            (r'[\$#>]\s*$',              True,  'the default prompt wait'),
            (r'Password|[\$#>]\s*$',     True,  "cmd_login's wait -- the bug"),
            (r'root@am62dxx-evm:~#',     True,  'an explicit prompt string'),
            (r'#',                       True,  'a bare hash'),
            (r'=>',                      True,  'a U-Boot prompt'),
            (r'SHELL',                   False, 'a user marker, not a prompt'),
            (r'SHELL_READY',             False, 'a user marker containing SHELL'),
            (r'MARKER_END',              False, 'a caller-built marker'),
            (r'card0|FAIL|Error',        False, 'a result pattern'),
            (r'PS_DONE',                 False, 'a runtime marker')):
        got = sp(re.compile(pattern), pattern)
        check(f'{pattern!r} -> {got}  ({why})', got == want)

src = open(AGENT).read()
b = src[src.index('def _wait_pattern('):]
b = b[:b.index('\ndef ', 1)]
check('_wait_pattern uses it instead of comparing strings',
      '_seeks_prompt(' in b and "pat.pattern == r'[\\$#>]\\s*$'" not in b)

sys.exit(1 if fails else 0)
