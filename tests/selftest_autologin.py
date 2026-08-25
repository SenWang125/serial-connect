#!/usr/bin/env python3
"""Red/green selftest: never fight a getty that is logging itself in.

A board whose serial getty runs `agetty --autologin sen` prints

    op5-plus login: sen (automatic login)

and then hands over to login(1).  serial-agent used to answer that prompt with
a hardcoded `root`, which the board rejects; the retry then landed inside
agetty's own 60 s LOGIN_TIMEOUT, so the two sides re-prompted each other
indefinitely and every send was typed into getty instead of a shell.

Covers: the banner is parsed, the console user reaches status.json, the account
is resolved rather than assumed, an announced autologin suppresses the login
attempt, a rejection backs off past getty's timeout, and --no-login /
SERIAL_NO_LOGIN are honoured by every caller.  No hardware required.
Exit 0 = GREEN.
"""
import argparse, json, os, sys, tempfile, time
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.environ.get('SERIAL_AGENT_UNDER_TEST') or next(
    p for p in (os.path.join(HERE, 'serial-agent'),
                os.path.join(HERE, os.pardir, 'bin', 'serial-agent'))
    if os.path.exists(p))

_BASE = tempfile.mkdtemp(prefix='sa-autologin-')
os.environ['SERIAL_AGENT_BASE'] = _BASE
os.environ.pop('SERIAL_LOGIN_USER', None)
os.environ.pop('SERIAL_NO_LOGIN', None)
sa = SourceFileLoader('sa_autologin', AGENT).load_module()

DEV = '/dev/ttySELFTEST-autologin'
fails = []


def check(name, cond, detail=''):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f'   {detail}' if not cond and detail else ''))
    if not cond:
        fails.append(name)


def need(attr):
    """A missing symbol is a RED, not a crash — this file must fail, not error,
    against the pre-fix source."""
    if not hasattr(sa, attr):
        check(f'{attr} exists', False)
        return None
    return getattr(sa, attr)


BANNER = ('\r\nUbuntu 24.04.4 LTS op5-plus ttyS2\r\n'
          'op5-plus login: sen (automatic login)\r\n')

print('1. the autologin banner names the account')
_re = need('RE_AUTOLOGIN')
if _re:
    m = _re.search(BANNER)
    check('RE_AUTOLOGIN matches the real banner', bool(m))
    check("RE_AUTOLOGIN captures 'sen'", bool(m) and m.group(1) == 'sen',
          repr(m.group(1)) if m else '')
    check('a plain login: prompt is not read as an autologin',
          not _re.search('op5-plus login: '))

print('2. the daemon records who the console belongs to')
d = sa.Daemon(DEV, None, 115200, 500, 0)
d.state = d._prev_state = 'BOOTING'
d._update_state(BANNER)
check('console_user learned from the banner',
      getattr(d, 'console_user', '') == 'sen', repr(getattr(d, 'console_user', None)))
check('the banner does not stop the state machine seeing the password prompt',
      (d._update_state('Password: '), d.state)[1] == 'PASSWORD', d.state)

d2 = sa.Daemon(DEV, None, 115200, 500, 0)
d2.state = d2._prev_state = 'BOOTING'
d2._update_state('\r\nsen@op5-plus:~$ ')
check('console_user also learned from a user@host prompt',
      getattr(d2, 'console_user', '') == 'sen', repr(getattr(d2, 'console_user', None)))

d3 = sa.Daemon(DEV, None, 115200, 500, 0)
d3.state = d3._prev_state = 'BOOTING'
d3._update_state('\r\nroot@am62dxx-evm:~# ')
check('a root board still resolves to root',
      getattr(d3, 'console_user', '') == 'root', repr(getattr(d3, 'console_user', None)))

print('3. the account is resolved, never assumed')
_res = need('_resolve_login_user')
if _res:
    check('no console evidence falls back to root', _res({}) == 'root')
    check('the console user wins over the fallback',
          _res({'console_user': 'sen'}) == 'sen')
    check('--user wins over the console',
          _res({'console_user': 'sen'}, 'debian') == 'debian')
    os.environ['SERIAL_LOGIN_USER'] = 'envuser'
    try:
        check('SERIAL_LOGIN_USER wins over the console',
              _res({'console_user': 'sen'}) == 'envuser')
        check('--user still wins over SERIAL_LOGIN_USER',
              _res({'console_user': 'sen'}, 'debian') == 'debian')
    finally:
        os.environ.pop('SERIAL_LOGIN_USER', None)

print('4. an autologin in flight suppresses our own login')
_pend = need('_autologin_pending')
if _pend:
    check('a banner seconds old is still in flight', _pend({'autologin_ago': 1.0}))
    check('a banner from a previous boot is not',
          not _pend({'autologin_ago': 3600.0}))
    check('a board that never announced one is not', not _pend({}))

print('5. a rejected login backs off past getty LOGIN_TIMEOUT')
_left = need('_login_backoff_left')
_rec = need('_record_login_attempt')
if _left and _rec:
    dd = sa.devdir(DEV)
    dd.mkdir(parents=True, exist_ok=True)
    _rec(DEV, 'root', False)
    check('a rejection blocks the immediate retry', _left(DEV) > 0)
    check('the wait outlasts agetty LOGIN_TIMEOUT (60 s)', _left(DEV) > 60,
          f'{_left(DEV):.0f}s')
    _b1 = _left(DEV)
    _rec(DEV, 'root', False)
    check('a second rejection waits longer than the first', _left(DEV) > _b1,
          f'{_b1:.0f}s -> {_left(DEV):.0f}s')
    _rec(DEV, 'root', True)
    check('a successful login clears the backoff', _left(DEV) == 0.0)

print('6. --no-login and SERIAL_NO_LOGIN are honoured everywhere')
_sup = need('_login_suppressed')
if _sup:
    check('--no-login suppresses', _sup(argparse.Namespace(no_login=True)))
    check('absent flag does not', not _sup(argparse.Namespace()))
    os.environ['SERIAL_NO_LOGIN'] = '1'
    try:
        check('SERIAL_NO_LOGIN suppresses a caller with no flag',
              _sup(argparse.Namespace()))
    finally:
        os.environ.pop('SERIAL_NO_LOGIN', None)

# The defect was not the flag, it was three callers that built their own
# Namespace with no_login pinned False and the user pinned 'root'.
src = open(AGENT).read()
import re as _pyre
_pinned = _pyre.findall(r"_maybe_auto_login\(argparse\.Namespace\([^)]*no_login=False[^)]*\)",
                        src, _pyre.S)
check('at most one caller pins no_login=False (cmd_reboot, documented)',
      len(_pinned) <= 1, f'{len(_pinned)} found')
check("no caller pins user='root'",
      not _pyre.search(r"_maybe_auto_login\(argparse\.Namespace\([^)]*user=[\"']root[\"']",
                       src, _pyre.S))
for _sub in ('boot', 'upload'):
    check(f"'{_sub}' accepts --no-login",
          f"--no-login" in src.split(f"sub.add_parser('{_sub}'")[1].split('sub.add_parser(')[0])

print('7. _maybe_auto_login waits for the board instead of typing over it')
# Behavioural, not symbol-dependent: this section must run (and fail) against
# the pre-fix source too, or the assertion that matters is never red-proved.
if True:
    dd = sa.devdir(DEV)
    dd.mkdir(parents=True, exist_ok=True)
    sf = dd / 'status.json'

    def drive(status, wait_result, **overrides):
        """Run _maybe_auto_login against a fixed console state.

        wait_result is what the console does while we wait: 'shell' = the
        autologin completes, None = it never does. Returns (typed, waits).
        """
        (dd / 'login.attempt').unlink(missing_ok=True)
        sf.write_text(json.dumps(status))
        typed, waits = [], []

        def _fake_wait(device, state_csv, timeout, print_output=True):
            waits.append((state_csv, timeout))
            if wait_result == 'shell':
                sf.write_text(json.dumps({'state': 'SHELL',
                                          'console_user': status.get('console_user', '')}))
                return True
            return False

        _o_send, _o_wait = sa._do_send, sa._wait_state
        sa._do_send = lambda device, cmd, **kw: typed.append(cmd)
        sa._wait_state = _fake_wait
        ns = dict(device=DEV, no_login=False, login=False, user=None, password=None)
        ns.update(overrides)
        try:
            sa._maybe_auto_login(argparse.Namespace(**ns))
        except SystemExit:
            pass
        finally:
            sa._do_send, sa._wait_state = _o_send, _o_wait
        return typed, waits

    AL = {'state': 'LOGIN', 'console_user': 'sen', 'autologin_user': 'sen',
          'autologin_ago': 0.5}

    typed, waits = drive(AL, 'shell')
    check('an announced autologin is waited for, not answered', typed == [], repr(typed))
    check('the wait targets SHELL', bool(waits) and 'SHELL' in waits[0][0], repr(waits))

    # Same board with the autologin misconfigured (agetty -o without -f): the
    # banner prints, login(1) then asks for a password anyway. Once the grace is
    # spent we must log in -- as the account the console named, never as root.
    typed, waits = drive(AL, None)
    check('a stalled autologin is eventually answered', typed[:1] == ['sen'], repr(typed))
    check('and never as root', 'root' not in typed, repr(typed))
    check('the autologin grace is waited out first', bool(waits))
    # One attempt is one failure: counting it twice doubles every later backoff.
    try:
        _att = json.loads((dd / 'login.attempt').read_text())
    except (OSError, ValueError):
        _att = {}
    check('one auto-login records exactly one failure', _att.get('fails') == 1,
          repr(_att))
    # ...and the grace is waited out once, not once per layer.
    _grace = getattr(sa, 'AUTOLOGIN_GRACE', 10.0)
    check('the autologin grace is not waited twice',
          sum(1 for _c, _t in waits
              if abs(_t - (_grace - AL['autologin_ago'])) < 0.01) <= 1,
          repr(waits))

    # No banner at all: a getty that just prints login: still names its user in
    # the prompt of the shell it reached earlier, and that is who we answer with.
    typed, _ = drive({'state': 'LOGIN', 'console_user': 'debian'}, None)
    check('a board with no banner uses its last-seen shell account',
          typed[:1] == ['debian'], repr(typed))

    typed, _ = drive({'state': 'LOGIN'}, None, user='debian')
    check('--user overrides everything', typed[:1] == ['debian'], repr(typed))

    typed, _ = drive(AL, 'shell', no_login=True)
    check('--no-login types nothing at a login prompt', typed == [], repr(typed))

    # A rejection must silence the next caller rather than collide with getty.
    sf.write_text(json.dumps({'state': 'LOGIN', 'console_user': 'sen'}))
    if not _rec:
        check('a caller arriving during the backoff types nothing', False)
        _rec = lambda *a, **kw: None
    _rec(DEV, 'sen', False)
    _typed2 = []
    _o_send, _o_wait = sa._do_send, sa._wait_state
    sa._do_send = lambda device, cmd, **kw: _typed2.append(cmd)
    sa._wait_state = lambda *a, **kw: False
    try:
        sa._maybe_auto_login(argparse.Namespace(device=DEV, no_login=False,
                                                login=False, user=None, password=None))
    except SystemExit:
        pass
    finally:
        sa._do_send, sa._wait_state = _o_send, _o_wait
    check('a caller arriving during the backoff types nothing', _typed2 == [],
          repr(_typed2))

import shutil
shutil.rmtree(_BASE, ignore_errors=True)
print(f"\n{'RED: ' + str(len(fails)) + ' failed' if fails else 'GREEN (all checks passed)'}")
sys.exit(1 if fails else 0)
