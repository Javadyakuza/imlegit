#!/usr/bin/env bash
# imlegit: type `imlegit` on your Mac; Claude Code runs on your SERVER and works on the Mac.
#   1) on the server:  bash install.sh        -> prints a pairing token
#   2) on the Mac:     bash install.sh        -> paste the token
# Extra: history MACPATH SRVPATH | mount | remove | help.  No root needed anywhere.
set -euo pipefail

MARK="# claude-mac-bridge"; TP=2222; CDP=9222; OS=$(uname)
ask() { read -r -p "$1" "$2" </dev/tty; }
b64d() { base64 -d 2>/dev/null || base64 -D; }
enc() { p=${1%/}; echo "${p:-/}" | sed 's/[^a-zA-Z0-9]/-/g'; }
die() { echo "ERROR: $*" >&2; exit 1; }
GNUSED=(sed -i); [ "$OS" = Darwin ] && GNUSED=(sed -i '')

guide() { cat <<'GUIDE'
imlegit: Claude Code runs on a SERVER and works on your Mac. Type `imlegit` on the Mac.

TWO COMMANDS (same script, it detects Linux vs Mac):
 1. SERVER (offers to install Claude Code there if missing):
      bash install.sh          -> prints a pairing token, then waits for the Mac
 2. MAC (Remote Login ON: System Settings > General > Sharing):
      bash install.sh          -> paste the token (or: bash install.sh <token>)
 The Mac prints "Ready"; then type `imlegit` in any Mac terminal (first run: /login).
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
  for t in ssh ssh-keygen base64 awk sed; do command -v "$t" >/dev/null || die "missing tool on server: $t"; done
  # already paired and live: nothing to do (re-running must not break a working setup)
  PAIRED=0; ssh -o BatchMode=yes -o ConnectTimeout=3 mac true 2>/dev/null && PAIRED=1
  [ $PAIRED = 1 ] || { command -v ss >/dev/null && ss -ltn | grep -E ":($TP|$CDP)\b" && die "tunnel port $TP or $CDP is busy on this server"; }
  # sshd must allow reverse forwards (readable as root only; skipped if we can't read it)
  if /usr/sbin/sshd -T 2>/dev/null | grep -qiE '^allowtcpforwarding (no|local)'; then die "sshd has AllowTcpForwarding disabled; set it to yes in sshd_config"; fi
  mkdir -p ~/.ssh ~/.claude; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys ~/.ssh/config ~/.claude/CLAUDE.md; chmod 600 ~/.ssh/authorized_keys
  # not connected = a new pairing: forget any previous Mac so a fresh token can register a new one
  [ $PAIRED = 1 ] || { rm -f ~/.ssh/cmb_macuser ~/.ssh/cmb_login_pub ~/.ssh/cmb_known_hosts; "${GNUSED[@]}" "/# cmb-login/d" ~/.ssh/authorized_keys; }
  [ -f ~/.ssh/cmb_tunnel ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/cmb_tunnel -C claude-mac-bridge
  [ -f ~/.ssh/cmb_to_mac ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/cmb_to_mac -C claude-bridge
  # The only thing the tunnel key may run is this script: it records the Mac's username
  # (sent by the Mac as the "command") and keeps the tunnel open. No shell, no other commands.
  cat > ~/.ssh/cmb_hello <<'HELLO'
#!/bin/sh
c="$SSH_ORIGINAL_COMMAND"; d="$HOME/.ssh"
if [ "$c" = kill-old ]; then pkill -u "$(id -u)" -f 'sleep 2147483647' 2>/dev/null; exit 0; fi
# pairing message from the Mac: "<mac username> ssh-ed25519 <key>". First pairing wins; anything else is refused.
u=${c%% *}; k=${c#* }
case "$u" in ""|*[!a-zA-Z0-9._-]*) exit 1;; esac
case "$k" in "ssh-ed25519 "*) ;; *) exit 1;; esac
b=${k#ssh-ed25519 }; case "$b" in ""|*[!A-Za-z0-9+/=]*) exit 1;; esac
if [ -s "$d/cmb_macuser" ] && [ -s "$d/cmb_login_pub" ]; then [ "$(cat "$d/cmb_macuser")" = "$u" ] && [ "$(cat "$d/cmb_login_pub")" = "$k" ] || exit 1; fi
echo "$u" > "$d/cmb_macuser"; echo "$k" > "$d/cmb_login_pub"
grep -qF "$b" "$d/authorized_keys" || echo "$k imlegit-login # cmb-login" >> "$d/authorized_keys"
sed -i "/# claude-mac-bridge\$/,/# claude-mac-bridge-end/ s/^  User .*/  User $u/" "$d/config"
exec sleep 2147483647
HELLO
  chmod 700 ~/.ssh/cmb_hello
  # what `imlegit` runs on the server: Claude Code in a stable workspace, told where the Mac is
  mkdir -p ~/imlegit
  cat > ~/.ssh/cmb_start <<'START'
#!/bin/bash
export PATH="$HOME/.local/bin:$PATH"
shift  # first arg is the Mac's cwd, sent by the `imlegit` launcher; unused
command -v claude >/dev/null || { echo "Claude Code is not installed on this server. Install it: curl -fsSL https://claude.ai/install.sh | bash"; exit 1; }
cd "$HOME/imlegit"
# by default the session is told the user's Mac is a remote machine it can work on; `imlegit --no-mac` = server only
m=1; a=(); for x in "$@"; do case "$x" in --no-mac) m=0;; --mac) ;; *) a+=("$x");; esac; done
if [ $m = 1 ]; then
  exec claude --append-system-prompt "You run on this server. The user's own Mac is also available as a remote machine: 'ssh mac' (passwordless, as the user; may be offline). Work on it when the request is about the Mac or its files, via ssh mac '<cmd>'. Each call is a fresh shell (cd does not persist): use absolute paths or 'cd dir && cmd'. Mac Chrome DevTools is on localhost:9222 when Chrome runs with --remote-debugging-port=9222. Everything else runs here on the server." "${a[@]}"
fi
exec claude "${a[@]}"
START
  chmod 700 ~/.ssh/cmb_start
  "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys
  echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$TP\",permitlisten=\"127.0.0.1:$CDP\",command=\"$HOME/.ssh/cmb_hello\" $(cut -d' ' -f1,2 ~/.ssh/cmb_tunnel.pub) $MARK" >> ~/.ssh/authorized_keys

  # auto-detect how the Mac reaches this server: the address/port of the SSH session we are in
  HOST=${CMB_HOST:-$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')}; SPORT=${CMB_PORT:-$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')}
  [ -n "$HOST" ] || HOST=$(curl -4fs -m3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  [ -n "$SPORT" ] || SPORT=$(ss -ltnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')
  SPORT=${SPORT:-22}; MACUSER=$(cat ~/.ssh/cmb_macuser 2>/dev/null || echo unknown)
  echo "server address for the token: $HOST:$SPORT"

  "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config ~/.claude/CLAUDE.md
  # our block goes FIRST: ssh uses the first value it finds, so an older `Host mac` of yours can't shadow it
  cp ~/.ssh/config ~/.ssh/cmb_config.old
  cat > ~/.ssh/config <<EOF
$MARK
Host mac
  HostName localhost
  Port $TP
  User $MACUSER
  IdentityFile ~/.ssh/cmb_to_mac
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/cmb_known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
$MARK-end
EOF
  cat ~/.ssh/cmb_config.old >> ~/.ssh/config; rm -f ~/.ssh/cmb_config.old; chmod 600 ~/.ssh/config
  # Nothing is written to ~/.claude/CLAUDE.md: each `imlegit` session is told about the Mac via its system prompt (`--no-mac` skips it).
  if [ $PAIRED = 1 ]; then echo "Already paired and connected; refreshed. On your Mac type: imlegit   (to pair a different Mac: 'bash install.sh remove' here, then run again)"; return 0; fi

  HK=""; for t in ed25519 ecdsa rsa; do [ -r /etc/ssh/ssh_host_${t}_key.pub ] && { HK=$(awk '{print $1" "$2}' /etc/ssh/ssh_host_${t}_key.pub); break; }; done
  TOKEN="cmb1.$(printf '%s\n' "$HOST" "$SPORT" "$(id -un)" "$HK" "$(cut -d' ' -f1,2 ~/.ssh/cmb_to_mac.pub)" "$(grep -v -- ----- ~/.ssh/cmb_tunnel | tr -d '\n')" | base64 | tr -d '\n')"
  printf '\n=== PAIRING TOKEN (secret; paste on your Mac) ===\n%s\n\nOn the Mac run the same one-liner and paste the token.\n\nWaiting for the Mac (Ctrl-C to stop; re-run any time)...\n' "$TOKEN"
  for _ in $(seq 120); do
    ssh -o BatchMode=yes -o ConnectTimeout=3 mac 'echo "connected to $(hostname) as $(whoami)"' 2>/dev/null && { echo "Done. On your Mac, type:  imlegit   (first run asks you to /login on the server)"; return; }
    sleep 5
  done
  echo "Not connected yet. Run the Mac step; then test with: ssh mac hostname"
}

mac() {
  [ "$OS" = Darwin ] || die "run this step on the Mac"
  TOKEN=${1:-}; [ -n "$TOKEN" ] || ask "Paste the token from the server: " TOKEN
  # tolerate a pasted banner, wrapped lines or stray spaces: pull out just the token
  TOKEN=$(printf '%s\n' "$TOKEN" | tr -d ' \r' | awk 'f==0 && /cmb1\./ {sub(/.*cmb1\./,"cmb1."); t=$0; f=1; next} f==1 && /^[A-Za-z0-9+\/=]+$/ {t=t $0; next} f==1 {exit} END{print t}')
  [ -n "$TOKEN" ] || die "no token found in what you pasted (it starts with cmb1.)"
  D=$(printf %s "${TOKEN#cmb1.}" | b64d 2>/dev/null) || die "bad token"
  host=$(echo "$D" | sed -n 1p); port=$(echo "$D" | sed -n 2p); suser=$(echo "$D" | sed -n 3p)
  hk=$(echo "$D" | sed -n 4p); spub=$(echo "$D" | sed -n 5p); priv=$(echo "$D" | sed -n 6p)
  [ -n "$host" ] && [ -n "$port" ] && [ -n "$suser" ] && [ -n "$spub" ] && [ -n "$priv" ] || die "bad token"
  until nc -z localhost 22 2>/dev/null; do
    echo "-> Turn ON: System Settings > General > Sharing > Remote Login"; [ -r /dev/tty ] || die "Remote Login is off"
    ask "   Press Enter once it is on: " _
  done
  NEWPATH=0; LK=$HOME/.ssh/cmb_login; [ -f "$LK" ] || ssh-keygen -q -t ed25519 -N "" -f "$LK" -C imlegit-login
  K=$HOME/.ssh/cmb_tunnel; KH=$HOME/.ssh/cmb_known_hosts; PLIST=$HOME/Library/LaunchAgents/com.claude-mac-bridge.plist
  mkdir -p ~/.ssh "$HOME/Library/LaunchAgents"; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
  (umask 077; printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n' "$(echo "$priv" | fold -w70)" > "$K")
  STRICT=accept-new; : > "$KH"
  [ -n "$hk" ] || echo "WARNING: server host key not in the token; first connection is trusted without verification."
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
exec ssh \$O -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:$TP:localhost:22 -R 127.0.0.1:$CDP:localhost:$CDP $suser@$host "\$(id -un) \$(cut -d' ' -f1,2 $LK.pub)"
EOF
  # `imlegit`: Claude Code on the server, started from this terminal. caffeinate keeps the Mac awake meanwhile.
  mkdir -p ~/.local/bin
  cat > ~/.local/bin/imlegit <<EOF
#!/bin/bash
B=\$(printf %s "\$PWD" | base64 | tr -d '\n')
exec caffeinate -i ssh -t -i $LK -o IdentitiesOnly=yes -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=$STRICT -o ServerAliveInterval=30 -p $port $suser@$host "~/.ssh/cmb_start \$B\$(printf ' %q' "\$@")"
EOF
  chmod +x ~/.local/bin/imlegit
  RC=~/.zshrc; case "${SHELL:-}" in *bash) RC=~/.bash_profile;; esac
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) grep -qF "$MARK" "$RC" 2>/dev/null || echo "export PATH=\"\$HOME/.local/bin:\$PATH\" $MARK" >> "$RC"; NEWPATH=1;; esac
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
  echo "Connecting..."
  for _ in $(seq 12); do
    sleep 3
    ssh -i "$LK" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=$STRICT -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$suser@$host" 'ssh -o BatchMode=yes -o ConnectTimeout=5 mac true' 2>/dev/null && {
      echo "Ready. In a new terminal (or after: source $RC) type:  imlegit"; [ $NEWPATH = 1 ] && echo "(added ~/.local/bin to PATH in $RC)"; return; }
  done
  echo "Not connected. Likely causes:"
  echo " - this token was already used by another pairing: run the server step again for a fresh token"
  echo " - Remote Login is limited to certain users (System Settings > Sharing > Remote Login > allow your user)"
  echo " - the server's sshd blocks port forwarding or the tunnel ports are busy"
  echo "Log: /tmp/claude-mac-bridge.log"; exit 1
}

history() {
  [ $# -ge 2 ] || die "usage: install.sh history MACPATH SERVERPATH"
  command -v rsync >/dev/null || die "rsync is not installed on this server (apt install rsync)"
  cfg=${CMB_MAC_CONFIG:-.claude}
  rsync -au --mkpath mac:"$cfg/projects/$(enc "$1")/" "$HOME/.claude/projects/$(enc "$2")/" 2>/dev/null \
    || { mkdir -p "$HOME/.claude/projects/$(enc "$2")"; rsync -au mac:"$cfg/projects/$(enc "$1")/" "$HOME/.claude/projects/$(enc "$2")/"; }
  echo "copied; now: cd $2 && claude --resume"
}

mount_mac() {
  command -v sshfs >/dev/null || die "sshfs not installed on this server"
  mkdir -p ~/mac; sshfs -o reconnect,ServerAliveInterval=15 "mac:" ~/mac && echo "mounted ~/mac"
}

# Optional: let the server's Claude run `ssh mac ...` without asking each time. Opt-in because it means
# unattended command execution on your Mac.
allow() {
  command -v python3 >/dev/null || die "python3 needed"
  mkdir -p ~/.claude; python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p)) if os.path.exists(p) else {}
a = s.setdefault("permissions", {}).setdefault("allow", [])
if "Bash(ssh mac:*)" not in a: a.append("Bash(ssh mac:*)")
json.dump(s, open(p, "w"), indent=2)
PY
  echo "allowed: Claude on this server can now run 'ssh mac ...' without prompting (undo: remove it from ~/.claude/settings.json)"
}

remove() {
  if [ "$OS" = Darwin ]; then
    launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-mac-bridge.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.claude-mac-bridge.plist ~/.ssh/cmb_* ~/.local/bin/imlegit; "${GNUSED[@]}" "/$MARK/d" ~/.zshrc ~/.bash_profile 2>/dev/null || true
    "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys 2>/dev/null || true
  else
    fusermount -u ~/mac 2>/dev/null || true; rmdir ~/mac 2>/dev/null || true
    "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys 2>/dev/null || true
    "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config ~/.claude/CLAUDE.md 2>/dev/null || true
    "${GNUSED[@]}" "/# cmb-login/d" ~/.ssh/authorized_keys 2>/dev/null || true; rmdir ~/imlegit 2>/dev/null || true; rm -f ~/.ssh/cmb_*; pkill -u "$(id -u)" -f "sleep 2147483647" 2>/dev/null || true
  fi
  echo "removed"
}

case "${1:-}" in
  -h|--help|help) guide;;
  history) shift; history "$@";;
  mount) mount_mac;;
  allow) allow;;
  remove|uninstall|--uninstall) remove;;
  *) if [ "$OS" = Darwin ]; then mac "${1:-}"; else server; fi;;
esac
