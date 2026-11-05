# sing-box helpers (TopFlow)

This directory currently ships the **WAN balance** helper used by the
touchscreen「分流」page and `singbox-manager` `wan-mode-*` commands.

## WAN balance (`singbox-wan-balance.sh`)

Host-mode sing-box stamps proxied sockets with `SO_MARK 0x2024`. mwan3 then
skips those packets, so without this helper all proxy egress sticks to the
default 5G route. The script installs an `nft` jhash chain (`tf-sbwan`) that
selects among online cellular WANs using mwan3 policy weights.

### Presets

| Preset | Meaning |
|---|---|
| `auto` | Quality-weighted three-card pool + soft bias (TCP prefers 5G, UDP prefers 4G; weak cards spill) |
| `shared` | Forced shared pool; quality degrade still on; no soft bias |
| `game` | Legacy hard bind (CLI only; not offered on the touch UI) |

Quality signals: mwan3track `LATENCY_*` / `LOSS_*` (primary) and optional
`/data/local/weaknet/radio.snap` `rsrp=` for the 5G card. Enter/exit hysteresis
avoids flap. The watchdog re-applies about every 15s.

### Install

```sh
cp singbox/wan-balance.conf.example /data/sing-box/wan-balance.conf
cp singbox/singbox-wan-balance.sh /data/sing-box/singbox-wan-balance.sh
chmod 755 /data/sing-box/singbox-wan-balance.sh
sh /data/sing-box/singbox-wan-balance.sh preset-set auto
```

Do **not** commit a device `wan-balance.conf` with site-specific overrides that
embed private hostnames. The example file is the public template.

### Offline tests

```sh
sh singbox/tests/test_wan_balance_render.sh
```
