#!/usr/bin/env python3
"""Red/green selftest for three confirmed output-parsing defects.

1. cmd_run re-parsed SERIAL_EXITCODE out of text _clean_output had already
   stripped it from, so every `run` exited 0 regardless of the script.
2. _clean_output's trailing-prompt strip is greedy and matches any line ending
   in $ # or >, so it deletes real output - a kernel line quoting an email
   address, or an entire XML file.
3. cmd_watch --send matched its own echoed command, the same bug already fixed
   for --wait.
No hardware required. Exit 0 = GREEN.
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

def body(fn):
    b = src[src.index(f'def {fn}('):]
    return b[:b.index('\ndef ', 1)]

print('1. run must report the script exit code')
rb = body('cmd_run')
check('cmd_run does not re-parse the tag out of cleaned output',
      'RE_EXITCODE.match' not in rb)
check('cmd_run keeps the exit code _clean_output already extracted',
      "result.get('exit_code')" in rb or "result['exit_code']" in rb)

print()
print('2. the trailing-prompt strip must not eat real output')
kern = ['[    0.540700] pps_core: LinuxPPS API ver. 1 registered',
        '[    0.540800] pps_core: Copyright Rodolfo Giometti <giometti@linux.it>']
o, _ = sa._clean_output(kern, sent_cmd='dmesg | grep -i pps')
check('a kernel line ending in ">" survives', 'giometti' in o)
o2, _ = sa._clean_output(['<node>', '<name>foo</name>', '</node>'], sent_cmd='cat x.xml')
check('xml output survives', '</node>' in o2)
o3, _ = sa._clean_output(['total 0', 'drwxr-xr-x 2 root root'], sent_cmd='ls -l')
check('ordinary output unaffected', 'drwxr-xr-x 2 root root' in o3)
# a genuine trailing prompt must still go
o4, _ = sa._clean_output(['hello', 'root@am62dxx-evm:~#'], sent_cmd='echo hello')
check('a real trailing prompt is still removed', o4.strip() == 'hello')
o5, _ = sa._clean_output(['hello', '# '], sent_cmd='echo hello')
check('a bare trailing prompt is still removed', o5.strip() == 'hello')

print()
print('3. watch --send must not match its own echo')
wb = body('cmd_watch')
check('cmd_watch strips the echo before matching', '_echo_free(' in wb)

sys.exit(1 if fails else 0)
