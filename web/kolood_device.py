#!/usr/bin/env python3
"""kolood device: make Claude (running on a server) work on the user's device.

Claude Code runs on a Linux server; the user's device is reachable via ssh and
its home directory is mounted on the server at the same path (env
KOLOOD_DEVICE_ROOT holds that path). Subcommands route every shell command to
the device and make clipboard, links, ripgrep and git behave as if local.
Python 3.8+ stdlib only.
"""
import json
import os
import re
import shlex
import stat
import subprocess
import sys

UNREACHABLE = 'kolood: your computer is not reachable (asleep or offline?)'
SNAP_RE = re.compile(r'^source\s+(\S+)\s+2>/dev/null\s+\|\|\s+true\s+&&\s+')
CWD_RE = re.compile(r'pwd -P >\| (/tmp/claude-[A-Za-z0-9_-]+-cwd)')
URL_RE = re.compile(r'^(https?|file)://')
SHIMS = ('rg', 'git', 'xclip', 'wl-paste', 'open')
# Darwin device scripts (run on the device through one ssh call each)
DARWIN_TARGETS = '''osascript -e 'clipboard info' 2>/dev/null | grep -qE 'PNGf|TIFF' && { echo image/png; exit 0; }
t=$(pbpaste 2>/dev/null)
[ -n "$t" ] && echo text/plain
exit 0
'''
DARWIN_PNG = '''f=$(mktemp ${TMPDIR:-/tmp}/kolood-clip.XXXXXX) || exit 1
osascript -e 'set d to (the clipboard as «class PNGf»)' \\
  -e 'set fh to open for access POSIX file "'"$f"'" with write permission' \\
  -e 'write d to fh' -e 'close access fh' 2>/dev/null && { cat "$f"; rm -f "$f"; exit 0; }
osascript -e 'set d to (the clipboard as «class TIFF»)' \\
  -e 'set fh to open for access POSIX file "'"$f"'" with write permission' \\
  -e 'write d to fh' -e 'close access fh' 2>/dev/null && sips -s format png "$f" --out "$f.png" >/dev/null 2>&1 && { cat "$f.png"; rm -f "$f" "$f.png"; exit 0; }
rm -f "$f" "$f.png"
exit 1
'''
# Linux device scripts (xclip, falling back to wl-paste)
LINUX_TARGETS = (
    't=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null)\n'
    '[ -n "$t" ] || t=$(wl-paste -l 2>/dev/null)\n'
    'case "$t" in *image/png*) echo image/png; exit 0;; esac\n'
    't=$(xclip -selection clipboard -o 2>/dev/null)\n'
    '[ -n "$t" ] || t=$(wl-paste 2>/dev/null)\n'
    '[ -n "$t" ] && echo text/plain\n'
    'exit 0\n')
LINUX_PNG = (
    'if xclip -selection clipboard -t image/png -o 2>/dev/null; then exit 0; fi\n'
    'exec wl-paste --type image/png\n')
LINUX_TEXT = (
    'if xclip -selection clipboard -o 2>/dev/null; then exit 0; fi\n'
    'exec wl-paste\n')
INFO_SCRIPT = (
    'os=$(uname -s 2>/dev/null) || true\n'
    'if [ "$os" = Darwin ]; then\n'
    '  if xcode-select -p >/dev/null 2>&1; then git=true; else git=false; fi\n'
    'elif command -v git >/dev/null 2>&1; then git=true; else git=false; fi\n'
    'if command -v rg >/dev/null 2>&1; then rg=true; else rg=false; fi\n'
    "printf 'home\\t%s\\nos\\t%s\\nshell\\t%s\\nrg\\t%s\\ngit\\t%s\\n' "
    '"$HOME" "$os" "${SHELL:-}" "$rg" "$git"\n')


def ssh_prog():
    return os.environ.get('KOLOOD_SSH', 'ssh')


def remote_alias():
    return os.environ.get('KOLOOD_REMOTE', 'remote')


def dev_root():
    return os.environ.get('KOLOOD_DEVICE_ROOT') or ''


def ssh_argv(remote_cmd):
    return [ssh_prog(), '-T', '-o', 'BatchMode=yes', remote_alias(), remote_cmd]


def inside_root(cwd):
    root = dev_root()
    if not root:
        return False
    root = os.path.realpath(root)
    cwd = os.path.realpath(cwd)
    if root == '/':
        return cwd.startswith('/')
    return cwd == root or cwd.startswith(root + '/')


def strip_snapshot(cmd):
    """Drop a leading `source <server snapshot> 2>/dev/null || true && `."""
    m = SNAP_RE.match(cmd)
    if not m:
        return cmd
    tok = m.group(1)
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ('"', "'"):
        tok = tok[1:-1]
    home = os.environ.get('HOME') or ''
    if home and (tok == home or tok.startswith(home + '/')):
        return cmd[m.end():]
    return cmd


def run_on_server(cmd):
    if 'CLAUDE_PLUGIN_ROOT' in cmd:
        return True
    home = os.environ.get('HOME') or ''
    if home and home + '/' in cmd:
        return True
    if cmd.startswith('xclip ') or cmd.startswith('wl-paste ') \
            or cmd in ('xclip', 'wl-paste') or 'xclip -selection clipboard' in cmd:
        return True
    view = os.environ.get('KOLOOD_CONFIG_VIEW') or ''
    if view and (view + '/' in cmd or re.search(
            r'(?:^|[\s\'"=])' + re.escape(view) + r'(?:$|[\s\'";|&<>()`$])', cmd)):
        # paths under the visible config dir run on the server only when they
        # do not resolve into the device's own config mount
        real = os.environ.get('KOLOOD_CONFIG_REAL') or ''
        devcfg = os.environ.get('KOLOOD_DEVICE_CFG') or ''
        if not real or not devcfg:
            return True
        devcfg = os.path.realpath(devcfg)
        for ref in re.compile(
                re.escape(view) + r"(?:/[^\s'\";|&<>()`$]*)?").findall(cmd):
            target = os.path.realpath(real + ref[len(view):])
            if target != devcfg and not target.startswith(devcfg + '/'):
                return True
    if not dev_root() or not inside_root(os.getcwd()):
        return True
    return False


def fetch_cwd_file(path):
    """Fetch the cwd marker Claude wrote on the device to the same path here."""
    remote_cmd = 'cat %s && rm -f %s' % (shlex.quote(path), shlex.quote(path))
    try:
        p = subprocess.run(ssh_argv(remote_cmd), stdout=subprocess.PIPE)
    except OSError:
        return
    if p.returncode == 0:
        try:
            with open(path, 'wb') as f:
                f.write(p.stdout)
        except OSError:
            pass


def cmd_shell(args):
    cmdstring = args[0] if args else ''
    if not cmdstring:
        print('usage: kolood_device.py shell CMDSTRING', file=sys.stderr)
        sys.exit(2)
    cmd = strip_snapshot(cmdstring)
    if run_on_server(cmd):
        os.execvp('/bin/bash', ['/bin/bash', '-c', cmdstring])
    fwd = ['%s=%s' % (k, shlex.quote(os.environ[k]))
           for k in ('CLAUDECODE', 'CLAUDE_PROJECT_DIR') if k in os.environ]
    pre = 'export ' + ' '.join(fwd) + '; ' if fwd else ''
    q = shlex.quote(os.getcwd())  # never run silently in another folder
    remote_cmd = 'cd %s || { echo "kolood: this folder is not on your computer: "%s >&2; exit 1; }; %sexec "${SHELL:-/bin/sh}" -lc %s' % (
        q, q, pre, shlex.quote(cmd))
    p = subprocess.run(ssh_argv(remote_cmd))
    if p.returncode == 255:
        print(UNREACHABLE, file=sys.stderr)
    m = CWD_RE.search(cmd)
    if m:
        fetch_cwd_file(m.group(1))
    sys.exit(p.returncode)


def run_tool(tool, args):
    if dev_root() and inside_root(os.getcwd()):
        # over ssh the remote stdin is always a pipe, and rg then searches stdin instead of the folder;
        # pass stdin through only when the caller really pipes data in (as a local run would see it)
        try:
            mode = os.fstat(0).st_mode
            piped = stat.S_ISFIFO(mode) or stat.S_ISREG(mode)
        except OSError:
            piped = False
        remote_cmd = 'cd %s && exec %s %s%s' % (
            shlex.quote(os.getcwd()), tool,
            ' '.join(shlex.quote(a) for a in args), '' if piped else ' </dev/null')
        p = subprocess.run(ssh_argv(remote_cmd), stdin=None if piped else subprocess.DEVNULL)
        if p.returncode == 255:
            print(UNREACHABLE, file=sys.stderr)
        sys.exit(p.returncode)
    shim_dir = os.environ.get('KOLOOD_SHIM_DIR') or ''
    shim_real = os.path.realpath(shim_dir) if shim_dir else None
    for d in os.environ.get('PATH', '').split(os.pathsep):
        if not d or (shim_real is not None and os.path.realpath(d) == shim_real):
            continue
        cand = os.path.join(d, tool)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            os.execv(cand, [tool] + args)
    print('kolood: %s not found' % tool, file=sys.stderr)
    sys.exit(127)


# ------------------------------------------------------------------ clipboard

XCLIP_MODES = {
    ('-selection', 'clipboard', '-t', 'TARGETS', '-o'): 'targets',
    ('-selection', 'clipboard', '-t', 'image/png', '-o'): 'png',
    ('-selection', 'clipboard', '-t', 'text/plain', '-o'): 'text',
    ('-selection', 'clipboard', '-t', 'image/bmp', '-o'): 'bmp',
}


def cmd_xclip(args):
    mode = None
    if args:
        for form, m in XCLIP_MODES.items():
            if len(args) == len(form) and all(a == f for a, f in zip(args, form)):
                mode = m
                break
    clipboard_run(mode)


def cmd_wl_paste(args):
    if args in (['-l'], ['--list-types']):
        mode = 'targets'
    elif args == ['--type', 'image/png']:
        mode = 'png'
    elif args == ['--type', 'image/bmp']:
        mode = 'bmp'
    elif not args:  # wl-paste with no args: clipboard text
        mode = 'text'
    else:
        mode = None
    clipboard_run(mode)


def clipboard_run(mode):
    if mode is None or mode == 'bmp':
        sys.exit(1)
    if os.environ.get('KOLOOD_DEVICE_OS', 'Linux') == 'Darwin':
        script = {'targets': DARWIN_TARGETS, 'png': DARWIN_PNG}.get(mode, 'exec pbpaste')
    else:
        script = {'targets': LINUX_TARGETS, 'png': LINUX_PNG}.get(mode, LINUX_TEXT)
    try:
        p = subprocess.run(ssh_argv(script), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
    except OSError as e:
        print('kolood: %s' % e, file=sys.stderr)
        sys.exit(1)
    if p.returncode != 0:
        sys.exit(1)
    if mode != 'targets' and not p.stdout:
        sys.exit(1)
    try:
        sys.stdout.buffer.write(p.stdout)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        pass
    sys.exit(0)


# ------------------------------------------------------------------ open/info

def cmd_open(args):
    url = args[0] if args else ''
    if not URL_RE.match(url):
        sys.exit(2)
    darwin = os.environ.get('KOLOOD_DEVICE_OS', 'Linux') == 'Darwin'
    if darwin:
        remote_cmd = 'exec open %s' % shlex.quote(url)
    else:
        remote_cmd = 'xdg-open %s >/dev/null 2>&1 &' % shlex.quote(url)
    p = subprocess.run(ssh_argv(remote_cmd))
    sys.exit(p.returncode if darwin else 0)


def cmd_info():
    try:
        p = subprocess.run(ssh_argv(INFO_SCRIPT), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
    except OSError as e:
        print('kolood: %s' % e, file=sys.stderr)
        sys.exit(1)
    if p.returncode != 0:
        sys.exit(1)
    vals = {}
    for line in p.stdout.decode('utf-8', 'replace').splitlines():
        k, _, v = line.partition('\t')
        if k:
            vals[k] = v
    if not vals.get('os'):
        sys.exit(1)
    print(json.dumps({'home': vals.get('home', ''), 'os': vals['os'],
                      'shell': vals.get('shell', ''),
                      'rg': vals.get('rg') == 'true', 'git': vals.get('git') == 'true'}))


# ---------------------------------------------------------------- mcp-config

def load_json_file(path):
    try:
        with open(path, encoding='utf-8') as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def ssh_mcp_entry(project_dir, entry):
    parts = ['cd %s && exec env' % shlex.quote(project_dir)]
    env = entry.get('env')
    if isinstance(env, dict):
        for k in sorted(env):
            if isinstance(k, str) and isinstance(env[k], str):
                parts.append(shlex.quote('%s=%s' % (k, env[k])))
    parts.append(shlex.quote(str(entry['command'])))
    cargs = entry.get('args')
    if isinstance(cargs, list):
        parts += [shlex.quote(str(a)) for a in cargs]
    remote_cmd = ' '.join(parts)
    return {'command': ssh_prog(),
            'args': ['-T', '-o', 'BatchMode=yes', remote_alias(), remote_cmd]}


def cmd_mcp_config(args):
    if len(args) != 2:
        print('usage: kolood_device.py mcp-config PROJECT_DIR OUT_JSON', file=sys.stderr)
        sys.exit(2)
    project_dir, out_path = args
    servers = {}
    cfg_dir = os.environ.get('CLAUDE_CONFIG_DIR')
    src = os.path.join(cfg_dir, '.claude.json') if cfg_dir else os.path.expanduser('~/.claude.json')
    user = load_json_file(src)
    if isinstance(user.get('mcpServers'), dict):
        servers.update(user['mcpServers'])
    proj = load_json_file(os.path.join(project_dir, '.mcp.json'))
    if isinstance(proj.get('mcpServers'), dict):
        for name, entry in proj['mcpServers'].items():
            if not isinstance(entry, dict):
                continue
            if 'command' in entry and entry.get('type', 'stdio') == 'stdio':
                servers[name] = ssh_mcp_entry(project_dir, entry)
            else:
                servers[name] = dict(entry)
    if not servers:
        print(0)
        return
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump({'mcpServers': servers}, f, indent=2)
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    print(len(servers))


# ------------------------------------------------------------- config view

SYNC_KEYS = ('oauthAccount', 'primaryApiKey', 'customApiKeyResponses')


def link_target_under(path, base):
    """The symlink target if path is a symlink pointing under base, else None."""
    try:
        tgt = os.readlink(path)
    except OSError:
        return None
    if tgt == base or tgt.startswith(base + '/'):
        return tgt
    return None


def cmd_link_config(args):
    if len(args) != 3:
        print('usage: kolood_device.py link-config REAL DEVCFG SLUG', file=sys.stderr)
        sys.exit(2)
    real = os.path.abspath(args[0])
    devcfg = os.path.abspath(args[1])
    slug = args[2]
    if not re.match(r'^[A-Za-z0-9-]+$', slug):
        sys.exit(2)
    try:
        os.listdir(devcfg)
    except OSError:
        print(0)  # device config dir unreachable: change nothing, clean up nothing
        return

    def safe(fn):
        try:
            fn()
        except OSError:
            pass

    dm = os.path.join(devcfg, 'CLAUDE.md')
    rm = os.path.join(real, 'CLAUDE.md')
    if not os.path.lexists(rm) and os.path.isfile(dm):
        safe(lambda: os.symlink(dm, rm))
    for d in ('skills', 'agents', 'commands'):
        dd = os.path.join(devcfg, d)
        try:
            entries = os.listdir(dd)
        except OSError:
            continue
        rd = os.path.join(real, d)
        if os.path.islink(rd):
            continue  # the server has its own dir here: leave it alone
        try:
            if not os.path.lexists(rd):
                os.makedirs(rd)
        except OSError:
            continue
        for name in entries:
            if name.startswith('.'):
                continue
            dst = os.path.join(rd, name)
            if os.path.lexists(dst):
                continue
            safe(lambda dst=dst, src=os.path.join(dd, name): os.symlink(src, dst))
    m = os.path.join(real, 'projects', slug, 'memory')
    dm = os.path.join(devcfg, 'projects', slug, 'memory')
    if os.path.isdir(dm):
        if os.path.isdir(m) and not os.path.islink(m):
            def rmdir_if_empty():
                if not os.listdir(m):
                    os.rmdir(m)
            safe(rmdir_if_empty)
        if not os.path.lexists(m):
            def link_memory():
                os.makedirs(os.path.dirname(m), exist_ok=True)
                os.symlink(dm, m)
            safe(link_memory)
    # drop our links whose device target is gone, then count what is left
    ours = [rm]
    for d in ('skills', 'agents', 'commands'):
        rd = os.path.join(real, d)
        if os.path.islink(rd):
            continue
        try:
            ours += [os.path.join(rd, n) for n in os.listdir(rd)]
        except OSError:
            pass
    ours.append(m)
    count = 0
    for p in ours:
        tgt = link_target_under(p, devcfg)
        if tgt is None:
            continue
        if os.path.exists(tgt):
            count += 1
        else:
            safe(lambda p=p: os.remove(p))
    print(count)


def write_private(path, data):
    tmp = os.path.join(os.path.dirname(path) or '.', '.kolood-tmp-%d' % os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def cmd_sync_global(args):
    if len(args) != 2:
        print('usage: kolood_device.py sync-global SRC DST', file=sys.stderr)
        sys.exit(2)
    src, dst = args
    try:
        with open(src, 'rb') as f:
            sdata = json.loads(f.read().decode('utf-8'))
    except (OSError, ValueError, UnicodeDecodeError):
        return
    if not isinstance(sdata, dict):
        return
    if not os.path.lexists(dst):
        try:
            with open(src, 'rb') as f:
                write_private(dst, f.read())
        except OSError:
            pass
        return
    try:
        if os.stat(src).st_mtime <= os.stat(dst).st_mtime:
            return
        with open(dst, 'rb') as f:
            ddata = json.load(f)
    except (OSError, ValueError, UnicodeDecodeError):
        return
    if not isinstance(ddata, dict):
        return
    for k in SYNC_KEYS:
        if k in sdata:
            ddata[k] = sdata[k]
    write_private(dst, json.dumps(ddata).encode('utf-8'))


# --------------------------------------------------------------------- main

def dispatch(sub, args):
    if sub == 'shell':
        cmd_shell(args)
    elif sub in ('rg', 'git'):
        run_tool(sub, args)
    elif sub == 'xclip':
        cmd_xclip(args)
    elif sub == 'wl-paste':
        cmd_wl_paste(args)
    elif sub == 'open':
        cmd_open(args)
    elif sub == 'info':
        cmd_info()
    elif sub == 'mcp-config':
        cmd_mcp_config(args)
    elif sub == 'link-config':
        cmd_link_config(args)
    elif sub == 'sync-global':
        cmd_sync_global(args)
    else:
        print('usage: kolood_device.py {shell|rg|git|xclip|wl-paste|open|info|'
              'mcp-config|link-config|sync-global}', file=sys.stderr)
        sys.exit(2)


def main():
    argv = sys.argv[1:]
    try:
        if argv:
            dispatch(argv[0], argv[1:])
        else:
            base = os.path.splitext(os.path.basename(sys.argv[0]))[0]
            if base in SHIMS:  # invoked through a symlinked shim with no args
                dispatch(base, [])
            else:
                dispatch('', [])
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(1)
    except Exception as e:
        print('kolood: %s' % e, file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
