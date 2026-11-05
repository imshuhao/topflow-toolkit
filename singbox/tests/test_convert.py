import contextlib
import io
import ipaddress
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from singbox import convert  # noqa: E402


class ConvertTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.clash = yaml.safe_load((ROOT / "config.production-adapted.yaml").read_text(encoding="utf-8"))
        cls.providers = set((cls.clash.get("proxy-providers") or {}).keys())
        cls.cfg = convert.build_config(cls.clash, "", cls.providers)
        convert.validate_config(cls.cfg)

    def test_filter_lookahead_split(self):
        inc, exc = convert.parse_filter("^(?!.*(套餐|流量)).*$")
        self.assertEqual(inc, "")
        self.assertEqual(exc, "套餐|流量")

        inc, exc = convert.parse_filter("(?=.*(港|HK))^((?!(回国)).)*$")
        self.assertIn("港|HK", inc)
        self.assertEqual(exc, "回国")

        inc, exc = convert.parse_filter("(?i)(\\[v6\\]|⁶)")
        self.assertTrue(inc.startswith("(?i)"))

    def test_and_rule(self):
        kind, rule = convert.parse_rule("AND,((NETWORK,UDP),(DST-PORT,53)),DIRECT")
        self.assertEqual(kind, "rule")
        self.assertEqual(rule["type"], "logical")
        self.assertEqual(rule["mode"], "and")
        self.assertEqual(rule["outbound"], convert.DIRECT_TAG)
        self.assertEqual(rule["rules"][0]["network"], ["udp"])
        self.assertEqual(rule["rules"][1]["port"], [53])

    def test_match(self):
        self.assertEqual(convert.parse_rule("MATCH,🐟 漏网之鱼"), ("final", "🐟 漏网之鱼"))

    def test_vmess_ws(self):
        out = convert.convert_proxy(
            {
                "name": "x",
                "type": "vmess",
                "server": "example.com",
                "port": 443,
                "uuid": "u",
                "alterId": 0,
                "cipher": "auto",
                "tls": True,
                "servername": "sni.example.com",
                "network": "ws",
                "ws-opts": {"path": "/ws", "headers": {"Host": "h"}},
            }
        )
        self.assertEqual(out["transport"]["type"], "ws")
        self.assertEqual(out["transport"]["headers"]["Host"], "h")
        self.assertEqual(out["tls"]["server_name"], "sni.example.com")

    def test_all_providers_and_免流(self):
        self.assertEqual({p["tag"] for p in self.cfg["providers"]}, self.providers)
        tags = {o["tag"] for o in self.cfg["outbounds"]}
        self.assertIn(convert.MIANLIU_TAG, tags)
        self.assertIn(convert.DIRECT_GROUP_TAG, tags)
        by_tag = {o["tag"]: o for o in self.cfg["outbounds"]}
        self.assertEqual(by_tag[convert.MIANLIU_TAG]["default"], "国内-8080-联通免流-v2")
        self.assertEqual(by_tag["🎯 国内总模式"]["default"], convert.MIANLIU_TAG)
        self.assertEqual(by_tag["🌍 国外总模式"]["default"], "⚡ ALL·国外延迟最低")
        self.assertEqual(by_tag["🐟 漏网之鱼"]["default"], "🌍 国外总模式")
        self.assertEqual(len(self.cfg["route"]["rules"]), 116)
        self.assertIn(
            {"ip_version": 6, "outbound": "🌐 nasipv6"}, self.cfg["route"]["rules"]
        )
        self.assertEqual(len(self.cfg["route"]["rule_set"]), 36)

    def test_load_balance_groups_stay_loadbalance(self):
        by_tag = {o["tag"]: o for o in self.cfg["outbounds"]}
        groups = [g for g in self.clash["proxy-groups"] if g["type"] == "load-balance"]
        self.assertTrue(groups)
        for g in groups:
            out = by_tag[g["name"]]
            self.assertEqual(out["type"], "loadbalance", g["name"])
            self.assertEqual(out["strategy"], g.get("strategy") or "consistent-hashing", g["name"])
            self.assertEqual(
                out["outbounds"],
                [p for p in (g.get("proxies") or []) if p != convert.DNS_HIJACK_TAG],
                g["name"],
            )
            # Weak-net cadence: ignore Clash source interval/ttl, force 1m.
            self.assertEqual(out["interval"], "1m", g["name"])
            self.assertEqual(out["ttl"], "1m", g["name"])

    def test_load_balance_forces_1m_even_when_clash_source_differs(self):
        out = convert.convert_group(
            {
                "name": "⚖️ 测试负载均衡",
                "type": "load-balance",
                "strategy": "consistent-hashing",
                "proxies": ["国内-8080-联通免流-v2"],
                "url": "https://www.gstatic.com/generate_204",
                "interval": 1800,  # Clash 30m — must be ignored
                "tolerance": 50,
            },
            set(),
            all_proxy=True,
        )
        self.assertEqual(out["type"], "loadbalance")
        self.assertEqual(out["interval"], "1m")
        self.assertEqual(out["ttl"], "1m")
        self.assertEqual(out["strategy"], "consistent-hashing")

    # -- profiles (TUN / observability / eBPF) --------------------------------

    def test_profile_base_is_production_tun(self):
        self.assertEqual([i["type"] for i in self.cfg["inbounds"]], ["tun", "mixed"])
        self.assertEqual(self.cfg["inbounds"][0]["tag"], "tun-in")
        self.assertNotIn("observability", self.cfg["experimental"])
        self.assertEqual(self.cfg["experimental"]["clash_api"]["secret"], "")

    def test_profile_observability_keeps_tun(self):
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="observability", clash_secret="s3cret"
        )
        convert.validate_config(cfg)
        self.assertEqual([i["type"] for i in cfg["inbounds"]], ["tun", "mixed"])
        obs = cfg["experimental"]["observability"]
        self.assertTrue(obs["enabled"])
        self.assertFalse(obs["expose_sensitive"])
        self.assertEqual(obs["recent_connections"], 2000)
        self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "s3cret")

    def test_profile_ebpf_local(self):
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="ebpf-local", clash_secret="s3cret"
        )
        convert.validate_config(cfg)
        self.assertEqual([i["type"] for i in cfg["inbounds"]], ["ebpf", "mixed"])
        ebpf = cfg["inbounds"][0]
        self.assertEqual(ebpf["tag"], "ebpf-in")
        self.assertEqual(ebpf["local"]["data_plane"], "cgroup")
        self.assertNotIn("shared", ebpf)
        self.assertEqual(cfg["experimental"]["cache_file"]["path"], "/data/sing-box/cache.ebpf.db")
        self.assertIn("observability", cfg["experimental"])

    def test_profile_ebpf_full_bypasses_admin_ports(self):
        cfg = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-full",
            clash_secret="s3cret",
            ebpf_interface="br-lan",
        )
        convert.validate_config(cfg)
        ebpf = cfg["inbounds"][0]
        self.assertNotIn("tun-in", [i["tag"] for i in cfg["inbounds"]])
        shared = ebpf["shared"]
        self.assertEqual(shared["data_plane"], "packet_rewrite")
        self.assertEqual(shared["interface"], ["br-lan"])
        self.assertEqual(shared["dns_mode"], "hijack")
        for port in (22, 80, 443, 7890, 8899, 9999, 22622):
            self.assertIn(port, shared["bypass_port"])

    def test_profile_ebpf_local_only(self):
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="ebpf-local-only", clash_secret="",
            ebpf_interface="br-lan",
        )
        convert.validate_config(cfg)
        self.assertEqual([i["type"] for i in cfg["inbounds"]], ["ebpf", "mixed"])
        ebpf = cfg["inbounds"][0]
        self.assertEqual(ebpf["local"]["data_plane"], "cgroup")
        # Phase 1 pins the IPv6 scope: TUN captured ::/0, so an implicit default
        # would leave every v6 flow unproxied while v4 keeps working.
        self.assertTrue(ebpf["local"]["ipv6"])
        # LAN clients are not captured until phase 2.
        self.assertNotIn("shared", ebpf)
        # Zero-rating: the device's own traffic still uses the 免流 route.
        self.assertEqual(cfg["route"]["final"], convert.FINAL_TAG)
        self.assertEqual(cfg["experimental"]["cache_file"]["path"], "/data/sing-box/cache.ebpf.db")

    def test_profile_ebpf_local_shared_is_the_allproxy_stack(self):
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="ebpf-local-shared", clash_secret="",
            ebpf_interface="br-lan",
        )
        convert.validate_config(cfg)
        ebpf = cfg["inbounds"][0]
        self.assertTrue(ebpf["local"]["ipv6"])
        shared = ebpf["shared"]
        self.assertTrue(shared["enabled"])
        self.assertEqual(shared["data_plane"], "packet_rewrite")
        self.assertEqual(shared["interface"], ["br-lan"])
        self.assertEqual(shared["dns_mode"], "hijack")
        self.assertTrue(shared["bypass_private_address"])
        self.assertTrue(shared["ipv6"])
        # Zero-rating: no destination port may leave the data plane; management
        # reachability comes from bypass_private_address (192.168.0.1).
        self.assertEqual(shared["bypass_port"], [])
        self.assertEqual(cfg["route"]["final"], convert.FINAL_TAG)

        # Phase 2 must not diverge from the audited all-proxy stack: same
        # builder inputs, so the two generated configs are byte-identical.
        allproxy = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="ebpf-allproxy", clash_secret="",
            ebpf_interface="br-lan",
        )
        self.assertEqual(cfg, allproxy)

    def test_admin_bypass_is_rejected_on_allproxy_profiles(self):
        # Regression guard: re-adding the admin bypass list to an all-proxy
        # profile silently turns LAN 80/443 into direct egress (real data).
        broken = dict(convert.EBPF_PROFILES)
        broken["ebpf-local-shared"] = convert.EbpfProfile(shared=True, ipv6=True, admin_bypass=True)
        original = convert.EBPF_PROFILES
        convert.EBPF_PROFILES = broken
        try:
            with self.assertRaises(ValueError):
                convert.build_inbounds("ebpf-local-shared", "br-lan")
        finally:
            convert.EBPF_PROFILES = original

    def test_profile_ebpf_allproxy(self):
        cfg = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-allproxy",
            clash_secret="",
            ebpf_interface="br-lan",
        )
        convert.validate_config(cfg)
        ebpf = cfg["inbounds"][0]
        self.assertEqual(ebpf["type"], "ebpf")
        self.assertEqual(ebpf["tag"], "ebpf-in")
        # G1: nothing escapes the data plane by destination port.
        self.assertEqual(ebpf["shared"]["bypass_port"], [])
        # K4: IPv6 scope is explicit on both hooks, management stays direct.
        self.assertTrue(ebpf["local"]["ipv6"])
        self.assertTrue(ebpf["shared"]["ipv6"])
        self.assertTrue(ebpf["shared"]["bypass_private_address"])
        self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "")

        # G3: catch-all goes through the 免流 selector.
        self.assertEqual(cfg["route"]["final"], convert.FINAL_TAG)
        # G2: selectors that used to default to DIRECT now default to proxies.
        outbounds = {o["tag"]: o for o in cfg["outbounds"]}
        self.assertEqual(outbounds["🚀 专线机场"]["default"], "⚡ 专线机场·自动选择")
        self.assertEqual(outbounds["🌍 国外总模式"]["default"], convert.MIANLIU_TAG)
        self.assertEqual(outbounds["🐟 漏网之鱼"]["default"], convert.MIANLIU_TAG)
        # NAS/Emby/SubStore: default 放行 (NAS·IPv6直连); v6 proxy auto fallback.
        nas = outbounds[convert.NASIPV6_TAG]
        self.assertEqual(nas["default"], convert.NAS_DIRECT_TAG)
        self.assertEqual(
            nas["outbounds"][:2], [convert.NAS_DIRECT_TAG, convert.IPV6_AUTO_TAG]
        )
        self.assertEqual(nas["include"], convert.IPV6_FILTER)
        self.assertEqual(outbounds[convert.NAS_DIRECT_TAG]["type"], "direct")
        self.assertEqual(
            outbounds[convert.NAS_DIRECT_TAG]["domain_resolver"],
            {"server": "bootstrap", "strategy": "prefer_ipv6"},
        )
        self.assertEqual(outbounds[convert.NAS_DIRECT_TAG]["bind_interface"], "rmnet_data0")
        self.assertNotIn("routing_mark", outbounds[convert.NAS_DIRECT_TAG])
        ipv6_auto = outbounds[convert.IPV6_AUTO_TAG]
        self.assertEqual(ipv6_auto["include"], convert.IPV6_FILTER)
        self.assertEqual(ipv6_auto["url"], "https://ipv6.baidu.com/")
        self.assertIn("6.果冻", ipv6_auto.get("providers") or [])
        # Panel「更新机场订阅」needs type:remote (Local PUT is a silent no-op).
        for prov in cfg["providers"]:
            self.assertEqual(prov["type"], "remote", prov.get("tag"))
            self.assertIn("target=singbox", prov["url"], prov.get("tag"))
            self.assertIn("http_client", prov)
            if convert.NAS_DDNS_SUFFIX in prov["url"]:
                self.assertEqual(prov["http_client"]["detour"], convert.NAS_DIRECT_TAG)
            else:
                self.assertEqual(prov["http_client"]["detour"], convert.DIRECT_TAG)
        # DDNS must resolve for real before the global AAAA→fakeip rule.
        dns_rules = cfg["dns"]["rules"]
        self.assertIn(
            {
                "domain_suffix": [convert.NAS_DDNS_SUFFIX],
                "server": "bootstrap",
                "rewrite_ttl": 60,
            },
            dns_rules,
        )
        self.assertLess(
            dns_rules.index(
                {
                    "domain_suffix": [convert.NAS_DDNS_SUFFIX],
                    "server": "bootstrap",
                    "rewrite_ttl": 60,
                }
            ),
            next(i for i, r in enumerate(dns_rules) if r.get("query_type") == ["AAAA"]),
        )

        rules = cfg["route"]["rules"]
        # G4: IPv6 destinations follow `final`, not the nasipv6 airport group.
        self.assertFalse([rule for rule in rules if "ip_version" in rule])
        # G8: douyin/tencent QUIC is proxied instead of dropped.
        for rule in rules:
            atoms = rule.get("rules") or []
            self.assertFalse(
                rule.get("action") == "reject"
                and rule.get("type") == "logical"
                and any(atom.get("network") == ["udp"] for atom in atoms)
                and any(443 in (atom.get("port") or []) for atom in atoms),
                rule,
            )
        # G5: DIRECT survives only for LAN/management (免流: no PT exception).
        self.assert_allproxy_zero_direct(cfg)
        # Connectivity probes were the visible leak; they now proxy.
        gstatic = [rule for rule in rules if (rule.get("domain_suffix") or []) == ["www.gstatic.com"]]
        self.assertEqual([rule["outbound"] for rule in gstatic], [convert.MIANLIU_TAG])

    def test_profile_tun_allproxy(self):
        cfg = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="tun-allproxy",
            clash_secret="",
        )
        convert.validate_config(cfg)
        # Same inbound stack as base: TUN, no eBPF at all.
        self.assertEqual([i["type"] for i in cfg["inbounds"]], ["tun", "mixed"])
        self.assertEqual(cfg["inbounds"][0]["tag"], "tun-in")
        self.assertNotIn("ebpf", [i["type"] for i in cfg["inbounds"]])

        # TUN keeps its own cache, never the eBPF one.
        self.assertEqual(cfg["experimental"]["cache_file"]["path"], "/data/sing-box/cache.db")
        self.assertTrue(cfg["experimental"]["observability"]["enabled"])
        self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "")

        self.assertEqual(cfg["route"]["final"], convert.FINAL_TAG)
        outbounds = {o["tag"]: o for o in cfg["outbounds"]}
        self.assertEqual(outbounds["🚀 专线机场"]["default"], "⚡ 专线机场·自动选择")
        self.assertEqual(outbounds["🌍 国外总模式"]["default"], convert.MIANLIU_TAG)
        self.assertEqual(outbounds["🐟 漏网之鱼"]["default"], convert.MIANLIU_TAG)

        rules = cfg["route"]["rules"]
        self.assertFalse([rule for rule in rules if "ip_version" in rule])
        for rule in rules:
            atoms = rule.get("rules") or []
            self.assertFalse(
                rule.get("action") == "reject"
                and rule.get("type") == "logical"
                and any(atom.get("network") == ["udp"] for atom in atoms)
                and any(443 in (atom.get("port") or []) for atom in atoms),
                rule,
            )
        self.assert_allproxy_zero_direct(cfg)

    def assert_allproxy_zero_direct(self, cfg):
        """Observable zero-direct contract for the all-proxy profiles.

        Automatic path (selector defaults / urltest members) must stay proxied.
        OK groups may *list* DIRECT as a manual panel escape without poisoning
        ``final`` / DNS via full membership closure.
        """
        outbounds = cfg["outbounds"]
        by_tag = {o["tag"]: o for o in outbounds}
        tags = {o["tag"] for o in outbounds}
        direct_tags = set(convert.OUTBOUND_ALIAS) | set(convert.OUTBOUND_ALIAS.values())
        direct_tags |= {o["tag"] for o in outbounds if o["type"] == "direct"}
        # 2026-10-31: the manual direct-override group is gone in this mode.
        self.assertNotIn(convert.DIRECT_GROUP_TAG, tags)

        graph = {
            o["tag"]: list(o.get("outbounds") or [])
            for o in outbounds
            if o["type"] in ("selector", "urltest", "loadbalance")
        }

        # Direct entries only in OK groups (nasipv6 / 国内·国外总模式 panel escape).
        # Only nasipv6 may *default* to direct; 国内/国外 keep 免流 defaults.
        for tag, members in graph.items():
            if tag in convert.ALL_PROXY_DIRECT_OK_GROUPS:
                continue
            self.assertFalse(set(members) & direct_tags, tag)
        for out in outbounds:
            if out["type"] in ("selector", "urltest", "loadbalance"):
                if out["tag"] in {convert.NASIPV6_TAG, convert.SUB_UPDATE_TAG}:
                    continue
                self.assertNotIn(out.get("default"), direct_tags, out["tag"])
        self.assertIn(convert.DIRECT_TAG, by_tag[convert.DOMESTIC_MODE_TAG]["outbounds"])
        self.assertIn(convert.DIRECT_TAG, by_tag[convert.FOREIGN_MODE_TAG]["outbounds"])
        self.assertIn(convert.DIRECT_TAG, by_tag[convert.SUB_UPDATE_TAG]["outbounds"])
        self.assertEqual(by_tag[convert.SUB_UPDATE_TAG]["default"], convert.DIRECT_TAG)
        self.assertNotEqual(
            by_tag[convert.DOMESTIC_MODE_TAG]["default"], convert.DIRECT_TAG
        )
        self.assertNotEqual(
            by_tag[convert.FOREIGN_MODE_TAG]["default"], convert.DIRECT_TAG
        )

        rules = cfg["route"]["rules"]
        direct_rules = [rule for rule in rules if rule.get("outbound") in direct_tags]
        # private-* plus the narrow subscription DIRECT exception (VPN-detect
        # hosts such as carpetpacific.com).
        self.assertEqual(
            [rule.get("rule_set") for rule in direct_rules if rule.get("rule_set")],
            [["private-domain"], ["private-ip"]],
        )
        sub_direct = [
            rule
            for rule in direct_rules
            if not rule.get("rule_set") and rule.get("domain_suffix")
        ]
        self.assertTrue(sub_direct)
        for rule in sub_direct:
            self.assertTrue(
                set(rule["domain_suffix"]).issubset(set(convert.SUBSCRIPTION_DIRECT_SUFFIXES))
            )
        for rule in rules:
            target = rule.get("outbound")
            if not target or target in direct_tags:
                continue
            if target in {convert.NASIPV6_TAG, convert.SUB_UPDATE_TAG}:
                continue
            self.assertFalse(
                convert.automatic_path_tags(cfg, [target]) & direct_tags, target
            )
        self.assertEqual(cfg["route"]["final"], convert.FINAL_TAG)
        self.assertFalse(
            convert.automatic_path_tags(cfg, [cfg["route"]["final"]]) & direct_tags
        )

        # DNS: bootstrap (exact UDP 223.5.5.5, no detour) is the only external
        # exception, and only resolves node hostnames; everything else detours.
        servers = {s["tag"]: s for s in cfg["dns"]["servers"]}
        self.assertNotIn("nodes", servers)
        self.assertEqual(
            servers["bootstrap"],
            {"tag": "bootstrap", "type": "udp", "server": "223.5.5.5"},
        )
        for tag, server in servers.items():
            if tag in ("bootstrap", "fakeip"):
                continue
            detour = server.get("detour")
            self.assertTrue(detour, tag)
            self.assertFalse(
                convert.automatic_path_tags(cfg, [detour]) & direct_tags, tag
            )
        for tag in ("ali", "ali2"):
            self.assertEqual(servers[tag]["detour"], convert.MIANLIU_TAG)
        self.assertEqual(
            cfg["route"]["default_domain_resolver"],
            {"server": "bootstrap", "strategy": "ipv4_only"},
        )
        # Rule 0 pins node hostnames to bootstrap; NAS DDNS + LAN filter follow.
        self.assertEqual(set(cfg["dns"]["rules"][0]), {"domain", "server"})
        self.assertEqual(cfg["dns"]["rules"][0]["server"], "bootstrap")
        self.assertIn("acc.dxy5213.top", cfg["dns"]["rules"][0]["domain"])
        nas_dns = next(
            r
            for r in cfg["dns"]["rules"]
            if r.get("domain_suffix") == [convert.NAS_DDNS_SUFFIX]
        )
        self.assertEqual(nas_dns["server"], "bootstrap")
        self.assertEqual(nas_dns["rewrite_ttl"], 60)
        # The fake-ip filter keeps only LAN entries: a filtered CN domain would
        # get a real AAAA and open a v6 flow no 免流 node can exit from.
        filtered = next(
            r["domain_suffix"]
            for r in cfg["dns"]["rules"]
            if r.get("domain_suffix") == [".lan", ".local"]
            or (
                isinstance(r.get("domain_suffix"), list)
                and set(r["domain_suffix"]) == {".lan", ".local"}
            )
        )
        self.assertEqual(sorted(filtered), [".lan", ".local"])
        # AAAA must hit fake-ip before the CN rule, otherwise a real AAAA from
        # ali sends the client to a v6 address the nodes cannot exit from.
        query_types = [r.get("query_type") for r in cfg["dns"]["rules"]]
        self.assertLess(
            query_types.index(["AAAA"]),
            [r.get("rule_set") for r in cfg["dns"]["rules"]].index(["geosite-cn"]),
        )
        # Emby / home NAS land on 🌐 nasipv6 (v6 proxy auto; DIRECT is fallback).
        nas_route = next(
            r
            for r in cfg["route"]["rules"]
            if r.get("domain_suffix") == [convert.NAS_DDNS_SUFFIX]
        )
        self.assertEqual(nas_route["outbound"], convert.NASIPV6_TAG)

    def test_nonallproxy_still_keeps_the_direct_override(self):
        # The zero-direct cleanup is scoped to all-proxy profiles; the default
        # TUN stack (and the observability/ebpf experiment profiles) keep the
        # manual 🟢 直连模式 escape hatch and its selector entries.
        outbounds = {o["tag"]: o for o in self.cfg["outbounds"]}
        self.assertIn(convert.DIRECT_GROUP_TAG, outbounds)
        self.assertIn(convert.DIRECT_TAG, outbounds[convert.MIANLIU_TAG]["outbounds"])
        self.assertIn(convert.DIRECT_GROUP_TAG, outbounds["🌍 国外总模式"]["outbounds"])
        self.assertEqual(outbounds["🌍 国外总模式"]["default"], "⚡ ALL·国外延迟最低")
        self.assertEqual(outbounds["🐟 漏网之鱼"]["default"], "🌍 国外总模式")
        self.assertEqual(self.cfg["route"]["final"], "🐟 漏网之鱼")
        servers = {s["tag"]: s for s in self.cfg["dns"]["servers"]}
        self.assertIn("nodes", servers)
        self.assertEqual(self.cfg["route"]["default_domain_resolver"]["server"], "ali")

    def test_shared_data_plane_switch_changes_only_the_shared_plane(self):
        packet = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-allproxy",
            ebpf_interface="br-lan",
        )
        socket = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-allproxy",
            ebpf_interface="br-lan",
            ebpf_shared_data_plane="socket_assign",
        )
        self.assertEqual(packet["inbounds"][0]["shared"]["data_plane"], "packet_rewrite")
        self.assertEqual(socket["inbounds"][0]["shared"]["data_plane"], "socket_assign")
        # A/B may differ in the shared plane only; everything else (including
        # the cache file) must stay byte-identical.
        socket["inbounds"][0]["shared"]["data_plane"] = "packet_rewrite"
        self.assertEqual(packet, socket)
        convert.validate_config(packet)
        convert.validate_config(socket)

        # Default stays the production value, and unknown planes fail closed.
        default = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-full",
            ebpf_interface="br-lan",
        )
        self.assertEqual(default["inbounds"][0]["shared"]["data_plane"], "packet_rewrite")
        with self.assertRaises(ValueError):
            convert.build_inbounds("ebpf-full", "br-lan", "bpf_magic")

    def test_local_data_plane_default_is_cgroup(self):
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="ebpf-local"
        )
        convert.validate_config(cfg)
        # Device-local hook keeps the plane every eBPF profile has run with.
        self.assertEqual(cfg["inbounds"][0]["local"]["data_plane"], "cgroup")
        self.assertEqual(convert.LOCAL_DATA_PLANES, ("cgroup", "socket_assign"))

    def test_local_data_plane_socket_assign_changes_only_the_local_plane(self):
        cgroup = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-allproxy",
            ebpf_interface="br-lan",
        )
        socket = convert.build_config(
            self.clash,
            "/data/sing-box",
            self.providers,
            profile="ebpf-allproxy",
            ebpf_interface="br-lan",
            ebpf_local_data_plane="socket_assign",
        )
        self.assertEqual(cgroup["inbounds"][0]["local"]["data_plane"], "cgroup")
        self.assertEqual(socket["inbounds"][0]["local"]["data_plane"], "socket_assign")
        # The two hooks are independent: the local A/B must not move shared.
        self.assertEqual(cgroup["inbounds"][0]["shared"]["data_plane"], "packet_rewrite")
        self.assertEqual(socket["inbounds"][0]["shared"]["data_plane"], "packet_rewrite")
        # Byte-identical everywhere else (cache file and routing included).
        socket["inbounds"][0]["local"]["data_plane"] = "cgroup"
        self.assertEqual(cgroup, socket)
        convert.validate_config(cgroup)
        convert.validate_config(socket)

    def test_local_data_plane_rejects_tc_and_unknown_values(self):
        with self.assertRaises(ValueError) as tc:
            convert.build_inbounds("ebpf-local", "br-lan", local_data_plane="tc")
        # tc has no alias: the error has to point at the real alternative.
        self.assertIn("socket_assign", str(tc.exception))
        self.assertIn("alias", str(tc.exception))
        with self.assertRaises(ValueError) as unknown:
            convert.build_inbounds("ebpf-local", "br-lan", local_data_plane="af_xdp")
        self.assertIn("unknown local data plane", str(unknown.exception))

    def test_local_data_plane_cli_default_and_rejection(self):
        ap = convert.build_parser()
        parsed = ap.parse_args([])
        self.assertEqual(parsed.ebpf_local_data_plane, "cgroup")
        # Parser default and builder default must be the same plane.
        self.assertEqual(
            convert.build_config(
                self.clash, "/data/sing-box", self.providers, profile="ebpf-local"
            )["inbounds"][0]["local"]["data_plane"],
            parsed.ebpf_local_data_plane,
        )
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            ap.parse_args(["--ebpf-local-data-plane", "tc"])
        # The rejection must name the real alternative itself; matching the
        # usage line would also pass for a message that explains nothing.
        self.assertIn("use socket_assign", err.getvalue())
        self.assertIn("no tc alias", err.getvalue())

    def test_tun_profiles_never_acquire_the_local_data_plane(self):
        for profile in ("base", "tun-allproxy"):
            default = convert.build_config(
                self.clash, "/data/sing-box", self.providers, profile=profile
            )
            switched = convert.build_config(
                self.clash,
                "/data/sing-box",
                self.providers,
                profile=profile,
                ebpf_local_data_plane="socket_assign",
            )
            inbound = default["inbounds"][0]
            self.assertEqual(inbound["type"], "tun")
            self.assertNotIn("local", inbound)
            self.assertNotIn("shared", inbound)
            # The local knob is an eBPF-only switch; TUN output must not move.
            self.assertEqual(default, switched)

    def test_diagnostics_api_service_only_on_nonbase_profiles(self):
        expected = [
            {
                "type": "api",
                "tag": "diagnostics-api",
                "listen": "127.0.0.1",
                "listen_port": 8088,
            }
        ]
        self.assertNotIn("services", self.cfg)
        for profile in (
            "observability",
            "ebpf-local",
            "ebpf-full",
            "ebpf-local-only",
            "ebpf-local-shared",
            "ebpf-allproxy",
            "tun-allproxy",
        ):
            cfg = convert.build_config(
                self.clash, "/data/sing-box", self.providers, profile=profile
            )
            convert.validate_config(cfg)
            self.assertEqual(cfg["services"], expected, profile)
            # Clash controller stays on 9999 and passwordless; 8088 is the
            # separate gRPC diagnostics service (`sing-box api ebpf --deep`).
            self.assertEqual(
                cfg["experimental"]["clash_api"]["external_controller"], "0.0.0.0:9999"
            )
            self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "")

    def test_zero_direct_rejects_nested_and_aliased_direct(self):
        def fresh():
            return convert.build_config(
                self.clash, "/data/sing-box", self.providers, profile="tun-allproxy"
            )

        # Rule -> gap-1 -> gap-2 -> DIRECT: a member-only check would miss it.
        cfg = fresh()
        cfg["outbounds"].extend(
            [
                {"type": "selector", "tag": "gap-1", "outbounds": ["gap-2"], "default": "gap-2"},
                {
                    "type": "selector",
                    "tag": "gap-2",
                    "outbounds": [convert.DIRECT_TAG],
                    "default": convert.DIRECT_TAG,
                },
            ]
        )
        cfg["route"]["rules"].append({"domain": ["leak.example"], "outbound": "gap-1"})
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # Even a selector nothing routes to may not list DIRECT (panel path).
        cfg = fresh()
        cfg["outbounds"].append(
            {
                "type": "selector",
                "tag": "unused-gap",
                "outbounds": [convert.DIRECT_TAG],
                "default": convert.DIRECT_TAG,
            }
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # A second outbound of type direct is an alias of DIRECT even when its
        # tag is unrelated.
        cfg = fresh()
        cfg["outbounds"].append({"type": "direct", "tag": "dial-out"})
        cfg["route"]["rules"].append({"domain": ["alias.example"], "outbound": "dial-out"})
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # route.final may not name a direct outbound either.
        cfg = fresh()
        cfg["route"]["final"] = convert.DIRECT_TAG
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # A DIRECT rule may only keep private matching: OR with a public branch
        # or an inverted private match would let public traffic stay direct.
        cfg = fresh()
        cfg["route"]["rules"].append(
            {
                "type": "logical",
                "mode": "or",
                "rules": [
                    {"rule_set": ["private-domain"]},
                    {"domain": ["www.google.com"]},
                ],
                "outbound": convert.DIRECT_TAG,
            }
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        cfg["route"]["rules"].append(
            {"rule_set": ["private-ip"], "invert": True, "outbound": convert.DIRECT_TAG}
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

    def test_zero_direct_rejects_mixed_private_alternatives(self):
        def fresh():
            return convert.build_config(
                self.clash, "/data/sing-box", self.providers, profile="tun-allproxy"
            )

        # sing-box ORs the values inside one field, so a single public
        # alternative rides the DIRECT target even next to a private one.
        cfg = fresh()
        cfg["route"]["rules"].append(
            {"rule_set": ["private-domain", "geosite-cn"], "outbound": convert.DIRECT_TAG}
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        cfg["route"]["rules"].append(
            {"domain_suffix": [".lan", "example.com"], "outbound": convert.DIRECT_TAG}
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # The exception is the private rule-sets (plus local suffixes); a bare
        # private ip_cidr is not an approved exemption and must not broaden it.
        cfg = fresh()
        cfg["route"]["rules"].append(
            {"ip_cidr": ["192.168.0.0/16"], "outbound": convert.DIRECT_TAG}
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # Any extra destination matcher alongside the private anchor is
        # rejected, even when it looks private (only the allowlisted fields
        # are inspected, so unknown fields cannot smuggle a public branch).
        cfg = fresh()
        cfg["route"]["rules"].append(
            {
                "rule_set": ["private-ip"],
                "ip_cidr": ["8.8.8.8/32"],
                "outbound": convert.DIRECT_TAG,
            }
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

    def test_zero_direct_rejects_dns_exemption_misuse(self):
        def fresh():
            return convert.build_config(
                self.clash, "/data/sing-box", self.providers, profile="tun-allproxy"
            )

        # Baseline must be valid, otherwise the negative cases prove nothing.
        convert.validate_zero_direct(fresh())

        def server(cfg, tag):
            return next(s for s in cfg["dns"]["servers"] if s["tag"] == tag)

        cfg = fresh()
        del server(cfg, "ali2")["detour"]
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        server(cfg, "bootstrap")["detour"] = convert.MIANLIU_TAG
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        server(cfg, "bootstrap")["server"] = "119.29.29.29"
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        server(cfg, "bootstrap")["type"] = "tcp"
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # A second unproxied external resolver is exactly the leak the contract
        # forbids.
        cfg = fresh()
        cfg["dns"]["servers"].append({"tag": "escape", "type": "udp", "server": "1.1.1.1"})
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        cfg["dns"]["servers"].append(
            {
                "tag": "escape",
                "type": "https",
                "server": "dns.example",
                "detour": convert.DIRECT_TAG,
            }
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # The direct node resolver is not allowed back.
        cfg = fresh()
        cfg["dns"]["servers"].append(
            {
                "tag": "nodes",
                "type": "https",
                "server": "doh.pub",
                "domain_resolver": "bootstrap",
            }
        )
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        # bootstrap may answer node hostnames only, never client domains.
        cfg = fresh()
        cfg["dns"]["rules"].append({"rule_set": ["geosite-cn"], "server": "bootstrap"})
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        cfg["dns"]["final"] = "bootstrap"
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

        cfg = fresh()
        cfg["route"]["default_domain_resolver"] = {"server": "bootstrap"}
        with self.assertRaises(ValueError):
            convert.validate_zero_direct(cfg)

    def test_profile_secret_optional_empty_by_user_rule(self):
        # User rule (HANDOVER §29): the panel keeps no password; empty is valid
        # for every profile, and the generated config keeps secret "".
        for profile in (
            "observability",
            "ebpf-local",
            "ebpf-full",
            "ebpf-local-only",
            "ebpf-local-shared",
            "ebpf-allproxy",
            "tun-allproxy",
        ):
            convert.check_profile_args(profile, "")
            convert.check_profile_args(profile, "s3cret")
        convert.check_profile_args("base", "")
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="observability", clash_secret=""
        )
        convert.validate_config(cfg)
        self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "")
        self.assertTrue(cfg["experimental"]["observability"]["enabled"])
        with self.assertRaises(ValueError):
            convert.check_profile_args("bogus", "s3cret")

    def test_ads_false_positive_bili_domains_stripped(self):
        rules = [
            {
                "domain": [
                    "ads.example.com",
                    "dataflow.biliapi.com",
                    "miniapp.bilibili.com",
                    "line1-log.biligame.net",
                ]
            },
            {"domain_suffix": ["doubleclick.net"]},
        ]
        cleaned = convert._strip_ads_false_positives(rules)
        domains = cleaned[0]["domain"]
        self.assertEqual(domains, ["ads.example.com"])
        self.assertEqual(cleaned[1]["domain_suffix"], ["doubleclick.net"])
        for bad in convert.ADS_FALSE_POSITIVE_DOMAINS:
            self.assertNotIn(bad, domains)

    def test_douyin_extra_image_cdn_suffixes_merged(self):
        rules = [
            {"domain_suffix": ["douyinpic.com", "douyinvod.com"]},
            {"domain": ["v5-dy-o-abtest.zjcdn.com", "lf3-static.bytednsdoc.com"]},
        ]
        merged = convert._merge_douyin_extras(rules)
        suffix = merged[0]["domain_suffix"]
        for need in convert.DOUYIN_EXTRA_DOMAIN_SUFFIXES:
            self.assertIn(need, suffix)
        self.assertIn("douyinpic.com", suffix)
        # Exact host under zjcdn.com is absorbed into the suffix cover.
        exact = merged[1]["domain"]
        self.assertNotIn("v5-dy-o-abtest.zjcdn.com", exact)
        self.assertIn("lf3-static.bytednsdoc.com", exact)

    def test_dead_node_exclude_merged_into_provider_groups(self):
        self.assertIn("订阅暂不可用", convert._merge_dead_node_exclude(""))
        merged = convert._merge_dead_node_exclude(r"回国|温馨")
        self.assertIn("订阅暂不可用", merged)
        self.assertIn("请前往官网", merged)
        self.assertIn("回国", merged)
        # Idempotent.
        self.assertEqual(merged, convert._merge_dead_node_exclude(merged))

    def test_provider_outbounds_are_dead_detection(self):
        self.assertTrue(convert._provider_outbounds_are_dead([]))
        self.assertTrue(
            convert._provider_outbounds_are_dead(
                [{"type": "socks", "tag": "订阅暂不可用", "server": "127.0.0.1", "server_port": 1}]
            )
        )
        self.assertTrue(
            convert._provider_outbounds_are_dead(
                [{"type": "shadowsocks", "tag": "请前往官网重新获取订阅", "server": "1.1.1.1"}]
            )
        )
        self.assertFalse(
            convert._provider_outbounds_are_dead(
                [
                    {"type": "vmess", "tag": "CN-广州BGP", "server": "1.1.1.1"},
                    {"type": "socks", "tag": "订阅暂不可用", "server": "127.0.0.1", "server_port": 1},
                ]
            )
        )

    def test_douyin_default_is_domestic_urltest(self):
        by_tag = {o["tag"]: o for o in self.cfg["outbounds"]}
        douyin = by_tag["🎵 抖音"]
        self.assertEqual(douyin["default"], "⚡ ALL·国内延迟最低")
        self.assertIn("订阅暂不可用", douyin.get("exclude") or "")

    def test_subscription_direct_exception_on_allproxy(self):
        cfg = convert.build_config(
            self.clash, "/data/sing-box", self.providers, profile="ebpf-allproxy"
        )
        route_hit = [
            r
            for r in cfg["route"]["rules"]
            if r.get("outbound") == convert.DIRECT_TAG
            and "carpetpacific.com" in (r.get("domain_suffix") or [])
        ]
        self.assertTrue(route_hit, "carpetpacific.com must DIRECT on all-proxy")
        dns_hit = [
            r
            for r in cfg["dns"]["rules"]
            if "carpetpacific.com" in (r.get("domain_suffix") or [])
            and r.get("server") == "bootstrap"
        ]
        self.assertTrue(dns_hit, "carpetpacific.com must resolve via bootstrap")
        # Must not trip validate_zero_direct.
        convert.validate_zero_direct(cfg)


if __name__ == "__main__":
    unittest.main()
