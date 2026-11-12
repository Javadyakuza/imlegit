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
ACCTDIR=$HOME/.config/kolood/accounts   # Claude accounts on the server; "default" = ~/.claude
WEB=$HOME/.local/share/kolood/web; WPY=$HOME/.local/share/kolood/web/kolood_web.py   # phone web terminal + session holder
WUNIT=kolood-web.service; WPORT=7443
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
 Later: `kolood` (no arguments) opens the menu, on your computer and on the server.

KOLOOD ON YOUR COMPUTER (`kolood -h` for the full list)
 kolood                       interactive menu: sessions, accounts, pairing, update, uninstall
 kolood start [CLAUDE ARGS]   new Claude session on the server (one-liner, no questions)
 kolood -c | --resume [ID]    continue/resume; this computer's sessions are copied first
 kolood shell                 a login shell on the server
 kolood account list | add [NAME] | login NAME | use NAME | remove NAME
 Flags: --account NAME (Claude login on the server), --no-remote (session not told about
 this computer); any flag also starts Claude directly, e.g. kolood --model opus

SCRIPT COMMANDS: menu | server | pair [TOKEN] | refresh | update | allow on|off|toggle
 | pull dir PATH [SRVPATH] | pull id SESSION_ID | history PATH SRVPATH | mount | remove
 | account list|add [NAME]|login NAME|use NAME|remove NAME
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
  mkdir -p ~/.ssh ~/.claude; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys ~/.ssh/config; chmod 600 ~/.ssh/authorized_keys
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
I="$HOME/.local/share/kolood/install.sh"; W="$HOME/.local/share/kolood/web/kolood_web.py"
# run inside the session holder, so the session survives a closed terminal and the phone page can join it
if [ -z "${KOLOOD_INSIDE:-}" ] && [ -t 0 ] && [ -f "$W" ] && python3 "$W" status >/dev/null 2>&1; then exec python3 "$W" attach -- "$0" "$@"; fi
cwd=$(printf %s "${1:-}" | base64 -d 2>/dev/null || true); shift
m=1; sh=0; srv=0; acct=; a=()
while [ $# -gt 0 ]; do case "$1" in
  --no-remote|--no-mac) m=0;; --mac|--remote) ;; --shell) sh=1;; --server) srv=1;;
  --account|--acc) acct=$2; shift;; --account=*|--acc=*) acct=${1#*=};;
  *) a+=("$1");;
esac; shift; done
[ -n "$acct" ] || acct=$(cat "$HOME/.config/kolood/account" 2>/dev/null || true)
if [ -n "$acct" ] && [ "$acct" != default ]; then
  [[ "$acct" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || { echo "bad account name: $acct"; exit 1; }
  [ -d "$HOME/.config/kolood/accounts/$acct" ] || { echo "No account $acct on the server. Accounts: kolood account list"; exit 1; }
  export CLAUDE_CONFIG_DIR="$HOME/.config/kolood/accounts/$acct"
fi
# a token saved with `kolood account token` replaces the browser login for this account
E="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.kolood_env"; if [ -f "$E" ]; then set -a; . "$E"; set +a; fi
# local mode: work in the user's folder itself. Their home is mounted here at the same path (over the tunnel)
# and every shell command runs on their computer, so it is like running there. Otherwise: ~/workspace on the server.
D="$HOME/.local/share/kolood/web/kolood_device.py"; S="$HOME/.local/share/kolood/shims"; LOCAL=0
# drop a dead mount left behind when its process died (a daemon restart stops every process it started)
fresh() { if awk -v p="$1" '$2 == p && $3 ~ /^fuse/ {f=1} END {exit !f}' /proc/mounts 2>/dev/null && ! timeout 10 ls "$1" >/dev/null 2>&1; then fusermount -uz "$1" 2>/dev/null || fusermount3 -uz "$1" 2>/dev/null || true; fi; }
if [ $m = 1 ] && [ $sh = 0 ] && [ $srv = 0 ] && [ -n "$cwd" ] && [ -f "$D" ]; then
  why=""
  if ! command -v sshfs >/dev/null; then why="sshfs is not installed on the server (kolood update installs it)"
  elif ! INFO=$(python3 "$D" info 2>/dev/null); then why="your computer is not reachable"
  else
    eval "$(printf %s "$INFO" | python3 -c 'import json,sys,shlex;d=json.load(sys.stdin);print("DH=%s DOS=%s DRG=%d DGIT=%d"%(shlex.quote(d["home"]),shlex.quote(d["os"]),bool(d["rg"]),bool(d["git"])))')"
    case "$DH" in ""|/|"$HOME"|"$HOME"/*) why="your computer's home ($DH) overlaps the server's";; esac
    case "$HOME/" in "$DH"/*) why="your computer's home ($DH) contains the server's";; esac
    case "$cwd" in "$DH"|"$DH"/*) ;; *) [ -n "$why" ] || why="$cwd is outside your home folder";; esac
    [ -n "$why" ] || fresh "$DH"
    if [ -z "$why" ] && ! mountpoint -q "$DH"; then
      if [ -d "$DH" ] && { [ ! -r "$DH" ] || [ ! -w "$DH" ] || [ -n "$(ls -A "$DH" 2>/dev/null)" ]; }; then why="$DH already exists on the server (not empty or not yours)"
      else
        mkdir -p "$DH" 2>/dev/null || { sudo -n mkdir -p "$DH" && sudo -n chown "$(id -u):$(id -g)" "$DH"; } 2>/dev/null || why="cannot create $DH on the server (needs root or sudo)"
        # allow_other only so Claude's settings view can be mounted inside it (fusermount runs as root);
        # default_permissions + umask=077 keep everyone but you out
        AO=; grep -qs '^user_allow_other' /etc/fuse.conf && AO=,allow_other,default_permissions,umask=077
        [ -n "$why" ] || sshfs "remote:$DH" "$DH" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user$AO 2>/dev/null || why="could not mount your files (sshfs/FUSE)"
      fi
    fi
  fi
  if [ -z "$why" ] && cd "$cwd" 2>/dev/null; then LOCAL=1; else echo "kolood: working on the server in ~/workspace (${why:-cannot open $cwd})"; fi
fi
if [ $LOCAL = 1 ]; then
  export KOLOOD_DEVICE_ROOT="$DH" KOLOOD_DEVICE_OS="$DOS" KOLOOD_SHIM_DIR="$S" CLAUDE_CODE_SHELL_PREFIX="$S/kolood-shell" BROWSER="$S/kolood-open" PATH="$S:$PATH"
  if [ "$DRG" = 1 ]; then export KOLOOD_DEVICE_RG=1 USE_BUILTIN_RIPGREP=0; fi
  if [ "$DGIT" = 1 ]; then export KOLOOD_DEVICE_GIT=1; fi
  # Claude's own settings at your computer's path too (~/.claude, or ~/.claude-NAME for an account): the server's
  # config is shown there (bindfs), and your computer's CLAUDE.md, skills, agents, commands and this project's
  # memory are linked into it (read through a second mount, since the first one covers them)
  if command -v bindfs >/dev/null; then
    RC=${CLAUDE_CONFIG_DIR:-$HOME/.claude}; an=${acct:-default}; V="$DH/.claude"; [ "$an" = default ] || V="$DH/.claude-$an"
    H="$HOME/.local/share/kolood/devcfg/$an"; mkdir -p "$H" "$RC"; fresh "$V"; fresh "$H"
    if ! mountpoint -q "$V"; then mkdir -p "$V" 2>/dev/null && { bindfs --no-allow-other --resolve-symlinks -o nonempty "$RC" "$V" 2>/dev/null || bindfs --no-allow-other --resolve-symlinks "$RC" "$V" 2>/dev/null; } || true; fi   # nonempty: libfuse2 builds need it, libfuse3 ones refuse it
    mountpoint -q "$H" || sshfs "remote:$V" "$H" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user 2>/dev/null || true
    [ -f "$RC/CLAUDE.md" ] && [ ! -L "$RC/CLAUDE.md" ] && [ ! -s "$RC/CLAUDE.md" ] && rm -f "$RC/CLAUDE.md"   # an empty one left by older versions
    if mountpoint -q "$H"; then python3 "$D" link-config "$RC" "$H" "$(printf %s "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')" >/dev/null 2>&1 || true; fi
    if mountpoint -q "$V"; then
      [ "$an" = default ] && python3 "$D" sync-global "$HOME/.claude.json" "$RC/.claude.json" 2>/dev/null
      export CLAUDE_CONFIG_DIR="$V" KOLOOD_CONFIG_VIEW="$V" KOLOOD_CONFIG_REAL="$RC" KOLOOD_DEVICE_CFG="$H"
    else echo "kolood: Claude's settings stay at a server path (could not show them at $V)"; fi
  fi
  # the project's own MCP servers start on the user's computer too
  MC="$HOME/.config/kolood/mcp-$(printf %s "$cwd" | sha1sum | cut -c1-12).json"
  if [ -f "$cwd/.mcp.json" ] && [ "$(python3 "$D" mcp-config "$cwd" "$MC" 2>/dev/null)" != 0 ] && [ -f "$MC" ]; then a+=(--strict-mcp-config --mcp-config "$MC"); fi
else
  mkdir -p "$HOME/workspace"; cd "$HOME/workspace"
fi
[ $sh = 1 ] && exec "${SHELL:-/bin/bash}" -l
command -v claude >/dev/null || { echo "Claude Code is not installed on this server. Install it: curl -fsSL https://claude.ai/install.sh | bash"; exit 1; }
# resuming: copy the matching sessions from the user's computer first, so --resume ID, the picker and --continue see them
if [ $m = 1 ] && [ -f "$I" ]; then
  n=${#a[@]}
  for ((i=0; i<n; i++)); do case "${a[i]}" in
    -r|--resume) nx="${a[i+1]:-}"
      if [[ "$nx" =~ ^[0-9a-fA-F-]{8,}$ ]]; then bash "$I" pull id "$nx" "$PWD"; elif [ -n "$cwd" ]; then bash "$I" pull dir "$cwd" "$PWD"; fi;;
    --resume=*) bash "$I" pull id "${a[i]#--resume=}" "$PWD";;
    -c|--continue) [ -n "$cwd" ] && bash "$I" pull dir "$cwd" "$PWD";;
  esac; done
fi
# inside the session holder: tell it which conversation this is, so it can resume it after a server restart
if [ -n "${KOLOOD_SESSION_FILE:-}" ]; then
  sid=""; rs=0; n=${#a[@]}
  for ((i=0; i<n; i++)); do case "${a[i]}" in
    -r|--resume) rs=1; [[ "${a[i+1]:-}" =~ ^[0-9a-fA-F-]{8,}$ ]] && sid=${a[i+1]};;
    --resume=*) rs=1; sid=${a[i]#--resume=};;
    --session-id) rs=1; sid=${a[i+1]:-};;
    -c|--continue) rs=1
      P="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf %s "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
      f=$(ls -t "$P"/*.jsonl 2>/dev/null | head -n 1); [ -n "$f" ] && sid=$(basename "$f" .jsonl);;
  esac; done
  # a new conversation: pick its id now (only if this Claude version knows --session-id; checked once per version)
  if [ $rs = 0 ]; then
    C=$(readlink -f "$(command -v claude)"); K="$HOME/.config/kolood/claude-sid-$(stat -c %Y "$C" 2>/dev/null)"
    [ -f "$K" ] || { mkdir -p "${K%/*}"; if claude --help 2>&1 | grep -q -- --session-id; then echo yes; else echo no; fi > "$K"; }
    if [ "$(cat "$K")" = yes ]; then sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())'); a+=(--session-id "$sid"); fi
  fi
  if [ -n "$sid" ]; then nr=false; [ $m = 0 ] && nr=true
    printf '{"claude_id":"%s","account":"%s","no_remote":%s}\n' "$sid" "${acct:-default}" "$nr" > "$KOLOOD_SESSION_FILE"; fi
fi
[ $m = 1 ] || exec claude "${a[@]}"
[ $LOCAL = 1 ] && exec claude --append-system-prompt "Your working folder is $cwd on the user's computer ($DOS). The files you read and edit and every shell command you run are on that computer." "${a[@]}"
exec claude --append-system-prompt "You are on a server. The user is working on a remote machine, reached with: ssh remote '<cmd>' (it may be offline). Their working folder there is $cwd. Each call is a fresh shell, so use absolute paths or 'cd dir && cmd'. Their files and paths, including those in a resumed conversation, are on the remote." "${a[@]}"
START
  chmod 700 ~/.ssh/kolood_start
  # `kolood` on the server opens the menu
  save_self; mkdir -p ~/.local/bin; L=$HOME/.local/bin/kolood
  if [ ! -e "$L" ] || grep -qF "$MARK" "$L"; then printf '#!/bin/bash\n%s\nif [ $# = 0 ]; then exec bash "$HOME/.local/share/kolood/install.sh" menu; else exec bash "$HOME/.local/share/kolood/install.sh" "$@"; fi\n' "$MARK" > "$L"; chmod +x "$L"; fi
  add_path || true
  "${GNUSED[@]}" "/$MARK/d" ~/.ssh/authorized_keys
  echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$TP\",permitlisten=\"127.0.0.1:$CDP\",command=\"$HOME/.ssh/kolood_hello\" $(cut -d' ' -f1,2 ~/.ssh/kolood_tunnel.pub) $MARK" >> ~/.ssh/authorized_keys

  # auto-detect how the computer reaches this server: the address/port of the SSH session we are in
  HOST=${KOLOOD_HOST:-$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')}; SPORT=${KOLOOD_PORT:-$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')}
  [ -n "$HOST" ] || HOST=$(curl -4fs -m3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  [ -n "$SPORT" ] || SPORT=$(ss -ltnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')
  SPORT=${SPORT:-22}; MACUSER=$(cat ~/.ssh/kolood_user 2>/dev/null || echo unknown)

  "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config
  if [ -f ~/.claude/CLAUDE.md ] && [ ! -L ~/.claude/CLAUDE.md ]; then "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.claude/CLAUDE.md; fi   # never a link to the computer's file
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
  for n in $(ls "$ACCTDIR" 2>/dev/null); do acct_share "$n"; done
  local_install
  web_install "$HOST" || echo "WARNING: phone web terminal not set up (see above); retry: kolood web install"
  if [ $PAIRED = 1 ]; then echo "Paired and connected; refreshed. On your computer type: kolood"; return 0; fi
  if [ $KEEP = 1 ]; then echo "Refreshed. Your computer is not connected right now (asleep/offline?)."; return 0; fi

  echo "server address for the token: $HOST:$SPORT"
  HK=""; for t in ed25519 ecdsa rsa; do [ -r /etc/ssh/ssh_host_${t}_key.pub ] && { HK=$(awk '{print $1" "$2}' /etc/ssh/ssh_host_${t}_key.pub); break; }; done
  TOKEN="kolood1.$(printf '%s\n' "$HOST" "$SPORT" "$(id -un)" "$HK" "$(cut -d' ' -f1,2 ~/.ssh/kolood_to_remote.pub)" "$(grep -v -- ----- ~/.ssh/kolood_tunnel | tr -d '\n')" | base64 | tr -d '\n')"
  printf '\n=== PAIRING TOKEN (secret; paste on your computer) ===\n%s\n\nOn your computer run the same one-liner and choose "Pair", or: bash install.sh pair\n\nWaiting for your computer (Ctrl-C to stop; re-run any time)...\n' "$TOKEN"
  for _ in $(seq 120); do
    ssh -n -o BatchMode=yes -o ConnectTimeout=3 remote 'echo "connected to $(hostname) as $(whoami)"' 2>/dev/null && { echo "Done. On your computer, type:  kolood start   (first run asks you to /login on the server)"; return; }
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
  mkdir -p "$dst"; d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(enc "$(cd "$dst" && pwd -P)")"; mkdir -p "$d"
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
  mkdir -p ~/.claude
  python3 - "${1:-on}" "$HOME/.claude" "$HOME"/.config/kolood/accounts/* <<'PY'
import json, os, sys
r = "Bash(ssh remote:*)"; p = "settings.json"; m = sys.argv[1]
base = os.path.expanduser("~/.claude")
dirs = [d for d in sys.argv[2:] if os.path.isdir(d)] or [base]
s = json.load(open(os.path.join(base, p))) if os.path.exists(os.path.join(base, p)) else {}
a = s.get("permissions", {}).get("allow", [])
if m == "toggle": m = "off" if r in a else "on"
if m == "status": print("on" if r in a else "off"); sys.exit()
if m not in ("on", "off"): sys.exit("usage: allow on|off|toggle|status")
for d in dirs:
    fp = os.path.join(d, p)
    s = json.load(open(fp)) if os.path.exists(fp) else {}
    a = s.setdefault("permissions", {}).setdefault("allow", [])
    if m == "on" and r not in a: a.append(r)
    if m == "off" and r in a: a.remove(r)
    json.dump(s, open(fp, "w"), indent=2)
print("Claude may run 'ssh remote ...' without asking: " + m + " (all accounts)")
PY
}

acct_dir() { case "$1" in default) echo "$HOME/.claude";; *) echo "$ACCTDIR/$1";; esac; }
acct_names() { echo default; ls "$ACCTDIR" 2>/dev/null || true; }
acct_sel() { local s; s=$(cat ~/.config/kolood/account 2>/dev/null || true); echo "${s:-default}"; }
acct_email() {  # the email Claude saved at /login (default: ~/.claude.json; others: inside their dir)
  local f; if [ "$1" = default ]; then f=$HOME/.claude.json; else f=$(acct_dir "$1")/.claude.json; fi
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("oauthAccount",{}).get("emailAddress",""))
except Exception: pass' "$f" 2>/dev/null || true
}
acct_state() {
  local e; e="$(acct_dir "$1")/.kolood_env"
  if grep -q ANTHROPIC_API_KEY "$e" 2>/dev/null; then echo "API key"; elif [ -f "$e" ]; then echo "token (no browser)"
  elif [ -f "$(acct_dir "$1")/.credentials.json" ]; then echo "logged in (browser)"; else echo "not logged in"; fi
}
acct_usedby() {
  if [ "$1" = "$(acct_sel)" ]; then
    if [ "$1" = default ]; then echo "kolood"; else echo "kolood  (default now; also: kolood --account $1)"; fi
  else echo "kolood --account $1"; fi
}
# every account uses the same session store, so any account can continue any conversation
acct_share() {
  local d; [ "$1" = default ] && return 0
  d="$(acct_dir "$1")/projects"; mkdir -p ~/.claude/projects
  [ -L "$d" ] && return 0
  if [ -d "$d" ]; then if cp -an "$d"/. ~/.claude/projects/; then rm -rf "$d"; else mv "$d" "$d.old.$(date +%s)"; fi; fi
  ln -s ~/.claude/projects "$d"
}
# (server) multiple Claude accounts: "default" is plain ~/.claude; every other NAME is
# $ACCTDIR/NAME used via CLAUDE_CONFIG_DIR; the selected name lives in ~/.config/kolood/account
account() {
  case "${1:-}" in
    list)   # one block per account; * = what plain `kolood` uses
      for n in $(acct_names); do
        m=" "; [ "$n" = "$(acct_sel)" ] && m="*"
        e=$(acct_email "$n")
        echo "$m $n"; echo "    email:   ${e:-unknown}"; echo "    login:   $(acct_state "$n")"; echo "    used by: $(acct_usedby "$n")"
      done;;
    add)
      shift; n=${1:-}
      if [ -z "$n" ]; then n=kolood; i=2; while [ -d "$(acct_dir "$n")" ]; do n=kolood$i; i=$((i+1)); done; fi
      [ "$n" = default ] && die "'default' is the normal ~/.claude; pick another name"
      [[ "$n" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "bad account name: $n (lowercase letters, digits, - or _; max 32)"
      [ -d "$(acct_dir "$n")" ] && die "account $n already exists"
      mkdir -p "$(acct_dir "$n")"; chmod 700 "$(acct_dir "$n")"; acct_share "$n"
      echo "created account $n (used by: kolood --account $n)"
      if [ -t 0 ]; then
        m=""; ask "Log in with [b]rowser (/login) or a [t]oken from 'claude setup-token' / API key? [b/t]: " m || true
        case "$m" in [Tt]*) run account token "$n";; *) run account login "$n";; esac
      else echo "created $n; log in with: kolood account token $n   (paste a token from: claude setup-token)"; fi;;
    token|apikey)   # VALUE: argument, else read hidden from the terminal, else one line from stdin; "off" removes it
      k=$1; n=${2:-}; t=${3:-}
      [ -n "$n" ] || die "usage: install.sh account token|apikey NAME [VALUE|off]   (VALUE is read from stdin if omitted)"
      [ "$n" = default ] && mkdir -p ~/.claude
      [ -d "$(acct_dir "$n")" ] || die "no account $n (see: kolood account list)"
      if [ -z "$t" ]; then
        if [ -t 0 ]; then
          if [ "$k" = token ]; then echo "Get a token with:  claude setup-token   (on any computer with a browser)"; fi
          read -r -s -p "Paste it (hidden): " t; echo
        else IFS= read -r t || true; fi
      fi
      t=$(printf %s "$t" | tr -d ' \r\n')
      if [ "$t" = off ]; then rm -f "$(acct_dir "$n")/.kolood_env"; echo "removed the saved token/key of $n"; return 0; fi
      [[ "$t" =~ ^sk-ant-[A-Za-z0-9_-]{20,}$ ]] || die "that is not a Claude token or API key (they start with sk-ant-)"
      v=CLAUDE_CODE_OAUTH_TOKEN; if [ "$k" = apikey ]; then v=ANTHROPIC_API_KEY; fi
      (umask 077; printf "%s='%s'\n" "$v" "$t" > "$(acct_dir "$n")/.kolood_env")
      echo "saved: account $n logs in with this $k from now on (no browser)";;
    login)
      shift; n=${1:-}; [ -n "$n" ] || die "usage: install.sh account login NAME"
      [ -d "$(acct_dir "$n")" ] || die "no account $n (see: kolood account list)"
      mkdir -p "$HOME/workspace"; cd "$HOME/workspace"; export PATH="$HOME/.local/bin:$PATH"
      echo "Log in with /login, then /exit."
      if [ "$n" = default ]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR=$(acct_dir "$n"); fi
      claude;;
    use)
      shift; n=${1:-}; [ -n "$n" ] || die "usage: install.sh account use NAME"
      [ "$n" = default ] || [ -d "$(acct_dir "$n")" ] || die "no account $n (see: kolood account list)"
      if [ "$n" = default ]; then rm -f ~/.config/kolood/account
      else mkdir -p ~/.config/kolood; echo "$n" > ~/.config/kolood/account; fi
      echo "selected: $n";;
    remove)
      shift; n=${1:-}; [ "$n" = default ] && die "'default' cannot be removed"
      [ -n "$n" ] || die "usage: install.sh account remove NAME"
      [ -d "$(acct_dir "$n")" ] || die "no account $n (see: kolood account list)"
      if [ "$(cat ~/.config/kolood/account 2>/dev/null || true)" = "$n" ]; then rm -f ~/.config/kolood/account; fi
      # its settings view (local mode) goes first: unmount it, and the empty folder it made on the computer
      awk -v s="$(acct_dir "$n")" '$1 == s && $3 ~ /^fuse/ {print $2}' /proc/mounts 2>/dev/null | while read -r p; do fusermount -uz "$p" 2>/dev/null || fusermount3 -uz "$p" 2>/dev/null; rmdir "$p" 2>/dev/null; done
      fusermount -uz ~/.local/share/kolood/devcfg/"$n" 2>/dev/null || fusermount3 -uz ~/.local/share/kolood/devcfg/"$n" 2>/dev/null || true
      rm -f "$(acct_dir "$n")/projects"; rm -rf "$(acct_dir "$n")"   # projects is a link to the shared store: keep the sessions
      echo "removed account $n";;
    ""|menu)   # list of accounts (+ add); picking one opens its own options
      while :; do
        echo; echo "== Claude accounts on this server =="
        L=($(acct_names)); i=0
        for n in "${L[@]}"; do
          i=$((i+1)); e=$(acct_email "$n"); m=""; [ "$n" = "$(acct_sel)" ] && m="   <- default"
          echo " $i) $n$m"; echo "      ${e:-email unknown} · $(acct_state "$n")"; echo "      used by: $(acct_usedby "$n")"
        done
        echo " $((i+1))) + Add a new account"; echo " 0) Back"
        c=""; ask "Choose: " c || return 0
        if [ "$c" = 0 ]; then return 0
        elif [ "$c" = "$((i+1))" ]; then n=""; ask "Name for it (Enter = kolood, kolood2, ...): " n || true; run account add "$n"
        elif [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$i" ]; then account one "${L[$((c-1))]}"
        else echo "Pick one of the numbers above."; fi
      done;;
    one)   # the options of one account
      n=${2:-}; [ -d "$(acct_dir "$n")" ] || [ "$n" = default ] || die "no account $n"
      while [ -d "$(acct_dir "$n")" ] || [ "$n" = default ]; do
        e=$(acct_email "$n")
        echo; echo "== Account: $n =="
        echo "  email:   ${e:-unknown}"; echo "  login:   $(acct_state "$n")"; echo "  used by: $(acct_usedby "$n")"
        echo "  sessions: shared with every account (any account can continue them)"
        echo " 1) Make it the default (plain 'kolood' and the phone use it)"
        echo " 2) Log in with the browser (/login)"
        echo " 3) Log in with a token (from: claude setup-token; no browser)"
        echo " 4) Use an API key"
        echo " 5) Forget the saved token / API key"
        [ "$n" = default ] || echo " 6) Remove this account"
        echo " 0) Back"
        c=""; ask "Choose: " c || return 0
        case "$c" in
          1) run account use "$n";;
          2) run account login "$n";;
          3) run account token "$n";;
          4) run account apikey "$n";;
          5) run account token "$n" off;;
          6) if [ "$n" != default ] && yes_no "Remove account $n (its login; sessions stay)? [y/N] "; then run account remove "$n"; return 0; fi;;
          0) return 0;;
          *) echo "Pick one of the numbers above.";;
        esac
      done;;
    *) die "usage: install.sh account list|add [NAME]|login NAME|token NAME [TOKEN|off]|apikey NAME [KEY|off]|use NAME|remove NAME";;
  esac
}

# ---------------------------------------------------------------- local mode (server): stand-ins + sshfs
# apt installs: NEEDRESTART_SUSPEND / noninteractive / no stdin, so Ubuntu's restart prompts can't wait unseen
local_install() {
  local S=$HOME/.local/share/kolood/shims D='"$HOME/.local/share/kolood/web/kolood_device.py"'
  mkdir -p "$S"
  printf '#!/bin/sh\nexec python3 %s shell "$@"\n' "$D" > "$S/kolood-shell"
  printf '#!/bin/sh\nexec python3 %s open "$@"\n' "$D" > "$S/kolood-open"
  printf '#!/bin/sh\n[ "${KOLOOD_DEVICE_RG:-}" = 1 ] || KOLOOD_DEVICE_ROOT=\nexport KOLOOD_DEVICE_ROOT\nexec python3 %s rg "$@"\n' "$D" > "$S/rg"
  printf '#!/bin/sh\n[ "${KOLOOD_DEVICE_GIT:-}" = 1 ] || KOLOOD_DEVICE_ROOT=\nexport KOLOOD_DEVICE_ROOT\nexec python3 %s git "$@"\n' "$D" > "$S/git"
  printf '#!/bin/sh\nexec python3 %s xclip "$@"\n' "$D" > "$S/xclip"
  printf '#!/bin/sh\nexec python3 %s wl-paste "$@"\n' "$D" > "$S/wl-paste"
  chmod 755 "$S"/*
  if ! command -v sshfs >/dev/null || ! command -v bindfs >/dev/null; then
    if sudo_ok && command -v apt-get >/dev/null; then echo "Installing sshfs + bindfs (lets Claude work in your folders directly)..."; $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y sshfs bindfs </dev/null >/dev/null 2>&1 || true; fi
    command -v sshfs >/dev/null || echo "NOTE: sshfs is not installed: kolood works in ~/workspace on the server instead of in your folders (install: apt install sshfs)"
    command -v bindfs >/dev/null || echo "NOTE: bindfs is not installed: Claude's own settings show at a server path, and your computer's skills/CLAUDE.md aren't used (install: apt install bindfs)"
  fi
  # lets the settings view (bindfs) sit inside your mounted home; the home mount itself stays private (umask=077)
  if [ -f /etc/fuse.conf ] && ! grep -qs '^user_allow_other' /etc/fuse.conf && sudo_ok; then echo user_allow_other | $SUDO tee -a /etc/fuse.conf >/dev/null || true; fi
  [ -e /dev/fuse ] || echo "NOTE: /dev/fuse is missing on this server: kolood can't show your folders here (works in ~/workspace instead)"
}
unmount_local() {  # the user's home mounted for local mode
  # newest first: the config views sit on top of the home mount
  tac /proc/mounts 2>/dev/null | awk '($1 ~ /^remote:/ && $3 == "fuse.sshfs") || ($3 ~ /^fuse/ && $1 ~ /(\/\.claude|\/\.config\/kolood\/accounts\/[^\/]+)$/)' | awk '{print $2}' | while read -r p; do fusermount -u "$p" 2>/dev/null || fusermount3 -u "$p" 2>/dev/null || true; done
}
# Chrome on the user's computer for Claude (DevTools through the tunnel's port 9222), for every account
chrome() {
  case "${1:-status}" in on|off|status) ;; *) die "usage: kolood chrome on|off|status";; esac
  if [ "$1" = on ] && ! command -v npx >/dev/null; then die "needs Node.js on the server first: apt install nodejs npm"; fi
  local G=("$HOME/.claude.json"); [ -f "$HOME/.claude/.claude.json" ] && G+=("$HOME/.claude/.claude.json")   # the copy local mode uses
  python3 - "$1" "${G[@]}" "$ACCTDIR"/*/.claude.json <<'PY2'
import json, os, sys
mode, files = sys.argv[1], [f for f in sys.argv[2:] if "*" not in f]
entry = {"command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", "--browserUrl", "http://127.0.0.1:9222"]}
on = False
for f in files:
    c = json.load(open(f)) if os.path.exists(f) else {}
    s = c.setdefault("mcpServers", {})
    if mode == "status":
        on = on or "kolood-chrome" in s; continue
    if mode == "on": s["kolood-chrome"] = entry
    else: s.pop("kolood-chrome", None)
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.write(fd, json.dumps(c, indent=2).encode()); os.close(fd)
print("chrome: " + (("on" if on else "off") if mode == "status" else mode))
PY2
  if [ "$1" = on ]; then echo "On your computer, start Chrome with:  --remote-debugging-port=9222 --user-data-dir=<a separate profile folder>   (new sessions can then use it)"; fi
}

# ---------------------------------------------------------------- phone web terminal (server)
fetch() { curl -fsSL --retry 2 -m 120 "$1" -o "$2.tmp" && mv "$2.tmp" "$2"; }
webcfg() {  # webcfg key=value ... (empty value deletes the key) on ~/.config/kolood/web.json
  python3 - "$@" <<'PY2'
import json, os, sys
p = os.path.expanduser("~/.config/kolood/web.json")
c = json.load(open(p)) if os.path.exists(p) else {}
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1)
    if v == "": c.pop(k, None)
    else: c[k] = int(v) if v.isdigit() else v
os.makedirs(os.path.dirname(p), exist_ok=True)
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.write(fd, json.dumps(c, indent=2).encode()); os.close(fd)
PY2
}
webget() { python3 -c 'import json,os,sys;p=os.path.expanduser("~/.config/kolood/web.json");c=json.load(open(p)) if os.path.exists(p) else {};print(c.get(sys.argv[1],""))' "$1"; }
web_url() { local d; d=$(webget domain); if [ -n "$d" ]; then echo "https://$d"; else echo "https://$(webget host):$(webget tls_port)"; fi; }
web_running() { python3 "$WPY" status >/dev/null 2>&1; }
sudo_ok() { [ "$(id -u)" = 0 ] && SUDO="" && return 0; command -v sudo >/dev/null && sudo -n true 2>/dev/null && SUDO=sudo && return 0; return 1; }

web_service() {  # (re)start the daemon; keeps it running when sessions are open unless forced
  # the daemon writes the hash of its code to web.ver: same code = nothing to restart
  if web_running && [ "${1:-}" != force ]; then
    if [ "$(cat ~/.config/kolood/web.ver 2>/dev/null)" = "$(sha256sum "$WPY" | cut -d' ' -f1)" ]; then return 0; fi
    if [ -n "$(python3 "$WPY" list 2>/dev/null)" ]; then
      echo "web: new version installed; open sessions keep running on the old one until: kolood web restart (they are restored after it)"; return 0; fi
  fi
  if systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p ~/.config/systemd/user
    printf '[Unit]\nDescription=kolood web terminal + session holder\nStartLimitIntervalSec=0\n[Service]\nExecStart=%s %s serve\nRestart=always\nRestartSec=3\nKillMode=mixed\nTimeoutStopSec=15\n[Install]\nWantedBy=default.target\n' "$(command -v python3)" "$WPY" > ~/.config/systemd/user/$WUNIT
    systemctl --user daemon-reload; systemctl --user enable "$WUNIT" >/dev/null 2>&1; systemctl --user restart "$WUNIT"
    loginctl enable-linger "$(id -un)" 2>/dev/null || true
  else
    pkill -u "$(id -u)" -f "kolood_web.py serve" 2>/dev/null || true; sleep 1
    (nohup python3 "$WPY" serve >>/tmp/kolood-web.log 2>&1 &)
    if command -v crontab >/dev/null && ! crontab -l 2>/dev/null | grep -qF "$MARK"; then
      (crontab -l 2>/dev/null; echo "@reboot python3 $WPY serve >>/tmp/kolood-web.log 2>&1 $MARK") | crontab -; fi
  fi
  for _ in $(seq 10); do web_running && return 0; sleep 1; done
  echo "web: the daemon did not start; log: $(if systemctl --user show-environment >/dev/null 2>&1; then echo "journalctl --user -u $WUNIT"; else echo /tmp/kolood-web.log; fi)"; return 1
}

web_install() {  # files, password, self-signed HTTPS for access by IP, service
  local host=${1:-$(webget host)} src f
  command -v python3 >/dev/null || { echo "web: python3 is missing (apt install python3)"; return 1; }
  mkdir -p "$WEB/static" ~/.config/kolood; chmod 700 ~/.config/kolood
  src=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/web
  for f in kolood_web.py index.html kolood_device.py; do
    if [ -f "$src/$f" ] && ! [ "$src/$f" -ef "$WEB/$f" ]; then cp "$src/$f" "$WEB/$f"
    else fetch "${URL%/install.sh}/web/$f" "$WEB/$f" || [ -f "$WEB/$f" ] || { echo "web: could not download $f"; return 1; }; fi
  done
  # xterm.js (pinned), downloaded once
  [ -f "$WEB/static/xterm.js" ] || fetch https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js "$WEB/static/xterm.js" || { echo "web: could not download xterm.js"; return 1; }
  [ -f "$WEB/static/xterm.css" ] || fetch https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css "$WEB/static/xterm.css" || return 1
  [ -f "$WEB/static/addon-fit.js" ] || fetch https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js "$WEB/static/addon-fit.js" || return 1
  [ -n "$host" ] && webcfg host="$host"; [ -n "$(webget tls_port)" ] || webcfg tls_port=$WPORT
  # HTTPS by IP: a self-signed certificate (the phone asks once to trust it); a domain gets a real one (kolood web domain)
  if [ ! -f ~/.config/kolood/web.crt ] && command -v openssl >/dev/null; then
    case "$host" in *[!0-9.]*) san="DNS:$host";; *) san="IP:$host";; esac
    (umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=kolood" -addext "subjectAltName=$san" \
      -keyout ~/.config/kolood/web.key -out ~/.config/kolood/web.crt >/dev/null 2>&1) || echo "web: openssl failed; HTTPS by IP disabled"
  fi
  if [ -f ~/.config/kolood/web.crt ]; then webcfg cert="$HOME/.config/kolood/web.crt" key="$HOME/.config/kolood/web.key"; fi
  NEWPW=""; [ -n "$(webget pw_hash)" ] || NEWPW=$(python3 "$WPY" passwd | tail -1)
  web_service || return 1
  if sudo_ok && command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then $SUDO ufw allow "$(webget tls_port)/tcp" >/dev/null || true; fi
  echo "Phone: open $(web_url)"
  [ -z "$(webget domain)" ] && echo "       (self-signed certificate: accept the warning once; for a real one: kolood web domain NAME)"
  [ -n "$NEWPW" ] && echo "       password: $NEWPW   (change: kolood web password)"
  return 0
}

web_domain() {  # put the page on a domain with automatic HTTPS (Caddy; needs root or passwordless sudo)
  local d=${1:-} ip got cf=/etc/caddy/Caddyfile
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || die "usage: kolood web domain NAME (e.g. term.example.com) | kolood web domain off"
  sudo_ok || die "setting up a domain needs root or passwordless sudo on the server"
  ip=$(webget host); got=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}')
  if [ "$got" != "$ip" ]; then
    echo "DNS: $d points to '${got:-nothing}', this server is $ip. Create an A record $d -> $ip first."
    if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then yes_no "Continue anyway? [y/N] " || return 1; else return 1; fi
  fi
  if ss -ltnp 2>/dev/null | grep -E ':(80|443)\b' | grep -vq caddy; then
    die "port 80/443 is used by another web server; point it at 127.0.0.1:7700 yourself (reverse proxy with WebSocket)"; fi
  command -v caddy >/dev/null || { echo "Installing Caddy..."; $SUDO apt-get update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y caddy </dev/null >/dev/null; } || die "could not install caddy (apt). Install it, then retry"
  # the stock Caddyfile only serves a placeholder page: replace it; otherwise add our block
  if [ ! -f "$cf" ] || grep -q /usr/share/caddy "$cf"; then echo "" | $SUDO tee "$cf" >/dev/null; fi
  $SUDO sed -i "/$MARK\$/,/$MARK-end/d" "$cf"
  printf '%s\n%s {\n  reverse_proxy 127.0.0.1:%s\n}\n%s-end\n' "$MARK" "$d" "$(webget port | grep . || echo 7700)" "$MARK" | $SUDO tee -a "$cf" >/dev/null
  $SUDO systemctl enable caddy >/dev/null 2>&1 || true; $SUDO systemctl reload caddy 2>/dev/null || $SUDO systemctl restart caddy || die "caddy did not start: journalctl -u caddy"
  if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then $SUDO ufw allow 80/tcp >/dev/null; $SUDO ufw allow 443/tcp >/dev/null; fi
  webcfg domain="$d"
  echo "Getting a certificate for $d..."
  for _ in $(seq 30); do curl -fsS -m 5 -o /dev/null "https://$d/" 2>/dev/null && { echo "Phone: open https://$d"; return 0; }; sleep 2; done
  echo "Caddy is set up but https://$d does not answer yet (DNS/firewall?). Check: journalctl -u caddy"
}
web_domain_off() {
  local cf=/etc/caddy/Caddyfile
  if [ -f "$cf" ] && grep -qF "$MARK" "$cf" && sudo_ok; then $SUDO sed -i "/$MARK\$/,/$MARK-end/d" "$cf"; $SUDO systemctl reload caddy 2>/dev/null || true; fi
  webcfg domain=; echo "domain removed; phone: $(web_url)"
}

web_status() {
  if web_running; then echo "web terminal: running   $(web_url)"; else echo "web terminal: NOT running (kolood web restart)"; fi
  local n; n=$(python3 "$WPY" list 2>/dev/null | wc -l | tr -d ' '); echo "open sessions: ${n:-0}"
  python3 "$WPY" list 2>/dev/null | sed 's/^/  /' || true
}

web() {
  [ -f "$WPY" ] || { [ "${1:-}" = install ] || die "web terminal not installed: kolood web install"; }
  case "${1:-}" in
    status|url) web_status;;
    password) if [ -n "${2:-}" ]; then python3 "$WPY" passwd "$2"; echo "password set"; else echo "new password: $(python3 "$WPY" passwd | tail -1)"; fi
      echo "(all phones are logged out)";;
    domain) if [ "${2:-}" = off ]; then web_domain_off; else web_domain "${2:-}"; fi;;
    restart) web_service force;;
    install) web_install;;
    ""|menu)
      while :; do
        echo; echo "== Phone web terminal =="; web_status
        echo " p) new password   d) set a domain (automatic HTTPS)   o) remove the domain   r) restart   0) back"
        c=""; ask "Choose: " c || return 0
        case "$c" in
          p) run web password;;
          d) n=""; ask "Domain (its DNS A record must point to this server): " n || true; run web domain "$n";;
          o) run web domain off;;
          r) if yes_no "Restart? Open sessions come back by themselves (a Claude reply in progress is cut off). [y/N] "; then run web restart; fi;;
          0) return 0;;
          *) echo "Pick one of the letters above.";;
        esac
      done;;
    *) die "usage: kolood web [status|password [PW]|domain NAME|domain off|restart|install]";;
  esac
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
    && ssh -t "${SRV[@]}" "${KOLOOD_URL:+KOLOOD_URL=$(printf %q "$KOLOOD_URL") }bash ~/.local/share/kolood/install.sh $*" </dev/tty   # a custom update source applies to the server too
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
      tried=1; { sudo apt-get update -qq && sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y openssh-server </dev/null && { sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start; }; } || true
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
# `kolood` alone = the interactive menu; one-liners (subcommands or flags) = direct, no questions
I="$HOME/.local/share/kolood/install.sh"
case "${1:-}" in
  ""|setup|--setup|menu) exec bash "$I" menu;;
  update) exec bash "$I" update;;
  -h|--help|help) cat <<'HELP'
kolood                        interactive menu (sessions, accounts, pairing, update, uninstall)
One-liners (no questions asked):
  kolood start [CLAUDE ARGS]  new Claude session on the server  (e.g. kolood start "fix the tests")
  kolood -c                   continue the last session of this folder (local ones are copied first)
  kolood --resume [ID]        resume: pick from a list, or that session ID (copied from here if local)
  kolood shell                a login shell on the server
  kolood chrome on|off        let Claude drive Chrome on this computer (needs Node.js on the server)
  kolood update               update kolood here and on the server (then: kolood web restart)
  kolood sessions             running sessions on the server (also visible on the phone page)
  kolood history [FOLDER]     recent conversations (id, age, folder, title); resume one: kolood --resume ID
  kolood attach [ID]          join a running session (pick from a list without ID)
  kolood web [status | password [PW] | domain NAME | domain off | restart]   the phone page
  kolood account list | add [NAME] | login NAME | use NAME | remove NAME
  kolood account token NAME   log NAME in with a token from `claude setup-token` (no browser; `apikey` for an API key)
Flags (combine with start / -c / --resume; any other flag also starts Claude directly):
  --account NAME              use that Claude account on the server
  --no-remote                 this session is not told about your computer
  --server                    work in ~/workspace on the server instead of in this folder
  -h, --help                  this help, then Claude's own options
HELP
    [ "$1" = help ] && exit 0
    echo "--- Claude Code options (pass them after 'kolood start'; they run on the server) ---";;
  start|claude) shift;;
  shell|--shell) shift; set -- --shell "$@";;
  account|web|sessions|history|attach|chrome) ;;
  -*) ;;
  *) echo "kolood: unknown command '$1'. See: kolood -h   (to start Claude with a prompt: kolood start \"$1\")" >&2; exit 2;;
esac
. "$HOME/.ssh/kolood_conf" 2>/dev/null || { echo "kolood is not paired yet: run  kolood  and choose Pair"; exit 1; }
O=(-i "$HOME/.ssh/kolood_login" -o IdentitiesOnly=yes -o UserKnownHostsFile="$HOME/.ssh/kolood_known_hosts" -o StrictHostKeyChecking="$STRICT" -o ServerAliveInterval=30 -p "$port" "$suser@$host")
WP="python3 ~/.local/share/kolood/web/kolood_web.py"
if [ "${1:-}" = account ] && { [ "${2:-}" = token ] || [ "${2:-}" = apikey ]; } && [ -n "${3:-}" ]; then
  t=${4:-}   # the token travels over stdin, never on a command line
  if [ -z "$t" ]; then
    if [ "$2" = token ]; then echo "Get a token with:  claude setup-token   (on any computer with a browser)"; fi
    read -r -s -p "Paste it (hidden): " t </dev/tty; echo
  fi
  printf '%s\n' "$t" | ssh "${O[@]}" "bash ~/.local/share/kolood/install.sh account $2 $(printf %q "$3")"; exit $?
fi
O=(-t "${O[@]}")
case "${1:-}" in
  account|web|chrome) exec ssh "${O[@]}" "bash ~/.local/share/kolood/install.sh$(printf ' %q' "$@")";;
  sessions) exec ssh "${O[@]}" "$WP list";;
  history) shift; ssh "${O[@]}" "$WP history$(printf ' %q' "$@")" | awk -F'\t' '{printf "%s  %4s  %s  %s\n", $1, $2, $3, $4}'; exit "${PIPESTATUS[0]}";;
  attach) id=${2:-}
    if [ -z "$id" ]; then   # pick one
      L=$(ssh "${O[@]}" "$WP list" 2>/dev/null | tr -d '\r'); [ -n "$L" ] || { echo "No running sessions on the server."; exit 1; }
      echo "$L" | awk -F'\t' '{printf "%2d) %s  [%s, %s attached, %s]\n", NR, $2, $3, $4, $5}'
      read -r -p "Join which? " n </dev/tty; id=$(echo "$L" | sed -n "${n}p" | cut -f1); [ -n "$id" ] || exit 1
    fi
    if command -v caffeinate >/dev/null; then exec caffeinate -i ssh "${O[@]}" "$WP attach --id $(printf %q "$id")"; fi
    exec ssh "${O[@]}" "$WP attach --id $(printf %q "$id")";;
esac
B=$(printf %s "$PWD" | base64 | tr -d '\n')
W=(); if command -v caffeinate >/dev/null; then W=(caffeinate -i)
elif command -v systemd-inhibit >/dev/null && systemd-inhibit --what=sleep --why=kolood true 2>/dev/null; then W=(systemd-inhibit --what=sleep --why=kolood); fi
exec "${W[@]}" ssh "${O[@]}" "~/.ssh/kolood_start $B$(printf ' %q' "$@")"
EOF
  chmod +x ~/.local/bin/kolood
  add_path && NEWPATH=1
  tunnel_start
  echo "Connecting..."
  for _ in $(seq 12); do
    sleep 3
    if bridge_up; then
      echo "Ready. In a new terminal (or after: source $RC) type:  kolood   (menu)   or   kolood start   (Claude right away)"
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
  for f in ~/.ssh/config ~/.claude/CLAUDE.md; do if [ -f "$f" ] && [ ! -L "$f" ]; then "${GNUSED[@]}" "/$o/,/$o-end/d" "$f"; fi; done
  if [ -f ~/.local/bin/imlegit ] && grep -qF "$o" ~/.local/bin/imlegit; then rm -f ~/.local/bin/imlegit; fi
  rm -f ~/.ssh/cmb_*; rm -rf ~/.local/share/imlegit
}

remove() {
  legacy_cleanup
  tunnel_stop
  systemctl --user disable --now "$WUNIT" >/dev/null 2>&1 || true; rm -f ~/.config/systemd/user/$WUNIT
  pkill -u "$(id -u)" -f "kolood_web.py serve" 2>/dev/null || true
  if command -v crontab >/dev/null && crontab -l 2>/dev/null | grep -qF "$MARK"; then crontab -l | grep -vF "$MARK" | crontab - || true; fi
  if [ -f /etc/caddy/Caddyfile ] && grep -qF "$MARK" /etc/caddy/Caddyfile && sudo_ok; then $SUDO sed -i "/$MARK\$/,/$MARK-end/d" /etc/caddy/Caddyfile; $SUDO systemctl reload caddy 2>/dev/null || true; fi
  rm -f "$PLIST" ~/.config/systemd/user/$UNIT; systemctl --user daemon-reload >/dev/null 2>&1 || true
  for f in ~/.zshrc ~/.bash_profile ~/.bashrc ~/.profile; do if [ -f "$f" ]; then "${GNUSED[@]}" "/$MARK/d" "$f"; fi; done
  if [ -f ~/.local/bin/kolood ] && grep -qF "$MARK" ~/.local/bin/kolood; then rm -f ~/.local/bin/kolood; fi
  if [ -f ~/.claude/settings.json ] && command -v python3 >/dev/null; then allow off >/dev/null 2>&1 || true; fi
  unmount_local
  ssh -O exit remote 2>/dev/null || true
  fusermount -u ~/remote 2>/dev/null || true; rmdir ~/remote ~/workspace 2>/dev/null || true
  if [ -f ~/.ssh/authorized_keys ]; then "${GNUSED[@]}" -e "/$MARK/d" -e "/# kolood-login/d" ~/.ssh/authorized_keys; fi
  if [ -f ~/.ssh/config ]; then "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.ssh/config; fi
  if [ -f ~/.claude/CLAUDE.md ] && [ ! -L ~/.claude/CLAUDE.md ]; then "${GNUSED[@]}" "/$MARK/,/$MARK-end/d" ~/.claude/CLAUDE.md; fi
  pkill -u "$(id -u)" -f "sleep 2147483647" 2>/dev/null || true
  rm -f ~/.ssh/kolood_*
  # never delete through a mount that is still there (it would reach into the computer's files)
  for x in ~/.config/kolood "${I%/*}"; do if awk -v p="$x/" 'index($2, p) == 1 {f=1} END {exit !f}' /proc/mounts 2>/dev/null; then echo "kept $x: something is still mounted inside it"; else rm -rf "$x"; fi; done
  echo "removed"
}

# ---------------------------------------------------------------- menus
client_menu() {
  while :; do
    echo; echo "== kolood: this computer ($(plat)) =="
    if load_conf; then
      if bridge_up; then echo "Server $suser@$host:$port   bridge: UP"; else echo "Server $suser@$host:$port   bridge: DOWN (try 9)"; fi
    elif [ -f ~/.ssh/cmb_run.sh ]; then echo "Old imlegit install found: pair again (on the server: 'Pair a NEW computer')."
    else echo "Not paired yet: run the server step first, then choose 8."; fi
    echo " 1) New Claude session                (kolood start)"
    echo " 2) Continue the last session here    (kolood -c)"
    echo " 3) Pick a session to resume          (kolood --resume)"
    echo " 4) Join a running session            (kolood attach)"
    echo " 5) Shell on the server               (kolood shell)"
    echo " 6) Accounts on the server            (kolood account)"
    echo " 7) Phone web terminal                (kolood web)"
    echo " 8) Pair with a server (paste a token)"
    echo " 9) Restart the bridge"
    echo "10) Update kolood (here and on the server)"
    echo "11) Toggle: Claude may run 'ssh remote' without asking"
    echo "12) Uninstall (here and on the server)"
    echo " 0) Quit"
    c=""; ask "Choose: " c || exit 0
    case "$c" in
      1|2|3|4|5|6|7) if [ -f "$CONF" ]; then   # run it, then come back to this menu
           case "$c" in 1) set -- start;; 2) set -- -c;; 3) set -- --resume;; 4) set -- attach;; 5) set -- shell;; 6) set -- account menu;; 7) set -- web menu;; esac
           "$HOME/.local/bin/kolood" "$@" </dev/tty || true
         else echo "Pair first (8)."; fi;;
      8) run client;;
      9) if [ -f "$CONF" ]; then run restart_bridge; else echo "Pair first (8)."; fi;;
      10) run update;;
      11) if load_conf; then run rrun allow toggle; else echo "Pair first (8)."; fi;;
      12) if yes_no "Remove kolood from this computer AND the server? [y/N] "; then
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
    if command -v claude >/dev/null 2>&1 || [ -x ~/.local/bin/claude ]; then echo -n "Claude: installed   "; else echo -n "Claude: NOT installed (3 offers it)   "; fi
    sel=$(cat ~/.config/kolood/account 2>/dev/null || true); sel=${sel:-default}; echo -n "account: $sel   "
    if [ -s ~/.ssh/kolood_user ]; then
      if ssh -n -o BatchMode=yes -o ConnectTimeout=4 remote true 2>/dev/null; then echo "Paired with $(cat ~/.ssh/kolood_user): connected"
      else echo "Paired with $(cat ~/.ssh/kolood_user): not reachable now (asleep/offline?)"; fi
    else echo "Not paired yet (choose 3)."; fi
    echo " 1) Accounts (Claude logins)"
    echo " 2) Phone web terminal (address, password, domain)"
    echo " 3) Pair a computer / refresh setup"
    echo " 4) Pair a NEW computer (revokes the old token and keys)"
    echo " 5) Toggle: Claude may run 'ssh remote' without asking   [now: $(allow status 2>/dev/null || echo ?)]"
    echo " 6) Update kolood"
    echo " 7) Uninstall"
    echo " 0) Quit"
    c=""; ask "Choose: " c || exit 0
    case "$c" in
      1) run account menu;;
      2) run web menu;;
      3) run server;;
      4) if yes_no "Forget the current computer and make a new token? [y/N] "; then forget; run server; fi;;
      5) run allow toggle;;
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
  menu|setup|--setup) menu;;
  server) server;;
  refresh) server refresh;;
  pair|client) client "${2:-}";;
  pull) shift; pull "$@";;
  history) [ $# -ge 3 ] || die "usage: install.sh history PATH_ON_YOUR_COMPUTER SERVERPATH"; pull dir "$2" "$3";;
  mount) mount_remote;;
  allow) allow "${2:-on}";;
  account) shift; account "$@";;
  web) shift; web "$@";;
  chrome) chrome "${2:-status}";;
  update) update;;
  remove|uninstall|--uninstall) remove;;
  *kolood1.*) client "$1";;
  "") if [ -t 1 ] && [ -r /dev/tty ]; then menu; elif [ "$OS" = Darwin ]; then client; else server; fi;;
  *) die "unknown command: $1 (see: bash install.sh help)";;
esac
