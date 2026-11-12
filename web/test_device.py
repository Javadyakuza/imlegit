"""Tests for kolood_device.py — no real ssh: a fake ssh runs commands locally."""
import base64
import json
import os
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import http.client

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, 'kolood_device.py')
WEB = os.path.join(HERE, 'kolood_web.py')
PY = sys.executable

FAKE_SSH = '''#!/bin/sh
while [ "$#" -gt 0 ] && [ "$1" != remote ]; do shift; done
[ "$#" -gt 0 ] || exit 5
shift
printf '%s\\n' "$1" >> "${KOLOOD_FAKE_LOG:-/dev/null}"
exec /bin/sh -c "$1"
'''

FAKE_SSH_255 = '#!/bin/sh\nexit 255\n'

FAKE_OPEN = '#!/bin/sh\necho "OPENED $*"\n'

FAKE_RG = '#!/bin/sh\nprintf \'RG:%s\\n\' "$*"\n'

FAKE_SHIM_RG = '#!/bin/sh\necho SHIM-RAN\n'

FAKE_XCLIP = '''#!/bin/sh
mode=$(cat "$KOLOOD_CLIP_MODE" 2>/dev/null)
case "$*" in
*"-t TARGETS -o"*)
  if [ "$mode" = image ]; then echo image/png; else echo text/plain; fi;;
*"-t image/png -o"*)
  if [ "$mode" = image ]; then printf '\\211PNG\\r\\n\\032\\n\\000fake-data'; fi;;
*"-selection clipboard -o"*|*"-o")
  if [ "$mode" = text ]; then printf 'CLIP-TEXT\\nline2'; fi;;
esac
exit 0
'''


def write_script(path, content, mode=0o755):
    with open(path, 'w') as f:
        f.write(content)
    os.chmod(path, mode)
    return path


class DevBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='kolood-dev-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = os.path.join(self.tmp, 'fakehome')  # fake server $HOME
        self.root = os.path.join(self.tmp, 'device')   # KOLOOD_DEVICE_ROOT
        self.log = os.path.join(self.tmp, 'ssh.log')
        os.makedirs(self.home)
        os.makedirs(self.root)
        self.sshdir = os.path.join(self.tmp, 'sshbin')
        os.makedirs(self.sshdir)
        write_script(os.path.join(self.sshdir, 'fake-ssh'), FAKE_SSH)
        write_script(os.path.join(self.sshdir, 'fake-ssh-255'), FAKE_SSH_255)
        self.base_env = {
            'HOME': self.home,
            'KOLOOD_SSH': os.path.join(self.sshdir, 'fake-ssh'),
            'KOLOOD_REMOTE': 'remote',
            'KOLOOD_DEVICE_ROOT': self.root,
            'KOLOOD_FAKE_LOG': self.log,
        }

    def log_lines(self):
        try:
            with open(self.log) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def run_dev(self, args, env=None, cwd=None, input=None, timeout=30):
        e = dict(os.environ)
        for k in ('KOLOOD_DEVICE_ROOT', 'KOLOOD_SSH', 'KOLOOD_REMOTE',
                  'KOLOOD_SHIM_DIR', 'KOLOOD_DEVICE_OS', 'KOLOOD_FAKE_LOG',
                  'KOLOOD_CLIP_MODE', 'CLAUDECODE', 'CLAUDE_PROJECT_DIR',
                  'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_OAUTH_TOKEN',
                  'ANTHROPIC_API_KEY', 'SHELL', 'KOLOOD_CONFIG_VIEW',
                  'KOLOOD_CONFIG_REAL', 'KOLOOD_DEVICE_CFG'):
            e.pop(k, None)
        e.update(self.base_env)
        if env:
            e.update(env)
        # no inherited stdin: a pipe/file from the caller (ssh, CI) would count as "piped data"
        return subprocess.run([PY, DEV] + list(args), env=e, cwd=cwd,
                              input=input, stdin=None if input is not None else subprocess.DEVNULL,
                              capture_output=True, timeout=timeout)


class TestShell(DevBase):
    def bash_tool_string(self, n, snap):
        return ('source ' + snap + ' 2>/dev/null || true && '
                '{ shopt -u extglob || setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL; } '
                '>/dev/null 2>&1 || true && '
                "{ \\builtin unalias -- 'which'; \\builtin unset -f -- 'which'; } "
                '>/dev/null 2>&1 || true && '
                "eval 'echo PFX-OK' < /dev/null && pwd -P >| /tmp/claude-test%d-cwd" % n)

    def test_bash_tool_string(self):
        n = int(time.time() * 1000) % 100000000
        cwdfile = '/tmp/claude-test%d-cwd' % n
        self.addCleanup(lambda: os.path.exists(cwdfile) and os.remove(cwdfile))
        snap = os.path.join(self.home, '.claude', 'shell-snapshots',
                            'snapshot-zsh-123-abc.sh')
        r = self.run_dev(['shell', self.bash_tool_string(n, snap)], cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'PFX-OK', r.stdout)
        lines = self.log_lines()
        self.assertEqual(len(lines), 2, lines)
        self.assertNotIn('shell-snapshots', lines[0])
        self.assertFalse(lines[0].startswith('source'), lines[0])
        self.assertIn('echo PFX-OK', lines[0])
        self.assertIn('cd %s' % shlex.quote(os.path.realpath(self.root)), lines[0])
        self.assertEqual(lines[1], 'cat %s && rm -f %s' % (cwdfile, cwdfile))
        with open(cwdfile) as f:
            self.assertEqual(f.read().strip(), os.path.realpath(self.root))

    def test_exit_code_and_unreachable(self):
        r = self.run_dev(['shell', 'exit 7'], cwd=self.root)
        self.assertEqual(r.returncode, 7)
        r = self.run_dev(['shell', 'echo hi'], cwd=self.root,
                         env={'KOLOOD_SSH': os.path.join(self.sshdir, 'fake-ssh-255')})
        self.assertEqual(r.returncode, 255)
        self.assertIn(b'your computer is not reachable', r.stderr)

    def test_routing_to_server(self):
        # CLAUDE_PLUGIN_ROOT -> server (local bash)
        r = self.run_dev(['shell', "CLAUDE_PLUGIN_ROOT=/x echo LOCAL-A"],
                         cwd=self.root)
        self.assertEqual(r.returncode, 0)
        self.assertIn(b'LOCAL-A', r.stdout)
        self.assertEqual(self.log_lines(), [])
        # server $HOME followed by / -> local
        r = self.run_dev(['shell', 'echo LOCAL-B %s/sub' % self.home], cwd=self.root)
        self.assertIn(b'LOCAL-B', r.stdout)
        self.assertEqual(self.log_lines(), [])
        # cwd outside the device root -> local
        r = self.run_dev(['shell', 'echo LOCAL-C'], cwd=self.tmp)
        self.assertIn(b'LOCAL-C', r.stdout)
        self.assertEqual(self.log_lines(), [])
        # Claude's clipboard probe -> local (our shims handle it on the server)
        probe = ('xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -E x; '
                 'echo LOCAL-D')
        r = self.run_dev(['shell', probe], cwd=self.root)
        self.assertEqual(r.returncode, 0)
        self.assertIn(b'LOCAL-D', r.stdout)
        self.assertEqual(self.log_lines(), [])

    def test_forwarded_env(self):
        r = self.run_dev(['shell', 'true'], cwd=self.root, env={
            'CLAUDECODE': '1',
            'CLAUDE_PROJECT_DIR': '/fake/project',
            'CLAUDE_CODE_OAUTH_TOKEN': 'SECRET-TOK',
            'ANTHROPIC_API_KEY': 'SECRET-KEY',
            'CLAUDE_CONFIG_DIR': '/no/such',
        })
        self.assertEqual(r.returncode, 0)
        line = self.log_lines()[0]
        self.assertIn('export CLAUDECODE=1', line)
        self.assertIn('CLAUDE_PROJECT_DIR=/fake/project', line)
        for bad in ('OAUTH', 'ANTHROPIC', 'SECRET', 'CLAUDE_CONFIG_DIR', 'PATH=',
                    'HOME='):
            self.assertNotIn(bad, line)

    def test_hook_stdin(self):
        payload = b'{"hook":"JSON"}'
        r = self.run_dev(['shell', 'cat'], cwd=self.root, input=payload)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, payload)


class TestShims(DevBase):
    def setUp(self):
        super().setUp()
        self.shimdir = os.path.join(self.tmp, 'shim')
        self.realdir = os.path.join(self.tmp, 'real')
        os.makedirs(self.shimdir)
        os.makedirs(self.realdir)
        write_script(os.path.join(self.shimdir, 'rg'), FAKE_SHIM_RG)
        write_script(os.path.join(self.realdir, 'rg'), FAKE_RG)
        self.dev_path = self.realdir + os.pathsep + os.environ.get('PATH', '')
        self.host_path = self.shimdir + os.pathsep + self.realdir + os.pathsep + \
            os.environ.get('PATH', '')

    def test_inside_root_via_ssh(self):
        r = self.run_dev(['rg', "pat'tern x", 'sp ace'], cwd=self.root,
                         env={'PATH': self.dev_path})
        self.assertEqual(r.returncode, 0, r.stderr)
        want = 'cd %s && exec rg %s %s' % (shlex.quote(os.path.realpath(self.root)),
                                           shlex.quote("pat'tern x"),
                                           shlex.quote('sp ace'))
        # stdin is not piped here, so the remote side gets none (rg would otherwise search stdin)
        self.assertEqual(self.log_lines()[0], want + ' </dev/null')
        self.assertIn(b"RG:pat'tern x sp ace", r.stdout)

    def test_outside_root_real_tool(self):
        r = self.run_dev(['rg', 'x'], cwd=self.tmp,
                         env={'PATH': self.host_path, 'KOLOOD_SHIM_DIR': self.shimdir})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(b'SHIM-RAN', r.stdout)  # shim dir skipped, real tool exec'd
        self.assertIn(b'RG:x', r.stdout)
        self.assertEqual(self.log_lines(), [])

    def test_tool_missing(self):
        empty = os.path.join(self.tmp, 'empty')
        os.makedirs(empty)
        r = self.run_dev(['git', 'status'], cwd=self.tmp,
                         env={'PATH': empty, 'KOLOOD_SHIM_DIR': self.shimdir})
        self.assertEqual(r.returncode, 127)
        self.assertIn(b'kolood: git not found', r.stderr)


class TestOpen(DevBase):
    def test_rejects_non_url(self):
        r = self.run_dev(['open', 'javascript:x'], cwd=self.root)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.log_lines(), [])

    def test_darwin_quoted_url(self):
        fakedir = os.path.join(self.tmp, 'fakeopen')
        os.makedirs(fakedir)
        write_script(os.path.join(fakedir, 'open'), FAKE_OPEN)
        path = fakedir + os.pathsep + os.environ.get('PATH', '')
        r = self.run_dev(['open', 'https://a b'], cwd=self.root,
                         env={'KOLOOD_DEVICE_OS': 'Darwin', 'PATH': path})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.log_lines()[0], "exec open 'https://a b'")
        self.assertIn(b'OPENED https://a b', r.stdout)

    def test_linux_background(self):
        r = self.run_dev(['open', 'file:///tmp/x'], cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.log_lines()[0], 'xdg-open file:///tmp/x >/dev/null 2>&1 &')


class TestClipboard(DevBase):
    def setUp(self):
        super().setUp()
        self.clipdir = os.path.join(self.tmp, 'clipbin')
        os.makedirs(self.clipdir)
        write_script(os.path.join(self.clipdir, 'xclip'), FAKE_XCLIP)
        self.png = b'\x89PNG\r\n\x1a\n\x00fake-data'
        self.clipmode = os.path.join(self.tmp, 'clipmode')
        self.env = {'PATH': self.clipdir + os.pathsep + os.environ.get('PATH', ''),
                    'KOLOOD_DEVICE_OS': 'Linux',
                    'KOLOOD_CLIP_MODE': self.clipmode}

    def set_mode(self, mode):
        with open(self.clipmode, 'w') as f:
            f.write(mode)

    def test_targets_image(self):
        self.set_mode('image')
        r = self.run_dev(['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
                         cwd=self.root, env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'image/png\n')
        r = self.run_dev(['wl-paste', '-l'], cwd=self.root, env=self.env)
        self.assertEqual(r.stdout, b'image/png\n')

    def test_image_bytes(self):
        self.set_mode('image')
        r = self.run_dev(['xclip', '-selection', 'clipboard', '-t', 'image/png', '-o'],
                         cwd=self.root, env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, self.png)
        r = self.run_dev(['wl-paste', '--type', 'image/png'], cwd=self.root, env=self.env)
        self.assertEqual(r.stdout, self.png)

    def test_targets_text(self):
        self.set_mode('text')
        r = self.run_dev(['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
                         cwd=self.root, env=self.env)
        self.assertEqual(r.stdout, b'text/plain\n')
        r = self.run_dev(['wl-paste'], cwd=self.root, env=self.env)
        self.assertEqual(r.stdout, b'CLIP-TEXT\nline2')

    def test_unsupported(self):
        self.set_mode('image')
        for args in (['-selection', 'clipboard', '-t', 'image/bmp', '-o'],
                     ['wl-paste'], ['--type', 'image/bmp']):
            sub = ['xclip'] if args[0] == '-selection' else ['wl-paste']
            r = self.run_dev(sub + args, cwd=self.root, env=self.env)
            self.assertEqual(r.returncode, 1, (sub, args, r.stderr))


class TestInfo(DevBase):
    def test_info(self):
        r = self.run_dev(['info'], cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertEqual(set(data), {'home', 'os', 'shell', 'rg', 'git'})
        self.assertEqual(data['home'], self.home)
        self.assertTrue(data['os'])
        self.assertIsInstance(data['rg'], bool)
        self.assertIsInstance(data['git'], bool)

    def test_ssh_failure(self):
        r = self.run_dev(['info'], cwd=self.root,
                         env={'KOLOOD_SSH': os.path.join(self.sshdir, 'fake-ssh-255')})
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, b'')


class TestMcpConfig(DevBase):
    def write_cfg(self, path, obj):
        with open(path, 'w') as f:
            json.dump(obj, f)

    def test_build(self):
        projdir = os.path.join(self.tmp, 'proj')
        os.makedirs(projdir)
        self.write_cfg(os.path.join(self.home, '.claude.json'),
                       {'mcpServers': {'user-srv': {'type': 'http', 'url': 'http://u'}}})
        self.write_cfg(os.path.join(projdir, '.mcp.json'), {'mcpServers': {
            'user-srv': {'type': 'http', 'url': 'http://project-wins'},
            'stdio-srv': {'command': 'uvx',
                          'args': ['--from', 'pkg${V}', 'run'],
                          'env': {'FOO': 'bar baz', 'EMPTY': ''}},
            'http-srv': {'type': 'http', 'url': 'http://h/x'}}})
        out = os.path.join(self.tmp, 'out.json')
        r = self.run_dev(['mcp-config', projdir, out], cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'3\n')
        with open(out) as f:
            cfg = json.load(f)
        self.assertEqual(set(cfg['mcpServers']), {'user-srv', 'stdio-srv', 'http-srv'})
        self.assertEqual(cfg['mcpServers']['user-srv']['url'], 'http://project-wins')
        self.assertEqual(cfg['mcpServers']['http-srv'], {'type': 'http', 'url': 'http://h/x'})
        s = cfg['mcpServers']['stdio-srv']
        self.assertEqual(s['command'], self.base_env['KOLOOD_SSH'])
        self.assertEqual(s['args'][:4], ['-T', '-o', 'BatchMode=yes', 'remote'])
        want = 'cd %s && exec env EMPTY= %s uvx --from %s run' % (
            shlex.quote(projdir), shlex.quote('FOO=bar baz'), shlex.quote('pkg${V}'))
        self.assertEqual(s['args'][4], want)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)

    def test_config_dir_override(self):
        cfgdir = os.path.join(self.tmp, 'cfgdir')
        os.makedirs(cfgdir)
        self.write_cfg(os.path.join(cfgdir, '.claude.json'),
                       {'mcpServers': {'cfg-srv': {'type': 'http', 'url': 'http://c'}}})
        self.write_cfg(os.path.join(self.home, '.claude.json'),
                       {'mcpServers': {'user-srv': {'type': 'http', 'url': 'http://u'}}})
        out = os.path.join(self.tmp, 'out2.json')
        r = self.run_dev(['mcp-config', self.tmp, out], cwd=self.root,
                         env={'CLAUDE_CONFIG_DIR': cfgdir})
        self.assertEqual(r.stdout, b'1\n')
        with open(out) as f:
            cfg = json.load(f)
        self.assertEqual(list(cfg['mcpServers']), ['cfg-srv'])

    def test_no_servers(self):
        out = os.path.join(self.tmp, 'out3.json')
        r = self.run_dev(['mcp-config', self.tmp, out], cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'0\n')
        self.assertFalse(os.path.exists(out))


class TestWebResume(unittest.TestCase):
    """kolood_web /api/new with kind=claude + resume spawns in the conversation cwd."""

    def test_resume_spawns_in_conversation_cwd(self):
        tmp = tempfile.mkdtemp(prefix='kolood-web-')
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        home = os.path.join(tmp, 'kolood')
        fakehome = os.path.join(tmp, 'home')
        projdir = os.path.join(tmp, 'proj')
        os.makedirs(home)
        os.makedirs(fakehome)
        os.makedirs(projdir)
        start = write_script(os.path.join(tmp, 'kolood_start'),
                             '#!/bin/sh\n'
                             'printf \'{"claude_id":"res-abc-1"}\\n\' > "$KOLOOD_SESSION_FILE"\n'
                             'echo "STARTED:$*"\n'
                             'sleep 60\n')
        s = socket.socket()
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
        s.close()
        with open(os.path.join(home, 'web.json'), 'w') as f:
            json.dump({'port': port, 'commands': {'claude': [start, '']}}, f)
        projstore = os.path.join(fakehome, '.claude', 'projects', '-proj')
        os.makedirs(projstore)
        with open(os.path.join(projstore, 'res-abc-1.jsonl'), 'w') as f:
            f.write(json.dumps({'type': 'user', 'cwd': projdir,
                                'message': {'content': 'hello'}}) + '\n')
        env = dict(os.environ)
        env['KOLOOD_HOME'] = home
        env['HOME'] = fakehome
        r = subprocess.run([PY, WEB, 'passwd', 'X'], env=env, capture_output=True,
                           timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        logf = open(os.path.join(tmp, 'daemon.log'), 'w')
        proc = subprocess.Popen([PY, WEB, 'serve'], env=env,
                                stdout=logf, stderr=logf)
        self.addCleanup(logf.close)
        try:
            deadline = time.time() + 10
            while True:
                try:
                    c = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
                    c.request('GET', '/')
                    if c.getresponse().status == 200:
                        c.close()
                        break
                    c.close()
                except OSError:
                    pass
                self.assertLess(time.time(), deadline,
                                open(os.path.join(tmp, 'daemon.log')).read())
                time.sleep(0.1)
            c = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            c.request('POST', '/api/login', body=json.dumps({'password': 'X'}).encode(),
                      headers={'Content-Type': 'application/json'})
            r = c.getresponse()
            self.assertEqual(r.status, 200)
            cookie = r.getheader('Set-Cookie').split(';', 1)[0]
            r.read()
            c.close()
            c = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            c.request('POST', '/api/new', body=json.dumps(
                {'kind': 'claude', 'resume': 'res-abc-1'}).encode(),
                headers={'Content-Type': 'application/json', 'X-Kolood': '1',
                         'Cookie': cookie})
            r = c.getresponse()
            body = json.loads(r.read())
            c.close()
            self.assertEqual(r.status, 200, body)
            state = os.path.join(home, 'sessions.json')
            deadline = time.time() + 10
            entries = None
            while time.time() < deadline:
                try:
                    with open(state) as f:
                        entries = json.load(f)
                    if entries:
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(0.1)
            self.assertTrue(entries, 'no state file')
            e = [x for x in entries if x['id'] == body['id']]
            self.assertTrue(e, entries)
            want_cwd = base64.b64encode(projdir.encode()).decode()
            self.assertEqual(e[0]['cmd'], [start, want_cwd, '--resume', 'res-abc-1'])
            self.assertEqual(e[0]['cwd'], projdir)
        finally:
            # kill the spawned session, then the daemon
            try:
                subprocess.run(['pkill', '-f', start], timeout=5)
            except OSError:
                pass
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


class TestLinkConfig(DevBase):
    def setUp(self):
        super().setUp()
        self.real = os.path.join(self.tmp, 'real')
        self.dev = os.path.join(self.tmp, 'devcfg')
        self.slug = 'proj-x'
        os.makedirs(self.real)
        os.makedirs(self.dev)

    def mk(self, path, content='x\n', isdir=False):
        if isdir:
            os.makedirs(path)
            return path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(content)
        return path

    def run_link(self, slug=None):
        return self.run_dev(['link-config', self.real, self.dev,
                             self.slug if slug is None else slug])

    def test_creates_links(self):
        self.mk(os.path.join(self.dev, 'CLAUDE.md'), 'device md\n')
        self.mk(os.path.join(self.dev, 'skills', 'devskill', 'SKILL.md'), isdir=True)
        self.mk(os.path.join(self.dev, 'agents', 'a1.md'))
        self.mk(os.path.join(self.dev, 'commands', 'c1.md'))
        self.mk(os.path.join(self.dev, 'skills', '.hidden'))
        self.mk(os.path.join(self.dev, 'projects', self.slug, 'memory', 'm.json'),
                isdir=True)
        r = self.run_link()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'5\n')  # md + skill + agent + command + memory
        self.assertEqual(os.readlink(os.path.join(self.real, 'CLAUDE.md')),
                         os.path.join(self.dev, 'CLAUDE.md'))
        for d, n in (('skills', 'devskill'), ('agents', 'a1.md'), ('commands', 'c1.md')):
            p = os.path.join(self.real, d, n)
            self.assertTrue(os.path.islink(p), p)
            self.assertEqual(os.readlink(p), os.path.join(self.dev, d, n))
        mem = os.path.join(self.real, 'projects', self.slug, 'memory')
        self.assertTrue(os.path.islink(mem))
        self.assertEqual(os.readlink(mem),
                         os.path.join(self.dev, 'projects', self.slug, 'memory'))
        self.assertFalse(os.path.lexists(os.path.join(self.real, 'skills', '.hidden')))

    def test_leaves_server_own_entries(self):
        self.mk(os.path.join(self.real, 'CLAUDE.md'), 'server md\n')
        self.mk(os.path.join(self.real, 'skills', 'devskill'), '#!/bin/sh\nown\n')
        self.mk(os.path.join(self.dev, 'CLAUDE.md'))
        self.mk(os.path.join(self.dev, 'skills', 'devskill', 'SKILL.md'), isdir=True)
        self.mk(os.path.join(self.dev, 'skills', 'other', 'S.md'), isdir=True)
        r = self.run_link()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'1\n')
        with open(os.path.join(self.real, 'CLAUDE.md')) as f:
            self.assertEqual(f.read(), 'server md\n')
        self.assertFalse(os.path.islink(os.path.join(self.real, 'CLAUDE.md')))
        p = os.path.join(self.real, 'skills', 'devskill')
        self.assertFalse(os.path.islink(p))
        with open(p) as f:
            self.assertEqual(f.read(), '#!/bin/sh\nown\n')
        other = os.path.join(self.real, 'skills', 'other')
        self.assertTrue(os.path.islink(other))
        self.assertEqual(os.readlink(other), os.path.join(self.dev, 'skills', 'other'))

    def test_symlinked_dir_skipped(self):
        other = os.path.join(self.tmp, 'otherskills')
        os.makedirs(os.path.join(other, 's1'))
        os.symlink(other, os.path.join(self.real, 'skills'))
        self.mk(os.path.join(self.dev, 'skills', 'devskill', 'SKILL.md'), isdir=True)
        r = self.run_link()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'0\n')
        self.assertTrue(os.path.islink(os.path.join(self.real, 'skills')))
        self.assertFalse(os.path.lexists(os.path.join(other, 'devskill')))

    def test_empty_memory_replaced_nonempty_kept(self):
        dmem = os.path.join(self.dev, 'projects', self.slug, 'memory')
        self.mk(dmem, isdir=True)
        mem = os.path.join(self.real, 'projects', self.slug, 'memory')
        self.mk(mem, isdir=True)  # empty server dir -> replaced by the link
        r = self.run_link()
        self.assertEqual(r.stdout, b'1\n')
        self.assertTrue(os.path.islink(mem))
        os.remove(mem)
        os.makedirs(mem)
        self.mk(os.path.join(mem, 'note.md'))  # non-empty -> kept as a real dir
        r = self.run_link()
        self.assertEqual(r.stdout, b'0\n')
        self.assertFalse(os.path.islink(mem))
        self.assertTrue(os.path.isfile(os.path.join(mem, 'note.md')))

    def test_removes_dangling_links(self):
        skill = self.mk(os.path.join(self.dev, 'skills', 'devskill', 'SKILL.md'),
                        isdir=True)
        self.mk(os.path.join(self.dev, 'CLAUDE.md'))
        self.mk(os.path.join(self.dev, 'projects', self.slug, 'memory'), isdir=True)
        r = self.run_link()
        self.assertEqual(r.stdout, b'3\n')
        shutil.rmtree(os.path.join(self.dev, 'skills', 'devskill'))
        os.remove(os.path.join(self.dev, 'CLAUDE.md'))
        shutil.rmtree(os.path.join(self.dev, 'projects', self.slug))
        r = self.run_link()
        self.assertEqual(r.stdout, b'0\n')
        self.assertFalse(os.path.lexists(os.path.join(self.real, 'CLAUDE.md')))
        self.assertFalse(os.path.lexists(os.path.join(self.real, 'skills', 'devskill')))
        self.assertFalse(os.path.lexists(
            os.path.join(self.real, 'projects', self.slug, 'memory')))

    def test_unreachable_devcfg_changes_nothing(self):
        self.mk(os.path.join(self.real, 'CLAUDE.md'), 'keep\n')
        dangling = os.path.join(self.real, 'skills', 'old')
        os.makedirs(os.path.join(self.real, 'skills'))
        os.symlink(os.path.join(self.dev, 'skills', 'gone'), dangling)
        r = self.run_dev(['link-config', self.real,
                          os.path.join(self.tmp, 'nope'), self.slug])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'0\n')
        self.assertTrue(os.path.islink(dangling))  # not cleaned: device unreachable
        with open(os.path.join(self.real, 'CLAUDE.md')) as f:
            self.assertEqual(f.read(), 'keep\n')

    def test_bad_slug(self):
        for slug in ('bad/slug', 'bad_slug', 'bad slug', ''):
            r = self.run_link(slug=slug)
            self.assertEqual(r.returncode, 2, slug)
        self.assertEqual(sorted(os.listdir(self.real)), [])

    def test_idempotent(self):
        self.mk(os.path.join(self.dev, 'CLAUDE.md'))
        self.mk(os.path.join(self.dev, 'skills', 'devskill', 'SKILL.md'), isdir=True)
        r1 = self.run_link()
        self.assertEqual(r1.stdout, b'2\n')
        r2 = self.run_link()
        self.assertEqual(r2.stdout, b'2\n')
        self.assertTrue(os.path.islink(os.path.join(self.real, 'CLAUDE.md')))
        self.assertTrue(os.path.islink(os.path.join(self.real, 'skills', 'devskill')))


class TestSyncGlobal(DevBase):
    def setUp(self):
        super().setUp()
        self.src = os.path.join(self.tmp, 'src.json')
        self.dst = os.path.join(self.tmp, 'dst.json')

    def wr(self, path, obj):
        with open(path, 'w') as f:
            json.dump(obj, f)

    def rd(self, path):
        with open(path) as f:
            return json.load(f)

    def test_copy_when_missing(self):
        self.wr(self.src, {'oauthAccount': {'a': 1}, 'x': 2})
        r = self.run_dev(['sync-global', self.src, self.dst])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rd(self.dst), {'oauthAccount': {'a': 1}, 'x': 2})
        self.assertEqual(stat.S_IMODE(os.stat(self.dst).st_mode), 0o600)

    def test_merges_keys_when_src_newer(self):
        self.wr(self.src, {'oauthAccount': {'new': 1}, 'primaryApiKey': 'k',
                           'customApiKeyResponses': {'x': 'y'}, 'other': 's'})
        self.wr(self.dst, {'oauthAccount': {'old': 1}, 'keep': 'd'})
        os.utime(self.dst, (time.time() - 100, time.time() - 100))  # src is newer
        r = self.run_dev(['sync-global', self.src, self.dst])
        self.assertEqual(r.returncode, 0, r.stderr)
        d = self.rd(self.dst)
        self.assertEqual(d['oauthAccount'], {'new': 1})
        self.assertEqual(d['primaryApiKey'], 'k')
        self.assertEqual(d['customApiKeyResponses'], {'x': 'y'})
        self.assertEqual(d['keep'], 'd')
        self.assertNotIn('other', d)

    def test_dst_newer_untouched(self):
        self.wr(self.src, {'oauthAccount': {'new': 1}})
        self.wr(self.dst, {'oauthAccount': {'old': 1}, 'keep': 'd'})
        future = time.time() + 100
        os.utime(self.dst, (future, future))
        r = self.run_dev(['sync-global', self.src, self.dst])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.rd(self.dst),
                         {'oauthAccount': {'old': 1}, 'keep': 'd'})

    def test_invalid_dst_left_alone(self):
        self.wr(self.src, {'primaryApiKey': 'k'})
        with open(self.dst, 'w') as f:
            f.write('{not json')
        old = time.time() - 100
        os.utime(self.src, (old, old))
        r = self.run_dev(['sync-global', self.src, self.dst])
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.dst) as f:
            self.assertEqual(f.read(), '{not json')

    def test_bad_src_is_noop(self):
        self.wr(self.src, [1, 2])  # valid JSON, not an object
        r = self.run_dev(['sync-global', self.src, self.dst])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.dst))
        r = self.run_dev(['sync-global', os.path.join(self.tmp, 'nope'), self.dst])
        self.assertEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.dst))


class TestConfigRouting(DevBase):
    def setUp(self):
        super().setUp()
        self.real = os.path.join(self.tmp, 'real')
        self.dev = os.path.join(self.tmp, 'devcfg')
        self.view = os.path.join(self.root, '.claude')
        os.makedirs(self.real)
        os.makedirs(self.dev)
        # REAL/skills/devskill is a link into DEVCFG, as link-config makes it
        os.makedirs(os.path.join(self.dev, 'skills', 'devskill'))
        os.makedirs(os.path.join(self.real, 'skills'))
        os.symlink(os.path.join(self.dev, 'skills', 'devskill'),
                   os.path.join(self.real, 'skills', 'devskill'))
        self.cfg_env = {'KOLOOD_CONFIG_VIEW': self.view,
                        'KOLOOD_CONFIG_REAL': self.real,
                        'KOLOOD_DEVICE_CFG': self.dev}

    def test_under_devcfg_routes_to_device(self):
        cmd = 'cat %s/skills/devskill/x.sh; echo DEV-OK' % self.view
        r = self.run_dev(['shell', cmd], cwd=self.root, env=self.cfg_env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'DEV-OK', r.stdout)
        self.assertEqual(len(self.log_lines()), 1)

    def test_outside_devcfg_routes_to_server(self):
        cmd = 'cat %s/plugins/p/hook.sh 2>/dev/null; echo SRV-OK' % self.view
        r = self.run_dev(['shell', cmd], cwd=self.root, env=self.cfg_env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'SRV-OK', r.stdout)
        self.assertEqual(self.log_lines(), [])

    def test_snapshot_under_view_runs_on_device(self):
        cmd = 'source %s/shell-snapshots/s.sh 2>/dev/null || true && echo DEV-OK4' % self.view
        before = len(self.log_lines())
        r = self.run_dev(['shell', cmd], cwd=self.root, env=self.cfg_env)
        self.assertIn(b'DEV-OK4', r.stdout)
        self.assertEqual(len(self.log_lines()), before + 1)

    def test_missing_on_server_non_owned_runs_on_device(self):
        before = len(self.log_lines())
        r = self.run_dev(['shell', 'cat %s/orch/run.sh; echo DEV-OK5' % self.view],
                         cwd=self.root, env=self.cfg_env)
        self.assertIn(b'DEV-OK5', r.stdout)
        self.assertEqual(len(self.log_lines()), before + 1)

    def test_mixed_routes_to_server(self):
        cmd = 'cat %s/skills/devskill/x.sh %s/plugins/x; echo SRV-OK' % (
            self.view, self.view)
        r = self.run_dev(['shell', cmd], cwd=self.root, env=self.cfg_env)
        self.assertIn(b'SRV-OK', r.stdout)
        self.assertEqual(self.log_lines(), [])

    def test_no_view_reference_unchanged(self):
        before = len(self.log_lines())
        r = self.run_dev(['shell', 'echo DEV-OK2'], cwd=self.root, env=self.cfg_env)
        self.assertIn(b'DEV-OK2', r.stdout)
        self.assertEqual(len(self.log_lines()), before + 1)  # device, as before
        p = os.path.join(self.root, 'file.txt')  # device path that is not VIEW
        r = self.run_dev(['shell', 'cat %s; echo DEV-OK3' % p], cwd=self.root,
                         env=self.cfg_env)
        self.assertIn(b'DEV-OK3', r.stdout)
        self.assertEqual(len(self.log_lines()), before + 2)

    def test_view_without_real_or_devcfg_is_server(self):
        cmd = 'cat %s/skills/devskill/x.sh; echo SRV-OK' % self.view
        env = dict(self.cfg_env)
        env['KOLOOD_CONFIG_REAL'] = ''
        r = self.run_dev(['shell', cmd], cwd=self.root, env=env)
        self.assertIn(b'SRV-OK', r.stdout)
        self.assertEqual(self.log_lines(), [])
        env = {'KOLOOD_CONFIG_VIEW': self.view, 'KOLOOD_DEVICE_CFG': self.dev}
        r = self.run_dev(['shell', cmd], cwd=self.root, env=env)
        self.assertIn(b'SRV-OK', r.stdout)
        self.assertEqual(self.log_lines(), [])


if __name__ == '__main__':
    unittest.main()

