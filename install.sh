#!/usr/bin/env bash
# claude-mac-bridge: let Claude Code on a SERVER treat this Mac as its machine.
# Run on the Mac:  ./install.sh user@server [-p 2222] [--mount]   |   ./install.sh --uninstall user@server
# Needs: macOS Remote Login on (System Settings > General > Sharing). No root on the server.
set -euo pipefail

HELP=0; PORT=2222; MOUNT=0; UNINSTALL=0; SRV=""; HISTORY=""
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) HELP=1;; -p) PORT=$2; shift;; --mount) MOUNT=1;; --uninstall) UNINSTALL=1;; --history) HISTORY=$2; shift;; *) SRV=$1;;
  esac; shift
done
guide() { cat <<'GUIDE'
claude-mac-bridge: run Claude Code on a SERVER, with your Mac as its remote machine.

SETUP (about 3 minutes)
 1. Server: install Claude Code, run `claude`, then /login with your subscription.
 2. Mac: System Settings > General > Sharing > Remote Login = ON.
 3. Mac: you need SSH access to the server (password or key) as a normal user.
    Use a non-root user; this script needs no sudo anywhere.
 4. Mac, run:   ./install.sh user@server
    Optional flags:
      -p 2222            tunnel port on the server (default 2222, loopback only)
      --mount            also mount your Mac home at ~/mac on the server (needs sshfs)
      --history MAC:SRV  copy sessions: --history /Users/me/proj:/home/u/proj
 5. Server: cd into your project and run `claude`. Claude now knows `ssh mac`.

ENV: SSH_PORT=2200 (server sshd port), CLAUDE_CONFIG_DIR (Mac config dir, default ~/.claude)

SAFETY: it refuses if the server has <150MB RAM or <50MB disk free. It changes only
 the SSH user's ~/.ssh/config, ~/.ssh/to_mac*, ~/.claude/CLAUDE.md. One idle ssh
 process (~3MB) runs on the server side. Nothing is ever deleted there.
 The server key is accepted on your Mac only via the tunnel (from 127.0.0.1).

CHECK:     on the server run `ssh mac hostname`
RESUME:    --history copies sessions; then `cd <server dir> && claude --resume`
REMOVE:    ./install.sh --uninstall user@server
LIMITS:    Mac asleep/offline = bridge down (it reconnects by itself when back).
           Mac Chrome control needs Chrome started with --remote-debugging-port=9222.
GUIDE
}

LABEL=com.claude-mac-bridge
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
KEY=$HOME/.ssh/claude_bridge
MARK="# claude-mac-bridge"
ME=$(whoami); SSH_PORT=${SSH_PORT:-22}
ssh() { command ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$@"; }

[ $HELP = 1 ] && { guide; exit 0; }
# No arguments: interactive Mac-side wizard (works with `curl | bash` too, via /dev/tty)
if [ -z "$SRV" ]; then
  [ -r /dev/tty ] || { guide; exit 1; }
  ask() { read -r -p "$1" "$2" </dev/tty; }
  echo "claude-mac-bridge: Mac-side setup. (Server side: install Claude Code there and /login first.)"
  until nc -z localhost 22 2>/dev/null; do
    echo "-> Turn ON: System Settings > General > Sharing > Remote Login"
    ask "   Press Enter once it is on: " _
  done
  ask "Server login (user@host): " SRV
  [ -n "$SRV" ] || { echo "need a server"; exit 1; }
  ask "Server SSH port [22]: " p; SSH_PORT=${p:-22}
  ask "Copy Claude history for a project? Mac project path (blank = skip): " m
  if [ -n "$m" ]; then ask "  Same project's path on the server: " s; HISTORY="$m:$s"; fi
fi

if [ $UNINSTALL = 1 ]; then
  launchctl bootout gui/$(id -u) "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  sed -i '' "/$MARK/d" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
  ssh -i "$KEY" "$SRV" "rm -f ~/.ssh/to_mac ~/.ssh/to_mac.pub; sed -i '/$MARK/,/$MARK-end/d' ~/.ssh/config ~/.claude/CLAUDE.md 2>/dev/null; fusermount -u ~/mac 2>/dev/null; rmdir ~/mac 2>/dev/null; true"
  echo "removed"; exit 0
fi

nc -z localhost 22 2>/dev/null || { echo "Turn on Remote Login first (System Settings > General > Sharing)."; exit 1; }

# 1. Mac -> server key (for the tunnel)
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY" -C claude-mac-bridge
ssh-copy-id -i "$KEY.pub" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$SRV" || { echo "cannot reach/auth to $SRV"; exit 1; }

# 1b. read-only preflight on the server: refuse on low RAM/disk or busy ports
ssh -i "$KEY" "$SRV" "avail=\$(awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo)
disk=\$(df -Pm \$HOME | awk 'NR==2{print \$4}')
echo \"server: \${avail}MB RAM free, \${disk}MB disk free\"
[ \$avail -ge 150 ] || { echo 'REFUSING: under 150MB RAM available'; exit 3; }
[ \$disk -ge 50 ] || { echo 'REFUSING: under 50MB disk'; exit 3; }
if command -v ss >/dev/null && ! ssh -o BatchMode=yes -o ConnectTimeout=3 mac true 2>/dev/null; then ss -ltn | grep -E ':($PORT|9222)\\b' && { echo 'REFUSING: port busy (use -p)'; exit 3; }; fi
command -v rsync >/dev/null || echo 'note: no rsync on server (history sync unavailable)'
exit 0"

# 2. server -> Mac key; only accepted via the tunnel (arrives from 127.0.0.1)
SRVPUB=$(ssh -i "$KEY" "$SRV" '[ -f ~/.ssh/to_mac ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/to_mac -C claude-bridge; cat ~/.ssh/to_mac.pub')
mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
grep -qF "$SRVPUB" ~/.ssh/authorized_keys || echo "from=\"127.0.0.1,::1\" $SRVPUB $MARK" >> ~/.ssh/authorized_keys

# 3. server-side config: `ssh mac` + a note for Claude (idempotent via markers)
ssh -i "$KEY" "$SRV" "mkdir -p ~/.claude; touch ~/.ssh/config ~/.claude/CLAUDE.md
sed -i '/$MARK/,/$MARK-end/d' ~/.ssh/config ~/.claude/CLAUDE.md
cat >> ~/.ssh/config <<EOF
$MARK
Host mac
  HostName localhost
  Port $PORT
  User $ME
  IdentityFile ~/.ssh/to_mac
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
$MARK-end
EOF
cat >> ~/.claude/CLAUDE.md <<EOF
$MARK
# The user's Mac
Your own machine is a server. The user's Mac is reachable with \\\`ssh mac\\\` (reverse tunnel, may be offline).
Run Mac commands as \\\`ssh mac '<cmd>'\\\`. Mac files: \\\`ssh mac cat/ls\\\` or ~/mac if mounted.
Mac Chrome DevTools (CDP) is on localhost:9222 here when Chrome runs with --remote-debugging-port=9222.
$MARK-end
EOF"

# 4. keep the tunnel alive with launchd
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array>
<string>/usr/bin/ssh</string><string>-p</string><string>$SSH_PORT</string><string>-N</string><string>-i</string><string>$KEY</string>
<string>-o</string><string>ExitOnForwardFailure=yes</string>
<string>-o</string><string>ServerAliveInterval=30</string>
<string>-o</string><string>ServerAliveCountMax=3</string>
<string>-R</string><string>127.0.0.1:$PORT:localhost:22</string>
<string>-R</string><string>127.0.0.1:9222:localhost:9222</string>
<string>$SRV</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
</dict></plist>
EOF
launchctl bootout gui/$(id -u) "$PLIST" 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"

# 5. verify from the server side
sleep 3
ssh -i "$KEY" "$SRV" "ssh -o BatchMode=yes -o ConnectTimeout=8 mac 'echo bridge ok: \$(hostname)'" \
  || { echo "bridge test failed"; exit 1; }

# 6. optional: mount Mac home at ~/mac on the server (needs sshfs installed there)
if [ $MOUNT = 1 ]; then
  ssh -i "$KEY" "$SRV" 'command -v sshfs >/dev/null || { echo "sshfs missing on server (apt install sshfs); skipped"; exit 0; }
mkdir -p ~/mac; sshfs -o reconnect,ServerAliveInterval=15 mac:/Users/'"$ME"' ~/mac && echo mounted ~/mac'
fi
# 7. optional: copy Claude session history so `claude --resume` on the server sees Mac sessions.
# Claude keys sessions by project path, so Mac path -> server path. Never deletes, never overwrites newer files.
if [ -n "$HISTORY" ]; then
  enc() { echo "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
  MACDIR=${HISTORY%%:*}; SRVDIR=${HISTORY#*:}
  SRC=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(enc "$MACDIR")
  [ -d "$SRC" ] || { echo "no Mac sessions at $SRC"; exit 1; }
  ssh -i "$KEY" "$SRV" "mkdir -p ~/.claude/projects/$(enc "$SRVDIR")"
  rsync -au -e "ssh -i $KEY -p $SSH_PORT" "$SRC/" "$SRV:.claude/projects/$(enc "$SRVDIR")/"
  echo "history copied; on the server: cd $SRVDIR && claude --resume"
fi
echo "done. On the server: ssh mac"
