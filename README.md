# claude-mac-bridge

Run **Claude Code on an always-on server** (your subscription lives there) while your **Mac stays your personal machine that Claude can still reach**: its files, shell and Chrome. Open as many Claude sessions on the server as you like; all of them share one tunnel.

## Install (on your Mac)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/javadyakuza/claude-mac-bridge/main/install.sh)
```

It asks for your server (`user@host`), checks Remote Login, and sets everything up. Or non-interactive:

```bash
curl -fsSL https://raw.githubusercontent.com/javadyakuza/claude-mac-bridge/main/install.sh -o install.sh && bash install.sh user@server
```

**Before you run it**
1. Server: install Claude Code, run `claude`, `/login` with your subscription.
2. Mac: System Settings > General > Sharing > **Remote Login = ON**.
3. You can SSH to the server as a normal (non-root) user. No sudo is needed anywhere.

## Architecture

```
 Mac (launchd)                          Server
 ┌──────────────┐  ssh -R 2222 / 9222   ┌──────────────────────────┐
 │ sshd :22     │◄──────────────────────│ 127.0.0.1:2222 → Mac sshd │
 │ Chrome :9222 │◄──────────────────────│ 127.0.0.1:9222 → Mac CDP  │
 └──────────────┘  (Mac dials OUT,      │                          │
                    auto-reconnects)    │  claude session 1 ┐      │
                                        │  claude session 2 ├ ssh mac (one multiplexed connection)
                                        │  claude session N ┘      │
                                        └──────────────────────────┘
```

- The **Mac dials out** (`ssh -R`), kept alive by a launchd agent, so it works behind NAT/Wi-Fi with no open ports. It reconnects by itself after sleep or network loss.
- On the server, `ssh mac` reaches your Mac through the loopback-only tunnel. `ControlMaster` multiplexes every Claude session over one connection, so extra sessions cost almost nothing.
- The server's key is accepted on your Mac **only from 127.0.0.1** (i.e. only through the tunnel).
- A short block in the server's `~/.claude/CLAUDE.md` tells Claude that `ssh mac` is your local machine. That is how it "knows" to use it.

## What you get on the server

- `ssh mac '<cmd>'` runs commands on your Mac.
- Your Mac's Chrome DevTools on `localhost:9222` (start Chrome with `--remote-debugging-port=9222`).
- Optional `--mount`: your Mac home at `~/mac` via sshfs (needs sshfs on the server).
- Optional `--history MACPATH:SERVERPATH`: copy your local Claude sessions for a project so `cd <path> && claude --resume` continues them. Never deletes or overwrites newer files. Set `CLAUDE_CONFIG_DIR` if your Mac config is not `~/.claude`.

## Safety (small servers)

- Refuses to install if the server has under 150MB free RAM or 50MB free disk, or the ports are busy.
- Footprint on the server: one idle `ssh` process (~3MB) plus 3 small edits (`~/.ssh/config`, `~/.ssh/to_mac*`, `~/.claude/CLAUDE.md`). Nothing is deleted there.
- Tunnel ports bind to `127.0.0.1` only.
- Anyone with root on the server can use the tunnel to reach your Mac. Use servers you trust.

## Flags

| Flag | Meaning |
|---|---|
| `-p 2222` | tunnel port on the server |
| `--history MAC:SRV` | copy sessions between project paths |
| `--mount` | mount Mac home at `~/mac` on the server |
| `--uninstall user@server` | remove everything on both sides |
| `-h` | full guide |

Env: `SSH_PORT` (server sshd port, default 22), `CLAUDE_CONFIG_DIR`.

## Limits

- Mac asleep or offline means the bridge is down; it reconnects when the Mac is back. Use `caffeinate` if needed.
- Remote screen control (computer-use) is not bridged.
- Mac-only client. Server: any Linux with sshd.

MIT
