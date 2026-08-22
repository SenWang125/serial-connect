#!/usr/bin/env python3
"""Red/green selftest: a self-injected <<serial-agent GAP ...>> annotation must
not be read back as board output and reported as a live shell prompt.

No hardware required.  Exits 0 on GREEN, 1 on RED.
"""
import os, shutil, sys
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = next(p for p in (os.path.join(HERE, 'serial-agent'),
                         os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
             if os.path.exists(p))
sa = SourceFileLoader('sa', AGENT).load_module()

DEV = '/dev/ttySELFTEST-gap'
ddir = sa.devdir(DEV)

def run():
    d = sa.Daemon(DEV, None, 115200, 500, 0)
    d.state = d._prev_state = 'DEAD'
    d._update_state('\n<<serial-agent GAP 2.2s — port reopened; board '
                    'output during this window may be lost>>\n')
    return d.state, d.prompt_text

def check_real_prompt_still_detected():
    d = sa.Daemon(DEV, None, 115200, 500, 0)
    d.state = d._prev_state = 'BOOTING'
    d._update_state('root@am62dxx-evm:~# ')
    return d.state, d.prompt_text

try:
    state, prompt = run()
    ok_gap = (state != 'SHELL')
    print(f"gap-marker      -> state={state!r} prompt={prompt!r}  "
          f"{'PASS' if ok_gap else 'FAIL (dead port reports SHELL)'}")

    state2, prompt2 = check_real_prompt_still_detected()
    ok_real = (state2 == 'SHELL' and prompt2 == 'root@am62dxx-evm:~#')
    print(f"real prompt     -> state={state2!r} prompt={prompt2!r}  "
          f"{'PASS' if ok_real else 'FAIL (regression: real prompt missed)'}")
finally:
    shutil.rmtree(ddir, ignore_errors=True)

sys.exit(0 if (ok_gap and ok_real) else 1)
