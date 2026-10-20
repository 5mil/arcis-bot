# Arcis Bot on a VPS

The VPS is simply the machine. The hearth, NameStore, Catalog, ConceptStore, and agent memory all live on its local filesystem. No external runtimes, no cloud dependencies for the core loop. The same philosophy as the house box, just on a remote Linux host.

## Recommended specs

- Ubuntu 22.04 / 24.04 or Debian 12 (systemd)
- 2+ vCPU, 4 GB RAM minimum (8 GB preferred for Visio + a small GGUF)
- 20+ GB disk (model + hearth + build artifacts)
- A non-root user with sudo

## 1. Base system

```sh
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl build-essential pkg-config
# Optional but useful
sudo apt install -y htop tmux ufw
```

Create a dedicated user if you have not already:

```sh
sudo adduser arcis
sudo usermod -aG sudo arcis
su - arcis
```

## 2. Install Zig

```sh
# Example for Zig 0.14.x — check ziglang.org for the current tarball
cd /tmp
curl -LO https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /opt/zig
sudo ln -sf /opt/zig/zig /usr/local/bin/zig
zig version
```

## 3. Clone and build

```sh
cd ~
git clone https://github.com/5mil/arcis
git clone https://github.com/5mil/arcis-bot
cd arcis
zig build
# Binary lands at zig-out/bin/arcis
```

## 4. Model and hearth

```sh
mkdir -p ~/arcis/models/gguf
mkdir -p ~/arcis-hearth
# Download an openly licensed GGUF (example)
cd ~/arcis/models/gguf
# Use the parent tools/pull_gguf.sh or wget/curl the file directly
# e.g. DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf
```

## 5. Systemd unit

Copy the unit provided in this repo:

```sh
sudo cp ~/arcis-bot/deploy/systemd/arcis-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable arcis-bot
sudo systemctl start arcis-bot
sudo systemctl status arcis-bot
```

Logs:

```sh
journalctl -u arcis-bot -f
```

## 6. Firewall (keep the port local by default)

```sh
sudo ufw allow OpenSSH
sudo ufw enable
# Do NOT open 9090 to the world. Access via SSH tunnel:
# ssh -L 9090:127.0.0.1:9090 user@vps
```

If you later want a reverse proxy (Caddy/Nginx) in front of the dashboard, bind the Arcis port to 127.0.0.1 only and terminate TLS at the proxy.

## 7. Persistence and observation

- Hearth directory (`~/arcis-hearth` or the path in the unit) survives reboots.
- The bot generates its name and proposes terms on first start exactly as on a local PC.
- Routines (workflows) continue to fire via the existing scheduler.
- Use `journalctl` and the existing dashboard (via SSH tunnel) for observation.

## Philosophy note

The VPS is not a cloud service; it is a remote machine you control. State never leaves its disk unless you explicitly export it. The single Zig binary, naming system, ontology governance, and workflow engine remain unchanged.

See also the parent engine’s `deploy/systemd/arcis.service` for the original house-box unit.
