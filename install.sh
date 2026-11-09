#!/usr/bin/env bash
# claude-mac-bridge: Claude Code on a SERVER, your Mac as its remote machine.
#   1) on the server:  bash install.sh        -> prints a pairing token
#   2) on the Mac:     bash install.sh        -> paste the token
# Extra: history MACPATH SRVPATH | mount | remove | help.  No root needed anywhere.
set -euo pipefail

MARK="# claude-mac-bridge"; TP=2222; CDP=9222; OS=$(uname)
ask() { read -r -p "$1" "$2" </dev/tty; }
b64d() { base64 -d 2>/dev/null || base64 -D; }
enc() { echo "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
die() { echo "ERROR: $*" >&2; exit 1; }
GNUSED=(sed -i); [ "$OS" = Darwin ] && GNUSED=(sed -i '')

guide() { cat <<'GUIDE'
claude-mac-bridge: run Claude Code on a SERVER, with your Mac as its remote machine.

TWO COMMANDS (same script, it detects Linux vs Mac):
 1. SERVER (after installing Claude Code there and running /login):
      bash install.sh          -> prints a pairing token, then waits for the Mac
 2. MAC (Remote Login ON: System Settings > General > Sharing):
      bash install.sh          -> paste the token (or: bash install.sh <token>)
 The server terminal then says "connected". On the server: `cd project && claude`.
 Claude knows `ssh mac` is your local machine. Run as many sessions as you like;
 they share one multiplexed connection.

MORE
 history MACPATH SRVPATH   (server) pull Mac Claude sessions for a project, then
                           `cd SRVPATH && claude --resume`. CMB_MAC_CONFIG=dir if
                           your Mac config is not ~/.claude.
 mount                     (server) mount Mac home at ~/mac (needs sshfs)
 remove                    undo everything on this machine (run on both)
 Env for the server step: CMB_HOST, CMB_PORT (sshd port), CMB_MAC_USER.

SAFETY
 - Server refuses on <150MB free RAM or <50MB disk. Footprint: one idle ssh (~3MB).
 - The token carries a tunnel-only key: it can open 127.0.0.1:2222/9222 reverse
   forwards and nothing else (no shell). Treat the token like a password; `remove`
   on the server revokes it. The server's SSH host key is pinned in the token.
 - Your Mac accepts the server key only through the tunnel (from 127.0.0.1).
 - Anyone with root on the server can reach your Mac. Use servers you trust.
 - Mac asleep/offline = bridge down; it reconnects by itself.
 - Mac Chrome control: start Chrome with --remote-debugging-port=9222.
GUIDE
}

server() {
  [ "$OS" = Linux ] || die "run this step on the Linux server"
  avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); disk=$(df -Pm "$HOME" | awk 'NR==2{print $4}')
  echo "server: ${avail}MB RAM free, ${disk}MB disk free"
  [ "$avail" -ge 150 ] || die "under 150MB RAM available; refusing"
  [ "$disk" -ge 50 ] || die "under 50MB disk; refusing"
  if ! command -v claude >/dev/null 2>&1 && [ ! -x ~/.local/bin/claude ]; then
    a=""; echo "Claude Code is not installed on this server."
    [ -r /dev/tty ] && ask "Install it now with the official installer? [Y/n]: " a
    case "${a:-Y}" in
      [Nn]*) echo "Skipped. Install it yourself, then run: claude  (and /login)";;
      *) [ "$avail" -ge 600 ] || echo "WARNING: only ${avail}MB RAM free. Claude sessions here can push this server into swap/OOM; consider a bigger box for prod."
         curl -fsSL https://claude.ai/install.sh | bash || echo "Install failed; install Claude Code manually.";;
    esac
    echo ">>> After pairing, run 'claude' once on this server and /login with your subscription."
  fi
  if command -v ss >/dev/null && ! ssh -o BatchMode=yes -o ConnectTimeout=3 mac true 2>/dev/null; then
    ss -ltn | grep -E ":($TP|$CDP)\b" && die "tunnel port busy"
  fi
  mkdir -p ~/.ssh ~/.claude; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys ~/.ssh/config ~/.claude/CLAUDE.md; chmod 600 ~/.ssh/authorized_keys
  [ -f ~/.ssh/cmb_tunnel ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/cmb_tunnel -C claude-mac-bridge
  [ -f ~/.ssh/cmb_to_mac ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/cmb_to_mac -C claude-bridge
  # The only thing the tunnel key may run is this script: it records the Mac's username
  # (sent by the Mac as the "command") and keeps the tunnel open. No shell, no other commands.
  cat > ~/.ssh/cmb_hello <<'HELLO'
#!/bin/sh
c="$SSH_ORIGINAL_COMMAND"
if [ "$c" = kill-old ]; then pkill -u "$(id -u)" -f 'sleep 2147483647' 2>/dev/null; exit 0; fi
case "$c" in ""|*[!a-zA-Z0-9._-]*) exit 1;; esac
[ -s "$HOME/.ssh/cmb_macuser" ] && [ "$(cat "$HOME/.ssh/cmb_macuser")" != "$c" ] && exit 1
echo "$c" > "$HOME/.ssh/cmb_macuser"
sed -i "/# claude-mac-bridge\$/,/# claude-mac-bridge-end/ s/^  User .*/  User $c/" "$HOME/.ssh/config"
exec sleep 2147483647
HELLO
  chmod 700 ~/.ssh/cmb_hello
  "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys
  echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$TP\",permitlisten=\"127.0.0.1:$CDP\",command=\"$HOME/.ssh/cmb_hello\" $(cut -d' ' -f1,2 ~/.ssh/cmb_tunnel.pub) $MARK" >> ~/.ssh/authorized_keys

  # auto-detect how the Mac reaches this server: the address/port of the SSH session we are in
  HOST=${CMB_HOST:-$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')}; SPORT=${CMB_PORT:-$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')}
  [ -n "$HOST" ] || HOST=$(curl -4fs -m3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  SPORT=${SPORT:-22}; MACUSER=$(cat ~/.ssh/cmb_macuser 2>/dev/null || echo unknown)
  echo "server address for the token: $HOST:$SPORT"

  "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config ~/.claude/CLAUDE.md
  cat >> ~/.ssh/config <<EOF
$MARK
Host mac
  HostName localhost
  Port $TP
  User $MACUSER
  IdentityFile ~/.ssh/cmb_to_mac
  IdentitiesOnly yes
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
Your own machine is a server. The user's Mac is reachable with \`ssh mac\` (reverse tunnel, may be offline).
Run Mac commands as \`ssh mac '<cmd>'\`. Mac files: \`ssh mac cat/ls\`, or ~/mac if mounted.
Mac Chrome DevTools (CDP) is on localhost:$CDP here when Chrome runs with --remote-debugging-port=$CDP.
$MARK-end
EOF

  HK=$(awk '{print $1" "$2}' /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true)
  TOKEN="cmb1.$(printf '%s\n' "$HOST" "$SPORT" "$(id -un)" "$HK" "$(cut -d' ' -f1,2 ~/.ssh/cmb_to_mac.pub)" "$(grep -v -- ----- ~/.ssh/cmb_tunnel | tr -d '\n')" | base64 | tr -d '\n')"
  printf '\n=== PAIRING TOKEN (secret; paste on your Mac) ===\n%s\n\nOn the Mac run the same one-liner and paste the token.\n\nWaiting for the Mac (Ctrl-C to stop; re-run any time)...\n' "$TOKEN"
  for _ in $(seq 120); do
    ssh -o BatchMode=yes -o ConnectTimeout=3 mac 'echo "connected to $(hostname) as $(whoami)"' 2>/dev/null && { echo "Done. Now: export PATH=\$HOME/.local/bin:\$PATH; cd <project> && claude  (first run: /login)"; return; }
    sleep 5
  done
  echo "Not connected yet. Run the Mac step; then test with: ssh mac hostname"
}

mac() {
  [ "$OS" = Darwin ] || die "run this step on the Mac"
  TOKEN=${1:-}; [ -n "$TOKEN" ] || ask "Paste the token from the server: " TOKEN
  D=$(printf %s "${TOKEN#cmb1.}" | b64d 2>/dev/null) || die "bad token"
  host=$(echo "$D" | sed -n 1p); port=$(echo "$D" | sed -n 2p); suser=$(echo "$D" | sed -n 3p)
  hk=$(echo "$D" | sed -n 4p); spub=$(echo "$D" | sed -n 5p); priv=$(echo "$D" | sed -n 6p)
  [ -n "$host" ] && [ -n "$port" ] && [ -n "$suser" ] && [ -n "$spub" ] && [ -n "$priv" ] || die "bad token"
  until nc -z localhost 22 2>/dev/null; do
    echo "-> Turn ON: System Settings > General > Sharing > Remote Login"; [ -r /dev/tty ] || die "Remote Login is off"
    ask "   Press Enter once it is on: " _
  done
  K=$HOME/.ssh/cmb_tunnel; KH=$HOME/.ssh/cmb_known_hosts; PLIST=$HOME/Library/LaunchAgents/com.claude-mac-bridge.plist
  mkdir -p ~/.ssh "$HOME/Library/LaunchAgents"; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
  (umask 077; printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n' "$(echo "$priv" | fold -w70)" > "$K")
  STRICT=accept-new; : > "$KH"
  if [ -n "$hk" ]; then STRICT=yes; [ "$port" = 22 ] && echo "$host $hk" > "$KH" || echo "[$host]:$port $hk" > "$KH"; fi
  # the server's key may log in here only through the tunnel (arrives from loopback)
  "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys
  echo "from=\"127.0.0.1,::1\" $spub $MARK" >> ~/.ssh/authorized_keys
  # launchd runs this: clear any stale server-side session (after sleep/wake), then open the tunnel
  # and tell the server our username (the only "command" the tunnel key is allowed to send).
  W=$HOME/.ssh/cmb_run.sh
  cat > "$W" <<EOF
O="-i $K -o IdentitiesOnly=yes -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=$STRICT -o ConnectTimeout=15 -p $port"
ssh \$O $suser@$host kill-old >/dev/null 2>&1
exec ssh \$O -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:$TP:localhost:22 -R 127.0.0.1:$CDP:localhost:$CDP $suser@$host "\$(id -un)"
EOF
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.claude-mac-bridge</string>
<key>ProgramArguments</key><array>
<string>/bin/sh</string><string>$W</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
<key>StandardErrorPath</key><string>/tmp/claude-mac-bridge.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  sleep 5
  launchctl print "gui/$(id -u)/com.claude-mac-bridge" 2>/dev/null | grep -q "state = running" \
    && echo "Mac side is up. The server terminal should now say 'connected'." \
    || { echo "Tunnel not running yet; see /tmp/claude-mac-bridge.log"; exit 1; }
}

history() {
  [ $# -ge 2 ] || die "usage: install.sh history MACPATH SERVERPATH"
  cfg=${CMB_MAC_CONFIG:-.claude}
  rsync -au --mkpath mac:"$cfg/projects/$(enc "$1")/" "$HOME/.claude/projects/$(enc "$2")/" 2>/dev/null \
    || { mkdir -p "$HOME/.claude/projects/$(enc "$2")"; rsync -au mac:"$cfg/projects/$(enc "$1")/" "$HOME/.claude/projects/$(enc "$2")/"; }
  echo "copied; now: cd $2 && claude --resume"
}

mount_mac() {
  command -v sshfs >/dev/null || die "sshfs not installed on this server"
  mkdir -p ~/mac; sshfs -o reconnect,ServerAliveInterval=15 "mac:" ~/mac && echo "mounted ~/mac"
}

remove() {
  if [ "$OS" = Darwin ]; then
    launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-mac-bridge.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.claude-mac-bridge.plist ~/.ssh/cmb_*
    "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys 2>/dev/null || true
  else
    fusermount -u ~/mac 2>/dev/null || true; rmdir ~/mac 2>/dev/null || true
    "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys 2>/dev/null || true
    "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config ~/.claude/CLAUDE.md 2>/dev/null || true
    rm -f ~/.ssh/cmb_*; pkill -u "$(id -u)" -f "sleep 2147483647" 2>/dev/null || true
  fi
  echo "removed"
}

case "${1:-}" in
  -h|--help|help) guide;;
  history) shift; history "$@";;
  mount) mount_mac;;
  remove|uninstall|--uninstall) remove;;
  *) if [ "$OS" = Darwin ]; then mac "${1:-}"; else server; fi;;
esac
