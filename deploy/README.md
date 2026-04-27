# Deployment

How to run Avledet + ServerAuthority as a real service on a Linux host.

## systemd unit

[`systemd/avledet.service`](systemd/avledet.service) is the unit file currently running on the project's reference VPS.

Install:

```bash
sudo cp deploy/systemd/avledet.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now avledet
```

Watch logs:

```bash
sudo journalctl -u avledet -f
```

Watch only ServerAuthority output:

```bash
sudo journalctl -u avledet -f | grep ServerAuthority
```

Restart:

```bash
sudo systemctl restart avledet
```

Stop:

```bash
sudo systemctl stop avledet
```

## Assumed paths (edit the unit file if yours differ)

| Path | What |
|---|---|
| `/home/ubuntu/avledet-spike/Avledet/build/bin/` | Avledet build output. The unit's `WorkingDirectory` and `ExecStart`. |
| `/home/ubuntu/.steam/sdk64/steamclient.so` | Symlink to `libsteamclient.so` from a Valheim install. Steam SDK looks here at runtime. |
| `/home/ubuntu/avledet-spike/Avledet/build/bin/data/` | World saves, config (`server.yml`), Lua scripts. |
| `/home/ubuntu/avledet-spike/Avledet/build/bin/data/lua/scripts/ServerAuthority/` | This project's Lua module + `scriptInfo.yml`, copied here at deploy time. |

## Auto-restart behaviour

`Restart=on-failure` + `RestartSec=10`: the service will come back ~10 seconds after a crash. `StartLimitBurst=3` in 60 seconds caps the retry storm — if Avledet crashes 3 times in a minute, systemd will stop trying and you'll need to investigate and `systemctl reset-failed avledet` before manual restart.

Verified 2026-04-27: `kill -9` on the running PID was followed by automatic respawn 36 seconds later, with `ServerAuthority.lua` reloaded cleanly.

## Resource baseline (idle, no players)

| Metric | Value |
|---|---|
| RAM (RSS) | ~50 MB |
| CPU | <1% |
| UDP listeners | `27420` (game), `27421` (Steam query), `*` (random outbound) |

## Tracy profiling (optional)

Avledet is built with Tracy linked in `TRACY_ON_DEMAND` mode. Profiling stays inert with zero overhead until a Tracy GUI client connects to the server's profiler port. To enable real-time profiling, run the [Tracy server GUI](https://github.com/wolfpld/tracy/releases) and connect it to `<vps-ip>:8086` (or whatever Tracy's default port is).

## Deploying a new ServerAuthority Lua version

1. Edit `lua/scripts/ServerAuthority/ServerAuthority.lua` in this repo
2. Copy to `/home/ubuntu/avledet-spike/Avledet/build/bin/data/lua/scripts/ServerAuthority/`
3. `sudo systemctl restart avledet`
4. Confirm load: `sudo journalctl -u avledet -n 50 | grep ServerAuthority`

We will automate this with a deploy script as the project matures.
