#!/usr/bin/env python3
"""Red/green selftest: a wait must not succeed on a prompt that predates it.

_wait_pattern's fast path guarded freshness with `last_prompt_ago < elapsed`.
That value is only recomputed when a byte arrives, so on a board idle at a
prompt it is frozen -- often at 0.0 -- and the guard passes at the first poll.
A wedged board therefore returned success with empty output in 50ms, and
run/upload then pushed their whole chunk stream into a dead console with every
chunk "succeeding". Exit 0 = GREEN.
"""
import json, os, shutil, sys, time
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = next(p for p in (os.path.join(HERE, 'serial-agent'),
                         os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
             if os.path.exists(p))
sa = SourceFileLoader('sa', AGENT).load_module()
sa._daemon_running = lambda dev: True

fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond: fails.append(name)

DEV = '/dev/ttySELFTEST-fresh'
d = sa.devdir(DEV)

def setup(**status):
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True, exist_ok=True)
    base = {'state': 'SHELL', 'quiet_from': '', 'last_prompt_ago': 0.0,
            'prompt_text': 'root@x:~#', 'pid': 1, 'device': DEV}
    base.update(status)
    (d / 'status.json').write_text(json.dumps(base))
    (d / 'stream.log').write_text('')

try:
    check('the daemon publishes a monotonic prompt counter',
          'prompt_seq' in open(AGENT).read())

    setup(prompt_seq=7)                       # board wedged: counter never moves
    t0 = time.time()
    r = sa._wait_pattern(DEV, r'[\$#>]\s*$', 2)
    el = time.time() - t0
    check(f'wedged board times out instead of succeeding (returned {r} in {el:.1f}s)',
          r is False and el >= 1.8)

    # a board that answers: the counter advances while we wait
    setup(prompt_seq=7)
    import threading
    def bump():
        time.sleep(0.4)
        s = json.loads((d / 'status.json').read_text())
        s['prompt_seq'] = 8
        (d / 'status.json').write_text(json.dumps(s))
    threading.Thread(target=bump, daemon=True).start()
    t0 = time.time()
    r = sa._wait_pattern(DEV, r'[\$#>]\s*$', 3)
    el = time.time() - t0
    check(f'a fresh prompt is still matched (returned {r} in {el:.1f}s)',
          r is True and el < 2.0)

    # an old daemon with no counter must still work, not hang forever
    setup()
    s = json.loads((d / 'status.json').read_text()); s.pop('prompt_seq', None)
    (d / 'status.json').write_text(json.dumps(s))
    r = sa._wait_pattern(DEV, r'[\$#>]\s*$', 1)
    check('a daemon without the counter still resolves (no hang)', r in (True, False))
finally:
    shutil.rmtree(d, ignore_errors=True)

sys.exit(1 if fails else 0)
