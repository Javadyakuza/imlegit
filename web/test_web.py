"""Tests for kolood_web.py — stdlib only, one daemon per test class."""
import base64
import hashlib
import http.client
import json
import os
import pty
import select
import shutil
import socket
import struct
import signal
import subprocess
import sys
import tempfile
import time
import unittest

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'kolood_web.py')
PY = sys.executable


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


class WSClient:
    """Tiny RFC6455 client: handshake + masked frames."""

    def __init__(self, port, path, cookie=None, origin=None, timeout=5):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=timeout)
        self.sock.settimeout(timeout)
        hdr = {'Host': '127.0.0.1:%d' % port, 'Upgrade': 'websocket',
               'Connection': 'Upgrade',
               'Sec-WebSocket-Key': base64.b64encode(os.urandom(16)).decode(),
               'Sec-WebSocket-Version': '13'}
        if cookie:
            hdr['Cookie'] = 'kolood=' + cookie
        if origin is not None:
            hdr['Origin'] = origin
        self.sock.sendall(('GET %s HTTP/1.1\r\n' % path +
                           ''.join('%s: %s\r\n' % kv for kv in hdr.items()) + '\r\n').encode())
        resp = b''
        while b'\r\n\r\n' not in resp:
            d = self.sock.recv(4096)
            if not d:
                raise ConnectionError('eof during handshake')
            resp += d
        self.headers, _, self.leftover = resp.partition(b'\r\n\r\n')
        self.status = int(self.headers.split(b' ', 2)[1])

    def _read_sock(self, n):
        if self.leftover:
            out, self.leftover = self.leftover[:n], self.leftover[n:]
            return out
        return self.sock.recv(n)

    def send_frame(self, opcode, payload, fin=True):
        mask = os.urandom(4)
        b1 = (0x80 if fin else 0) | opcode
        n = len(payload)
        if n < 126:
            hdr = struct.pack('!BB', b1, 0x80 | n)
        elif n < 65536:
            hdr = struct.pack('!BBH', b1, 0x80 | 126, n)
        else:
            hdr = struct.pack('!BBQ', b1, 0x80 | 127, n)
        mp = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        self.sock.sendall(hdr + mask + mp)

    def send_text(self, s):
        self.send_frame(1, s.encode())

    def _recvn(self, n):
        buf = b''
        while len(buf) < n:
            d = self._read_sock(n - len(buf))
            if not d:
                raise ConnectionError('eof')
            buf += d
        return buf

    def recv_frame(self):
        b1, b2 = self._recvn(2)
        opcode = b1 & 0x0F
        ln = b2 & 0x7F
        if ln == 126:
            ln = struct.unpack('!H', self._recvn(2))[0]
        elif ln == 127:
            ln = struct.unpack('!Q', self._recvn(8))[0]
        payload = self._recvn(ln) if ln else b''
        return opcode, payload

    def next_data(self, timeout=10):
        """Returns ('data', bytes) | ('close', bytes). Answers pings."""
        deadline = time.time() + timeout
        while True:
            self.sock.settimeout(max(0.1, deadline - time.time()))
            op, p = self.recv_frame()
            if op == 9:
                self.send_frame(10, p)
            elif op in (1, 2):
                return 'data', p
            elif op == 8:
                return 'close', p

    def recv_until(self, substr, timeout=10):
        deadline = time.time() + timeout
        acc = b''
        while time.time() < deadline:
            kind, p = self.next_data(max(0.1, deadline - time.time()))
            if kind == 'close':
                raise AssertionError('closed while waiting for %r, got %r' % (substr, acc))
            acc += p
            if substr in acc.decode('utf-8', 'replace'):
                return acc.decode('utf-8', 'replace')
        raise AssertionError('did not receive %r, got %r' % (substr, acc[:400]))

    def close(self):
        try:
            self.send_frame(8, struct.pack('!H', 1000))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='kolood-test-')
        self.home = os.path.join(self.tmp, 'kolood')
        self.fake_home = os.path.join(self.tmp, 'fakehome')
        os.makedirs(self.home)
        os.makedirs(self.fake_home)
        self.port = free_port()
        with open(os.path.join(self.home, 'web.json'), 'w') as f:
            json.dump({'port': self.port, 'commands': {'shell': ['/bin/sh']}}, f)
        r = self.run_cli('passwd', 'X')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.errfiles = []
        self.errfile = None
        self.proc = None
        self.start_daemon()

    def start_daemon(self):
        self.errfile = open(os.path.join(self.tmp, 'daemon.log'), 'a')
        self.errfiles.append(self.errfile)
        self.proc = subprocess.Popen([PY, WEB, 'serve'], env=self.daemon_env(),
                                     stdout=self.errfile, stderr=self.errfile)
        self.wait_ready()

    def stop_daemon(self):
        self.proc.terminate()
        self.proc.wait(timeout=15)

    def daemon_env(self):
        env = dict(os.environ)
        env['KOLOOD_HOME'] = self.home
        env['HOME'] = self.fake_home
        return env

    def wait_ready(self):
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
                c.request('GET', '/')
                r = c.getresponse()
                r.read()
                c.close()
                if r.status == 200:
                    return
            except OSError:
                time.sleep(0.1)
        self.fail('daemon did not start: ' +
                  open(os.path.join(self.tmp, 'daemon.log')).read())

    def tearDown(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        for f in self.errfiles:
            f.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run([PY, WEB] + list(args), env=self.daemon_env(),
                              capture_output=True, text=True, timeout=30)

    def req(self, method, path, body=None, cookie=None, headers=None):
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        h = dict(headers or {})
        if cookie:
            h['Cookie'] = 'kolood=' + cookie
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h['Content-Type'] = 'application/json'
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        raw = r.read()
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = raw
        c.close()
        return r.status, r, parsed

    @staticmethod
    def cookie_of(resp):
        sc = resp.getheader('Set-Cookie')
        return sc.split(';', 1)[0].split('=', 1)[1]

    def login(self, pw='X'):
        st, r, _ = self.req('POST', '/api/login', {'password': pw})
        self.assertEqual(st, 200)
        return self.cookie_of(r)

    def new_session(self, cookie, body=None):
        st, _, parsed = self.req('POST', '/api/new', body or {'kind': 'shell'},
                                 cookie=cookie, headers={'X-Kolood': '1'})
        self.assertEqual(st, 200, parsed)
        return parsed['id']

    def sessions(self, cookie):
        st, _, parsed = self.req('GET', '/api/sessions', cookie=cookie)
        self.assertEqual(st, 200)
        return parsed

    def poll_sessions(self, cookie, pred, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            d = self.sessions(cookie)
            if pred(d):
                return d
            time.sleep(0.2)
        self.fail('condition not met: ' + json.dumps(self.sessions(cookie))[:400])


class TestAuth(Base):
    def test_auth_flow(self):
        st, _, _ = self.req('POST', '/api/login', {'password': 'wrong'})
        self.assertEqual(st, 401)
        cookie = self.login()
        st, _, _ = self.req('GET', '/api/me')
        self.assertEqual(st, 401)
        st, _, parsed = self.req('GET', '/api/me', cookie=cookie)
        self.assertEqual(st, 200)
        st, _, _ = self.req('POST', '/api/new', {'kind': 'shell'}, cookie=cookie)
        self.assertEqual(st, 403)
        # 10 failures already: 1 above -> 9 more allowed, 11th wrong login -> 429
        for i in range(9):
            st, _, _ = self.req('POST', '/api/login', {'password': 'nope%d' % i})
            self.assertEqual(st, 401)
        st, _, _ = self.req('POST', '/api/login', {'password': 'nope-last'})
        self.assertEqual(st, 429)


class TestWebSocket(Base):
    def test_shell_session(self):
        cookie = self.login()
        sid = self.new_session(cookie)
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        self.assertEqual(ws.status, 101)
        ws.send_text(json.dumps({'t': 'in', 'd': 'echo hi-$((1+1))\r'}))
        ws.recv_until('hi-2')
        ws.send_text(json.dumps({'t': 'resize', 'cols': 120, 'rows': 40}))
        ws.send_text(json.dumps({'t': 'in', 'd': 'echo rr-$((3*4))\r'}))
        ws.recv_until('rr-12')
        # reconnect -> replay contains hi-2
        ws.close()
        ws2 = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        self.assertEqual(ws2.status, 101)
        ws2.recv_until('hi-2')
        # second simultaneous client sees the same live output
        ws3 = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        self.assertEqual(ws3.status, 101)
        ws3.recv_until('hi-2')
        ws2.send_text(json.dumps({'t': 'in', 'd': 'echo qq-$((7*3))\r'}))
        ws3.recv_until('qq-21')
        ws2.close()
        ws3.close()

    def test_osc_title(self):
        cookie = self.login()
        sid = self.new_session(cookie)
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        ws.send_text(json.dumps({'t': 'in',
                                 'd': "printf '\\033]0;MyTitle\\007'\r"}))
        d = self.poll_sessions(cookie, lambda d: any(
            s['id'] == sid and s['title'] == 'MyTitle' for s in d['running']))
        ws.close()

    def test_kill(self):
        cookie = self.login()
        sid = self.new_session(cookie)
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        st, _, parsed = self.req('POST', '/api/kill', {'id': sid},
                                 cookie=cookie, headers={'X-Kolood': '1'})
        self.assertEqual(st, 200)
        self.assertTrue(parsed.get('ok'))
        self.poll_sessions(cookie, lambda d: all(s['id'] != sid for s in d['running']))
        deadline = time.time() + 10
        msg = None
        while time.time() < deadline:
            kind, p = ws.next_data(max(0.1, deadline - time.time()))
            if kind == 'close':
                break
            try:
                m = json.loads(p.decode('utf-8', 'replace'))
            except ValueError:
                continue
            if m.get('t') == 'exit':
                msg = m
                break
        self.assertIsNotNone(msg, 'no exit message received')
        self.assertIn('code', msg)
        ws.close()
        st, _, parsed = self.req('POST', '/api/kill', {'id': sid},
                                 cookie=cookie, headers={'X-Kolood': '1'})
        self.assertEqual(st, 404)

    def test_origin_and_unknown(self):
        cookie = self.login()
        sid = self.new_session(cookie)
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie,
                      origin='http://evil.example:9999')
        self.assertEqual(ws.status, 403)
        ws.close()
        ok = WSClient(self.port, '/ws?id=' + sid, cookie=cookie,
                      origin='http://127.0.0.1:%d' % self.port)
        self.assertEqual(ok.status, 101)
        ok.close()
        unk = WSClient(self.port, '/ws?id=doesnotexist', cookie=cookie)
        self.assertEqual(unk.status, 101)
        op, p = unk.recv_frame()
        self.assertEqual(op, 8)
        self.assertEqual(struct.unpack('!H', p[:2])[0], 4404)
        unk.close()


class TestRecent(Base):
    def test_recent_and_accounts(self):
        proj = os.path.join(self.fake_home, '.claude', 'projects', '-x')
        os.makedirs(proj)
        with open(os.path.join(proj, 'abc-1.jsonl'), 'w') as f:
            f.write(json.dumps({'type': 'user', 'cwd': '/tmp/proj',
                                'message': {'content': '  hello   world  '}}) + '\n')
            f.write(json.dumps({'type': 'assistant'}) + '\n')
        aproj = os.path.join(self.fake_home, '.config', 'kolood', 'accounts',
                             'work', 'projects', '-y')
        os.makedirs(aproj)
        with open(os.path.join(aproj, 'def-2.jsonl'), 'w') as f:
            f.write(json.dumps({'type': 'summary', 'summary': 'Summary Title'}) + '\n')
            f.write(json.dumps({'type': 'user', 'cwd': '/y',
                                'message': {'content': [
                                    {'type': 'text', 'text': 'body text'}]}}) + '\n')
        os.utime(os.path.join(proj, 'abc-1.jsonl'), (1000000000, 1000000000))
        os.utime(os.path.join(aproj, 'def-2.jsonl'), (1000000100, 1000000100))
        cookie = self.login()
        d = self.sessions(cookie)
        self.assertEqual(d['accounts'], ['default', 'work'])
        byid = {r['id']: r for r in d['recent']}
        self.assertIn('abc-1', byid)
        self.assertEqual(byid['abc-1']['title'], 'hello world')
        self.assertEqual(byid['abc-1']['account'], 'default')
        self.assertEqual(byid['abc-1']['cwd'], '/tmp/proj')
        self.assertIn('def-2', byid)
        self.assertEqual(byid['def-2']['title'], 'Summary Title')
        self.assertEqual(byid['def-2']['account'], 'work')
        self.assertEqual(d['recent'][0]['id'], 'def-2')


class TestCLI(Base):
    def test_attach_spawn(self):
        pid, fd = pty.fork()
        if pid == 0:  # child
            os.environ.update(self.daemon_env())
            os.execv(PY, [PY, WEB, 'attach', '--',
                          '/bin/sh', '-c', 'echo ATT-OK; exit 7'])
        out = b''
        while True:
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            if not d:
                break
            out += d
        os.close(fd)
        _, status = os.waitpid(pid, 0)
        self.assertIn(b'ATT-OK', out)
        self.assertEqual(status >> 8, 7)

    def test_list_kill_status(self):
        self.assertEqual(self.run_cli('status').returncode, 0)
        r = self.run_cli('status')
        self.assertIn('running', r.stdout)
        cookie = self.login()
        sid = self.new_session(cookie)
        r = self.run_cli('list')
        self.assertEqual(r.returncode, 0)
        self.assertIn(sid, r.stdout)
        r = self.run_cli('kill', sid)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.poll_sessions(cookie, lambda d: all(s['id'] != sid for s in d['running']))
        r = self.run_cli('kill', 'nosuchid')
        self.assertEqual(r.returncode, 1)
        self.proc.terminate()
        self.proc.wait()
        self.assertEqual(self.run_cli('status').returncode, 1)
        r = self.run_cli('attach', '--', '/bin/sh', '-c', 'true')
        self.assertEqual(r.returncode, 3)
        self.assertIn('kolood web is not running', r.stderr)


class TestValidation(Base):
    def test_bad_account(self):
        cookie = self.login()
        st, _, _ = self.req('POST', '/api/new', {'kind': 'claude', 'account': 'BAD!'},
                            cookie=cookie, headers={'X-Kolood': '1'})
        self.assertEqual(st, 400)
        st, _, _ = self.req('POST', '/api/new', {'kind': 'claude', 'resume': '../x'},
                            cookie=cookie, headers={'X-Kolood': '1'})
        self.assertEqual(st, 400)
        st, _, _ = self.req('POST', '/api/new', {'kind': 'bogus'},
                            cookie=cookie, headers={'X-Kolood': '1'})
        self.assertEqual(st, 400)

    def test_traversal(self):
        cookie = self.login()
        st, _, _ = self.req('GET', '/static/../kolood_web.py', cookie=cookie)
        self.assertEqual(st, 404)
        st, _, _ = self.req('GET', '/static/secret.txt')
        self.assertEqual(st, 404)
        st, _, _ = self.req('GET', '/nope', cookie=cookie)
        self.assertEqual(st, 404)

    def test_static_served_from_static_dir(self):
        d = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'static')
        made = not os.path.isdir(d)
        os.makedirs(d, exist_ok=True)
        f = os.path.join(d, 'addon-fit.js')
        existed = os.path.exists(f)
        if not existed:
            with open(f, 'w') as fh:
                fh.write('/*fit*/')
        try:
            st, _, body = self.req('GET', '/static/addon-fit.js')
            self.assertEqual(st, 200)
        finally:
            if not existed:
                os.remove(f)
            if made:
                os.rmdir(d)


class TestRestore(Base):
    def test_restore_shell(self):
        cookie = self.login()
        sid = self.new_session(cookie)
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        ws.send_text(json.dumps({'t': 'in', 'd': 'echo BEFORE-RESTART\r'}))
        ws.recv_until('BEFORE-RESTART')
        ws.close()
        self.stop_daemon()
        self.start_daemon()
        d = self.sessions(cookie)
        self.assertTrue([s for s in d['running'] if s['id'] == sid])
        ws2 = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        self.assertEqual(ws2.status, 101)
        text = ws2.recv_until('session restored')
        self.assertIn('BEFORE-RESTART', text)
        ws2.send_text(json.dumps({'t': 'in', 'd': 'echo AFTER-RESTART\r'}))
        ws2.recv_until('AFTER-RESTART')
        ws2.close()

    def test_restore_claude(self):
        script = os.path.join(self.tmp, 'kolood_start')
        with open(script, 'w') as f:
            f.write('#!/bin/sh\n'
                    'printf \'{"claude_id":"abc-123","account":"work"}\\n\' '
                    '> "$KOLOOD_SESSION_FILE"\n'
                    'echo "argv: $*"\n'
                    'sleep 60\n')
        os.chmod(script, 0o755)
        cfgp = os.path.join(self.home, 'web.json')
        with open(cfgp) as f:
            cfg = json.load(f)
        cfg['commands'] = {'claude': [script, '', 'PROMPTTEXT']}
        with open(cfgp, 'w') as f:
            json.dump(cfg, f)
        cookie = self.login()
        sid = self.new_session(cookie, {'kind': 'claude'})
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        ws.recv_until('PROMPTTEXT')
        ws.close()
        self.stop_daemon()
        self.start_daemon()
        d = self.sessions(cookie)
        self.assertTrue([s for s in d['running'] if s['id'] == sid])
        ws2 = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        self.assertEqual(ws2.status, 101)
        text = ws2.recv_until('session restored')
        post = text.split('session restored', 1)[1]
        deadline = time.time() + 10
        while '--resume abc-123' not in post and time.time() < deadline:
            kind, p = ws2.next_data(max(0.1, deadline - time.time()))
            if kind == 'close':
                self.fail('closed while waiting for resume argv, got: ' + post)
            post += p.decode('utf-8', 'replace')
        self.assertIn('--account work --resume abc-123', post)
        self.assertNotIn('PROMPTTEXT', post)
        ws2.close()

    def test_no_restore_after_exit(self):
        cookie = self.login()
        sid = self.new_session(cookie)
        ws = WSClient(self.port, '/ws?id=' + sid, cookie=cookie)
        ws.send_text(json.dumps({'t': 'in', 'd': 'exit\r'}))
        self.poll_sessions(cookie, lambda d: all(s['id'] != sid for s in d['running']))
        ws.close()
        self.stop_daemon()
        self.start_daemon()
        d = self.sessions(cookie)
        self.assertFalse([s for s in d['running'] if s['id'] == sid])

    def test_crash_loop(self):
        self.stop_daemon()
        counter = os.path.join(self.tmp, 'runs')
        crash = os.path.join(self.tmp, 'crash.sh')
        with open(crash, 'w') as f:
            f.write('#!/bin/sh\necho ran >> %s\n' % counter)
        os.chmod(crash, 0o755)
        state = os.path.join(self.home, 'sessions.json')
        entry = {'id': 'crash01', 'name': 'crash', 'kind': 'shell', 'cmd': [crash],
                 'cwd': self.tmp, 'started': time.time(), 'title': 'crash',
                 'restores': 0, 'restored_at': None}

        def runs():
            try:
                with open(counter) as f:
                    return len(f.read().split())
            except OSError:
                return 0

        with open(state, 'w') as f:
            json.dump([entry], f)
        for _ in range(4):
            self.start_daemon()
            time.sleep(1.0)
            self.stop_daemon()
        self.assertLessEqual(runs(), 3)
        # direct guard check: restores>=3 and no 60 s lifetime -> skipped
        entry['restores'] = 3
        entry['restored_at'] = time.time() - 10
        n = runs()
        with open(state, 'w') as f:
            json.dump([entry], f)
        self.start_daemon()
        time.sleep(1.0)
        self.assertEqual(runs(), n)
        with open(state) as f:
            self.assertEqual(json.load(f), [])
        self.stop_daemon()

    def test_attach_reconnect(self):
        pid, fd = pty.fork()
        if pid == 0:  # child
            os.environ.update(self.daemon_env())
            os.execv(PY, [PY, WEB, 'attach', '--', '/bin/sh'])
        out = b''

        def pump(substr, timeout):
            nonlocal out
            deadline = time.time() + timeout
            while time.time() < deadline:
                if substr in out:
                    return
                r, _, _ = select.select([fd], [], [], 0.3)
                if fd in r:
                    try:
                        d = os.read(fd, 4096)
                    except OSError:
                        break
                    if not d:
                        break
                    out += d
            self.assertIn(substr.decode(), out.decode('utf-8', 'replace'))

        try:
            pump(b'$ ', 15)
            self.stop_daemon()
            pump(b'reconnecting', 15)
            self.start_daemon()
            os.write(fd, b'echo RECONNECTED\n')
            pump(b'RECONNECTED', 20)
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass
            try:
                os.waitpid(pid, 0)
            except (ChildProcessError, OSError):
                pass

    def test_web_ver(self):
        with open(os.path.join(self.home, 'web.ver')) as f:
            ver = f.read().strip()
        with open(WEB, 'rb') as f:
            want = hashlib.sha256(f.read()).hexdigest()
        self.assertEqual(ver, want)


if __name__ == '__main__':
    unittest.main()
