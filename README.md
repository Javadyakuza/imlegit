# imlegit

Type `imlegit` in your Mac terminal and get **Claude Code running on your server** (your subscription lives there), working on **your Mac** through a private tunnel: its shell, files and Chrome. Open as many sessions as you like.

## Install: two commands, one token

**1. On the server** (the script installs Claude Code there if missing):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Javadyakuza/imlegit/main/install.sh)
```
It prints a **pairing token** and waits. Nothing to type, nothing to configure.

**2. On your Mac** (System Settings > General > Sharing > **Remote Login = ON**):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Javadyakuza/imlegit/main/install.sh)
```
Paste the token. The Mac checks the whole loop itself and prints `Ready`; the server terminal prints `connected`.

## Use

```bash
imlegit                 # in any Mac terminal: opens Claude Code on the server
imlegit --resume        # arguments go to claude
imlegit --no-mac        # this session runs on the server only and is not told about your Mac
```
- First run only: `/login` with your subscription (on the server).
- Plain `imlegit`: Claude runs **on the server** and knows `ssh mac` is your Mac (files, Mac Claude history in `~/.claude`, Chrome on 9222). Nothing is written to `~/.claude/CLAUDE.md`; it is per session. `--no-mac` leaves the Mac out.
- Mac Desktop/Documents/Downloads need: System Settings > Sharing > Remote Login (i) > "Allow full disk access for remote users".
- Each `imlegit` is its own session, all sharing one tunnel. The Mac stays awake while a session is open (`caffeinate`).
- If the terminal closes or the network drops, the session ends; continue with `imlegit --resume`.

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

## Other commands

```bash
bash install.sh history /Users/me/proj /home/me/proj   # (server) pull a Mac project's Claude sessions
bash install.sh mount                                  # (server) Mac home at ~/mac via sshfs
bash install.sh allow                                  # (server) let Claude run `ssh mac ...` without prompting (opt-in)
bash install.sh remove                                 # undo everything; run on each machine
```
`CMB_HOST` / `CMB_PORT` override the auto-detected server address; `CMB_MAC_CONFIG` for a non-default Mac config dir with `history`.

## Handled automatically

- Re-running the server step while connected keeps the connection and just refreshes Claude's instructions; when not connected it issues a fresh token, so re-pairing a wiped or different Mac just works.
- A token pasted with its banner, or wrapped over several lines, is cleaned up.
- Your own `Host mac` in the server's `~/.ssh/config` can't shadow ours (our block goes first); the Mac's host key lives in its own known-hosts file, so a different Mac never trips a host-key warning.
- Server address and SSH port come from your current SSH session (or the listening sshd); the host key pinned is ed25519, ecdsa or rsa, whichever exists.
- The server step stops with a clear message if sshd disables port forwarding, a tunnel port is busy, or required tools are missing; the Mac step explains the likely causes if pairing fails.
- Mac shell rc is `~/.zshrc` or `~/.bash_profile` depending on `$SHELL`; `remove` cleans both.

## Limits

- One Mac per server (fixed loopback ports 2222/9222).
- Mac asleep or offline: `imlegit` still opens, but Mac commands fail until it's back.
- The server edits Mac files through `ssh mac`, not Claude's native file tools, unless you use `mount` (needs sshfs).
- Chrome control needs Chrome started with `--remote-debugging-port=9222`. Screen control is not bridged.
- Mac client only. Server: Linux with OpenSSH 7.8+.

## Terms

imlegit is a remote-development helper. It does not change or hide where you use Claude from. You are responsible for following Anthropic's terms of service, usage policy and supported-regions policy, and for using servers you trust. No warranty (see LICENSE).

MIT
