#!/usr/bin/env bash
# kolood: type `kolood` on your computer (macOS, Linux, Windows via WSL); Claude Code runs on your
# Linux SERVER and can work on that computer through a private tunnel.
#   bash install.sh                 -> interactive menu (pair, start, status, update, uninstall)
#   server:   bash install.sh server        -> prints a pairing token
#   computer: bash install.sh pair [TOKEN]  -> paste the token
# `bash install.sh help` lists everything. No root needed (except installing sshd on Linux/WSL).
set -euo pipefail

MARK="# kolood-bridge"; TP=2222; CDP=9222; OS=$(uname)
URL=${KOLOOD_URL:-https://raw.githubusercontent.com/Javadyakuza/kolood/main/install.sh}
I=$HOME/.local/share/kolood/install.sh   # saved copy: menus, updates and session sync run from it
CONF=$HOME/.ssh/kolood_conf; LK=$HOME/.ssh/kolood_login; KH=$HOME/.ssh/kolood_known_hosts
LOG=/tmp/kolood.log; UNIT=kolood-bridge.service
PLIST=$HOME/Library/LaunchAgents/com.kolood.bridge.plist
ask() { read -r -p "$1" "$2" </dev/tty; }
yes_no() { local a=""; ask "$1" a || return 1; case "$a" in [Yy]*) return 0;; *) return 1;; esac; }
b64d() { base64 -d 2>/dev/null || base64 -D; }
enc() { p=${1%/}; echo "${p:-/}" | sed 's/[^a-zA-Z0-9]/-/g'; }
die() { echo "ERROR: $*" >&2; exit 1; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
plat() { case "$OS" in Darwin) echo macOS;; *) if is_wsl; then echo WSL; else echo Linux; fi;; esac; }
GNUSED=(sed -i); [ "$OS" = Darwin ] && GNUSED=(sed -i '')
case "${SHELL:-}" in *zsh) RC=$HOME/.zshrc;; *bash) if [ "$OS" = Darwin ]; then RC=$HOME/.bash_profile; else RC=$HOME/.bashrc; fi;; *) RC=$HOME/.profile;; esac
case "$OS" in MINGW*|MSYS*|CYGWIN*) die "Windows: use WSL. In PowerShell run 'wsl --install', open Ubuntu, and run this script there.";; esac
# run a step in a subshell so its errors (die) return to the menu instead of quitting it
run() { local r; set +e; ( set -e; "$@" ); r=$?; set -e; [ $r = 0 ] || echo "(that step did not finish; see the message above)"; }

guide() { cat <<'GUIDE'
kolood: Claude Code runs on a Linux SERVER; you type `kolood` on your computer
(macOS, Linux, or Windows via WSL). Claude can work on that computer as `ssh remote`.

SETUP  (or just `bash install.sh` for the interactive menu)
 1. server:   bash install.sh server       -> prints a pairing token and waits
 2. computer: bash install.sh pair [TOKEN] (macOS: Remote Login ON; Linux/WSL: sshd,
                                            the script offers to install it)
 Later: `kolood --setup` on your computer, `kolood` on the server opens the menu.

IMLEGIT FLAGS (on your computer; everything else is passed to claude)
 kolood                  Claude on the server; it can work on this computer (`ssh remote`)
 kolood --no-remote         server only; this session is not told about your computer
 kolood --resume [ID]    resume; your computer's sessions (this folder, or that ID)
 kolood --continue       are copied to the server first, so local sessions continue there
 kolood --shell          a login shell on the server instead of Claude
 kolood --setup          the menu: start, pair, restart bridge, update, uninstall

SCRIPT COMMANDS: menu | server | pair [TOKEN] | refresh | update | allow on|off|toggle
 | pull dir PATH [SRVPATH] | pull id SESSION_ID | history PATH SRVPATH | mount | remove
 Env: KOLOOD_HOST, KOLOOD_PORT (server address in the token), KOLOOD_REMOTE_CONFIG (dir under your
 home holding Claude's config on your computer, default .claude), KOLOOD_URL (update source).

SAFETY
 - Server refuses on <150MB free RAM or <50MB disk. Footprint: one idle ssh (~3MB).
 - The token carries a tunnel-only key: it can open 127.0.0.1:2222/9222 reverse forwards
   and nothing else (no shell). Treat it like a password. The server's host key is pinned.
 - Your computer accepts the server key only through the tunnel (from 127.0.0.1).
 - Anyone with root on the server can reach your computer. Use servers you trust.
 - Computer asleep/offline = bridge down; it reconnects by itself.
GUIDE
}

save_self() {
  mkdir -p "${I%/*}"
  if [ -f "$0" ]; then [ "$0" -ef "$I" ] || cp "$0" "$I"; return 0; fi
  if curl -fsSL "$URL" -o "$I.tmp" 2>/dev/null && bash -n "$I.tmp"; then mv "$I.tmp" "$I"
  else rm -f "$I.tmp"; echo "WARNING: could not save a copy of install.sh (menu, update and session sync need it): $URL"; fi
}
add_path() {  # returns 0 if it had to add ~/.local/bin to PATH
  case ":$PATH:" in *":$HOME/.local/bin:"*) return 1;; esac
  grep -qF "local/bin:\$PATH\" $MARK" "$RC" 2>/dev/null || echo "export PATH=\"\$HOME/.local/bin:\$PATH\" $MARK" >> "$RC"
}

# ---------------------------------------------------------------- server
server() {
  [ "$OS" = Linux ] || die "the server step runs on Linux"
  is_wsl && echo "NOTE: this looks like WSL. If this is YOUR computer, use: bash install.sh pair"
  legacy_cleanup
  KEEP=0; [ "${1:-}" = refresh ] && KEEP=1
  avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); disk=$(df -Pm "$HOME" | awk 'NR==2{print $4}')
  echo "server: ${avail}MB RAM free, ${disk}MB disk free"
  [ "$avail" -ge 150 ] || die "under 150MB RAM available; refusing"
  [ "$disk" -ge 50 ] || die "under 50MB disk; refusing"
  if ! command -v claude >/dev/null 2>&1 && [ ! -x ~/.local/bin/claude ]; then
    a=""; echo "Claude Code is not installed on this server."
    [ -r /dev/tty ] && { ask "Install it now with the official installer? [Y/n]: " a || true; }
    case "${a:-Y}" in
      [Nn]*) echo "Skipped. Install it yourself, then run: claude  (and /login)";;
      *) [ "$avail" -ge 600 ] || echo "WARNING: only ${avail}MB RAM free. Claude sessions here can push this server into swap/OOM; consider a bigger box for prod."
         curl -fsSL https://claude.ai/install.sh | bash || echo "Install failed; install Claude Code manually.";;
    esac
    echo ">>> After pairing, run 'claude' once on this server and /login with your subscription."
  fi
  for t in ssh ssh-keygen base64 awk sed tar; do command -v "$t" >/dev/null || die "missing tool on server: $t"; done
  # already paired and live: nothing to do (re-running must not break a working setup)
  PAIRED=0; ssh -n -o BatchMode=yes -o ConnectTimeout=3 remote true 2>/dev/null && PAIRED=1
  NEW=0; [ $PAIRED = 0 ] && [ $KEEP = 0 ] && NEW=1
  if [ $NEW = 1 ] && command -v ss >/dev/null; then
    # a just-stopped tunnel (old install, or a computer that just went away) needs a few seconds to let go of its ports
    for _ in $(seq 20); do ss -ltn | grep -qE ":($TP|$CDP)\b" || break; sleep 1; done
    if ss -ltn | grep -E ":($TP|$CDP)\b"; then die "tunnel port $TP or $CDP is busy on this server (held by: $(ss -ltnp 2>/dev/null | grep -E ":($TP|$CDP)\b" | grep -o 'users:.*' | head -1))"; fi
  fi
  # sshd must allow reverse forwards (readable as root only; skipped if we can't read it)
  if /usr/sbin/sshd -T 2>/dev/null | grep -qiE '^allowtcpforwarding (no|local)'; then die "sshd has AllowTcpForwarding disabled; set it to yes in sshd_config"; fi
  mkdir -p ~/.ssh ~/.claude; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys ~/.ssh/config ~/.claude/CLAUDE.md; chmod 600 ~/.ssh/authorized_keys
  # not connected = a new pairing: forget any previous computer so a fresh token can register a new one
  [ $NEW = 0 ] || { rm -f ~/.ssh/kolood_user ~/.ssh/kolood_login_pub ~/.ssh/kolood_known_hosts; "${GNUSED[@]}" "/# kolood-login/d" ~/.ssh/authorized_keys; }
  [ -f ~/.ssh/kolood_tunnel ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/kolood_tunnel -C kolood-tunnel
  [ -f ~/.ssh/kolood_to_remote ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/kolood_to_remote -C kolood-server
  # The only thing the tunnel key may run is this script: it records the computer's username
  # (sent as the "command") and keeps the tunnel open. No shell, no other commands.
  cat > ~/.ssh/kolood_hello <<'HELLO'
#!/bin/sh
c="$SSH_ORIGINAL_COMMAND"; d="$HOME/.ssh"
if [ "$c" = kill-old ]; then pkill -u "$(id -u)" -f 'sleep 2147483647' 2>/dev/null; exit 0; fi
# pairing message: "<username> ssh-ed25519 <key>". First pairing wins; anything else is refused.
u=${c%% *}; k=${c#* }
case "$u" in ""|*[!a-zA-Z0-9._-]*) exit 1;; esac
case "$k" in "ssh-ed25519 "*) ;; *) exit 1;; esac
b=${k#ssh-ed25519 }; case "$b" in ""|*[!A-Za-z0-9+/=]*) exit 1;; esac
if [ -s "$d/kolood_user" ] && [ -s "$d/kolood_login_pub" ]; then [ "$(cat "$d/kolood_user")" = "$u" ] && [ "$(cat "$d/kolood_login_pub")" = "$k" ] || exit 1; fi
echo "$u" > "$d/kolood_user"; echo "$k" > "$d/kolood_login_pub"
grep -qF "$b" "$d/authorized_keys" || echo "$k kolood-login # kolood-login" >> "$d/authorized_keys"
sed -i "/# kolood-bridge\$/,/# kolood-bridge-end/ s/^  User .*/  User $u/" "$d/config"
exec sleep 2147483647
HELLO
  chmod 700 ~/.ssh/kolood_hello
  # what `kolood` runs on the server: Claude Code (or a shell) in a stable workspace
  cat > ~/.ssh/kolood_start <<'START'
#!/bin/bash
# $1 = the user's cwd on their computer (base64); the rest = kolood flags and claude args
export PATH="$HOME/.local/bin:$PATH"
I="$HOME/.local/share/kolood/install.sh"
cwd=$(printf %s "${1:-}" | base64 -d 2>/dev/null || true); shift
m=1; sh=0; a=()
for x in "$@"; do case "$x" in --no-remote|--no-mac) m=0;; --mac|--remote) ;; --shell) sh=1;; *) a+=("$x");; esac; done
mkdir -p "$HOME/workspace"; cd "$HOME/workspace"
[ $sh = 1 ] && exec "${SHELL:-/bin/bash}" -l
command -v claude >/dev/null || { echo "Claude Code is not installed on this server. Install it: curl -fsSL https://claude.ai/install.sh | bash"; exit 1; }
[ $m = 1 ] || exec claude "${a[@]}"
# resuming: copy the matching sessions from the user's computer first, so --resume ID, the picker and --continue see them
if [ -f "$I" ]; then
  n=${#a[@]}
  for ((i=0; i<n; i++)); do case "${a[i]}" in
    -r|--resume) nx="${a[i+1]:-}"
      if [[ "$nx" =~ ^[0-9a-fA-F-]{8,}$ ]]; then bash "$I" pull id "$nx"; elif [ -n "$cwd" ]; then bash "$I" pull dir "$cwd"; fi;;
    --resume=*) bash "$I" pull id "${a[i]#--resume=}";;
    -c|--continue) [ -n "$cwd" ] && bash "$I" pull dir "$cwd";;
  esac; done
fi
exec claude --append-system-prompt "You are on a server. The user is working on a remote machine, reached with: ssh remote '<cmd>' (it may be offline). Their working folder there is $cwd. Each call is a fresh shell, so use absolute paths or 'cd dir && cmd'. Their files and paths, including those in a resumed conversation, are on the remote." "${a[@]}"
START
  chmod 700 ~/.ssh/kolood_start
  # `kolood` on the server opens the menu
  save_self; mkdir -p ~/.local/bin; L=$HOME/.local/bin/kolood
  if [ ! -e "$L" ] || grep -qF "$MARK" "$L"; then printf '#!/bin/bash\n%s\nexec bash "$HOME/.local/share/kolood/install.sh" menu "$@"\n' "$MARK" > "$L"; chmod +x "$L"; fi
  add_path || true
  "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys
  echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$TP\",permitlisten=\"127.0.0.1:$CDP\",command=\"$HOME/.ssh/kolood_hello\" $(cut -d' ' -f1,2 ~/.ssh/kolood_tunnel.pub) $MARK" >> ~/.ssh/authorized_keys

  # auto-detect how the computer reaches this server: the address/port of the SSH session we are in
  HOST=${KOLOOD_HOST:-$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')}; SPORT=${KOLOOD_PORT:-$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')}
  [ -n "$HOST" ] || HOST=$(curl -4fs -m3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  [ -n "$SPORT" ] || SPORT=$(ss -ltnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')
  SPORT=${SPORT:-22}; MACUSER=$(cat ~/.ssh/kolood_user 2>/dev/null || echo unknown)

  "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config ~/.claude/CLAUDE.md
  # our block goes FIRST: ssh uses the first value it finds, so an older `Host remote` of yours can't shadow it
  cp ~/.ssh/config ~/.ssh/kolood_config.old
  cat > ~/.ssh/config <<EOF
$MARK
Host remote
  HostName localhost
  Port $TP
  User $MACUSER
  IdentityFile ~/.ssh/kolood_to_remote
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/kolood_known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
$MARK-end
EOF
  cat ~/.ssh/kolood_config.old >> ~/.ssh/config; rm -f ~/.ssh/kolood_config.old; chmod 600 ~/.ssh/config
  # Nothing is written to ~/.claude/CLAUDE.md: each `kolood` session is told about the computer via its system prompt (`--no-remote` skips it).
  if [ $PAIRED = 1 ]; then echo "Paired and connected; refreshed. On your computer type: kolood"; return 0; fi
  if [ $KEEP = 1 ]; then echo "Refreshed. Your computer is not connected right now (asleep/offline?)."; return 0; fi

  echo "server address for the token: $HOST:$SPORT"
  HK=""; for t in ed25519 ecdsa rsa; do [ -r /etc/ssh/ssh_host_${t}_key.pub ] && { HK=$(awk '{print $1" "$2}' /etc/ssh/ssh_host_${t}_key.pub); break; }; done
  TOKEN="kolood1.$(printf '%s\n' "$HOST" "$SPORT" "$(id -un)" "$HK" "$(cut -d' ' -f1,2 ~/.ssh/kolood_to_remote.pub)" "$(grep -v -- ----- ~/.ssh/kolood_tunnel | tr -d '\n')" | base64 | tr -d '\n')"
  printf '\n=== PAIRING TOKEN (secret; paste on your computer) ===\n%s\n\nOn your computer run the same one-liner and choose "Pair", or: bash install.sh pair\n\nWaiting for your computer (Ctrl-C to stop; re-run any time)...\n' "$TOKEN"
  for _ in $(seq 120); do
    ssh -n -o BatchMode=yes -o ConnectTimeout=3 remote 'echo "connected to $(hostname) as $(whoami)"' 2>/dev/null && { echo "Done. On your computer, type:  kolood   (first run asks you to /login on the server)"; return; }
    sleep 5
  done
  echo "Not connected yet. Run the pairing step on your computer; then test with: ssh remote hostname"
}

# pairing a NEW computer: revoke the old token (tunnel key) and login key, drop the live tunnel
forget() {
  ssh -O exit remote 2>/dev/null || true
  pkill -u "$(id -u)" -f 'sleep 2147483647' 2>/dev/null || true
  rm -f ~/.ssh/kolood_tunnel ~/.ssh/kolood_tunnel.pub ~/.ssh/kolood_user ~/.ssh/kolood_login_pub ~/.ssh/kolood_known_hosts
  "${GNUSED[@]}" "/# kolood-login/d" ~/.ssh/authorized_keys 2>/dev/null || true
}

# (server) copy Claude sessions from the user's computer into a server project so claude can resume them
pull() {
  mode=${1:-}; arg=${2:-}; dst=${3:-$HOME/workspace}
  case "$mode" in
    dir) [ -n "$arg" ] || die "usage: install.sh pull dir PATH_ON_YOUR_COMPUTER [SERVERPATH]"; arg=$(enc "$arg");;
    id) [[ "$arg" =~ ^[A-Za-z0-9-]+$ ]] || die "bad session id: $arg";;
    *) die "usage: install.sh pull dir PATH [SERVERPATH] | pull id SESSION_ID [SERVERPATH]";;
  esac
  cfg=${KOLOOD_REMOTE_CONFIG:-.claude}; [[ "$cfg" =~ ^[A-Za-z0-9._/-]+$ ]] || die "bad KOLOOD_REMOTE_CONFIG"
  mkdir -p "$dst"; d="$HOME/.claude/projects/$(enc "$(cd "$dst" && pwd -P)")"; mkdir -p "$d"
  K=""; tar --help 2>&1 | grep -q keep-newer-files && K=--keep-newer-files   # a session continued here stays
  set +e
  ssh -o BatchMode=yes -o ConnectTimeout=5 remote sh -s -- "$mode" "$arg" "$cfg" <<'R' | tar -xf - -C "$d" $K 2>/dev/null
export COPYFILE_DISABLE=1
cd "$HOME" && cd "$3/projects" 2>/dev/null || exit 3
if [ "$1" = id ]; then
  f=$(ls -t ./*/"$2.jsonl" 2>/dev/null | head -n 1); [ -n "$f" ] || exit 4
  cd "${f%/*}" || exit 4
  if [ -d "$2" ]; then tar -cf - "$2.jsonl" "$2"; else tar -cf - "$2.jsonl"; fi
else
  cd "./$2" 2>/dev/null || exit 4
  tar -cf - .
fi
R
  r=${PIPESTATUS[0]}; set -e
  case $r in
    0) echo "kolood: copied Claude session(s) from your computer";;
    3) echo "kolood: no Claude config (~/$cfg) on your computer";;
    4) [ "$mode" = id ] && echo "kolood: session $arg is not on your computer (using the server's)" || echo "kolood: no Claude sessions for that folder on your computer";;
    *) echo "kolood: your computer is not reachable; resuming from the server's sessions only";;
  esac
}

mount_remote() {
  command -v sshfs >/dev/null || die "sshfs not installed on this server"
  mkdir -p ~/remote; sshfs -o reconnect,ServerAliveInterval=15 "remote:" ~/remote && echo "mounted ~/remote"
}

# Opt-in: let the server's Claude run `ssh remote ...` without asking each time (unattended commands on your computer).
allow() {
  command -v python3 >/dev/null || die "python3 needed"
  mkdir -p ~/.claude; python3 - "${1:-on}" <<'PY'
import json, os, sys
p = os.path.expanduser("~/.claude/settings.json"); r = "Bash(ssh remote:*)"
s = json.load(open(p)) if os.path.exists(p) else {}
a = s.setdefault("permissions", {}).setdefault("allow", [])
m = sys.argv[1]
if m == "status": print("on" if r in a else "off"); sys.exit()
if m == "toggle": m = "off" if r in a else "on"
if m not in ("on", "off"): sys.exit("usage: allow on|off|toggle|status")
if m == "on" and r not in a: a.append(r)
if m == "off" and r in a: a.remove(r)
json.dump(s, open(p, "w"), indent=2)
print("Claude may run 'ssh remote ...' without asking: " + m)
PY
}

# ---------------------------------------------------------------- your computer
load_conf() {
  [ -f "$CONF" ] || return 1
  . "$CONF"
  SRV=(-i "$LK" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking="$STRICT" -o ConnectTimeout=8 -p "$port" "$suser@$host")
}
bridge_up() { ssh -n -o BatchMode=yes "${SRV[@]}" 'ssh -o BatchMode=yes -o ConnectTimeout=4 remote true' 2>/dev/null; }
# run this script on the server (uploads this copy first, so both sides match)
rrun() {
  ssh -o BatchMode=yes "${SRV[@]}" 'mkdir -p ~/.local/share/kolood && cat > ~/.local/share/kolood/install.sh.new && mv ~/.local/share/kolood/install.sh.new ~/.local/share/kolood/install.sh' < "$I" \
    && ssh -t "${SRV[@]}" "bash ~/.local/share/kolood/install.sh $*" </dev/tty
}
logs_hint() {
  if [ "$OS" != Darwin ] && systemctl --user show-environment >/dev/null 2>&1; then echo "journalctl --user -u $UNIT"; else echo "$LOG"; fi
}

need_sshd() {
  local tried=0
  until port_open 22; do
    [ -r /dev/tty ] || die "no SSH server on port 22 here"
    if [ "$OS" = Darwin ]; then
      echo "-> Turn ON: System Settings > General > Sharing > Remote Login"; ask "   Press Enter once it is on: " _
    elif [ $tried = 0 ] && command -v apt-get >/dev/null && yes_no "No SSH server (sshd) here. Install and start openssh-server with sudo now? [y/N] "; then
      tried=1; { sudo apt-get update -qq && sudo apt-get install -y openssh-server && { sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start; }; } || true
    else
      tried=1; echo "-> Install and start an SSH server on port 22 (openssh-server; WSL: sudo service ssh start)"; ask "   Press Enter once it runs: " _
    fi
  done
}

tunnel_stop() {
  if [ "$OS" = Darwin ]; then launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  else systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true; fi
  pkill -u "$(id -u)" -f kolood_loop.sh 2>/dev/null || true
  pkill -u "$(id -u)" -f "$HOME/.ssh/kolood_tunnel" 2>/dev/null || true
}

# keep the tunnel up: launchd (macOS), a systemd user service (Linux/WSL with systemd), else a background loop
tunnel_start() {
  tunnel_stop
  if [ "$OS" = Darwin ]; then
    mkdir -p "${PLIST%/*}"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.kolood.bridge</string>
<key>ProgramArguments</key><array>
<string>/bin/sh</string><string>$HOME/.ssh/kolood_run.sh</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  elif systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/$UNIT <<'EOF'
[Unit]
Description=kolood tunnel to the server
StartLimitIntervalSec=0
[Service]
ExecStart=/bin/sh %h/.ssh/kolood_run.sh
Restart=always
RestartSec=15
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload; systemctl --user enable --now "$UNIT" >/dev/null 2>&1
    loginctl enable-linger "$(id -un)" 2>/dev/null || true   # keep it up without an open login, where allowed
  else
    printf 'while :; do sh "$HOME/.ssh/kolood_run.sh"; sleep 15; done\n' > ~/.ssh/kolood_loop.sh
    grep -qF kolood_loop.sh "$RC" 2>/dev/null || echo "pgrep -u \"\$(id -u)\" -f kolood_loop.sh >/dev/null || (nohup sh \"\$HOME/.ssh/kolood_loop.sh\" >>$LOG 2>&1 &) $MARK" >> "$RC"
    (nohup sh "$HOME/.ssh/kolood_loop.sh" >>"$LOG" 2>&1 &)
    echo "(no systemd: the tunnel runs in the background and is restarted when you open a terminal)"
  fi
}

client() {
  case "$OS" in Darwin|Linux) ;; *) die "unsupported OS (macOS, Linux, or Windows via WSL)";; esac
  TOKEN=${1:-}; [ -n "$TOKEN" ] || ask "Paste the token from the server: " TOKEN
  # tolerate a pasted banner, wrapped lines or stray spaces: pull out just the token
  TOKEN=$(printf '%s\n' "$TOKEN" | tr -d ' \r' | awk 'f==0 && /kolood1\./ {sub(/.*kolood1\./,"kolood1."); t=$0; f=1; next} f==1 && /^[A-Za-z0-9+\/=]+$/ {t=t $0; next} f==1 {exit} END{print t}')
  [ -n "$TOKEN" ] || die "no token found in what you pasted (it starts with kolood1.)"
  legacy_cleanup
  D=$(printf %s "${TOKEN#kolood1.}" | b64d 2>/dev/null) || die "bad token"
  host=$(echo "$D" | sed -n 1p); port=$(echo "$D" | sed -n 2p); suser=$(echo "$D" | sed -n 3p)
  hk=$(echo "$D" | sed -n 4p); spub=$(echo "$D" | sed -n 5p); priv=$(echo "$D" | sed -n 6p)
  [ -n "$host" ] && [ -n "$port" ] && [ -n "$suser" ] && [ -n "$spub" ] && [ -n "$priv" ] || die "bad token"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$host" =~ ^[A-Za-z0-9.:_-]+$ ]] && [[ "$suser" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad token (unexpected server address or user)"
  for t in ssh ssh-keygen base64 awk sed fold tar; do command -v "$t" >/dev/null || die "missing tool here: $t"; done
  need_sshd
  NEWPATH=0; mkdir -p ~/.ssh; chmod 700 ~/.ssh
  [ -f "$LK" ] || ssh-keygen -q -t ed25519 -N "" -f "$LK" -C kolood-login
  K=$HOME/.ssh/kolood_tunnel; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
  (umask 077; printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n' "$(echo "$priv" | fold -w70)" > "$K")
  STRICT=accept-new; : > "$KH"
  [ -n "$hk" ] || echo "WARNING: server host key not in the token; first connection is trusted without verification."
  if [ -n "$hk" ]; then STRICT=yes; if [ "$port" = 22 ]; then echo "$host $hk" > "$KH"; else echo "[$host]:$port $hk" > "$KH"; fi; fi
  (umask 077; printf 'host=%q\nport=%q\nsuser=%q\nSTRICT=%q\n' "$host" "$port" "$suser" "$STRICT" > "$CONF"; printf '%s\n' "$TOKEN" > ~/.ssh/kolood_token)
  load_conf
  # the server's key may log in here only through the tunnel (arrives from loopback)
  "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys
  echo "from=\"127.0.0.1,::1\" $spub $MARK" >> ~/.ssh/authorized_keys
  # the service runs this: clear any stale server-side session (after sleep/wake), then open the tunnel
  # and tell the server our username (the only "command" the tunnel key is allowed to send).
  cat > ~/.ssh/kolood_run.sh <<EOF
O="-i $K -o IdentitiesOnly=yes -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=$STRICT -o ConnectTimeout=15 -p $port"
ssh \$O $suser@$host kill-old >/dev/null 2>&1
exec ssh \$O -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:$TP:localhost:22 -R 127.0.0.1:$CDP:localhost:$CDP $suser@$host "\$(id -un) \$(cut -d' ' -f1,2 $LK.pub)"
EOF
  save_self
  # `kolood`: Claude Code on the server, started from this terminal; the computer is kept awake meanwhile
  mkdir -p ~/.local/bin
  cat > ~/.local/bin/kolood <<'EOF'
#!/bin/bash
# kolood-bridge
[ "${1:-}" = --setup ] && exec bash "$HOME/.local/share/kolood/install.sh" menu
. "$HOME/.ssh/kolood_conf" 2>/dev/null || { echo "kolood is not paired yet: run  kolood --setup"; exit 1; }
B=$(printf %s "$PWD" | base64 | tr -d '\n')
W=(); if command -v caffeinate >/dev/null; then W=(caffeinate -i)
elif command -v systemd-inhibit >/dev/null && systemd-inhibit --what=sleep --why=kolood true 2>/dev/null; then W=(systemd-inhibit --what=sleep --why=kolood); fi
exec "${W[@]}" ssh -t -i "$HOME/.ssh/kolood_login" -o IdentitiesOnly=yes -o UserKnownHostsFile="$HOME/.ssh/kolood_known_hosts" -o StrictHostKeyChecking="$STRICT" -o ServerAliveInterval=30 -p "$port" "$suser@$host" "~/.ssh/kolood_start $B$(printf ' %q' "$@")"
EOF
  chmod +x ~/.local/bin/kolood
  add_path && NEWPATH=1
  tunnel_start
  echo "Connecting..."
  for _ in $(seq 12); do
    sleep 3
    if bridge_up; then
      echo "Ready. In a new terminal (or after: source $RC) type:  kolood      (menu: kolood --setup)"
      [ $NEWPATH = 1 ] && echo "(added ~/.local/bin to PATH in $RC)"
      is_wsl && echo "WSL: Windows files are under /mnt/c; the bridge runs while WSL is running."
      return 0
    fi
  done
  echo "Not connected. Likely causes:"
  echo " - this token was already used by another pairing: on the server choose 'Pair a NEW computer' for a fresh token"
  [ "$OS" = Darwin ] && echo " - Remote Login is limited to certain users (System Settings > Sharing > Remote Login > allow your user)"
  echo " - the server's sshd blocks port forwarding or the tunnel ports are busy"
  echo "Log: $(logs_hint)"; exit 1
}

restart_bridge() {
  load_conf || die "not paired"
  tunnel_start; echo "Restarting..."
  for _ in $(seq 8); do sleep 3; bridge_up && { echo "Bridge UP"; return 0; }; done
  die "still down. Log: $(logs_hint)"
}

update() {
  t=$(mktemp); curl -fsSL "$URL" -o "$t" && bash -n "$t" || { rm -f "$t"; die "download failed: $URL"; }
  mkdir -p "${I%/*}"; mv "$t" "$I"; echo "Downloaded the latest kolood."
  if load_conf; then   # your computer: update the server too, then this computer
    rrun refresh || echo "WARNING: could not update the server now (offline?); later: 'kolood' on the server > Update"
    exec bash "$I" pair "$(cat ~/.ssh/kolood_token)"
  elif [ -f ~/.ssh/kolood_start ]; then exec bash "$I" refresh
  else echo "Not set up on this machine yet."; fi
}

# installs from before the rename (imlegit / claude-mac-bridge): stop and delete them so they can't hold the ports
legacy_cleanup() {
  local o="# claude-mac-bridge" f
  [ -e ~/.ssh/cmb_hello ] || [ -e ~/.ssh/cmb_run.sh ] || [ -e ~/Library/LaunchAgents/com.claude-mac-bridge.plist ] || return 0
  echo "Removing an older imlegit install..."
  launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-mac-bridge.plist 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/com.claude-mac-bridge.plist
  systemctl --user disable --now imlegit-bridge.service >/dev/null 2>&1 || true; rm -f ~/.config/systemd/user/imlegit-bridge.service
  pkill -u "$(id -u)" -f cmb_loop.sh 2>/dev/null || true; pkill -u "$(id -u)" -f "$HOME/.ssh/cmb_tunnel" 2>/dev/null || true
  ssh -O exit mac 2>/dev/null || true; pkill -u "$(id -u)" -f "sleep 2147483647" 2>/dev/null || true
  for f in ~/.zshrc ~/.bash_profile ~/.bashrc ~/.profile ~/.ssh/authorized_keys; do if [ -f "$f" ]; then "${GNUSED[@]}" -e "/$o/d" -e "/# cmb-login/d" "$f"; fi; done
  for f in ~/.ssh/config ~/.claude/CLAUDE.md; do if [ -f "$f" ]; then "${GNUSED[@]}" "/$o/,/$o-end/d" "$f"; fi; done
  if [ -f ~/.local/bin/imlegit ] && grep -qF "$o" ~/.local/bin/imlegit; then rm -f ~/.local/bin/imlegit; fi
  rm -f ~/.ssh/cmb_*; rm -rf ~/.local/share/imlegit
}

remove() {
  legacy_cleanup
  tunnel_stop
  rm -f "$PLIST" ~/.config/systemd/user/$UNIT; systemctl --user daemon-reload >/dev/null 2>&1 || true
  for f in ~/.zshrc ~/.bash_profile ~/.bashrc ~/.profile; do if [ -f "$f" ]; then "${GNUSED[@]}" "/$MARK/d" "$f"; fi; done
  if [ -f ~/.local/bin/kolood ] && grep -qF "$MARK" ~/.local/bin/kolood; then rm -f ~/.local/bin/kolood; fi
  if [ -f ~/.claude/settings.json ] && command -v python3 >/dev/null; then allow off >/dev/null 2>&1 || true; fi
  ssh -O exit remote 2>/dev/null || true
  fusermount -u ~/remote 2>/dev/null || true; rmdir ~/remote ~/workspace 2>/dev/null || true
  if [ -f ~/.ssh/authorized_keys ]; then "${GNUSED[@]}" -e "/$MARK/d" -e "/# kolood-login/d" ~/.ssh/authorized_keys; fi
  if [ -f ~/.ssh/config ]; then "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config; fi
  if [ -f ~/.claude/CLAUDE.md ]; then "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.claude/CLAUDE.md; fi
  pkill -u "$(id -u)" -f "sleep 2147483647" 2>/dev/null || true
  rm -f ~/.ssh/kolood_*; rm -rf "${I%/*}"
  echo "removed"
}

# ---------------------------------------------------------------- menus
client_menu() {
  while :; do
    echo; echo "== kolood: this computer ($(plat)) =="
    if load_conf; then
      if bridge_up; then echo "Server $suser@$host:$port   bridge: UP"; else echo "Server $suser@$host:$port   bridge: DOWN (try 4)"; fi
    elif [ -f ~/.ssh/cmb_run.sh ]; then echo "Old imlegit install found: pair again (on the server: 'Pair a NEW computer')."
    else echo "Not paired yet: run the server step first, then choose 3."; fi
    echo " 1) Start Claude on the server        (kolood)"
    echo " 2) Open a shell on the server        (kolood --shell)"
    echo " 3) Pair with a server (paste a token)"
    echo " 4) Restart the bridge"
    echo " 5) Update kolood (here and on the server)"
    echo " 6) Toggle: Claude may run 'ssh remote' without asking"
    echo " 7) Uninstall (here and on the server)"
    echo " 0) Quit"
    c=""; ask "Choose: " c || exit 0
    case "$c" in
      1|2) if [ -f "$CONF" ]; then [ "$c" = 1 ] && exec "$HOME/.local/bin/kolood"; exec "$HOME/.local/bin/kolood" --shell; else echo "Pair first (3)."; fi;;
      3) run client;;
      4) if [ -f "$CONF" ]; then run restart_bridge; else echo "Pair first (3)."; fi;;
      5) run update;;
      6) if load_conf; then run rrun allow toggle; else echo "Pair first (3)."; fi;;
      7) if yes_no "Remove kolood from this computer AND the server? [y/N] "; then
           if load_conf; then rrun remove || echo "Server not reachable: run 'bash install.sh remove' there."; fi
           remove; exit 0; fi;;
      0|q|Q) exit 0;;
      *) echo "Pick one of the numbers above.";;
    esac
  done
}

server_menu() {
  while :; do
    echo; echo "== kolood: server =="
    if command -v claude >/dev/null 2>&1 || [ -x ~/.local/bin/claude ]; then echo -n "Claude: installed   "; else echo -n "Claude: NOT installed (1 offers it)   "; fi
    if [ -s ~/.ssh/kolood_user ]; then
      if ssh -n -o BatchMode=yes -o ConnectTimeout=4 remote true 2>/dev/null; then echo "Paired with $(cat ~/.ssh/kolood_user): connected"
      else echo "Paired with $(cat ~/.ssh/kolood_user): not reachable now (asleep/offline?)"; fi
    else echo "Not paired yet (choose 1)."; fi
    echo " 1) Pair a computer / refresh setup"
    echo " 2) Pair a NEW computer (revokes the old token and keys)"
    echo " 3) Toggle: Claude may run 'ssh remote' without asking   [now: $(allow status 2>/dev/null || echo ?)]"
    echo " 4) Import a project's Claude sessions from your computer"
    echo " 5) Mount your computer's home at ~/remote (sshfs)"
    echo " 6) Update kolood"
    echo " 7) Uninstall"
    echo " 0) Quit"
    c=""; ask "Choose: " c || exit 0
    case "$c" in
      1) run server;;
      2) if yes_no "Forget the current computer and make a new token? [y/N] "; then forget; run server; fi;;
      3) run allow toggle;;
      4) p=""; q=""; ask "Project path on your computer (absolute, e.g. /Users/me/proj): " p || true
         ask "Server path [~/workspace]: " q || true; q=${q/#\~/$HOME}; run pull dir "$p" "${q:-$HOME/workspace}";;
      5) run mount_remote;;
      6) run update;;
      7) if yes_no "Remove kolood from this server? [y/N] "; then remove; exit 0; fi;;
      0|q|Q) exit 0;;
      *) echo "Pick one of the numbers above.";;
    esac
  done
}

menu() {
  [ -r /dev/tty ] || die "no terminal for the menu; see: bash install.sh help"
  case "$OS" in
    Darwin) client_menu;;
    *) if [ -f "$CONF" ] || [ -f ~/.ssh/cmb_run.sh ]; then client_menu
       elif [ -f ~/.ssh/kolood_start ]; then server_menu
       else
         echo "Is this machine the SERVER (Claude Code runs here) or YOUR COMPUTER (you type kolood here)?"
         r=""; ask "[s]erver / [c]omputer: " r || exit 0
         case "$r" in [Ss]*) server_menu;; [Cc]*) client_menu;; *) die "answer s or c";; esac
       fi;;
  esac
}

case "${1:-}" in
  -h|--help|help) guide;;
  menu|setup) menu;;
  server) server;;
  refresh) server refresh;;
  pair|client) client "${2:-}";;
  pull) shift; pull "$@";;
  history) [ $# -ge 3 ] || die "usage: install.sh history PATH_ON_YOUR_COMPUTER SERVERPATH"; pull dir "$2" "$3";;
  mount) mount_remote;;
  allow) allow "${2:-on}";;
  update) update;;
  remove|uninstall|--uninstall) remove;;
  *kolood1.*) client "$1";;
  "") if [ -t 1 ] && [ -r /dev/tty ]; then menu; elif [ "$OS" = Darwin ]; then client; else server; fi;;
  *) die "unknown command: $1 (see: bash install.sh help)";;
esac
