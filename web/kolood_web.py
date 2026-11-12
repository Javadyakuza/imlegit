#!/usr/bin/env python3
"""kolood web: phone web terminal + session holder. Python stdlib only."""
import asyncio, base64, fcntl, glob, gzip, hashlib, hmac, json, os, re, secrets
import signal, socket, ssl, struct, subprocess, sys, termios, time, tty
import urllib.parse

ASSET_DIR = os.path.dirname(os.path.abspath(__file__))
WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
STATIC_WHITELIST = ('xterm.js', 'xterm.css', 'addon-fit.js', 'icon.png')
MAX_HEADER = 16 * 1024
MAX_BODY = 64 * 1024
MAX_WS_FRAME = 1024 * 1024
REASONS = {101: 'Switching Protocols', 200: 'OK', 400: 'Bad Request',
           401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found',
           413: 'Payload Too Large', 429: 'Too Many Requests',
           500: 'Internal Server Error', 503: 'Service Unavailable'}
RESTORED_MSG = b'\r\n\x1b[2m[kolood: session restored after a server restart]\x1b[0m\r\n'


class WebError(Exception):
    pass


def log(msg):
    sys.stderr.write(time.strftime('[%Y-%m-%d %H:%M:%S] ') + str(msg) + '\n')
    sys.stderr.flush()


def home_dir():
    return os.environ.get('KOLOOD_HOME') or os.path.expanduser('~/.config/kolood')


def cfg_path():
    return os.path.join(home_dir(), 'web.json')


def load_cfg():
    try:
        with open(cfg_path()) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except Exception:
        return {}


def save_cfg(cfg):
    os.makedirs(home_dir(), exist_ok=True)
    p = cfg_path()
    with open(p, 'w') as f:
        json.dump(cfg, f, indent=2)
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass


def fmt_age(sec):
    sec = max(0, int(sec))
    if sec < 60:
        return '%ds' % sec
    if sec < 3600:
        return '%dm' % (sec // 60)
    if sec < 86400:
        return '%dh' % (sec // 3600)
    return '%dd' % (sec // 86400)


# ---------------------------------------------------------------- socket CLI

def send_frame(sock, ftype, payload=b''):
    sock.sendall(ftype + struct.pack('>I', len(payload)) + payload)


def recv_exact(sock, n):
    buf = b''
    while len(buf) < n:
        d = sock.recv(n - len(buf))
        if not d:
            return None
        buf += d
    return buf


def recv_frame(sock):
    h = recv_exact(sock, 5)
    if h is None:
        return None, None
    ln = struct.unpack('>I', h[1:5])[0]
    payload = recv_exact(sock, ln) if ln else b''
    if ln and payload is None:
        return None, None
    return h[0:1], payload


def connect_daemon():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(os.path.join(home_dir(), 'web.sock'))
    s.settimeout(None)
    return s


def write_all(fd, data):
    while data:
        n = os.write(fd, data)
        data = data[n:]


def cmd_passwd(args):
    pw = args[0] if args else secrets.token_urlsafe(12)
    cfg = load_cfg()
    salt = secrets.token_hex(16)
    cfg['pw_salt'] = salt
    cfg['pw_hash'] = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt.encode(), 200000).hex()
    cfg['secret'] = secrets.token_hex(32)
    save_cfg(cfg)
    if not args:
        print(pw)


def cmd_status():
    try:
        s = connect_daemon()
    except OSError:
        sys.exit(1)
    try:
        send_frame(s, b'J', json.dumps({'op': 'ping'}).encode())
        t, p = recv_frame(s)
        if t == b'J' and json.loads(p or b'{}').get('ok'):
            print('running')
            return
    except OSError:
        pass
    finally:
        s.close()
    sys.exit(1)


def cmd_list():
    try:
        s = connect_daemon()
    except OSError:
        print('kolood web is not running', file=sys.stderr)
        sys.exit(1)
    try:
        send_frame(s, b'J', json.dumps({'op': 'list'}).encode())
        t, p = recv_frame(s)
    except OSError:
        s.close()
        sys.exit(1)
    s.close()
    if t != b'J':
        return
    for sess in json.loads(p or b'{}').get('sessions', []):
        title = sess.get('title') or sess.get('name') or ''
        age = fmt_age(time.time() - sess.get('started', time.time()))
        print('\t'.join([sess.get('id', ''), title, sess.get('kind', ''),
                         str(sess.get('clients', 0)), age]))


def cmd_history(args):
    """Recent Claude conversations, newest first: id, age, folder, title (what the phone page lists)."""
    only = args[0] if args else None  # optional folder filter (substring of its path)
    for it in Daemon.collect_recent(Daemon.account_list()):
        if only and only not in (it.get('cwd') or ''):
            continue
        print('\t'.join([it['id'], fmt_age(time.time() - it['mtime']), it.get('cwd') or '', it['title']]))


def cmd_kill(sid):
    try:
        s = connect_daemon()
    except OSError:
        print('kolood web is not running', file=sys.stderr)
        sys.exit(1)
    try:
        send_frame(s, b'J', json.dumps({'op': 'kill', 'id': sid}).encode())
        t, p = recv_frame(s)
    except OSError:
        t = None
    s.close()
    if t == b'J' and json.loads(p or b'{}').get('ok'):
        return
    print('unknown session: %s' % sid, file=sys.stderr)
    sys.exit(1)


def tty_size():
    if sys.stdin.isatty():
        try:
            r, c = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))[:2]
            if c > 0 and r > 0:
                return c, r
        except OSError:
            pass
    return 80, 24


def cmd_attach(argv):
    args, cmd = list(argv), None
    if '--' in args:
        i = args.index('--')
        cmd = args[i + 1:]
        args = args[:i]
    sid = name = None
    i = 0
    while i < len(args):
        if args[i] == '--id' and i + 1 < len(args):
            sid = args[i + 1]; i += 2
        elif args[i] == '--name' and i + 1 < len(args):
            name = args[i + 1]; i += 2
        else:
            i += 1
    try:
        sock = connect_daemon()
    except OSError:
        print('kolood web is not running', file=sys.stderr)
        sys.exit(3)

    cols, rows = tty_size()
    if sid is None and name is not None:
        send_frame(sock, b'J', json.dumps({'op': 'list'}).encode())
        t, p = recv_frame(sock)
        if t == b'J':
            for sess in json.loads(p or b'{}').get('sessions', []):
                if sess.get('name') == name:
                    sid = sess['id']
                    break
        if sid is None:
            print('no session named %s' % name, file=sys.stderr)
            sys.exit(1)
    if sid is None:
        if not cmd:
            print('usage: kolood_web.py attach [--id ID | --name NAME] [-- CMD ...]', file=sys.stderr)
            sys.exit(2)
        env = dict(os.environ)
        env['KOLOOD_INSIDE'] = '1'
        req = {'op': 'spawn', 'cmd': cmd, 'cwd': os.getcwd(), 'env': env,
               'name': os.path.basename(cmd[0]), 'kind': 'cmd', 'cols': cols, 'rows': rows}
    else:
        req = {'op': 'attach', 'id': sid, 'cols': cols, 'rows': rows}
    send_frame(sock, b'J', json.dumps(req).encode())
    t, p = recv_frame(sock)
    if t != b'J':
        print('bad daemon reply', file=sys.stderr)
        sys.exit(1)
    reply = json.loads(p or b'{}')
    if not reply.get('ok'):
        print('error: %s' % reply.get('error', 'unknown'), file=sys.stderr)
        sys.exit(1)
    if reply.get('id'):
        sid = reply['id']  # remember for reconnect (daemon restart)

    resize_flag = [False]
    saved = None
    fd = sys.stdin.fileno()
    if sys.stdin.isatty():
        saved = termios.tcgetattr(fd)
        tty.setraw(fd, termios.TCSANOW)  # TCSAFLUSH (default) would drop keys typed while starting

    def on_winch(_sig, _frm):
        resize_flag[0] = True

    try:
        signal.signal(signal.SIGWINCH, on_winch)
    except (ValueError, OSError):
        pass
    code = 0
    info = {}
    try:
        while True:
            res = attach_stream(sock, resize_flag, info)  # None = closed without an exit frame
            if res is not None:
                code = res
                break
            write_all(1, b'\r\n[kolood: server restarting, reconnecting...]\r\n')
            sock = reconnect_attach(sid)
            if sock is None:
                write_all(1, b'\r\n[kolood: the session did not come back]\r\n')
                code = 1
                break
    finally:
        if saved is not None:
            try:
                termios.tcsetattr(fd, termios.TCSADRAIN, saved)
            except termios.error:
                pass
        try:
            sock.close()
        except OSError:
            pass
    if info.get('resume') and re.fullmatch(r'[0-9a-fA-F-]{8,}', str(info['resume'])):
        print('\nTo resume this session: kolood --resume %s' % info['resume'])
    sys.exit(code)


def attach_stream(sock, resize_flag, info):
    """Stream one connection. Returns the exit code, or None if the socket
    closed without a J exit frame (the daemon is going away)."""
    stdin_fd = sys.stdin.fileno()
    watch = [sock.fileno()]
    if stdin_fd != sock.fileno():
        watch.append(stdin_fd)
    stdin_open = True
    try:
        while True:
            if resize_flag[0]:
                resize_flag[0] = False
                c, r = tty_size()
                send_frame(sock, b'J', json.dumps({'op': 'resize', 'cols': c, 'rows': r}).encode())
            rset, _, _ = select_watch(watch)
            if sock.fileno() in rset:
                t, p = recv_frame(sock)
                if t is None:
                    return None
                if t == b'D':
                    write_all(1, p)
                elif t == b'J':
                    msg = json.loads(p or b'{}')
                    if 'exit' in msg:
                        info['resume'] = msg.get('resume')
                        return msg['exit'] if isinstance(msg['exit'], int) else 0
            if stdin_open and stdin_fd in rset:
                d = os.read(stdin_fd, 4096)
                if not d:
                    stdin_open = False
                    watch.remove(stdin_fd)
                else:
                    send_frame(sock, b'D', d)
    except OSError:
        return None


def reconnect_attach(sid):
    """Retry every 1 s for up to 90 s. Returns a connected socket or None."""
    deadline = time.time() + 90
    while time.time() < deadline:
        time.sleep(1)
        s = None
        try:
            s = connect_daemon()
            s.settimeout(5)
            cols, rows = tty_size()
            send_frame(s, b'J', json.dumps(
                {'op': 'attach', 'id': sid, 'cols': cols, 'rows': rows}).encode())
            t, p = recv_frame(s)
        except OSError:
            if s:
                s.close()
            continue
        if t == b'J':
            reply = json.loads(p or b'{}')
            if reply.get('ok'):
                s.settimeout(None)
                return s
            if 'unknown' in str(reply.get('error', '')):
                s.close()
                return None
        s.close()
    return None


def select_watch(fds):
    import select as _s
    return _s.select(fds, [], [], 0.5)


# ---------------------------------------------------------------- sessions

class TitleParser:
    """Incremental OSC 0/2 title tracker (sequences may split across reads)."""

    def __init__(self, sess):
        self.sess = sess
        self.state = 0  # 0 normal, 1 got ESC, 2 in OSC, 3 ESC inside OSC
        self.osc = b''
        self.kind = None

    def feed(self, data):
        for b in data:
            if self.state == 0:
                if b == 0x1b:
                    self.state = 1
            elif self.state == 1:
                if b == 0x5d:  # ]
                    self.state = 2
                    self.osc = b''
                    self.kind = None
                else:
                    self.state = 0
            elif self.state == 2:
                if b == 0x07:  # BEL
                    self._end()
                elif b == 0x1b:
                    self.state = 3
                elif self.kind is None:
                    if b == 0x3b:  # ;
                        try:
                            self.kind = self.osc.decode('ascii').strip()
                        except UnicodeDecodeError:
                            self.state = 0
                        self.osc = b''
                    elif len(self.osc) < 8:
                        self.osc += bytes([b])
                    else:
                        self.state = 0
                elif len(self.osc) < 2048:
                    self.osc += bytes([b])
                else:
                    self.state = 0
            elif self.state == 3:
                if b == 0x5c:  # backslash -> ST
                    self._end()
                else:
                    self.state = 1

    def _end(self):
        self.state = 0
        if self.kind in ('0', '2'):
            self.sess.osc_title = self.osc.decode('utf-8', 'replace')[:512]


class BaseClient:
    session = None

    def write_d(self, data):
        self._write_frame(b'D', data)

    def write_json(self, obj):
        self._write_frame(b'J', json.dumps(obj).encode())

    def send_exit(self, code, resume=None):
        try:
            self.write_json({'exit': code, 'resume': resume})
        except Exception:
            pass
        self.close()

    def close(self):
        pass

    def _kick(self):
        pass


class SockClient(BaseClient):
    def __init__(self, writer):
        self.writer = writer
        self.drain_task = None

    def _write_frame(self, t, payload):
        try:
            self.writer.write(t + struct.pack('>I', len(payload)) + payload)
        except Exception:
            self.close()
            return
        self._kick()

    def _kick(self):
        if self.drain_task is None or self.drain_task.done():
            self.drain_task = asyncio.ensure_future(self._drain())

    async def _drain(self):
        try:
            await self.writer.drain()
        except Exception:
            self.close()

    def close(self):
        try:
            self.writer.close()
        except Exception:
            pass


class WsClient(BaseClient):
    def __init__(self, writer):
        self.writer = writer
        self.drain_task = None

    def _write_frame(self, t, payload):
        op = 2 if t == b'D' else 1
        try:
            self.writer.write(ws_encode(op, payload))
        except Exception:
            self.close()
            return
        self._kick()

    def send_exit(self, code, resume=None):
        try:
            self.write_json({'t': 'exit', 'code': code})
            self.writer.write(ws_encode(8, struct.pack('!H', 1000)))
        except Exception:
            pass
        self.close()

    def _kick(self):
        if self.drain_task is None or self.drain_task.done():
            self.drain_task = asyncio.ensure_future(self._drain())

    async def _drain(self):
        try:
            await self.writer.drain()
        except Exception:
            self.close()

    def close(self):
        try:
            self.writer.close()
        except Exception:
            pass


def ws_encode(opcode, payload):
    b1 = 0x80 | opcode
    n = len(payload)
    if n < 126:
        hdr = struct.pack('!BB', b1, n)
    elif n < 65536:
        hdr = struct.pack('!BBH', b1, 126, n)
    else:
        hdr = struct.pack('!BBQ', b1, 127, n)
    return hdr + payload


class Session:
    def __init__(self, mgr, cmd, cwd, env, name, kind, cols, rows, sid=None):
        self.mgr = mgr
        self.loop = mgr.loop
        self.id = sid or secrets.token_hex(4)
        self.kind = kind
        self.name = name or os.path.basename(cmd[0])
        self.osc_title = None
        self.started = time.time()
        self.cmd = list(cmd)
        self.cwd = cwd
        self.restores = 0
        self.restored_at = None
        self.cols = cols
        self.rows = rows
        self.clients = set()
        self.buf = bytearray()
        self.done = False
        self.finishing = False
        self.eof_watch = None
        self.tparser = TitleParser(self)
        master, slave = os.openpty()
        e = dict(env)
        e.setdefault('TERM', 'xterm-256color')
        e['KOLOOD_SESSION_FILE'] = mgr.sess_file(self.id)
        self.proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                                     cwd=cwd, env=e, start_new_session=True)
        os.close(slave)
        self.master = master
        self.apply_winsz(rows, cols)
        self.loop.add_reader(master, self._on_read)

    @property
    def title(self):
        return self.osc_title or self.name

    def replay(self):
        return bytes(self.buf)

    def _on_read(self):
        try:
            data = os.read(self.master, 65536)
        except OSError:
            self.mgr.check_finish(self)
            return
        if not data:
            self.mgr.check_finish(self)
            return
        self.feed(data)

    def drain(self):
        """Pass on what the process wrote last (e.g. Claude's resume hint) before the pty is closed."""
        try:
            os.set_blocking(self.master, False)
            while True:
                data = os.read(self.master, 65536)
                if not data:
                    break
                self.feed(data)
        except OSError:
            pass

    def feed(self, data):
        cap = self.mgr.buffer_bytes()
        if len(self.buf) + len(data) > cap:
            self.buf += data
            excess = len(self.buf) - cap
            nl = self.buf.rfind(b'\n', 0, excess)
            del self.buf[:nl + 1 if nl >= 0 else excess]
        else:
            self.buf += data
        prev_title = self.osc_title
        self.tparser.feed(data)
        if self.osc_title != prev_title:
            self.mgr.title_changed(self)
        for c in list(self.clients):
            c.write_d(data)

    def apply_winsz(self, rows, cols):
        if cols and cols > 0 and rows and rows > 0:
            self.cols, self.rows = cols, rows
            try:
                fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                            struct.pack('HHHH', rows, cols, 0, 0))
            except OSError:
                pass

    def resize(self, cols, rows):
        self.apply_winsz(rows, cols)


class Manager:
    def __init__(self, daemon):
        self.daemon = daemon
        self.sessions = {}
        self._title_dirty = False
        self._title_task = None

    @property
    def loop(self):
        return self.daemon.loop

    def cfg(self):
        return self.daemon.cfg()

    def buffer_bytes(self):
        try:
            return int(self.cfg().get('buffer_bytes', 2097152))
        except (TypeError, ValueError):
            return 2097152

    # ---- persisted state (sessions.json + sess/) ----------------------------

    def state_path(self):
        return os.path.join(home_dir(), 'sessions.json')

    def sess_file(self, sid):
        return os.path.join(home_dir(), 'sess', sid + '.json')

    def buf_file(self, sid):
        return os.path.join(home_dir(), 'sess', sid + '.buf')

    @staticmethod
    def ensure_sess_dir():
        d = os.path.join(home_dir(), 'sess')
        os.makedirs(d, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
        return d

    def state_entries(self):
        return [{'id': s.id, 'name': s.name, 'kind': s.kind, 'cmd': s.cmd, 'cwd': s.cwd,
                 'started': s.started, 'title': s.title, 'restores': s.restores,
                 'restored_at': s.restored_at}
                for s in sorted(self.sessions.values(), key=lambda s: s.started)]

    def save_state(self):
        tmp = self.state_path() + '.tmp'
        try:
            with open(tmp, 'w') as f:
                json.dump(self.state_entries(), f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.state_path())
        except OSError as e:
            log('cannot save state: %r' % e)

    def save_buffer(self, sess):
        try:
            with open(self.buf_file(sess.id), 'wb') as f:
                f.write(sess.replay())
            os.chmod(self.buf_file(sess.id), 0o600)
        except OSError as e:
            log('cannot save buffer for %s: %r' % (sess.id, e))

    def preload_buffer(self, sess):
        try:
            with open(self.buf_file(sess.id), 'rb') as f:
                data = f.read()
        except OSError:
            return
        cap = self.buffer_bytes()
        if cap > 0 and len(data) > cap:
            data = data[-cap:]
        sess.buf += data
        sess.buf += RESTORED_MSG
        try:
            os.unlink(self.buf_file(sess.id))
        except OSError:
            pass

    def read_sess_meta(self, sid):
        try:
            with open(self.sess_file(sid)) as f:
                v = json.load(f)
            return v if isinstance(v, dict) else {}
        except (OSError, ValueError):
            return {}

    def drop_files(self, sid):
        for p in (self.sess_file(sid), self.buf_file(sid)):
            try:
                os.unlink(p)
            except OSError:
                pass

    def title_changed(self, sess):
        if self.daemon.shutting_down or sess not in self.sessions:
            return
        self._title_dirty = True
        if self._title_task is None or self._title_task.done():
            self._title_task = self.loop.create_task(self._save_title_later())

    async def _save_title_later(self):
        await asyncio.sleep(5)
        self._title_dirty = False
        if not self.daemon.shutting_down:
            self.save_state()

    def spawn(self, cmd, cwd, env, name=None, kind='cmd', cols=100, rows=30, sid=None):
        cfg = self.cfg()
        try:
            max_sessions = int(cfg.get('max_sessions', 20))
        except (TypeError, ValueError):
            max_sessions = 20
        if sid is None and len(self.sessions) >= max_sessions:
            raise WebError('too many sessions (max %d)' % max_sessions)
        if not isinstance(cmd, list) or not cmd or not all(isinstance(x, str) for x in cmd):
            raise WebError('bad cmd')
        if not os.path.isdir(cwd):
            raise WebError('cwd does not exist: %s' % cwd)
        if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                for k, v in env.items()):
            raise WebError('bad env')
        self.ensure_sess_dir()
        sess = Session(self, cmd, cwd, env, name, kind, cols, rows, sid=sid)
        self.sessions[sess.id] = sess
        log('spawned session %s kind=%s cmd=%s pid=%d' % (sess.id, kind, cmd[0], sess.proc.pid))
        self.save_state()
        return sess

    def kill(self, sid):
        sess = self.sessions.get(sid)
        if not sess:
            return False
        try:
            os.killpg(sess.proc.pid, signal.SIGHUP)
        except OSError:
            pass
        self.loop.create_task(self._kill_later(sess))
        log('kill requested for %s' % sid)
        return True

    async def _kill_later(self, sess):
        await asyncio.sleep(3)
        if not sess.done and sess.proc.poll() is None:
            try:
                os.killpg(sess.proc.pid, signal.SIGKILL)
            except OSError:
                pass

    def check_finish(self, sess):
        if sess.done or sess.finishing:
            return
        if sess.proc.poll() is not None:
            self.loop.create_task(self._finish(sess))
        elif sess.eof_watch is None:
            sess.eof_watch = self.loop.create_task(self._watch_eof(sess))

    async def _watch_eof(self, sess):
        while not sess.done and sess.proc.poll() is None:
            await asyncio.sleep(0.2)
        await self._finish(sess)

    async def _finish(self, sess):
        if sess.done or sess.finishing:
            return
        sess.finishing = True
        try:
            self.loop.remove_reader(sess.master)
        except Exception:
            pass
        code = sess.proc.poll()
        if code is None:
            try:
                code = await asyncio.wait_for(
                    self.loop.run_in_executor(None, sess.proc.wait), 5)
            except asyncio.TimeoutError:
                try:
                    sess.proc.kill()
                except OSError:
                    pass
                code = await self.loop.run_in_executor(None, sess.proc.wait)
        sess.drain()
        try:
            os.close(sess.master)
        except OSError:
            pass
        if self.daemon.shutting_down:
            sess.done = True  # keep it for restore; clients keep silent (no exit frame)
            return
        resume = self.read_sess_meta(sess.id).get('claude_id')
        for c in list(sess.clients):
            c.send_exit(code, resume)
        sess.clients.clear()
        self.sessions.pop(sess.id, None)
        self.drop_files(sess.id)
        self.save_state()
        log('session %s ended code=%s' % (sess.id, code))


def read_frame_async(reader):
    async def _read():
        hdr = await reader.readexactly(5)
        ln = struct.unpack('>I', hdr[1:5])[0]
        if ln > 16 * 1024 * 1024:
            raise WebError('frame too large')
        payload = await reader.readexactly(ln) if ln else b''
        return hdr[0:1], payload
    return _read()


# ---------------------------------------------------------------- daemon

class Daemon:
    def __init__(self):
        self.loop = None
        self.mgr = Manager(self)
        self.fails = {}
        self._gz = {}
        self._cfg_cache = (-1, None)
        self.shutting_down = False
        self._stop_evt = None

    def cfg(self):
        try:
            mt = os.stat(cfg_path()).st_mtime_ns
        except OSError:
            return {}
        mt = int(mt)
        if self._cfg_cache[0] == mt and self._cfg_cache[1] is not None:
            return self._cfg_cache[1]
        cfg = load_cfg()
        self._cfg_cache = (mt, cfg)
        return cfg

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self._stop_evt = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                self.loop.add_signal_handler(sig, self._on_signal)
            except (NotImplementedError, OSError):
                pass
        os.makedirs(home_dir(), exist_ok=True)
        self.mgr.ensure_sess_dir()
        self.write_ver()
        self.restore_all()
        sock_path = os.path.join(home_dir(), 'web.sock')
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        unix_srv = await asyncio.start_unix_server(self.handle_unix, path=sock_path)
        os.chmod(sock_path, 0o600)
        cfg = self.cfg()
        port = int(cfg.get('port', 7700))
        self.tcp_srv = await asyncio.start_server(self.handle_conn, '127.0.0.1', port)
        log('listening on 127.0.0.1:%d and %s' % (port, sock_path))
        self.tls_srv = None
        tp, cert, key = cfg.get('tls_port'), cfg.get('cert'), cfg.get('key')
        if tp and cert and key:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(cert, key)
            self.tls_srv = await asyncio.start_server(self.handle_conn, '0.0.0.0',
                                                      int(tp), ssl=ctx)
            log('listening on 0.0.0.0:%s (TLS)' % tp)
        await self._stop_evt.wait()

    # ---- shutdown / restore --------------------------------------------------

    def write_ver(self):
        try:
            with open(__file__, 'rb') as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            with open(os.path.join(home_dir(), 'web.ver'), 'w') as f:
                f.write(digest)
        except OSError as e:
            log('cannot write web.ver: %r' % e)

    def _on_signal(self):
        if self.shutting_down:
            return
        self.shutting_down = True
        log('shutting down')
        self.loop.create_task(self._shutdown())

    async def _shutdown(self):
        self.mgr.save_state()
        for sess in list(self.mgr.sessions.values()):
            self.mgr.save_buffer(sess)
            for c in list(sess.clients):
                c.close()  # no exit frame: clients will reconnect to the new daemon
            sess.clients.clear()
        for sess in list(self.mgr.sessions.values()):
            try:
                os.killpg(sess.proc.pid, signal.SIGHUP)
            except OSError:
                pass
        self._stop_evt.set()

    def restore_all(self):
        try:
            with open(self.mgr.state_path()) as f:
                entries = json.load(f)
        except (OSError, ValueError):
            return
        if not isinstance(entries, list):
            return
        for e in entries:
            if not isinstance(e, dict) or not isinstance(e.get('id'), str) \
                    or '/' in e['id'] or e['id'] in ('.', '..'):
                continue
            if not self.restore_one(e):
                self.mgr.drop_files(e['id'])
        self.mgr.save_state()

    def restore_one(self, e):
        try:
            prev_restores = int(e.get('restores', 0))
        except (TypeError, ValueError):
            prev_restores = 0
        try:
            ra = float(e['restored_at']) if e.get('restored_at') is not None else None
        except (TypeError, ValueError):
            ra = None
        if prev_restores >= 3 and (ra is None or time.time() - ra < 60):
            log('crash-loop guard: not restoring session %s' % e['id'])
            return False
        cmd = self.restore_cmd(e, self.mgr.read_sess_meta(e['id']))
        if cmd is None:
            log('not restoring session %s (kind=%s)' % (e['id'], e.get('kind')))
            return False
        cwd = e.get('cwd')
        if not cwd or not os.path.isdir(cwd):
            cwd = os.path.expanduser('~/workspace')
            try:
                os.makedirs(cwd, exist_ok=True)
            except OSError:
                pass
        env = dict(os.environ)
        env['KOLOOD_INSIDE'] = '1'
        env['TERM'] = 'xterm-256color'
        env.setdefault('LANG', 'C.UTF-8')
        try:
            sess = self.mgr.spawn(cmd, cwd, env, name=e.get('name'),
                                  kind=e.get('kind') or 'cmd', sid=e['id'])
        except (WebError, OSError, TypeError, ValueError) as ex:
            log('cannot restore session %s: %r' % (e['id'], ex))
            return False
        sess.restores = prev_restores + 1
        sess.restored_at = time.time()
        if e.get('title'):
            sess.osc_title = str(e['title'])
        self.mgr.preload_buffer(sess)
        self.loop.create_task(self._restored_lived(sess))
        log('restored session %s restores=%d' % (sess.id, sess.restores))
        return True

    @staticmethod
    def restore_cmd(e, meta):
        """Build the command for a restored session, or None to not restore."""
        cmd = e.get('cmd')
        if not isinstance(cmd, list) or not cmd or not all(isinstance(x, str) for x in cmd):
            return None
        is_start = cmd[0].endswith('kolood_start')
        if is_start and meta.get('claude_id'):
            out = [cmd[0], cmd[1] if len(cmd) > 1 else '']
            if meta.get('no_remote'):
                out.append('--no-remote')
            account = meta.get('account')
            if account and account != 'default':
                out += ['--account', str(account)]
            out += ['--resume', str(meta['claude_id'])]
            return out
        if is_start:  # a Claude session without a known conversation id is not re-run (its args may hold a prompt)
            return list(cmd) if '--shell' in cmd else None
        if e.get('kind') in ('shell', 'remote'):
            return list(cmd)
        # anything else only if it is a plain interactive shell (never re-run an arbitrary command or script)
        if os.path.basename(cmd[0]) in ('sh', 'bash', 'zsh', 'dash', 'fish', 'ksh') and all(x.startswith('-') and x != '-c' for x in cmd[1:]):
            return list(cmd)
        return None

    async def _restored_lived(self, sess):
        await asyncio.sleep(60)
        if self.mgr.sessions.get(sess.id) is sess and not self.shutting_down:
            sess.restores = 0  # it survived: restart the crash-loop counter
            self.mgr.save_state()

    # ---- unix socket

    async def handle_unix(self, reader, writer):
        try:
            t, p = (await read_frame_async(reader))
            if t != b'J':
                return
            msg = json.loads(p or b'{}')
            op = msg.get('op')
            if op == 'ping':
                SockClient(writer).write_json({'ok': True})
            elif op == 'list':
                sess_list = [{'id': s.id, 'name': s.name, 'kind': s.kind, 'title': s.title,
                              'started': s.started, 'clients': len(s.clients),
                              'cols': s.cols, 'rows': s.rows}
                             for s in self.mgr.sessions.values()]
                SockClient(writer).write_json({'sessions': sess_list})
            elif op == 'kill':
                ok = self.mgr.kill(msg.get('id'))
                SockClient(writer).write_json({'ok': ok})
            elif op in ('spawn', 'attach'):
                await self.stream_unix(reader, writer, msg)
            else:
                SockClient(writer).write_json({'ok': False, 'error': 'bad op'})
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        except Exception as e:
            log('unix error %r' % e)
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def stream_unix(self, reader, writer, msg):
        op = msg.get('op')
        sess = None
        if op == 'spawn':
            try:
                sess = self.mgr.spawn(msg.get('cmd'), msg.get('cwd') or os.getcwd(),
                                      msg.get('env') or {}, msg.get('name'),
                                      msg.get('kind', 'cmd'),
                                      int(msg.get('cols') or 80), int(msg.get('rows') or 24))
            except (WebError, TypeError, ValueError) as e:
                SockClient(writer).write_json({'ok': False, 'error': str(e)})
                return
            SockClient(writer).write_json({'ok': True, 'id': sess.id})
        else:
            sess = self.mgr.sessions.get(msg.get('id'))
            if not sess:
                SockClient(writer).write_json({'ok': False, 'error': 'unknown session'})
                return
            SockClient(writer).write_json({'ok': True})
            sess.resize(int(msg.get('cols') or 0), int(msg.get('rows') or 0))
        client = SockClient(writer)
        sess.clients.add(client)
        client.write_d(sess.replay())
        try:
            while True:
                t, p = (await read_frame_async(reader))
                if t is None:
                    break
                if t == b'D':
                    try:
                        if p:
                            os.write(sess.master, p)
                    except OSError:
                        break
                elif t == b'J':
                    try:
                        m = json.loads(p or b'{}')
                    except json.JSONDecodeError:
                        continue
                    if m.get('op') == 'resize':
                        sess.resize(m.get('cols'), m.get('rows'))
        except (asyncio.IncompleteReadError, ConnectionError, OSError, WebError):
            pass
        finally:
            sess.clients.discard(client)
            client.close()

    # ---- HTTP

    async def handle_conn(self, reader, writer):
        peer = writer.get_extra_info('peername')
        is_tls = writer.get_extra_info('ssl_object') is not None
        try:
            req = await self.read_request(reader, writer)
            if req is None:
                return
            await self.route(reader, writer, *req, is_tls=is_tls, peer=peer)
        except (ConnectionError, asyncio.IncompleteReadError, OSError):
            pass
        except Exception as e:
            log('http error %r' % e)
            try:
                await self.respond(writer, 500, {'error': 'internal error'})
            except Exception:
                pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def read_request(self, reader, writer):
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = await reader.read(4096)
            if not chunk:
                return None
            data += chunk
            if len(data) > MAX_HEADER:
                await self.respond(writer, 413, {'error': 'headers too large'})
                return None
        head, _, rest = data.partition(b'\r\n\r\n')
        lines = head.split(b'\r\n')
        try:
            parts = lines[0].decode('latin1').split()
            method, target = parts[0], parts[1]
        except (IndexError, UnicodeDecodeError):
            await self.respond(writer, 400, {'error': 'bad request line'})
            return None
        headers = {}
        for line in lines[1:]:
            k, _, v = line.partition(b':')
            headers[k.decode('latin1').strip().lower()] = v.decode('latin1').strip()
        body = rest
        try:
            cl = int(headers.get('content-length') or 0)
        except ValueError:
            cl = 0
        if cl:
            if cl > MAX_BODY:
                await self.respond(writer, 413, {'error': 'body too large'})
                return None
            while len(body) < cl:
                chunk = await reader.read(cl - len(body))
                if not chunk:
                    return None
                body += chunk
            body = body[:cl]
        return method, target, headers, body

    async def respond(self, writer, status, obj=None, headers=None, body=None,
                      content_type='application/json'):
        if body is None:
            body = json.dumps(obj if obj is not None else {}).encode()
        lines = ['HTTP/1.1 %d %s' % (status, REASONS.get(status, 'OK'))]
        hdrs = [('Content-Type', content_type), ('Content-Length', str(len(body))),
                ('Connection', 'close'), ('Cache-Control', 'no-store')]
        if headers:
            hdrs += headers
        for k, v in hdrs:
            lines.append('%s: %s' % (k, v))
        writer.write(('\r\n'.join(lines) + '\r\n\r\n').encode('latin1') + body)
        await writer.drain()

    async def route(self, reader, writer, method, target, headers, body, is_tls, peer):
        path = urllib.parse.urlsplit(target).path
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(target).query)
        if method == 'GET' and path == '/':
            return await self.serve_asset(writer, 'index.html', headers, is_index=True)
        if method == 'GET' and path.startswith('/static/'):
            name = path[len('/static/'):]
            if name not in STATIC_WHITELIST:
                return await self.respond(writer, 404, {'error': 'not found'})
            return await self.serve_asset(writer, 'static/' + name, headers)
        if method == 'POST' and path == '/api/login':
            return await self.api_login(writer, headers, body, is_tls, peer)
        if method == 'POST' and path == '/api/logout':
            clear = ('Set-Cookie', 'kolood=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/')
            return await self.respond(writer, 200, {'ok': True}, headers=[clear])
        if not self.check_cookie(headers):
            return await self.respond(writer, 401, {'error': 'unauthorized'})
        if method == 'POST' and headers.get('x-kolood') != '1':
            return await self.respond(writer, 403, {'error': 'forbidden'})
        if method == 'GET' and path == '/api/me':
            return await self.respond(writer, 200, {})
        if method == 'GET' and path == '/api/sessions':
            return await self.respond(writer, 200, self.sessions_payload())
        if method == 'POST' and path == '/api/new':
            return await self.api_new(writer, body)
        if method == 'POST' and path == '/api/kill':
            return await self.api_kill(writer, body)
        if method == 'GET' and path == '/ws':
            return await self.handle_ws(reader, writer, headers, query, is_tls)
        return await self.respond(writer, 404, {'error': 'not found'})

    # ---- auth

    def client_ip(self, peer, headers):
        host = peer[0] if isinstance(peer, tuple) and peer else None
        if host in ('127.0.0.1', '::1', 'localhost'):
            xff = headers.get('x-forwarded-for')
            if xff:
                return xff.split(',')[0].strip()
        return host or 'unknown'

    def make_cookie(self, cfg):
        secret = cfg.get('secret') or ''
        expiry = int(time.time() + 30 * 86400)
        sig = hmac.new(bytes.fromhex(secret), str(expiry).encode(), hashlib.sha256).hexdigest()
        return '%d.%s' % (expiry, sig)

    def cookie_valid(self, raw, cfg):
        secret = cfg.get('secret') or ''
        if not secret or not raw or '.' not in raw:
            return False
        exp, _, sig = raw.partition('.')
        if not exp.isdigit():
            return False
        try:
            want = hmac.new(bytes.fromhex(secret), exp.encode(), hashlib.sha256).hexdigest()
        except ValueError:
            return False
        return hmac.compare_digest(want, sig) and int(exp) > time.time()

    def check_cookie(self, headers):
        raw = None
        for part in (headers.get('cookie') or '').split(';'):
            k, _, v = part.strip().partition('=')
            if k == 'kolood':
                raw = v
        return self.cookie_valid(raw, self.cfg())

    async def api_login(self, writer, headers, body, is_tls, peer):
        cfg = self.cfg()
        pw_hash, salt = cfg.get('pw_hash'), cfg.get('pw_salt')
        if not pw_hash or not salt or not cfg.get('secret'):
            return await self.respond(writer, 503,
                                      {'error': 'no password set: run kolood web password'})
        ip = self.client_ip(peer, headers)
        now = time.time()
        lst = [t for t in self.fails.get(ip, []) if now - t < 600]
        self.fails[ip] = lst
        if len(lst) >= 10:
            return await self.respond(writer, 429, {'error': 'too many attempts, wait'})
        try:
            msg = json.loads(body or b'{}')
        except json.JSONDecodeError:
            return await self.respond(writer, 400, {'error': 'bad json'})
        pw = msg.get('password', '')
        got = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt.encode(), 200000).hex()
        if hmac.compare_digest(got, pw_hash):
            secure = is_tls or headers.get('x-forwarded-proto', '').lower() == 'https'
            sc = 'Set-Cookie', ('kolood=%s; Max-Age=2592000; HttpOnly; SameSite=Strict; '
                                'Path=/' + ('; Secure' if secure else '')) % self.make_cookie(cfg)
            return await self.respond(writer, 200, {'ok': True}, headers=[sc])
        lst.append(now)
        return await self.respond(writer, 401, {'error': 'wrong password'})

    # ---- api

    @staticmethod
    def account_list():
        accounts = ['default']
        base = os.path.expanduser('~/.config/kolood/accounts')
        try:
            accounts += sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
        except OSError:
            pass
        return accounts

    def sessions_payload(self):
        running = sorted(
            ({'id': s.id, 'title': s.title, 'kind': s.kind, 'started': s.started,
              'clients': len(s.clients)} for s in self.mgr.sessions.values()),
            key=lambda s: s['started'])
        return {'running': running, 'recent': self.collect_recent(self.account_list()),
                'accounts': self.account_list()}

    @staticmethod
    def collect_recent(accounts):
        cfgdirs = [('default', os.path.expanduser('~/.claude/projects'))]
        for acct in accounts:
            if acct == 'default':
                continue
            cfgdirs.append((acct, os.path.expanduser(
                '~/.config/kolood/accounts/%s/projects' % acct)))
        out, seen = [], set()
        for account, projdir in cfgdirs:
            real = os.path.realpath(projdir)  # accounts share one store (symlink): list each conversation once
            if real in seen:
                continue
            seen.add(real)
            for fp in glob.glob(os.path.join(projdir, '*', '*.jsonl')):
                item = Daemon.parse_jsonl(fp, account)
                if item:
                    out.append(item)
        out.sort(key=lambda x: x['mtime'], reverse=True)
        return out[:30]

    @staticmethod
    def parse_jsonl(fp, account):
        title = None
        first_user = None
        cwd = None
        try:
            with open(fp, encoding='utf-8', errors='replace') as f:
                for i, line in enumerate(f):
                    if i >= 200:
                        break
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(obj, dict):
                        continue
                    if cwd is None and isinstance(obj.get('cwd'), str):
                        cwd = obj['cwd']
                    t = obj.get('type')
                    if t == 'summary' and isinstance(obj.get('summary'), str) and not title:
                        title = obj['summary']
                    elif t == 'user' and first_user is None:
                        msg = obj.get('message')
                        c = msg.get('content') if isinstance(msg, dict) else None
                        if isinstance(c, str) and c:
                            if not c.lstrip().startswith('<'):  # slash-command / caveat wrappers are not a title
                                first_user = c
                        elif isinstance(c, list):
                            for part in c:
                                if (isinstance(part, dict) and part.get('type') == 'text'
                                        and isinstance(part.get('text'), str) and part['text']):
                                    first_user = part['text']
                                    break
                    if title and cwd:
                        break
        except OSError:
            return None
        if not title:
            title = first_user
        if not title:
            return None
        title = ' '.join(title.split())[:80]
        try:
            mtime = os.path.getmtime(fp)
        except OSError:
            mtime = 0
        return {'id': os.path.splitext(os.path.basename(fp))[0], 'title': title,
                'cwd': cwd, 'mtime': mtime, 'account': account}

    def build_cmd(self, kind, account, resume):
        cfg = self.cfg()
        override = (cfg.get('commands') or {}).get(kind)
        if override:
            cmd = [os.path.expanduser(str(x)) for x in override]
        elif kind == 'claude':
            start = os.path.expanduser('~/.ssh/kolood_start')
            if os.path.isfile(start) and os.access(start, os.X_OK):
                cmd = [start, '']
            else:
                cmd = ['claude']
        elif kind == 'shell':
            cmd = [os.environ.get('SHELL') or '/bin/bash', '-l']
        elif kind == 'remote':
            cmd = ['ssh', '-t', 'remote']
        else:
            raise WebError('bad kind')
        if kind == 'claude':
            if account and account != 'default':
                cmd += ['--account', account]
            if resume:
                cmd += ['--resume', resume]
        return cmd

    async def api_new(self, writer, body):
        try:
            msg = json.loads(body or b'{}')
        except json.JSONDecodeError:
            return await self.respond(writer, 400, {'error': 'bad json'})
        kind = msg.get('kind')
        if kind not in ('claude', 'shell', 'remote'):
            return await self.respond(writer, 400, {'error': 'bad kind'})
        account, resume = msg.get('account'), msg.get('resume')
        if account is not None and not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,31}', account):
            return await self.respond(writer, 400, {'error': 'bad account'})
        if resume is not None and not re.fullmatch(r'[A-Za-z0-9-]{1,64}', resume):
            return await self.respond(writer, 400, {'error': 'bad resume id'})
        try:
            cmd = self.build_cmd(kind, account, resume)
        except WebError as e:
            return await self.respond(writer, 400, {'error': str(e)})
        cwd = os.path.expanduser('~/workspace')
        os.makedirs(cwd, exist_ok=True)
        if kind == 'claude' and resume:
            # resume in the folder the conversation ran in (it is on the device
            # mount, so isdir() here means it exists on the server too)
            for item in self.collect_recent(self.account_list()):
                if item['id'] != resume:
                    continue
                c = item.get('cwd') or ''
                if c.startswith('/') and len(cmd) > 1 and cmd[1] == '':
                    # the b64 cwd arg for kolood_start: it mounts the user's folder if needed and works there
                    cmd[1] = base64.b64encode(c.encode()).decode()
                if os.path.isdir(c):
                    cwd = c
                break
        env = dict(os.environ)
        env['KOLOOD_INSIDE'] = '1'
        env['TERM'] = 'xterm-256color'
        env.setdefault('LANG', 'C.UTF-8')  # services often start without a locale; Claude's UI needs UTF-8
        try:
            sess = self.mgr.spawn(cmd, cwd, env, kind=kind, cols=100, rows=30)
        except (WebError, OSError) as e:
            return await self.respond(writer, 400, {'error': str(e)})
        return await self.respond(writer, 200, {'id': sess.id})

    async def api_kill(self, writer, body):
        try:
            msg = json.loads(body or b'{}')
        except json.JSONDecodeError:
            return await self.respond(writer, 400, {'error': 'bad json'})
        if self.mgr.kill(msg.get('id')):
            return await self.respond(writer, 200, {'ok': True})
        return await self.respond(writer, 404, {'error': 'unknown session'})

    # ---- assets

    CONTENT_TYPES = {'.html': 'text/html; charset=utf-8',
                     '.js': 'text/javascript; charset=utf-8',
                     '.css': 'text/css; charset=utf-8',
                     '.png': 'image/png'}

    def gz_asset(self, name, mtime, raw):
        hit = self._gz.get(name)
        if hit and hit[0] == mtime:
            return hit[1]
        gz = gzip.compress(raw, 5)
        self._gz[name] = (mtime, gz)
        return gz

    async def serve_asset(self, writer, name, headers, is_index=False):
        path = os.path.join(ASSET_DIR, name)
        try:
            with open(path, 'rb') as f:
                raw = f.read()
            mtime = int(os.stat(path).st_mtime)
        except OSError:
            return await self.respond(writer, 404, {'error': 'not found'})
        ct = self.CONTENT_TYPES.get(os.path.splitext(name)[1], 'application/octet-stream')
        data = raw
        extra = []
        if 'gzip' in (headers.get('accept-encoding') or '').lower():
            data = self.gz_asset(name, mtime, raw)
            extra.append(('Content-Encoding', 'gzip'))
        extra.append(('Cache-Control', 'max-age=86400' if not is_index else 'no-store'))
        return await self.respond(writer, 200, headers=extra, body=data,
                                  content_type=ct)

    # ---- websocket

    async def handle_ws(self, reader, writer, headers, query, is_tls):
        sess_id = (query.get('id') or [None])[0]
        origin = headers.get('origin')
        if origin and urllib.parse.urlsplit(origin).netloc != headers.get('host', ''):
            return await self.respond(writer, 403, {'error': 'bad origin'})
        key = headers.get('sec-websocket-key')
        if (headers.get('upgrade') or '').lower() != 'websocket' or not key:
            return await self.respond(writer, 400, {'error': 'not a websocket request'})
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        writer.write(('HTTP/1.1 101 Switching Protocols\r\n'
                      'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                      'Sec-WebSocket-Accept: %s\r\n\r\n' % accept).encode())
        await writer.drain()
        sess = self.mgr.sessions.get(sess_id)
        if not sess:
            try:
                writer.write(ws_encode(8, struct.pack('!H', 4404)))
                await writer.drain()
            finally:
                writer.close()
            return
        client = WsClient(writer)
        sess.clients.add(client)
        client.write_d(sess.replay())
        try:
            while True:
                m = await self.ws_read_message(reader, writer)
                if m is None:
                    break
                op, payload = m
                if op == 1:
                    try:
                        msg = json.loads(payload.decode('utf-8'))
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if msg.get('t') == 'in':
                        try:
                            os.write(sess.master, str(msg.get('d', '')).encode('utf-8'))
                        except OSError:
                            break
                    elif msg.get('t') == 'resize':
                        sess.resize(msg.get('cols'), msg.get('rows'))
        except (asyncio.IncompleteReadError, ConnectionError, OSError, WebError):
            pass
        finally:
            sess.clients.discard(client)
            try:
                writer.close()
            except Exception:
                pass

    async def ws_read_message(self, reader, writer):
        msg_op = None
        buf = b''
        while True:
            hdr = await reader.readexactly(2)
            b1, b2 = hdr
            fin = b1 & 0x80
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            ln = b2 & 0x7F
            if ln == 126:
                ln = struct.unpack('!H', await reader.readexactly(2))[0]
            elif ln == 127:
                ln = struct.unpack('!Q', await reader.readexactly(8))[0]
            if ln > MAX_WS_FRAME:
                try:
                    writer.write(ws_encode(8, struct.pack('!H', 1009)))
                    await writer.drain()
                finally:
                    writer.close()
                raise WebError('ws frame too large')
            mask = await reader.readexactly(4) if masked else None
            payload = await reader.readexactly(ln) if ln else b''
            if mask:
                payload = bytes(c ^ mask[i & 3] for i, c in enumerate(payload))
            if opcode in (8, 9, 10):
                if opcode == 9:
                    writer.write(ws_encode(10, payload))
                elif opcode == 8:
                    writer.write(ws_encode(8, payload[:2]))
                    await writer.drain()
                    writer.close()
                    return None
                continue
            if opcode != 0:
                msg_op, buf = opcode, payload
            elif msg_op is None:
                writer.close()
                raise WebError('bad continuation')
            else:
                buf += payload
            if fin and msg_op is not None:
                return msg_op, buf


def cmd_serve():
    try:
        asyncio.run(Daemon().run())
    except KeyboardInterrupt:
        pass


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else ''
    if cmd == 'serve':
        cmd_serve()
    elif cmd == 'passwd':
        cmd_passwd(args[1:])
    elif cmd == 'status':
        cmd_status()
    elif cmd == 'list':
        cmd_list()
    elif cmd == 'history':
        cmd_history(args[1:])
    elif cmd == 'kill':
        if len(args) < 2:
            print('usage: kolood_web.py kill ID', file=sys.stderr)
            sys.exit(1)
        cmd_kill(args[1])
    elif cmd == 'attach':
        cmd_attach(args[1:])
    else:
        print('usage: kolood_web.py {serve|passwd|status|list|history|kill|attach}', file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
