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
                  'ANTHROPIC_API_KEY', 'SHELL'):
            e.pop(k, None)
        e.update(self.base_env)
        if env:
            e.update(env)
        return subprocess.run([PY, DEV] + list(args), env=e, cwd=cwd,
                              input=input, capture_output=True, timeout=timeout)


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


if __name__ == '__main__':
    unittest.main()

