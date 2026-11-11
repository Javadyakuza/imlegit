# imlegit

Type `imlegit` in your terminal and get **Claude Code running on your server** (your subscription lives there), working on **your computer** (macOS, Linux, or Windows via WSL) through a private tunnel: its shell, files, Claude sessions and Chrome. Open as many sessions as you like. (The computer is called `mac` on the server, whatever its OS.)

## Install: same one-liner on both machines, one token

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Javadyakuza/imlegit/main/install.sh)
```
It opens an **interactive menu** (on Linux it first asks: server or your computer?).

1. **Server** (Linux): choose *Pair a computer*. It installs Claude Code if missing, prints a **pairing token** and waits.
2. **Your computer**: choose *Pair with a server* and paste the token. It prints `Ready`.
   - macOS: System Settings > General > Sharing > **Remote Login = ON**.
   - Linux / WSL: needs an SSH server; the script offers to install `openssh-server` with sudo.
   - Windows: install WSL (`wsl --install` in PowerShell), open Ubuntu, and run the one-liner there.

Later, open the menu again with `imlegit --setup` (your computer) or `imlegit` (server). No commands to remember.

## Use

| On your computer | What it does |
|---|---|
| `imlegit` | Claude Code on the server; it can work on your computer via `ssh mac` |
| `imlegit --resume [ID]` | Resume a session. Your computer's sessions for the **current folder** (or that **ID**) are copied to the server first, so a local session continues there |
| `imlegit --continue` / `-c` | Continue the latest session of the current folder (local ones included) |
| `imlegit --no-mac` | Server only; this session isn't told about your computer (no copying either) |
| `imlegit --shell` | A login shell on the server instead of Claude (`ssh mac` works there too) |
| `imlegit --setup` | Menu: start, shell, pair, restart bridge, update, toggle permissions, uninstall |
| anything else | Passed to `claude` (e.g. `imlegit --model opus`) |

- First run only: `/login` with your subscription (on the server).
- Claude is told the folder your terminal is in, and that paths in resumed local sessions live on your computer.
- macOS Desktop/Documents/Downloads need: System Settings > Sharing > Remote Login (i) > "Allow full disk access for remote users".
- Each `imlegit` is its own session, all sharing one tunnel. Your computer stays awake while a session is open (`caffeinate` on macOS, `systemd-inhibit` on Linux).
- If the terminal closes or the network drops, the session ends; continue with `imlegit -c`.
- Copied sessions keep the newer version: one you continued on the server isn't overwritten by an older local copy.

## Architecture

```
 Mac                                       Server
 ┌────────────────────┐   login (imlegit)  ┌───────────────────────────────┐
 │ `imlegit` ─────────┼───────────────────►│ ~/imlegit: claude              │
 │                    │                    │      │ ssh mac                 │
 │ sshd :22  ◄────────┼── reverse tunnel ──┤      ▼                         │
 │ Chrome :9222 ◄─────┼── (Mac dials out,  │ 127.0.0.1:2222 → Mac sshd      │
 │ launchd keeps up   │    auto-reconnect) │ 127.0.0.1:9222 → Mac Chrome    │
 └────────────────────┘                    └───────────────────────────────┘
```
- The **Mac dials out** (launchd-managed), so it works behind NAT with no open ports and reconnects after sleep.
- `ssh mac` from the server is multiplexed (`ControlMaster`): many sessions, one connection.

## The token and keys

- The token holds the server address and SSH host key (pinned: no man-in-the-middle on first connect) plus a **tunnel-only key**. In the server's `authorized_keys` that key is limited to `restrict,port-forwarding,permitlisten=127.0.0.1:2222/9222,command=~/.ssh/cmb_hello`: it can open those two forwards and run one tiny script. No shell.
- On first use the Mac sends its username and its own **login key** through that script. **First pairing wins**: the token can't register a second key or change the name afterwards, so it is single-use in effect. Treat it like a password until you've used it.
- The login key gives the Mac a normal shell on the server (that is what `imlegit` uses).
- The server's key is accepted on your Mac only from 127.0.0.1 (through the tunnel).
- Anyone with root on the server can reach your Mac through the tunnel. Use servers you trust.

## What the server can do on your Mac

Anything your Mac user can do over SSH: run commands, read/write/delete the files that user can, reach Chrome DevTools on :9222. Not root (unless you have passwordless sudo), no GUI or screen control. macOS may block protected folders (Desktop, Documents...) for SSH unless you grant Full Disk Access. Claude treats it like any remote host it logs into with `ssh mac '<cmd>'`: no native file tools, and every command is a fresh shell.

## Small servers

The server step refuses under 150MB free RAM or 50MB free disk, warns under 600MB (a Claude session needs a few hundred MB), and checks the tunnel ports are free. Footprint: one idle `ssh` and one `sleep` process plus edits to `~/.ssh/{config,authorized_keys,cmb_*}`, and a `~/imlegit` folder.

## Script commands (everything the menu does, for scripting)

```bash
bash install.sh                  # menu
bash install.sh server           # (server) pair: print a token and wait; refreshes if already paired
bash install.sh pair [TOKEN]     # (computer) pair with a server
bash install.sh update           # download the latest; on your computer also updates the server
bash install.sh allow on|off|toggle            # (server) Claude may run `ssh mac ...` without asking
bash install.sh pull id SESSION_ID             # (server) copy one session from your computer
bash install.sh pull dir /Users/me/proj [SRV]  # (server) copy a project's sessions (alias: history)
bash install.sh mount            # (server) your computer's home at ~/mac via sshfs
bash install.sh remove           # undo everything on this machine (the menu does both machines)
```
Env: `CMB_HOST` / `CMB_PORT` override the auto-detected server address; `CMB_MAC_CONFIG` = Claude's config dir under your computer's home (default `.claude`); `IMLEGIT_URL` = update source.

## Handled automatically

- Re-running the server step while connected keeps the connection and just refreshes Claude's instructions; when not connected it issues a fresh token, so re-pairing a wiped or different Mac just works.
- A token pasted with its banner, or wrapped over several lines, is cleaned up.
- Your own `Host mac` in the server's `~/.ssh/config` can't shadow ours (our block goes first); the Mac's host key lives in its own known-hosts file, so a different Mac never trips a host-key warning.
- Server address and SSH port come from your current SSH session (or the listening sshd); the host key pinned is ed25519, ecdsa or rsa, whichever exists.
- The server step stops with a clear message if sshd disables port forwarding, a tunnel port is busy, or required tools are missing; the Mac step explains the likely causes if pairing fails.
- Mac shell rc is `~/.zshrc` or `~/.bash_profile` depending on `$SHELL`; `remove` cleans both.

## Limits

- One computer per server (fixed loopback ports 2222/9222). *Pair a NEW computer* revokes the old one.
- Computer asleep or offline: `imlegit` still opens, but its commands fail until it's back.
- The server edits your files through `ssh mac`, not Claude's native file tools, unless you use `mount` (needs sshfs).
- Chrome control needs Chrome started with `--remote-debugging-port=9222`. Screen control is not bridged.
- Clients: macOS, Linux (systemd user service, or a background loop without systemd), Windows via WSL (the bridge runs while WSL runs; Windows files are under `/mnt/c`). Native Windows shells are not supported. Server: Linux with OpenSSH 7.8+.
- Installs made before the menu existed: pair once more (server menu > *Pair a NEW computer*).

## Terms

imlegit is a remote-development helper. It does not change or hide where you use Claude from. You are responsible for following Anthropic's terms of service, usage policy and supported-regions policy, and for using servers you trust. No warranty (see LICENSE).

MIT
