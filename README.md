# kolood

Type `kolood` in your terminal and get **Claude Code running on your server** (your subscription lives there), working on **your computer** (macOS, Linux, or Windows via WSL) through a private tunnel: its shell, files, Claude sessions and Chrome. Open as many sessions as you like. (On the server your computer is the SSH host `remote`; Claude is only told "you are on a server, the user works on a remote".)

## Install: same one-liner on both machines, one token

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Javadyakuza/kolood/main/install.sh)
```
It opens an **interactive menu** (on Linux it first asks: server or your computer?).

1. **Server** (Linux): choose *Pair a computer*. It installs Claude Code if missing, prints a **pairing token** and waits.
2. **Your computer**: choose *Pair with a server* and paste the token. It prints `Ready`.
   - macOS: System Settings > General > Sharing > **Remote Login = ON**.
   - Linux / WSL: needs an SSH server; the script offers to install `openssh-server` with sudo.
   - Windows: install WSL (`wsl --install` in PowerShell), open Ubuntu, and run the one-liner there.

Later, just type `kolood` (on your computer or on the server) to get the menu again.

## Use

Two ways, same features:

**Interactive:** type `kolood`. The menu lists: new Claude session, continue the last session here, pick a session to resume, join a running session, shell on the server, accounts, phone web terminal, pair, restart bridge, update, permissions, uninstall. When a session ends you're back in the menu.

**One-liners** (direct, no questions; for scripts, aliases, muscle memory):

| Command | What it does |
|---|---|
| `kolood start [CLAUDE ARGS]` | New Claude session on the server, e.g. `kolood start "fix the tests"` or `kolood start --model opus` |
| `kolood -c` | Continue the latest session of the current folder. Your computer's sessions for this folder are copied to the server first |
| `kolood --resume [ID]` | Resume: pick from the list, or that session ID (copied from your computer if it's a local one) |
| `kolood shell` | A login shell on the server (`ssh remote` works there too) |
| `kolood sessions` | Sessions running on the server (the same list the phone page shows) |
| `kolood attach [ID]` | Join a running session (started here, on the phone, or anywhere); without ID you pick from a list |
| `kolood web [status \| password [PW] \| domain NAME \| domain off \| restart]` | The phone page: its address, password, domain |
| `kolood account list \| add [NAME] \| login NAME \| use NAME \| remove NAME` | Manage Claude accounts on the server (`kolood account` alone = accounts menu) |
| `kolood account token NAME` | Log that account in with a token from `claude setup-token` (no browser); `apikey NAME` for an API key |
| `kolood -h` | kolood help, then Claude's own options |

Flags (add to `start`, `-c` or `--resume`):

| Flag | Effect |
|---|---|
| `--account NAME` | Use that Claude account on the server for this session |
| `--no-remote` | This session isn't told about your computer (and nothing is copied) |
| any Claude flag | Passed to `claude`; a command that starts with a flag starts Claude directly (`kolood --model opus`) |

A bare word that isn't a command is rejected (`kolood fix` → use `kolood start "fix"`), so a typo never sends a prompt by accident.

- First run only: `/login` with your subscription (on the server).
- Claude is told the folder your terminal is in, and that paths in resumed local sessions live on your computer.
- macOS Desktop/Documents/Downloads need: System Settings > Sharing > Remote Login (i) > "Allow full disk access for remote users".
- Each `kolood` is its own session, all sharing one tunnel. Your computer stays awake while a session is open (`caffeinate` on macOS, `systemd-inhibit` on Linux).
- Sessions live on the server: if the terminal closes or the network drops, the session keeps running. Rejoin with `kolood attach`, or open it on your phone.
- Copied sessions keep the newer version: one you continued on the server isn't overwritten by an older local copy.

## Accounts

Several Claude logins can live on the server, like `claude` and `claude2` on one machine: `default` (the normal `~/.claude`) plus one config dir per extra account (`~/.config/kolood/accounts/NAME`, used via `CLAUDE_CONFIG_DIR`).

- **Menu** (`kolood account`, or the menus: your computer 6, server 1): every account on its own lines with its email, how it's logged in, and the command that uses it, plus **+ Add a new account**. Pick an account for its options: make it the default, log in with the browser / a token / an API key, forget the token, remove it.
- **One-liners**: `kolood account list | add [NAME] | login NAME | token NAME | apikey NAME | use NAME | remove NAME`.
- **Using one**: plain `kolood` (and the phone) use the default account; `kolood --account NAME` (or `--acc NAME`) picks one for a session.
- **Shared sessions**: all accounts use one session store, so any account can continue any conversation (`kolood --acc work --resume ID` continues a session started with `default`). Removing an account keeps its sessions.

**Log in without a browser** (like an SSH key for Claude): run `claude setup-token` once on any computer with a browser; it prints a long-lived token. Then `kolood account token NAME` and paste it (hidden; it travels over stdin, never on a command line). Every session of that account starts already logged in. For a pay-per-token Console key: `kolood account apikey NAME`. `kolood account token NAME off` removes it. Stored only on the server, readable only by your user (`~/.config/kolood/accounts/NAME/.kolood_env`, or `~/.claude/.kolood_env` for `default`).

## Phone (web terminal)

Installed with the server step. Open the address it prints (`kolood web` shows it again) on your phone:
- **Sessions**: everything running on the server, including sessions you started with `kolood` on your computer. Tap one to join it live; ← (or the phone's back gesture) returns to the list and leaves it running; ✕ ends it.
- **New**: a Claude session, a shell on the server, or a shell on your computer.
- **Recent conversations**: your Claude history (all accounts); tap one to resume it.
- **Key bar**: Esc, Tab, sticky Ctrl/⇧ (tap = once, double-tap = lock; ⇧+Tab = Claude's mode switch, ⇧+⏎ = new line), ^C, arrows (hold to repeat), Copy (the screen as selectable text), Paste.
- Scrolling is the browser's own (no tmux): each session keeps its last 2 MB of output and replays it when you join.

Access:
- **By IP**: `https://SERVER_IP:7443` with a self-signed certificate (accept the warning once). The password is printed at install; `kolood web password` makes a new one (and logs every phone out).
- **With a domain**: point an A record at the server, then `kolood web domain term.example.com`. Caddy is installed and gets a real certificate automatically (needs root or passwordless sudo; ports 80/443 free). `kolood web domain off` undoes it.
- Logins last 30 days; 10 wrong passwords per 10 minutes block that address for a while.

## Architecture

```
 Computer                                  Server
 ┌────────────────────┐   login (kolood)   ┌──────────────────────────────────┐
 │ `kolood` ──────────┼───────────────────►│ ~/workspace: claude              │
 │                    │                    │      │ ssh remote                │
 │ sshd :22  ◄────────┼── reverse tunnel ──┤      ▼                           │
 │ Chrome :9222 ◄─────┼── (dials out,      │ 127.0.0.1:2222 → computer sshd   │
 │ launchd / systemd  │    auto-reconnect) │ 127.0.0.1:9222 → computer Chrome │
 └────────────────────┘                    └──────────────────────────────────┘
```
- Your **computer dials out** (launchd / systemd), so it works behind NAT with no open ports and reconnects after sleep.
- `ssh remote` from the server is multiplexed (`ControlMaster`): many sessions, one connection.

## The token and keys

- The token holds the server address and SSH host key (pinned: no man-in-the-middle on first connect) plus a **tunnel-only key**. In the server's `authorized_keys` that key is limited to `restrict,port-forwarding,permitlisten=127.0.0.1:2222/9222,command=~/.ssh/kolood_hello`: it can open those two forwards and run one tiny script. No shell.
- On first use your computer sends its username and its own **login key** through that script. **First pairing wins**: the token can't register a second key or change the name afterwards, so it is single-use in effect. Treat it like a password until you've used it.
- The login key gives your computer a normal shell on the server (that is what `kolood` uses).
- The server's key is accepted on your computer only from 127.0.0.1 (through the tunnel).
- Anyone with root on the server can reach your computer through the tunnel. Use servers you trust.

## What the server can do on your computer

Anything your user can do over SSH: run commands, read/write/delete the files that user can, reach Chrome DevTools on localhost:9222 (Claude is not told about it; say so when you need it). Not root (unless you have passwordless sudo), no GUI or screen control. macOS may block protected folders (Desktop, Documents...) for SSH unless you grant Full Disk Access. Claude treats it like any remote host it logs into with `ssh remote '<cmd>'`: no native file tools, and every command is a fresh shell.

## Small servers

The server step refuses under 150MB free RAM or 50MB free disk, warns under 600MB (a Claude session needs a few hundred MB), and checks the tunnel ports are free. Footprint: one idle `ssh` and one `sleep` process plus edits to `~/.ssh/{config,authorized_keys,kolood_*}`, and a `~/workspace` folder.

## Script commands (everything the menu does, for scripting)

```bash
bash install.sh                  # menu
bash install.sh server           # (server) pair: print a token and wait; refreshes if already paired
bash install.sh pair [TOKEN]     # (computer) pair with a server
bash install.sh update           # download the latest; on your computer also updates the server
bash install.sh allow on|off|toggle            # (server) Claude may run `ssh remote ...` without asking
bash install.sh account list|add [NAME]|login NAME|use NAME|remove NAME  # (server) Claude accounts
bash install.sh pull id SESSION_ID             # (server) copy one session from your computer
bash install.sh pull dir /Users/me/proj [SRV]  # (server) copy a project's sessions (alias: history)
bash install.sh mount            # (server) your computer's home at ~/remote via sshfs
bash install.sh remove           # undo everything on this machine (the menu does both machines)
```
Env: `KOLOOD_HOST` / `KOLOOD_PORT` override the auto-detected server address; `KOLOOD_REMOTE_CONFIG` = Claude's config dir under your computer's home (default `.claude`); `KOLOOD_URL` = update source.

## Handled automatically

- Re-running the server step while connected keeps the connection and just refreshes Claude's instructions; when not connected it issues a fresh token, so re-pairing a wiped or different computer just works.
- A token pasted with its banner, or wrapped over several lines, is cleaned up.
- Your own `Host remote` in the server's `~/.ssh/config` can't shadow ours (our block goes first); the computer's host key lives in its own known-hosts file, so a different computer never trips a host-key warning.
- Server address and SSH port come from your current SSH session (or the listening sshd); the host key pinned is ed25519, ecdsa or rsa, whichever exists.
- The server step stops with a clear message if sshd disables port forwarding, a tunnel port is busy, or required tools are missing; the pairing step explains the likely causes if pairing fails.
- Shell rc is `~/.zshrc`, `~/.bash_profile` (macOS) or `~/.bashrc` (Linux) depending on `$SHELL`; `remove` cleans all.

## Limits

- One computer per server (fixed loopback ports 2222/9222). *Pair a NEW computer* revokes the old one.
- Computer asleep or offline: `kolood` still opens, but its commands fail until it's back.
- The server edits your files through `ssh remote`, not Claude's native file tools, unless you use `mount` (needs sshfs).
- Chrome control needs Chrome started with `--remote-debugging-port=9222`. Screen control is not bridged.
- Clients: macOS, Linux (systemd user service, or a background loop without systemd), Windows via WSL (the bridge runs while WSL runs; Windows files are under `/mnt/c`). Native Windows shells are not supported. Server: Linux with OpenSSH 7.8+.
- Installs made before the menu existed: pair once more (server menu > *Pair a NEW computer*).
- Running sessions live in the web daemon: restarting it (`kolood web restart`, a server reboot) ends them. Updates keep it running while sessions are open. Your Claude conversations are saved by Claude as usual, so they can be resumed.
- The phone page needs Python 3 on the server (standard on Ubuntu/Debian) and downloads xterm.js once at install.

## Terms

kolood is a remote-development helper. It does not change or hide where you use Claude from. You are responsible for following Anthropic's terms of service, usage policy and supported-regions policy, and for using servers you trust. No warranty (see LICENSE).

MIT
