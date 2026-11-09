# claude-mac-bridge

Run **Claude Code on an always-on server** (your subscription lives there) while your **Mac stays your personal machine that Claude can still reach**: its files, shell and Chrome. Open as many Claude sessions on the server as you like; they all share one tunnel.

## Install: two commands, paired by a token

**1. On the server** (the script offers to install Claude Code there if missing; you then run `claude` once and `/login`):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Javadyakuza/claude-mac-bridge/main/install.sh)
```
It prints a **pairing token** and waits.

**2. On your Mac** (System Settings > General > Sharing > **Remote Login = ON**):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Javadyakuza/claude-mac-bridge/main/install.sh)
```
Paste the token (that is all: the server address, SSH port and your Mac username are detected automatically). The server terminal prints `connected to <your-mac>`. Then on the server: `cd project && claude`.

Same script both times; it detects Linux vs macOS. No root, no prior SSH access from the Mac to the server, no sudo anywhere.

## Architecture

```
 Mac (launchd agent)                     Server
 ┌──────────────┐   ssh -N -R ...       ┌───────────────────────────────┐
 │ sshd :22     │◄──────────────────────│ 127.0.0.1:2222 → Mac sshd      │
 │ Chrome :9222 │◄──────────────────────│ 127.0.0.1:9222 → Mac Chrome    │
 └──────────────┘  (Mac dials OUT,      │                               │
                    auto-reconnects)    │ claude session 1 ┐            │
                                        │ claude session 2 ├ `ssh mac`  │
                                        │ claude session N ┘ (1 shared  │
                                        │                    connection)│
                                        └───────────────────────────────┘
```

- The **Mac dials out**, kept alive by launchd, so it works behind NAT with no open ports, and reconnects after sleep or network loss.
- On the server, `ssh mac` reaches your Mac through the loopback-only tunnel. `ControlMaster` multiplexes all Claude sessions over one connection.
- A short block in the server's `~/.claude/CLAUDE.md` tells Claude that `ssh mac` is your local machine; that is how it uses it by default.

## The token

It carries the server address, the server's SSH **host key** (pinned, so no man-in-the-middle on first connect), the key that lets the server log in to your Mac, and a **tunnel-only private key**. That key is locked in the server's `authorized_keys` with `restrict,port-forwarding,permitlisten=127.0.0.1:2222,permitlisten=127.0.0.1:9222,command=~/.ssh/cmb_hello`: it can open those two reverse forwards and run one tiny script that records your Mac username (first name wins) and holds the tunnel open. No shell, no other commands. Treat the token like a password; `remove` on the server revokes it.

## What you get on the server

- `ssh mac '<cmd>'`: commands on your Mac.
- Mac Chrome DevTools on `localhost:9222` (start Chrome with `--remote-debugging-port=9222`).
- `bash install.sh history /Users/me/proj /home/me/proj`: pull your local Claude sessions for a project, then `cd /home/me/proj && claude --resume`. Never deletes or overwrites newer files. `CMB_MAC_CONFIG=.claude-acc2` if your Mac config dir differs.
- `bash install.sh mount`: Mac home at `~/mac` via sshfs (needs sshfs on the server).

## Safety (small servers)

- The server step refuses to run under 150MB free RAM or 50MB free disk, or if the tunnel ports are busy.
- Footprint: one idle `ssh` process (~3MB) on the server side plus edits to `~/.ssh/config`, `~/.ssh/authorized_keys`, `~/.ssh/cmb_*`, `~/.claude/CLAUDE.md`. Nothing is deleted.
- The server's key is accepted on your Mac only from 127.0.0.1, i.e. through the tunnel.
- Anyone with root on the server can use the tunnel to reach your Mac. Use servers you trust.

## Remove

Run `bash install.sh remove` on each machine.

## Limits

- Mac asleep or offline means the bridge is down; it reconnects when the Mac is back (`caffeinate` helps).
- Remote screen control (computer-use) is not bridged.
- Mac client only. Server: any Linux with OpenSSH 7.8+.
- Tunnel ports are fixed at 2222 and 9222 (loopback).

MIT
