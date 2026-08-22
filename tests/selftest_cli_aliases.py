#!/usr/bin/env python3
"""Red/green selftest: the flag forms agents actually reach for must be accepted.

Mined from 9,956 real serial-agent invocations across 739 past sessions: 191 bash
cells got a `usage:` dump back for a flag that does not exist. Each case below is
a form that was typed, rejected, and then re-typed differently — the tool should
have taken the first one.  No hardware required.  Exit 0 = GREEN.
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = next(p for p in (os.path.join(HERE, 'serial-agent'),
                         os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
             if os.path.exists(p))
DEV = 'ttySELFTEST-cli'          # no daemon: parsing must still succeed

REJECTS = ('unrecognized arguments', 'invalid choice', 'expected one argument',
           'are required')

# argparse rejects instantly (exit 2); anything that blocks got PAST parsing,
# which is what we are asserting. Stateful subcommands are never executed.
CASES = [
    # (argv, what was typed in the wild, sessions that hit it)
    (['tail', DEV, '--lines', '25'],       'tail --lines N',        'c4ac0bfd x14'),
    (['tail', DEV, '-n', '40'],            'tail -n N',             'c4ac0bfd x10'),
    (['login', DEV, '--timeout', '90'],    'login --timeout N',     'c4ac0bfd x15'),
    (['send', DEV, 'x', '--until', 'M'],   'send --until (watch-only flag)', 'c4ac0bfd'),
    (['watch', DEV, '--pattern', '.'],     'watch --pattern',       'agent-ad, d5495d5b'),
    (['expect', DEV, 'aplay_rc='],         'expect POSITIONAL',     '1cc6f3e1'),
    (['list', '--verbose'],                'list --verbose',        'agent-ab, agent-a0'),
]

fails = []
for argv, typed, seen in CASES:
    try:
        r = subprocess.run([sys.executable, AGENT] + argv,
                           capture_output=True, text=True, timeout=4)
        err = (r.stderr or '') + (r.stdout or '')
    except subprocess.TimeoutExpired:
        err = ''            # blocked => argparse accepted it
    bad = next((m for m in REJECTS if m in err), None)
    if bad:
        print(f"  FAIL  {typed:38} -> argparse rejected it ({bad!r})   [{seen}]")
        fails.append(typed)
    else:
        print(f"  PASS  {typed:38} accepted   [{seen}]")

print()
print('help text must name the alias so it is discoverable')
for sub, needle in (('send', '--until'), ('watch', '--pattern'), ('tail', '--lines'),
                    ('connect', '--device')):
    h = subprocess.run([sys.executable, AGENT, sub, '--help'],
                       capture_output=True, text=True, timeout=30).stdout
    ok = needle in h
    print(f"  {'PASS' if ok else 'FAIL'}  {sub} --help mentions {needle}")
    if not ok:
        fails.append(f'{sub} --help')

print()
print('auto-login must work for QUIET<-LOGIN, the state it was written for')
import json, shutil, tempfile
from importlib.machinery import SourceFileLoader
sa = SourceFileLoader('sa', AGENT).load_module()
QDEV = 'ttySELFTEST-quiet'
qd = sa.devdir(QDEV); qd.mkdir(parents=True, exist_ok=True)
(qd / 'status.json').write_text(json.dumps(
    {'state': 'QUIET', 'quiet_from': 'LOGIN', 'prompt_text': '',
     'pid': 1, 'device': '/dev/' + QDEV}))
try:
    r = subprocess.run([sys.executable, AGENT, 'login', QDEV],
                       capture_output=True, text=True, timeout=30)
    err = (r.stderr or '') + (r.stdout or '')
    ok = 'Unexpected state' not in err
    print(f"  {'PASS' if ok else 'FAIL'}  login accepts QUIET<-LOGIN"
          f"{'' if ok else '  -> ' + err.strip().splitlines()[0]}")
    if not ok: fails.append('login QUIET')
    # _needs_login and cmd_login must agree, or auto-login is inert
    agree = sa._needs_login({'state': 'QUIET', 'quiet_from': 'LOGIN'}) and ok
    print(f"  {'PASS' if agree else 'FAIL'}  _needs_login and cmd_login agree on QUIET<-LOGIN")
    if not agree: fails.append('guard disagreement')
finally:
    shutil.rmtree(qd, ignore_errors=True)

print()
print('a swallowed auto-login failure must not pass silently')
src = open(AGENT).read()
body = src[src.index('def _maybe_auto_login('):]
body = body[:body.index('\ndef ', 1)]
ok = 'except SystemExit' not in body or '_needs_login' in body.split('except SystemExit')[1]
print(f"  {'PASS' if ok else 'FAIL'}  _maybe_auto_login re-checks after cmd_login")
if not ok: fails.append('silent auto-login failure')

for _leak in (DEV, QDEV):
    shutil.rmtree(sa.devdir(_leak), ignore_errors=True)

sys.exit(1 if fails else 0)
