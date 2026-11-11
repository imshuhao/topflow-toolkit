#!/usr/bin/env python3
"""Clash Meta (mihomo) -> sing-box 1.14 fork config converter.

Source: ../../config.production-adapted.yaml (this repo)
Target: reF1nd/sing-box 1.14.4 (musl static on device)

Design notes
------------
* Proxy providers are ``type: remote`` (Clash-API refreshable) with a local
  ``path`` cache. SubStore URLs are normalized to ``?target=singbox``; download
  detours ``🌐 NAS·IPv6直连`` for ``*.example.invalid`` so Zashboard「更新」
  works (Local providers only returned empty 204).
* Rule providers are converted to local sing-box source rule-sets (exact
  source lists), except CN geosite/geoip which use SagerNet ``.srs``.
* Clash ``filter`` uses PCRE lookaheads, which Go's RE2 does not support.
  They are split into ``include`` / ``exclude`` regexes.
* Clash ``load-balance`` maps to the fork's ``loadbalance`` outbound;
  ``fallback`` maps to ``urltest`` (no exact equivalent).
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote

import yaml

ROOT = Path(__file__).resolve().parent
DEFAULT_INPUT = ROOT.parent / "config.production-adapted.yaml"
DEFAULT_OUT = ROOT / "generated"
CACHE = ROOT / ".cache"

DIRECT_TAG = "🌐 本机·本地直连"
BLOCK_TAG = "⛔️ 禁止·拒绝连接"
REJECT_DROP_TAG = "REJECT-DROP"
DNS_HIJACK_TAG = "🌐 DNS_Hijack"
PROVIDER_HTTP_CLIENT = "订阅直连"

# Output profiles (see main()):
#   base         production TUN stack + mixed inbound (unchanged default)
#   observability base + experimental.observability (metrics / recent / top-K)
#   ebpf-local   eBPF inbound, cgroup local only (device-originated traffic)
#   ebpf-full    eBPF inbound, local + shared packet_rewrite on the LAN bridge
#   ebpf-local-only   migration phase 1: ebpf-local with the IPv6 scope spelled
#                out on the local hook (dual-stack parity with TUN's ::/0).
#                LAN clients are *not* captured, so this is a short test window
#                only -- uncaptured LAN traffic leaves on the SIM (real data).
#   ebpf-local-shared migration phase 2: local + shared packet_rewrite, IPv6
#                on both hooks, empty bypass_port (every public port is proxied;
#                management stays direct through bypass_private_address).
#   ebpf-allproxy ebpf-full + zero direct leaks: no bypass_port, no DIRECT
#                reachable from route.final/rules/DNS or from any group member
#                or default, no 🟢 直连模式 group, final 免流.  Everything
#                public is proxied.
#   tun-allproxy the same all-proxy routing on the production TUN stack, for
#                when eBPF shared packet_rewrite stalls LAN TCP.
PROFILES = (
    "base",
    "observability",
    "ebpf-local",
    "ebpf-full",
    "ebpf-local-only",
    "ebpf-local-shared",
    "ebpf-allproxy",
    "tun-allproxy",
)

# Profiles that proxy every public flow (免流).  The routing delta is shared;
# only the inbound and the cache file differ.  The migration pair is included:
# zero-rating is the whole point of the device, so a migration phase that let
# LAN clients bypass the proxy would burn real data.
ALL_PROXY_PROFILES = ("ebpf-allproxy", "ebpf-local-only", "ebpf-local-shared", "tun-allproxy")

# Management ports that must stay on the kernel path when the shared hook
# captures LAN clients: WebUI 80, mixed 7890, WebSSH 8899, Clash API 9999,
# sshd 22622 (22/443 are aliases for the same services).  53 is taken over by
# ``shared.dns_mode: hijack``, which has priority over ``bypass_port``.
#
# Only the non-all-proxy ``ebpf-full`` uses this list.  Under the zero-rating
# rule every *public* port must be proxied -- a bypassed 80/443 is a direct
# LAN egress -- and management reachability to 192.168.0.1 is already covered
# by ``bypass_private_address``.
ADMIN_BYPASS_PORTS = (22, 80, 443, 7890, 8899, 9999, 22622)


@dataclass(frozen=True)
class EbpfProfile:
    """Plane selection for the ``ebpf-*`` profiles (see build_inbounds()).

    ``shared``       attach the TC packet_rewrite hook for LAN clients;
    ``ipv6``         write ``ipv6: true`` on every enabled hook instead of
                     relying on the build default (TUN captured ::/0, so an
                     implicit default silently drops IPv6 to the kernel);
    ``admin_bypass`` keep ADMIN_BYPASS_PORTS out of the shared data plane.
                     Invalid on an all-proxy profile: a bypassed 80/443 is a
                     direct leak for LAN web.
    """

    shared: bool
    ipv6: bool
    admin_bypass: bool


EBPF_PROFILES: dict[str, EbpfProfile] = {
    "ebpf-local": EbpfProfile(shared=False, ipv6=False, admin_bypass=True),
    "ebpf-full": EbpfProfile(shared=True, ipv6=False, admin_bypass=True),
    "ebpf-local-only": EbpfProfile(shared=False, ipv6=True, admin_bypass=False),
    "ebpf-local-shared": EbpfProfile(shared=True, ipv6=True, admin_bypass=False),
    "ebpf-allproxy": EbpfProfile(shared=True, ipv6=True, admin_bypass=False),
}

SAGERNET_GEOSITE = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-{tag}.srs"
SAGERNET_GEOIP = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-{tag}.srs"
GITMETA = "https://raw.githubusercontent.com/GitMetaio/rule/master/rule/Clash"


@dataclass
class RuleSetSpec:
    tag: str
    kind: str  # srs | domain | ip | list
    url: str | None = None
    original: list[str] = field(default_factory=list)


# original Clash rule-provider tag -> spec
RULE_SET_SPECS: dict[str, RuleSetSpec] = {
    "CN_域": RuleSetSpec("geosite-cn", "srs", SAGERNET_GEOSITE.format(tag="cn"), ["CN_域"]),
    "cn": RuleSetSpec("geosite-cn", "srs", SAGERNET_GEOSITE.format(tag="cn"), ["cn"]),
    "CN_IP": RuleSetSpec("geoip-cn", "srs", SAGERNET_GEOIP.format(tag="cn"), ["CN_IP"]),
    "WebRTC_端/域": RuleSetSpec(
        "webrtc", "list", "https://raw.githubusercontent.com/GitMetaio/Surfing/rm/Home/rules/WebRTC.list",
        ["WebRTC_端/域"],
    ),
    "No-ads-all_域": RuleSetSpec("no-ads-all", "domain", "https://anti-ad.net/domains.txt", ["No-ads-all_域"]),
    "AliPay_域": RuleSetSpec("alipay", "domain", f"{GITMETA}/AliPay/AliPay_OCD_Domain.txt", ["AliPay_域"]),
    "Tencent_域": RuleSetSpec("tencent", "domain", f"{GITMETA}/Tencent/Tencent_OCD_Domain.txt", ["Tencent_域"]),
    "Baidu_域": RuleSetSpec("baidu", "domain", f"{GITMETA}/Baidu/Baidu_OCD_Domain.txt", ["Baidu_域"]),
    "DouYin_域": RuleSetSpec("douyin", "domain", f"{GITMETA}/DouYin/DouYin_OCD_Domain.txt", ["DouYin_域"]),
    "XiaoHongShu_域": RuleSetSpec(
        "xiaohongshu", "domain", f"{GITMETA}/XiaoHongShu/XiaoHongShu_OCD_Domain.txt", ["XiaoHongShu_域"]
    ),
    "BiliBili_域": RuleSetSpec("bilibili", "domain", f"{GITMETA}/BiliBili/BiliBili_OCD_Domain.txt", ["BiliBili_域"]),
    "BiliBili_IP": RuleSetSpec("bilibili-ip", "ip", f"{GITMETA}/BiliBili/BiliBili_OCD_IP.txt", ["BiliBili_IP"]),
    "Steam_域": RuleSetSpec("steam", "domain", f"{GITMETA}/Steam/Steam_OCD_Domain.txt", ["Steam_域"]),
    "TikTok_域": RuleSetSpec("tiktok", "domain", f"{GITMETA}/TikTok/TikTok_OCD_Domain.txt", ["TikTok_域"]),
    "Spotify_域": RuleSetSpec("spotify", "domain", f"{GITMETA}/Spotify/Spotify_OCD_Domain.txt", ["Spotify_域"]),
    "Spotify_IP": RuleSetSpec("spotify-ip", "ip", f"{GITMETA}/Spotify/Spotify_OCD_IP.txt", ["Spotify_IP"]),
    "Facebook_域": RuleSetSpec("facebook", "domain", f"{GITMETA}/Facebook/Facebook_OCD_Domain.txt", ["Facebook_域"]),
    "Facebook_IP": RuleSetSpec("facebook-ip", "ip", f"{GITMETA}/Facebook/Facebook_OCD_IP.txt", ["Facebook_IP"]),
    "Telegram_域": RuleSetSpec("telegram", "domain", f"{GITMETA}/Telegram/Telegram_OCD_Domain.txt", ["Telegram_域"]),
    "Telegram_IP": RuleSetSpec("telegram-ip", "ip", f"{GITMETA}/Telegram/Telegram_OCD_IP.txt", ["Telegram_IP"]),
    "YouTube_域": RuleSetSpec("youtube", "domain", f"{GITMETA}/YouTube/YouTube_OCD_Domain.txt", ["YouTube_域"]),
    "YouTube_IP": RuleSetSpec("youtube-ip", "ip", f"{GITMETA}/YouTube/YouTube_OCD_IP.txt", ["YouTube_IP"]),
    "Google_域": RuleSetSpec("google", "domain", f"{GITMETA}/Google/Google_OCD_Domain.txt", ["Google_域"]),
    "Google_IP": RuleSetSpec("google-ip", "ip", f"{GITMETA}/Google/Google_OCD_IP.txt", ["Google_IP"]),
    "GoogleFCM_域": RuleSetSpec(
        "googlefcm", "domain", f"{GITMETA}/GoogleFCM/GoogleFCM_OCD_Domain.txt", ["GoogleFCM_域"]
    ),
    "GoogleFCM_IP": RuleSetSpec("googlefcm-ip", "ip", f"{GITMETA}/GoogleFCM/GoogleFCM_OCD_IP.txt", ["GoogleFCM_IP"]),
    "Microsoft_域": RuleSetSpec("microsoft", "domain", f"{GITMETA}/Microsoft/Microsoft_OCD_Domain.txt", ["Microsoft_域"]),
    "Apple_域": RuleSetSpec("apple", "domain", f"{GITMETA}/Apple/Apple_OCD_Domain.txt", ["Apple_域"]),
    "Apple_IP": RuleSetSpec("apple-ip", "ip", f"{GITMETA}/Apple/Apple_OCD_IP.txt", ["Apple_IP"]),
    "OpenAI_域": RuleSetSpec("openai", "domain", f"{GITMETA}/OpenAI/OpenAI_OCD_Domain.txt", ["OpenAI_域"]),
    "OpenAI_IP": RuleSetSpec("openai-ip", "ip", f"{GITMETA}/OpenAI/OpenAI_OCD_IP.txt", ["OpenAI_IP"]),
    "Netflix_域": RuleSetSpec("netflix", "domain", f"{GITMETA}/Netflix/Netflix_OCD_Domain.txt", ["Netflix_域"]),
    "Netflix_IP": RuleSetSpec("netflix-ip", "ip", f"{GITMETA}/Netflix/Netflix_OCD_IP.txt", ["Netflix_IP"]),
    "Discord_域": RuleSetSpec("discord", "domain", f"{GITMETA}/Discord/Discord_OCD_Domain.txt", ["Discord_域"]),
    "GitHub_域": RuleSetSpec("github", "domain", f"{GITMETA}/GitHub/GitHub_OCD_Domain.txt", ["GitHub_域"]),
    "Twitter_域": RuleSetSpec("twitter", "domain", f"{GITMETA}/Twitter/Twitter_OCD_Domain.txt", ["Twitter_域"]),
    "Twitter_IP": RuleSetSpec("twitter-ip", "ip", f"{GITMETA}/Twitter/Twitter_OCD_IP.txt", ["Twitter_IP"]),
    "Private_域": RuleSetSpec("private-domain", "domain", f"{GITMETA}/Lan/Lan_OCD_Domain.txt", ["Private_域"]),
    "Private_IP": RuleSetSpec("private-ip", "ip", f"{GITMETA}/Lan/Lan_OCD_IP.txt", ["Private_IP"]),
}

ORIGINAL_TO_TAG = {spec_key: spec.tag for spec_key, spec in RULE_SET_SPECS.items()}
TAG_TO_SPEC = {spec.tag: spec for spec in RULE_SET_SPECS.values()}

# Tags that are used by DNS rules even if no route rule references them.
EXTRA_RULE_SET_TAGS = {"geosite-cn"}


def mirror_urls(url: str) -> list[str]:
    out = [url]
    prefix = "https://raw.githubusercontent.com/"
    if url.startswith(prefix):
        rest = url[len(prefix) :]
        parts = rest.split("/", 3)
        if len(parts) == 4:
            owner, repo, branch, path = parts
            jsdelivr = f"https://cdn.jsdelivr.net/gh/{owner}/{repo}@{branch}/{path}"
            out = [jsdelivr, url, "https://gh-proxy.com/" + url]
    return out


def fetch(url: str, dest: Path, refresh: bool = False) -> bytes:
    if dest.exists() and not refresh:
        return dest.read_bytes()
    dest.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    curl = shutil.which("curl")
    for candidate in mirror_urls(url):
        for _ in range(2):
            tmp = dest.with_name(dest.name + ".part")
            try:
                if curl:
                    proc = subprocess.run(
                        [
                            curl,
                            "-fsSL",
                            "--connect-timeout",
                            "5",
                            "--max-time",
                            "60",
                            "-A",
                            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                            "(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
                            "-o",
                            str(tmp),
                            candidate,
                        ],
                        capture_output=True,
                        text=True,
                        timeout=150,
                    )
                    if proc.returncode != 0:
                        raise RuntimeError(proc.stderr.strip() or f"curl rc={proc.returncode}")
                    data = tmp.read_bytes()
                else:
                    req = urllib.request.Request(candidate, headers={"User-Agent": "Mozilla/5.0"})
                    with urllib.request.urlopen(req, timeout=60) as resp:
                        data = resp.read()
                    tmp.write_bytes(data)
                if not data:
                    raise ValueError("empty response")
                tmp.replace(dest)
                return data
            except Exception as exc:  # noqa: BLE001 - network fallback
                last_error = exc
                print(f"WARN: fetch failed ({candidate}): {exc}", file=sys.stderr)
                try:
                    tmp.unlink(missing_ok=True)
                except OSError:
                    pass
    raise RuntimeError(f"failed to fetch {url}: {last_error}")


def parse_domain_text(text: str) -> tuple[list[str], list[str]]:
    exact: set[str] = set()
    suffix: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("!"):
            continue
        if line.startswith("||"):
            line = line[2:].split("^", 1)[0]
        if line.startswith("+."):
            suffix.add(line[2:])
        elif line.startswith("*."):
            suffix.add(line[2:])
        elif line.startswith("."):
            suffix.add(line[1:])
        elif re.fullmatch(r"[0-9A-Za-z_.\-]+", line):
            exact.add(line)
    return sorted(exact), sorted(suffix)


def parse_ip_text(text: str) -> list[str]:
    out: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("!"):
            continue
        if line.upper().startswith("IP-CIDR") or line.upper().startswith("IP-CIDR6"):
            line = line.split(",", 1)[1] if "," in line else ""
        if re.fullmatch(r"[0-9A-Fa-f:.]+/\d{1,3}", line):
            out.add(line)
    return sorted(out)


def parse_list_text(text: str) -> tuple[list[str], list[str], list[str], list[str], list[str]]:
    exact: set[str] = set()
    suffix: set[str] = set()
    cidrs: set[str] = set()
    keywords: set[str] = set()
    regexes: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("!"):
            continue
        parts = [p.strip() for p in line.split(",")]
        typ = parts[0].upper()
        val = parts[1] if len(parts) > 1 else ""
        if typ == "DOMAIN":
            exact.add(val)
        elif typ == "DOMAIN-SUFFIX":
            suffix.add(val.lstrip("."))
        elif typ in ("IP-CIDR", "IP-CIDR6"):
            if re.fullmatch(r"[0-9A-Fa-f:.]+/\d{1,3}", val):
                cidrs.add(val)
        elif typ == "DOMAIN-KEYWORD":
            keywords.add(val)
        elif typ == "DOMAIN-REGEX":
            regexes.add(val)
    return sorted(exact), sorted(suffix), sorted(cidrs), sorted(keywords), sorted(regexes)


# anti-ad 会误收录业务域；广告规则又排在 BiliBili 等应用规则之前，
# 不剔除就会把 B 站小程序/埋点/dataflow 直接 REJECT-DROP（表现为 App 转圈）。
ADS_FALSE_POSITIVE_DOMAINS = frozenset(
    {
        "dataflow.biliapi.com",
        "line1-log.biligame.net",
        "miniapp.bilibili.com",
    }
)

# DouYin OCD 列表偏旧：评论区图床常用 byteimg / zjcdn，未收录时会漏出
# 「🎵 抖音」落到 geosite-cn / 漏网（现网国内总模式若切到负载均衡，图床短连接
# 更容易打到弱节点）。生成时强制并入 suffix，refresh 上游也不会丢。
DOUYIN_EXTRA_DOMAIN_SUFFIXES = (
    "byteimg.com",
    "zjcdn.com",
    "bytedance.com",
    "zijieapi.com",
    "bytegoofy.com",
)

# Dead subscription placeholders must never enter urltest/loadbalance.
# Provider tags are prefixed (e.g. ``1.中国国际机场/订阅暂不可用``); an
# include that matches geography in the provider *name* (``中国``) would
# otherwise health-check 127.0.0.1:1 every interval (2026-11-04 evidence).
DEAD_NODE_EXCLUDE = r"订阅暂不可用|请前往官网|暂不可用"


def _merge_dead_node_exclude(exclude: str) -> str:
    """Append DEAD_NODE_EXCLUDE to a group exclude regex (idempotent)."""
    if not exclude:
        return DEAD_NODE_EXCLUDE
    if "订阅暂不可用" in exclude and "请前往官网" in exclude:
        return exclude
    return f"(?:{exclude})|(?:{DEAD_NODE_EXCLUDE})"


def _provider_outbounds_are_dead(outbounds: list[Any]) -> bool:
    """True when every outbound is a known subscription-dead placeholder."""
    if not outbounds:
        return True
    dead_needles = ("订阅暂不可用", "请前往官网", "暂不可用")
    for o in outbounds:
        if not isinstance(o, dict):
            return False
        tag = str(o.get("tag") or "")
        if not any(n in tag for n in dead_needles):
            # socks sink used by older placeholder writers
            if o.get("type") == "socks" and o.get("server") == "127.0.0.1" and int(o.get("server_port") or 0) == 1:
                continue
            return False
    return True


def _strip_ads_false_positives(rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for rule in rules:
        cleaned: dict[str, Any] = {}
        for key, val in rule.items():
            if key in ("domain", "domain_suffix") and isinstance(val, list):
                kept = [d for d in val if str(d).lower() not in ADS_FALSE_POSITIVE_DOMAINS]
                if kept:
                    cleaned[key] = kept
            else:
                cleaned[key] = val
        if cleaned:
            out.append(cleaned)
    return out


def _merge_douyin_extras(rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    extras = {d.lower() for d in DOUYIN_EXTRA_DOMAIN_SUFFIXES}
    suffix: set[str] = set()
    exact: set[str] = set()
    other: list[dict[str, Any]] = []
    for rule in rules:
        if "domain_suffix" in rule and set(rule) <= {"domain_suffix"}:
            suffix.update(str(d).lower() for d in (rule.get("domain_suffix") or []))
        elif "domain" in rule and set(rule) <= {"domain"}:
            # Promote exact hosts that already sit under an extra suffix.
            for d in rule.get("domain") or []:
                host = str(d).lower()
                if any(host == s or host.endswith("." + s) for s in extras):
                    continue
                exact.add(host)
        else:
            other.append(rule)
    suffix |= extras
    out: list[dict[str, Any]] = []
    if suffix:
        out.append({"domain_suffix": sorted(suffix)})
    if exact:
        out.append({"domain": sorted(exact)})
    out.extend(other)
    return out


def rule_set_source(spec: RuleSetSpec, refresh: bool) -> dict[str, Any]:
    cache_name = spec.tag + (".list" if spec.kind == "list" else ".txt")
    raw = fetch(spec.url, CACHE / cache_name, refresh).decode("utf-8", "replace")
    if spec.kind == "domain":
        exact, suffix = parse_domain_text(raw)
        rules = []
        if suffix:
            rules.append({"domain_suffix": suffix})
        if exact:
            rules.append({"domain": exact})
    elif spec.kind == "ip":
        cidrs = parse_ip_text(raw)
        rules = [{"ip_cidr": cidrs}] if cidrs else []
    elif spec.kind == "list":
        exact, suffix, cidrs, keywords, regexes = parse_list_text(raw)
        rules = []
        if suffix:
            rules.append({"domain_suffix": suffix})
        if exact:
            rules.append({"domain": exact})
        if keywords:
            rules.append({"domain_keyword": keywords})
        if regexes:
            rules.append({"domain_regex": regexes})
        if cidrs:
            rules.append({"ip_cidr": cidrs})
    else:
        raise ValueError(f"unknown rule-set kind: {spec.kind}")
    if spec.tag == "no-ads-all":
        rules = _strip_ads_false_positives(rules)
    if spec.tag == "douyin":
        rules = _merge_douyin_extras(rules)
    return {"version": 1, "rules": rules}


def fmt_duration(seconds: int | str | None, default: str = "5m") -> str:
    if seconds is None:
        return default
    seconds = int(seconds)
    if seconds % 3600 == 0:
        return f"{seconds // 3600}h"
    if seconds % 60 == 0:
        return f"{seconds // 60}m"
    return f"{seconds}s"


def parse_filter(expr: str) -> tuple[str, str]:
    """Split a Clash PCRE filter into RE2-compatible include/exclude."""
    if not expr:
        return "", ""
    s = expr.strip()
    flags = ""
    if s.startswith("(?i)"):
        flags = "(?i)"
        s = s[4:]

    positives: list[str] = []
    negatives: list[str] = []
    leftover: list[str] = []
    i = 0
    while i < len(s):
        if s.startswith("(?=", i) or s.startswith("(?!", i):
            marker = s[i : i + 3]
            depth = 0
            j = i
            while j < len(s):
                if s[j] == "(":
                    depth += 1
                elif s[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            content = s[i + 3 : j]
            if content.startswith(".*"):
                content = content[2:]
            if content.startswith("(") and content.endswith(")"):
                content = content[1:-1]
            (positives if marker == "(?=" else negatives).append(content)
            i = j + 1
        else:
            leftover.append(s[i])
            i += 1

    rest = "".join(leftover)
    rest = rest.replace("^", "").replace("$", "")
    rest = re.sub(r"\(\s*\)", "", rest)
    rest = re.sub(r"\(\.\*\)", "", rest)
    rest = rest.strip("().*")
    if rest:
        positives.append(rest)

    include = "|".join(x for x in positives if x)
    exclude = "|".join(x for x in negatives if x)
    if flags:
        include = flags + include if include else include
        exclude = flags + exclude if exclude else exclude
    return include, exclude


OUTBOUND_ALIAS = {"DIRECT": DIRECT_TAG}
IPV6_AUTO_TAG = "⚡ IPv6·自动选择"
# Dedicated direct dialer for the home NAS / Emby DDNS: those names are
# IPv6-only (AAAA, no A).  The global route.default_domain_resolver is
# ipv4_only (三卡分流), which returns empty for such names — so nasipv6 must
# not reuse 🌐 本机·本地直连.
NAS_DIRECT_TAG = "🌐 NAS·IPv6直连"
NAS_DDNS_SUFFIX = "example.invalid"
# Subscription hosts that fingerprint proxied fetches and return a stub
# ("请关闭VPN更新订阅").  Device-side update-providers must hit them DIRECT
# (cellular), not through 免流/fake-ip.  User-confirmed 2026-11-05 for
# 中国国际机场 / carpetpacific.com — narrow exception to zero-direct.
SUBSCRIPTION_DIRECT_SUFFIXES = ("carpetpacific.com",)

DEFAULT_OVERRIDES = {
    # 国内走免流节点；国外走正常国外节点（可靠）；需要全免流时在面板把
    # 🌍 国外总模式 / 🐟 漏网之鱼 切到 🚀 免流模式。`ebpf-allproxy` 就是那档
    # （见 ALL_PROXY_DEFAULT_OVERRIDES）。
    "🎯 国内总模式": "🚀 免流模式",
    "🌍 国外总模式": "⚡ ALL·国外延迟最低",
    "🐟 漏网之鱼": "🌍 国外总模式",
    "🚀 专线机场": DIRECT_TAG,
    # §36: 评论区图床短连接在「国内总模式→负载均衡」下易打到弱节点；
    # 默认直接走国内 urltest，重启后不再丢面板临时 PUT。
    "🎵 抖音": "⚡ ALL·国内延迟最低",
    # Home UGREEN NAS / Emby / SubStore on IPv6-only DDNS.  2026-11-05: cellular
    # IPv6 DIRECT to sub/nas.example.invalid works (HTTP 200); default to
    # 放行 so subscription refreshes and NAS hits skip the airport v6 pool.
    "🌐 nasipv6": NAS_DIRECT_TAG,
    # Clash proxy-provider downloads (and panel「更新」) must not hairpin 免流.
    "🔄 订阅更新": DIRECT_TAG,
}

MIANLIU_NODES = [
    "dxy3884-汇总",
    "dxy3880-独立",
    "dxy3881-全局",
    "dxy6666-免流",
    "dxy80",
    "国内-80-电信免流",
    "国内-80-电信免流-v2",
    "国内-8080-联通免流",
    "国内-8080-联通免流-v2",
    "国内-80-阿里免流-v2",
    "国内-8080-紅卡免流-v2",
    "国内-杭州-101.37.66.215",
    "国内-南京-129.211.188.71",
]
MIANLIU_TAG = "🚀 免流模式"
MIANLIU_AUTO_TAG = "⚡ 免流·自动选择"
FINAL_TAG = "🐟 漏网之鱼"
DIRECT_GROUP_TAG = "🟢 直连模式"
BOOTSTRAP_DNS_SERVER = "223.5.5.5"
# Resolver the proxy-server hostnames depend on.  It must stay the same
# resolver the TUN stack used: the node domain is multi-homed, and a different
# resolver answers with an address that times out (measured 2026-10-31).
BOOTSTRAP_DNS_NAME = "doh.pub"
# sing-box's self-bypass mark.  The TUN stack gets it from auto_redirect; eBPF
# profiles have to spell it out so mwan3's 0x3f00 rules keep skipping proxy
# egress and singbox-wan-balance.sh can pick a WAN per connection.
PROXY_MARK = 0x2024
# Broad IPv6 marker (foreign + domestic). NAS / IPv6-auto pools use this:
# cellular has no route to the home AAAA, and the sole CNˇ⁶ node
# (AAAA-only hostname) timed out dialling its own server from this WAN.
IPV6_FILTER = r"(?i)(\[v6\]|⁶|\| ipv6|｜IPV6)"
# Narrower CN-only variant kept for docs / one-off experiments.
IPV6_CN_FILTER = (
    r"(?i)((CN|国内).{0,48}(\[v6\]|⁶|\|\s*ipv6|｜IPV6))"
    r"|((^|/)CN[^/\n]*⁶)"
)
NASIPV6_TAG = "🌐 nasipv6"
DOMESTIC_MODE_TAG = "🎯 国内总模式"
FOREIGN_MODE_TAG = "🌍 国外总模式"
SUB_UPDATE_TAG = "🔄 订阅更新"
# Groups that may *list* a direct dialer on all-proxy profiles as a manual
# panel escape. Automatic path is still enforced by defaults (免流/proxy) and
# default-chain reachability in validate_zero_direct — not full membership.
# 2026-11-05: DIRECT visible under 国内/国外总模式 + nasipv6 + 订阅更新放行.
ALL_PROXY_DIRECT_OK_GROUPS = frozenset(
    {NASIPV6_TAG, DOMESTIC_MODE_TAG, FOREIGN_MODE_TAG, SUB_UPDATE_TAG}
)

# All-proxy profile selector defaults: every public path must proxy, so the
# groups that used to default to DIRECT now default to a proxied node.
ALL_PROXY_DEFAULT_OVERRIDES = {
    **DEFAULT_OVERRIDES,
    "🌍 国外总模式": MIANLIU_TAG,
    "🐟 漏网之鱼": MIANLIU_TAG,
    "🚀 专线机场": "⚡ 专线机场·自动选择",
    NASIPV6_TAG: NAS_DIRECT_TAG,
    SUB_UPDATE_TAG: DIRECT_TAG,
}

# For the all-proxy profile a source ``DIRECT`` target is remapped to
# MIANLIU_TAG.  Only LAN/management resolution stays direct: those
# destinations never leave the box.  The 14 PT/BT sites used to stay direct
# for share ratio; removed 2026-10-31 (用户拍板：免流 = 全部公网流量走代理).
DIRECT_KEEP_RULE_SETS = {"private-domain", "private-ip"}
DIRECT_KEEP_SUFFIXES = (".lan", ".local", ".localdomain", ".in-addr.arpa", ".ip6.arpa")

# A direct rule may only be anchored on the private rule-sets or local-use
# suffixes.  These keys are the whole allowed vocabulary: the three anchor
# fields, source/port narrowing that cannot add a public destination branch,
# and the routing envelope.  Anything else (ip_cidr, ip_is_private,
# domain_keyword, domain_regex, geosite, geoip, ...) is rejected conservatively.
PRIVATE_DIRECT_RULE_FIELDS = frozenset(
    {
        "type",
        "outbound",
        "action",
        "method",
        "rule_set",
        "domain",
        "domain_suffix",
        "network",
        "port",
        "source_port",
        "source_ip_cidr",
        "source_ip_is_private",
    }
)

# Device-local hook data planes accepted by the fork's eBPF inbound.  Selected
# at build time (``--ebpf-local-data-plane``); ``cgroup`` is the default and the
# only plane any generated profile has shipped, ``socket_assign`` is the
# experimental local-side A/B for the LAN stall investigation.  ``tc`` belongs
# to neither hook in this build and is rejected by name -- see
# :func:`check_local_data_plane` (no alias).
LOCAL_DATA_PLANES = ("cgroup", "socket_assign")

# Shared TC hook data planes accepted by the fork's eBPF inbound.  Selected at
# build time (``--ebpf-shared-data-plane``); ``packet_rewrite`` is the default
# and the only value any production profile used so far, ``socket_assign`` is
# the experimental A/B alternative for the LAN stall investigation.
SHARED_DATA_PLANES = ("packet_rewrite", "socket_assign")

# Loopback-only API the ``sing-box api ebpf --url http://127.0.0.1:8088``
# diagnostics talk to (gRPC; the Clash API on 9999 is a different protocol).
DIAGNOSTICS_API_PORT = 8088

GROUP_OUTBOUND_TYPES = ("selector", "urltest", "loadbalance")


def synthetic_groups(all_proxy: bool = False) -> list[dict[str, Any]]:
    """Built-in groups.

    ``🟢 直连模式`` exists only outside all-proxy profiles.  Zero-rating governs
    the automatic path *and* the panel there: the user decided 2026-10-31 that
    no direct entry may be reachable, so the manual override group is omitted
    and ``🚀 免流模式`` lists no ``DIRECT`` member either.
    """
    groups: list[dict[str, Any]] = [
        {
            "type": "urltest",
            "tag": MIANLIU_AUTO_TAG,
            "outbounds": MIANLIU_NODES,
            "url": "http://connect.rom.miui.com/generate_204",
            "interval": "5m",
            "tolerance": 50,
        },
        {
            "type": "selector",
            "tag": MIANLIU_TAG,
            "outbounds": MIANLIU_NODES
            + [MIANLIU_AUTO_TAG]
            + ([] if all_proxy else [DIRECT_TAG])
            + [BLOCK_TAG],
            "default": "国内-8080-联通免流-v2",
        },
    ]
    if not all_proxy:
        groups.append(
            {
                "type": "selector",
                "tag": DIRECT_GROUP_TAG,
                "outbounds": [DIRECT_TAG, BLOCK_TAG],
                "default": DIRECT_TAG,
            }
        )
    groups.append(
        {
            "type": "urltest",
            "tag": IPV6_AUTO_TAG,
            "outbounds": [],
            # All v6-labelled nodes (CN + foreign). Cellular DIRECT cannot
            # reach the home AAAA; foreign IPV6 exits are the working pool.
            "providers": [
                "1.中国国际机场",
                "2.快跑",
                "3.桃花源",
                "6.果冻",
                "9.CG",
            ],
            "include": IPV6_FILTER,
            "url": "https://ipv6.baidu.com/",
            "interval": "5m",
            "tolerance": 50,
        }
    )
    return groups


def nas_direct_outbound(
    resolver: str = "bootstrap",
    bind_interface: str = "rmnet_data0",
) -> dict[str, Any]:
    """Direct dialer that can resolve IPv6-only DDNS (Emby / UGREEN NAS).

    Bind to the 5G WAN (``rmnet_data0``): only that card has a working IPv6
    default.  A wrong source/iface pick otherwise yields
    ``connect: network is unreachable`` even when ``ip -6 route get`` looks fine.
    """
    # Keep route.default_mark (0x2024): clearing it re-captures the dial under
    # eBPF socket_assign and surfaces as network-unreachable.
    # prefer_ipv6 (not ipv6_only): AAAA-only NAS DDNS still dials; panel delay
    # tests that hit dual-stack hosts (gstatic) can fall back to A instead of
    # always failing as "没网" under ipv6_only + CM overseas v6 blackhole.
    out: dict[str, Any] = {
        "type": "direct",
        "tag": NAS_DIRECT_TAG,
        "domain_resolver": {"server": resolver, "strategy": "prefer_ipv6"},
    }
    if bind_interface:
        out["bind_interface"] = bind_interface
    return out


def normalize_subscription_url(url: str) -> str:
    """Force SubStore/Clash downloads into sing-box JSON for remote providers.

    Zashboard's provider refresh is ``PUT /providers/proxies/{name}``. That only
    re-fetches when the provider is ``type: remote`` and the URL returns a
    sing-box ``{"outbounds":[...]}`` document. Clash YAML (prettyYaml / ClashMeta)
    must be converted by SubStore via ``target=singbox``.
    """
    url = (url or "").strip()
    if not url:
        return url
    if "target=ClashMeta" in url:
        url = url.replace("target=ClashMeta", "target=singbox")
    if "target=" not in url:
        url += ("&" if "?" in url else "?") + "target=singbox"
    return url


def _provider_user_agent(proxy_provider: dict[str, Any]) -> str:
    headers = proxy_provider.get("header") or {}
    ua_list = headers.get("User-Agent") or headers.get("user-agent")
    if isinstance(ua_list, list):
        return str(ua_list[0]) if ua_list else "clash-verge/v2.2.3"
    return str(ua_list or "clash-verge/v2.2.3")


def remote_provider_entry(
    *,
    name: str,
    idx: int,
    url: str,
    user_agent: str,
    health_check_url: str,
    health_check_interval: str,
    base: str,
    all_proxy: bool,
) -> dict[str, Any]:
    """Build a Clash-API-refreshable remote provider (panel「更新」works).

    Download detours through ``🌐 NAS·IPv6直连`` for home SubStore
    (``*.example.invalid``, AAAA-only) or ``🌐 本机·本地直连`` otherwise so
    VPN-detect / IPv6-only hosts are not fetched via 免流.
    """
    url = normalize_subscription_url(url)
    # 中国国际机场：NAS 桥 ~6h 写 SubStore；消费端必须同量级拉取，并 bypass
    # SubStore 产物缓存，否则会一直吃旧节点。
    if "中国国际" in name or "%E5%9B%BD%E9%99%85" in url or "/国际" in url:
        if "noCache=" not in url:
            url += ("&" if "?" in url else "?") + "noCache=true"
        update_interval = "6h"
    else:
        update_interval = "24h"
    path = f"{base}/providers/p{idx}.json" if base else f"providers/p{idx}.json"
    # SubStore / home NAS DDNS is IPv6-only; carpetpacific etc. are dual-stack.
    if NAS_DDNS_SUFFIX in url:
        detour = NAS_DIRECT_TAG
        resolver: dict[str, Any] = {"server": "bootstrap" if all_proxy else "ali", "strategy": "prefer_ipv6"}
    else:
        detour = DIRECT_TAG
        resolver = {"server": "bootstrap" if all_proxy else "ali"}
    return {
        "type": "remote",
        "tag": name,
        "url": url,
        "path": path,
        "update_interval": update_interval,
        "http_client": {
            "detour": detour,
            "domain_resolver": resolver,
            "connect_timeout": "20s",
            "headers": {"User-Agent": [user_agent or "clash-verge/v2.2.3"]},
        },
        "health_check": {
            # Group urltest/loadbalance does its own checks; avoid startup storms.
            "enabled": False,
            "url": health_check_url,
            "interval": health_check_interval,
            "timeout": "3s",
        },
    }


def patch_provider_v6_domain_resolver(path: Path, resolver: str = "bootstrap") -> int:
    """Force ipv6_only domain_resolver on v6-labelled provider nodes.

    Those nodes often publish AAAA-only hostnames (e.g. ``v6-node.example.invalid``).
    With ``route.default_domain_resolver.strategy=ipv4_only`` the dialer gets
    ``lookup …: empty result`` and the whole NAS path 502s.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 0
    changed = 0
    for outbound in data.get("outbounds") or []:
        tag = str(outbound.get("tag") or "")
        if not re.search(IPV6_FILTER, tag):
            continue
        if outbound.get("type") not in {
            "vmess",
            "vless",
            "trojan",
            "shadowsocks",
            "hysteria2",
            "tuic",
            "anytls",
        }:
            continue
        want = {"server": resolver, "strategy": "ipv6_only"}
        if outbound.get("domain_resolver") != want:
            outbound["domain_resolver"] = want
            changed += 1
    if changed:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return changed


def split_top(s: str, sep: str = ",") -> list[str]:
    parts: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


def parse_atom(atom: str) -> dict[str, Any] | None:
    parts = split_top(atom)
    typ = parts[0].strip().upper()
    val = parts[1].strip() if len(parts) > 1 else ""
    if typ == "NETWORK":
        return {"network": [val.lower()]}
    if typ == "DST-PORT":
        return {"port": [int(val)]}
    if typ == "SRC-PORT":
        return {"source_port": [int(val)]}
    if typ == "DOMAIN":
        return {"domain": [val]}
    if typ == "DOMAIN-SUFFIX":
        return {"domain_suffix": [val.lstrip(".")]}
    if typ == "DOMAIN-KEYWORD":
        return {"domain_keyword": [val]}
    if typ == "DOMAIN-REGEX":
        return {"domain_regex": [val]}
    if typ in ("IP-CIDR", "IP-CIDR6"):
        return {"ip_cidr": [val]}
    if typ == "SRC-IP-CIDR":
        return {"source_ip_cidr": [val]}
    if typ == "RULE-SET":
        tag = ORIGINAL_TO_TAG.get(val)
        if not tag:
            raise ValueError(f"unknown rule-set in atom: {val}")
        return {"rule_set": [tag]}
    if typ == "GEOSITE":
        return {"rule_set": [f"geosite-{val.lower()}"]}
    if typ == "GEOIP":
        return {"rule_set": [f"geoip-{val.lower()}"]}
    if typ == "PROCESS-NAME":
        return None
    raise ValueError(f"unsupported rule atom: {atom}")


def apply_target(rule: dict[str, Any], target: str) -> dict[str, Any]:
    if target == DNS_HIJACK_TAG:
        rule["action"] = "hijack-dns"
    elif target in ("REJECT", "REJECT-DROP"):
        rule["action"] = "reject"
        if target == "REJECT-DROP":
            rule["method"] = "drop"
    else:
        rule["outbound"] = OUTBOUND_ALIAS.get(target, target)
    return rule


def parse_rule(rule: str) -> tuple[str, Any] | None:
    """Return ('rule', dict) or ('final', tag) or None to drop."""
    rule = rule.strip()
    if not rule:
        return None
    parts = split_top(rule)
    typ = parts[0].strip().upper()

    if typ == "MATCH":
        return ("final", OUTBOUND_ALIAS.get(parts[1].strip(), parts[1].strip()))
    if typ == "AND":
        payload = parts[1].strip()
        if payload.startswith("(") and payload.endswith(")"):
            payload = payload[1:-1]
        atoms: list[dict[str, Any]] = []
        depth = 0
        cur: list[str] = []
        groups: list[str] = []
        for ch in payload:
            if ch == "(":
                depth += 1
                if depth == 1:
                    continue
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    groups.append("".join(cur))
                    cur = []
                    continue
            if depth == 0 and ch == ",":
                continue
            cur.append(ch)
        for group in groups:
            atom = parse_atom(group)
            if atom is None:
                print(f"WARN: dropping AND rule with unsupported atom: {rule}", file=sys.stderr)
                return None
            atoms.append(atom)
        target = parts[2].strip() if len(parts) > 2 else ""
        return ("rule", apply_target({"type": "logical", "mode": "and", "rules": atoms}, target))

    # simple rule: TYPE,VALUE,TARGET[,no-resolve]
    target = parts[2].strip() if len(parts) > 2 else ""
    if target == "no-resolve":
        target = parts[3].strip() if len(parts) > 3 else ""
    atom = parse_atom(rule)
    if atom is None:
        print(f"WARN: dropping unsupported rule: {rule}", file=sys.stderr)
        return None
    return ("rule", apply_target(atom, target))


def convert_proxy(p: dict[str, Any], resolver: str = "ali") -> dict[str, Any] | None:
    typ = p.get("type")
    name = p["name"]
    if typ == "dns":
        return None
    if typ == "direct":
        return {
            "type": "direct",
            "tag": name,
            "domain_resolver": {"server": resolver},
            "tcp_fast_open": True,
        }
    if typ == "reject":
        return {"type": "block", "tag": name}
    if typ != "vmess":
        raise ValueError(f"unsupported proxy type {typ!r} for {name!r}")

    out: dict[str, Any] = {
        "type": "vmess",
        "tag": name,
        "server": p["server"],
        "server_port": int(p["port"]),
        "uuid": p["uuid"],
        "security": p.get("cipher") or "auto",
        "alter_id": int(p.get("alterId") or 0),
    }
    if p.get("tls"):
        tls: dict[str, Any] = {"enabled": True}
        server_name = p.get("servername") or p.get("sni")
        if server_name:
            tls["server_name"] = server_name
        if p.get("skip-cert-verify"):
            tls["insecure"] = True
        if p.get("alpn"):
            tls["alpn"] = p["alpn"]
        out["tls"] = tls

    network = (p.get("network") or "tcp").lower()
    if network == "ws":
        opts = p.get("ws-opts") or {}
        headers = {str(k): str(v) for k, v in (opts.get("headers") or {}).items()}
        transport: dict[str, Any] = {"type": "ws", "path": opts.get("path") or "/"}
        if headers:
            transport["headers"] = headers
        out["transport"] = transport
    elif network in ("http", "h2"):
        opts = p.get("http-opts") or {}
        hosts = opts.get("headers", {}).get("Host") or []
        if isinstance(hosts, str):
            hosts = [hosts]
        transport = {"type": "http", "path": (opts.get("path") or ["/"])[0], "method": opts.get("method") or "GET"}
        if hosts:
            transport["host"] = hosts
        headers = {
            str(k): str(v[0] if isinstance(v, list) else v)
            for k, v in (opts.get("headers") or {}).items()
            if k.lower() != "host"
        }
        if headers:
            transport["headers"] = headers
        out["transport"] = transport
    elif network not in ("tcp", ""):
        raise ValueError(f"unsupported transport {network!r} for {name!r}")
    return out


def convert_group(
    g: dict[str, Any], allowed_providers: set[str], all_proxy: bool = False
) -> dict[str, Any]:
    gtype = g["type"]
    tag = g["name"]
    explicit = [x for x in (g.get("proxies") or []) if x != DNS_HIJACK_TAG]
    providers = [x for x in (g.get("use") or []) if x in allowed_providers]
    if providers and explicit and all(x in (DIRECT_TAG, BLOCK_TAG, REJECT_DROP_TAG) for x in explicit):
        # Clash inserts provider nodes before bare direct/reject members; a
        # selector whose only explicit members are direct/reject should default
        # to a provider node instead of silently going DIRECT.
        explicit = []
    elif providers:
        tail = [x for x in explicit if x in (DIRECT_TAG, BLOCK_TAG, REJECT_DROP_TAG)]
        explicit = [x for x in explicit if x not in tail] + tail
    if all_proxy and tag not in ALL_PROXY_DIRECT_OK_GROUPS:
        # Zero-direct applies to *every* selector/urltest/loadbalance, even the
        # ones no route rule currently reaches: the panel is part of the
        # automatic path once a user clicks, and 2026-10-31 forbids any direct
        # entry there (HANDOVER §32.2 item 5).  Exception: 🌐 nasipv6 may keep
        # DIRECT because the home NAS is on domestic-broadband DDNS.
        explicit = [x for x in explicit if x != DIRECT_TAG]
    if not explicit and not providers:
        explicit = [BLOCK_TAG]
    if tag == NASIPV6_TAG:
        # Order: NAS IPv6 direct (default 放行) → v6 proxy auto → rest.
        # 2026-11-05: cellular IPv6 DIRECT reaches the home AAAA again.
        rest = [
            x
            for x in explicit
            if x not in (DIRECT_TAG, NAS_DIRECT_TAG, IPV6_AUTO_TAG)
        ]
        explicit = [NAS_DIRECT_TAG, IPV6_AUTO_TAG] + rest
    if tag in ("🌍 国外总模式", "🎯 国内总模式", "🐟 漏网之鱼"):
        explicit = [MIANLIU_TAG] + [x for x in explicit if x != MIANLIU_TAG]
        # ``🟢 直连模式`` is not generated for all-proxy profiles; do not point
        # at it there either.  The proxied groups above already cover the path.
        if not all_proxy and DIRECT_GROUP_TAG not in explicit:
            if DIRECT_TAG in explicit:
                explicit.insert(explicit.index(DIRECT_TAG), DIRECT_GROUP_TAG)
            else:
                explicit.append(DIRECT_GROUP_TAG)
    include, exclude = parse_filter(g.get("filter") or "")
    if tag == NASIPV6_TAG:
        include, exclude = IPV6_FILTER, ""
    if providers:
        exclude = _merge_dead_node_exclude(exclude)

    if gtype == "select":
        out: dict[str, Any] = {"type": "selector", "tag": tag, "outbounds": explicit}
        if providers:
            out["providers"] = providers
        if include:
            out["include"] = include
        if exclude:
            out["exclude"] = exclude
        if explicit:
            overrides = ALL_PROXY_DEFAULT_OVERRIDES if all_proxy else DEFAULT_OVERRIDES
            preferred = overrides.get(tag, explicit[0])
            out["default"] = preferred if preferred in explicit else explicit[0]
        return out

    if gtype in ("url-test", "fallback"):
        out = {
            "type": "urltest",
            "tag": tag,
            "outbounds": explicit,
            "url": g.get("url") or "https://www.gstatic.com/generate_204",
            "interval": fmt_duration(g.get("interval")),
            "tolerance": int(g.get("tolerance") or 50),
        }
        if providers:
            out["providers"] = providers
        if include:
            out["include"] = include
        if exclude:
            out["exclude"] = exclude
        return out

    if gtype == "load-balance":
        # Clash `load-balance` 只有 round-robin / consistent-hashing /
        # sticky-sessions 三种策略（mihomo 默认 consistent-hashing），fork 的
        # loadbalance 三种都接受（实测 `sing-box check` 全部通过）；
        # 源码写了 strategy 就原样透传，没写才退回 consistent-hashing。
        #
        # Weak-net (2026-11-02): keep consistent-hashing for CDN affinity
        # (Bilibili/Douyin), but do not glue a destination to a dead member
        # for 10 minutes. Force a 1-minute health cadence and hash TTL so a
        # failed node is dropped from the pool and remapped quickly. The
        # Clash source interval is ignored here on purpose.
        out = {
            "type": "loadbalance",
            "tag": tag,
            "strategy": g.get("strategy") or "consistent-hashing",
            "outbounds": explicit,
            "url": g.get("url") or "https://www.gstatic.com/generate_204",
            "interval": "1m",
            "ttl": "1m",
        }
        if providers:
            out["providers"] = providers
        if include:
            out["include"] = include
        if exclude:
            out["exclude"] = exclude
        return out

    raise ValueError(f"unsupported group type {gtype!r} for {tag!r}")


def fakeip_dns_rule(filters: list[str]) -> dict[str, Any] | None:
    exact: list[str] = []
    suffix: list[str] = []
    for item in filters:
        if item.startswith("+."):
            suffix.append("." + item[2:])
        elif item.startswith("*."):
            suffix.append("." + item[2:])
        elif item.startswith("."):
            suffix.append(item)
        else:
            exact.append(item)
    rule: dict[str, Any] = {}
    if suffix:
        rule["domain_suffix"] = suffix
    if exact:
        rule["domain"] = exact
    if not rule:
        return None
    rule["server"] = "ali"
    return rule


LOCAL_DNS_SUFFIXES = (".lan", ".local", ".localdomain", ".in-addr.arpa", ".ip6.arpa")


def local_only_filter(filters: list[str]) -> list[str]:
    """Keep only the LAN/local entries of a Clash ``fake-ip-filter``.

    The original list also excludes CN domains from fake-ip so they resolve to
    real addresses.  That is wrong under zero-rating: a CN domain answered with
    a real AAAA makes the client open a real v6 flow, the 免流 nodes have no v6
    egress, and the connection dies while the A record works.  Every public
    flow is proxied anyway, so those domains belong in fake-ip too.
    """
    keep: list[str] = []
    for item in filters:
        core = (item[2:] if item.startswith(("+.", "*.")) else item).lstrip(".").lower()
        if core in ("localhost", "local") or any(
            core == suffix.lstrip(".") or core.endswith(suffix) for suffix in LOCAL_DNS_SUFFIXES
        ):
            keep.append(item)
    return keep


def _is_ip_literal(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def build_dns(
    clash: dict[str, Any],
    all_proxy: bool = False,
    node_domains: Iterable[str] = (),
) -> dict[str, Any]:
    dns = clash.get("dns") or {}
    # Zero-rating: client DNS is content, so the DoH resolvers detour through
    # 🚀 免流模式.  ``bootstrap`` is the *only* structural exception: it resolves
    # the proxy-server hostnames themselves, so it cannot ride the proxy it is
    # needed to reach.  All-proxy profiles therefore emit no second unproxied
    # resolver and no separate node resolver: one unproxied UDP hop is the
    # documented limit (HANDOVER §32.3).
    #
    # KNOWN RISK: 223.5.5.5 was measured on 2026-10-31 answering the node
    # domain with a timing-out address (101.37.66.215) where doh.pub returned a
    # working one (180.110.193.140).  The device is verified separately with
    # check + automatic rollback; do not "fix" this by adding a direct DoH
    # resolver here -- that reintroduces the exemption the contract forbids.
    via = {"detour": MIANLIU_TAG} if all_proxy else {}
    # ``bootstrap`` is plain UDP and never serves a client query.  Non-all-proxy
    # profiles keep ``nodes`` (direct doh.pub) as the resolver for proxy server
    # hostnames, matching the stack that has been running on the device.
    servers: list[dict[str, Any]] = [
        {"tag": "bootstrap", "type": "udp", "server": BOOTSTRAP_DNS_SERVER},
    ]
    if not all_proxy:
        servers.append(
            {
                "tag": "nodes",
                "type": "https",
                "server": BOOTSTRAP_DNS_NAME,
                "domain_resolver": "bootstrap",
            }
        )
    servers += [
        {"tag": "ali", "type": "https", "server": BOOTSTRAP_DNS_NAME, "domain_resolver": "bootstrap", **via},
        {"tag": "ali2", "type": "https", "server": "dns.alidns.com", "domain_resolver": "bootstrap", **via},
        {
            "tag": "google",
            "type": "tls",
            "server": "8.8.8.8",
            "detour": "🌍 国外总模式",
            "domain_resolver": "bootstrap",
        },
        {
            "tag": "fakeip",
            "type": "fakeip",
            "inet4_range": "198.18.0.0/16",
            "inet6_range": "fdfe:dcba:9876::/64",
        },
    ]

    rules: list[dict[str, Any]] = []
    if all_proxy:
        # Node hostnames must resolve to real addresses, never to fake-ip: a
        # fake address cannot be dialled, and a poisoned answer turns every
        # proxied flow into 502.  First rule wins, so this precedes fake-ip.
        # Bootstrap is the only resolver exempt from the proxy detour, so it is
        # also the only one that can answer this: no separate direct node
        # resolver is generated for all-proxy profiles (HANDOVER §32.3).
        # Provider nodes come from files at runtime, so this covers the static
        # list; their lookups go through route.default_domain_resolver anyway.
        nodes = sorted({d.lower() for d in node_domains})
        if nodes:
            rules.append({"domain": nodes, "server": "bootstrap"})
        # Home NAS / Emby DDNS is IPv6-only.  It must hit bootstrap *before*
        # the global AAAA→fakeip rule, otherwise clients get fdfe:dcba:9876::
        # and the dialer (ipv4_only) cannot rediscover the real AAAA.
        rules.append(
            {
                "domain_suffix": [NAS_DDNS_SUFFIX],
                "server": "bootstrap",
                "rewrite_ttl": 60,
            }
        )
        # Subscription DIRECT domains need a real A/AAAA from bootstrap;
        # fake-ip would make the DIRECT dial useless.
        if SUBSCRIPTION_DIRECT_SUFFIXES:
            rules.append(
                {
                    "domain_suffix": list(SUBSCRIPTION_DIRECT_SUFFIXES),
                    "server": "bootstrap",
                    "rewrite_ttl": 60,
                }
            )
    filters = dns.get("fake-ip-filter") or []
    if all_proxy:
        filters = local_only_filter(filters)
    fw = fakeip_dns_rule(filters)
    if fw:
        rules.append(fw)
    if all_proxy:
        # AAAA -> fake-ip *before* the CN rule.  A real AAAA from ali sends the
        # client to a real v6 address, the 免流 nodes have no v6 egress, and the
        # connection dies while the A record works -- the "dual-stack 000"
        # failure.  With a fake v6 the flow carries the domain, and the node
        # resolves it over its own IPv4 exit: v6 clients stay proxied.
        # Exception: NAS_DDNS_SUFFIX already handled above.
        rules.append({"query_type": ["AAAA"], "server": "fakeip", "rewrite_ttl": 1})
    rules.append({"rule_set": ["geosite-cn"], "server": "ali"})
    rules.append(
        {
            "query_type": ["A"] if all_proxy else ["A", "AAAA"],
            "server": "fakeip",
            "rewrite_ttl": 1,
        }
    )

    return {
        "servers": servers,
        "rules": rules,
        "final": "ali",
        "strategy": "prefer_ipv6",
        "cache_capacity": 8192,
        "optimistic": {"enabled": True},
        "reverse_mapping": True,
    }


def _rule_has_invert(rule: dict[str, Any]) -> bool:
    """True when any level of a rule negates its match."""
    if rule.get("invert"):
        return True
    return any(_rule_has_invert(atom) for atom in rule.get("rules") or [] if isinstance(atom, dict))


def _local_host(value: str) -> bool:
    host = str(value).lstrip(".").lower()
    return any(
        host.endswith(suffix) or host == suffix.lstrip(".") for suffix in DIRECT_KEEP_SUFFIXES
    )


def _private_scoped(rule: dict[str, Any]) -> bool:
    """True when the rule can only match LAN/management destinations.

    Whole-field alternatives are checked, not an ``any`` over them: a rule_set
    list ``[private-domain, geosite-cn]`` or a suffix list ``[.lan, example.com]``
    ORs a public branch onto the DIRECT target, so it is not private-scoped.
    Only the private rule-sets (and local-use suffixes) qualify; a bare private
    ``ip_cidr`` does not broaden the exception.

    ``and`` is safe when any atom is private (the other atoms only narrow);
    ``or`` is safe only when *every* atom is private.  An empty logical rule
    matches everything, so it is never private-scoped.
    """
    if rule.get("type") == "logical":
        atoms = [atom for atom in rule.get("rules") or [] if isinstance(atom, dict)]
        if not atoms:
            return False
        if rule.get("mode") == "or":
            return all(_private_scoped(atom) for atom in atoms)
        return any(_private_scoped(atom) for atom in atoms)
    if set(rule) - PRIVATE_DIRECT_RULE_FIELDS:
        return False
    rule_sets = rule.get("rule_set") or []
    domains = (rule.get("domain") or []) + (rule.get("domain_suffix") or [])
    if rule_sets and not all(tag in DIRECT_KEEP_RULE_SETS for tag in rule_sets):
        return False
    if domains and not all(_local_host(domain) for domain in domains):
        return False
    return bool(rule_sets or domains)


def keeps_direct_target(rule: dict[str, Any]) -> bool:
    """True when a source ``DIRECT`` target must stay direct in all-proxy mode.

    Only LAN/management (``private-domain`` / ``private-ip`` and the local-use
    suffixes): those never leave the box, so proxying them breaks admin access
    and local resolution without saving any cellular data.  A negated or
    empty/partly-public match is rejected: it would let public traffic keep the
    DIRECT target while passing a rule-set check.
    """
    return not _rule_has_invert(rule) and _private_scoped(rule)


def drops_udp443_reject(rule: dict[str, Any]) -> bool:
    """The ``AND,((RULE-SET,douyin|tencent),(NETWORK,UDP),(DST-PORT,443)),REJECT`` pair.

    Those two rules exist to suppress QUIC.  In all-proxy mode a dropped QUIC
    packet is a leak-shaped hole (nothing gets proxied); removing them lets the
    later ``UDP + CN 域`` rules send the flow through the proxy instead.
    """
    if rule.get("type") != "logical" or rule.get("action") != "reject":
        return False
    atoms = rule.get("rules") or []
    if not any(atom.get("network") == ["udp"] for atom in atoms):
        return False
    if not any(443 in (atom.get("port") or []) for atom in atoms):
        return False
    return any(set(atom.get("rule_set") or []) & {"douyin", "tencent"} for atom in atoms)


def build_route(
    clash: dict[str, Any],
    base: str,
    final: str,
    used_tags: set[str],
    all_proxy: bool = False,
) -> dict[str, Any]:
    route_rules: list[dict[str, Any]] = [
        {"action": "sniff", "sniffer": ["http", "tls", "quic", "stun", "dns"], "timeout": "300ms"},
        {"protocol": ["dns"], "action": "hijack-dns"},
    ]
    for raw in clash.get("rules") or []:
        parsed = parse_rule(raw)
        if parsed is None:
            continue
        kind, value = parsed
        if kind == "final":
            final = value
            continue
        if all_proxy:
            if drops_udp443_reject(value):
                continue
            if value.get("outbound") == DIRECT_TAG and not keeps_direct_target(value):
                value = {**value, "outbound": MIANLIU_TAG}
        route_rules.append(value)

    if all_proxy:
        # Catch-all still goes through 🐟 漏网之鱼 so the panel selector is
        # live; that group's all-proxy default is 🚀 免流模式 (not a skip).
        final = FINAL_TAG
        # Emby / home NAS / SubStore DDNS: keep the 🌐 nasipv6 selector
        # (default = NAS·IPv6直连 放行; v6 proxy auto stays as fallback).
        for rule in route_rules:
            if rule.get("domain_suffix") == [NAS_DDNS_SUFFIX] and rule.get("outbound") in {
                DIRECT_TAG,
                NAS_DIRECT_TAG,
            }:
                rule["outbound"] = NASIPV6_TAG
        # Prepend subscription DIRECT exceptions (must win over geosite-cn /
        # 免流). Carpetpacific returns a VPN-detect stub when dialed via proxy.
        if SUBSCRIPTION_DIRECT_SUFFIXES:
            route_rules.insert(
                0,
                {
                    "domain_suffix": list(SUBSCRIPTION_DIRECT_SUFFIXES),
                    "outbound": DIRECT_TAG,
                },
            )

    # Keep IPv6 literal traffic on v6-capable airport nodes (nasipv6 group),
    # after CN/domain rules so CN v6 still follows the domestic path.
    if not all_proxy and "🌐 nasipv6" in {g.get("name") for g in clash.get("proxy-groups") or []}:
        route_rules.append({"ip_version": 6, "outbound": "🌐 nasipv6"})

    rule_sets: list[dict[str, Any]] = []
    for tag in sorted(used_tags):
        spec = TAG_TO_SPEC.get(tag)
        if not spec:
            raise ValueError(f"no spec for rule-set tag {tag!r}")
        if spec.kind == "srs":
            rule_sets.append(
                {
                    "type": "local",
                    "tag": tag,
                    "format": "binary",
                    "path": f"{base}/rules/{tag}.srs" if base else f"rules/{tag}.srs",
                }
            )
        else:
            rule_sets.append(
                {
                    "type": "local",
                    "tag": tag,
                    "format": "source",
                    "path": f"{base}/rules/{tag}.json" if base else f"rules/{tag}.json",
                }
            )

    return {
        "rules": route_rules,
        "rule_set": rule_sets,
        "final": final,
        "auto_detect_interface": False,
        # Node hostnames must resolve to IPv4: the three cellular WANs can be
        # load balanced only over IPv4 (IPv6 exists on the 5G card alone), and
        # a v6 node connection pins all proxied traffic to that one card.
        # Client-facing DNS keeps its own prefer_ipv6 strategy.
        # Non-all-proxy keeps ``nodes`` (direct doh.pub) like the running device
        # stack.  All-proxy may not carry a second unproxied resolver: node
        # hostnames go through ``bootstrap`` (the one structural exception),
        # which is also why the node-domain DNS rule targets it.
        "default_domain_resolver": {"server": "bootstrap" if all_proxy else "ali", "strategy": "ipv4_only"},
    }


def check_local_data_plane(value: str) -> str:
    """Validate a ``local`` hook data plane and return it (argparse ``type=``).

    ``tc`` is not a local hook value in this build: the fork's ``ebpf.local``
    accepts only cgroup or socket_assign.  Map it by name instead of aliasing
    it onto socket_assign, otherwise the diagnosis log and the config would
    disagree about which capture mechanism is actually attached.
    """
    if value == "tc":
        raise ValueError(
            "tc is not a valid ebpf.local data plane; use socket_assign "
            "(accepted: " + ", ".join(LOCAL_DATA_PLANES) + "; there is no tc alias)"
        )
    if value not in LOCAL_DATA_PLANES:
        raise ValueError(
            f"unknown local data plane {value!r}; expected one of "
            + ", ".join(LOCAL_DATA_PLANES)
        )
    return value


def cli_local_data_plane(value: str) -> str:
    """argparse adapter for :func:`check_local_data_plane`.

    argparse replaces a ValueError raised by ``type=`` with "invalid <callable>
    value", which drops the reason.  ArgumentTypeError keeps the message, so a
    `--ebpf-local-data-plane tc` on the command line still says there is no tc
    alias and names socket_assign.
    """
    try:
        return check_local_data_plane(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from None


def build_inbounds(
    profile: str,
    ebpf_interface: str,
    shared_data_plane: str = "packet_rewrite",
    local_data_plane: str = "cgroup",
) -> list[dict[str, Any]]:
    """Inbound set for the selected profile.

    ``base`` / ``tun-allproxy`` keep the production TUN stack.  ``ebpf-*``
    replaces TUN with the fork's experimental eBPF inbound (available in the
    1.14.4-reF1nd build, see docs/TELEGRAM-E58695-SINGBOX-DIGEST-2026-10-30.md §2):
      * ``local``  -> cgroup v2 socket-address hook, device-originated traffic,
        with ``local_data_plane`` selecting cgroup (default) or the
        experimental socket_assign A/B;
      * ``shared`` -> TC hook on the LAN bridge, downstream clients, with
        ``shared_data_plane`` selecting packet_rewrite (default) or the
        experimental socket_assign A/B.
    Admin ports must be bypassed on the shared path, otherwise TC ingress also
    hijacks management traffic addressed to 192.168.0.1.

    The plane selection per profile lives in :data:`EBPF_PROFILES`; the two
    ``ebpf-local-only`` / ``ebpf-local-shared`` entries are the staged
    migration pair (phase 1 = device traffic only, phase 2 = LAN clients too),
    which is why they spell out ``ipv6`` on every enabled hook.  Both also
    carry the all-proxy routing delta and no ``bypass_port``: the device is a
    zero-rating link, so any port that escapes the data plane is real data.
    """
    if shared_data_plane not in SHARED_DATA_PLANES:
        raise ValueError(
            f"unknown shared data plane {shared_data_plane!r}; expected one of "
            + ", ".join(SHARED_DATA_PLANES)
        )
    # Fail closed on the local plane even for TUN profiles: an unsupported
    # value is a typo, never something to silently ignore.
    check_local_data_plane(local_data_plane)
    mixed = {"type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": 7890}
    if not profile.startswith("ebpf"):
        return [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "sbtun0",
                "address": ["172.19.0.1/30", "fdfe:dcba:9877::1/126"],
                # Capture *all* IPv6, not only the fake-ip range.  With only
                # fdfe:dcba:9876::/64 routed, any v6 destination with a real
                # address (literal, or a CN AAAA answered by ali) skipped the
                # redirect chain and left the box unproxied.  LAN prefixes are
                # subtracted by sing-box (interface address set appears in the
                # generated redirect rules); multicast is excluded below so
                # NDP/MLD never enters the TUN.
                "route_address": ["::/0"],
                "mtu": 1400,
                "stack": "mixed",
                "auto_route": True,
                "auto_redirect": True,
                "strict_route": False,
                "route_exclude_address": [
                    "192.168.0.0/16",
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "169.254.0.0/16",
                    "fd00:5252:0:1::/64",
                    "fe80::/10",
                    "ff00::/8",
                ],
            },
            mixed,
        ]

    ebpf_profile = EBPF_PROFILES[profile]
    if ebpf_profile.admin_bypass and profile in ALL_PROXY_PROFILES:
        # Zero-rating invariant: a bypassed destination port is a direct LAN
        # egress, i.e. real data.  Only management traffic may leave the proxy,
        # and that is handled by bypass_private_address (192.168.0.1).
        raise ValueError(f"{profile}: admin bypass ports are not allowed on an all-proxy profile")
    ebpf_inbound: dict[str, Any] = {
        "type": "ebpf",
        "tag": "ebpf-in",
        "network": ["tcp", "udp"],
        "local": {
            "enabled": True,
            "data_plane": local_data_plane,
            "dns_mode": "respect_policy",
            "bypass_private_address": True,
        },
    }
    if ebpf_profile.ipv6:
        # Without shared the local hook is the only capture path: an implicit
        # IPv6 default would send every v6 flow straight out the WAN while the
        # v4 flow is proxied (the "v4 works, dual-stack 000" failure mode).
        ebpf_inbound["local"]["ipv6"] = True
    if ebpf_profile.shared:
        shared: dict[str, Any] = {
            "enabled": True,
            "data_plane": shared_data_plane,
            "interface": [ebpf_interface],
            "dns_mode": "hijack",
            "bypass_private_address": True,
        }
        if ebpf_profile.admin_bypass:
            shared["bypass_port"] = list(ADMIN_BYPASS_PORTS)
        else:
            # All-proxy: nothing may leave the kernel unproxied.  80/443 in
            # bypass_port hid every LAN HTTP/HTTPS flow from the data plane;
            # the remaining ports hid public 22/7890/8899/9999/22622 too.
            # Management access to 192.168.0.1 still stays direct through
            # bypass_private_address.  ipv6 is spelled out instead of relying
            # on the default so the scope cannot silently flip with a build.
            shared["bypass_port"] = []
        if ebpf_profile.ipv6:
            shared["ipv6"] = True
        ebpf_inbound["shared"] = shared
    return [ebpf_inbound, mixed]


def group_graph(cfg: dict[str, Any]) -> dict[str, list[str]]:
    """Group tag -> member tags, for reachability checks."""
    return {
        o["tag"]: list(o.get("outbounds") or [])
        for o in cfg.get("outbounds") or []
        if o.get("type") in GROUP_OUTBOUND_TYPES
    }


def direct_entry_tags(cfg: dict[str, Any]) -> set[str]:
    """Every tag/alias that means "dial from this box" in a config."""
    tags = set(OUTBOUND_ALIAS)
    tags.update(OUTBOUND_ALIAS.values())
    tags.update(o["tag"] for o in cfg.get("outbounds") or [] if o.get("type") == "direct")
    return tags


def reachable_tags(graph: dict[str, list[str]], roots: Iterable[str]) -> set[str]:
    """Transitive closure of group membership (cycles are tolerated)."""
    seen: set[str] = set()
    stack = [root for root in roots if root]
    while stack:
        tag = stack.pop()
        if tag in seen:
            continue
        seen.add(tag)
        stack.extend(graph.get(tag) or [])
    return seen


def automatic_path_tags(cfg: dict[str, Any], roots: Iterable[str]) -> set[str]:
    """Tags reached by the *automatic* path from ``roots``.

    Selectors follow ``default`` (else first outbound). urltest / loadbalance /
    fallback treat every member as live. Used by zero-direct so panel escape
    DIRECT entries in OK groups do not trip the graph check.
    """
    by_tag = {o["tag"]: o for o in cfg.get("outbounds") or []}
    seen: set[str] = set()
    stack = [root for root in roots if root]
    while stack:
        tag = stack.pop()
        if tag in seen:
            continue
        seen.add(tag)
        ob = by_tag.get(tag)
        if not ob or ob.get("type") not in GROUP_OUTBOUND_TYPES:
            continue
        members = list(ob.get("outbounds") or [])
        if ob.get("type") == "selector":
            nxt = ob.get("default") or (members[0] if members else None)
            if nxt:
                stack.append(nxt)
        else:
            stack.extend(members)
    return seen


def validate_zero_direct(cfg: dict[str, Any]) -> None:
    """Fail closed if the *automatic* all-proxy path dials the internet direct.

    HANDOVER §32: route.final is ``🐟 漏网之鱼`` (defaults to ``🚀 免流模式``);
    route rules may only *target* direct for private/management (plus the
    narrow subscription / NAS exceptions).  Panel groups listed in
    ``ALL_PROXY_DIRECT_OK_GROUPS`` may *offer* DIRECT as a manual escape; their
    ``default`` must stay proxied (except ``🌐 nasipv6`` which defaults to
    NAS·IPv6直连). Reachability checks follow selector defaults, not full
    membership, so a visible DIRECT option does not poison ``final`` / DNS.

    DNS: ``bootstrap`` (exact UDP 223.5.5.5, no detour) is the *only* external
    resolver exception; ``fakeip`` answers locally.  Every other server must
    detour through a group whose automatic path cannot reach direct.
    """
    outbounds = cfg.get("outbounds") or []
    tags = {o["tag"] for o in outbounds}
    direct_tags = direct_entry_tags(cfg)
    if DIRECT_GROUP_TAG in tags:
        raise ValueError(f"all-proxy profile must not generate {DIRECT_GROUP_TAG}")

    for group in outbounds:
        if group.get("type") not in GROUP_OUTBOUND_TYPES:
            continue
        allow_direct = group.get("tag") in ALL_PROXY_DIRECT_OK_GROUPS
        for member in group.get("outbounds") or []:
            if member in direct_tags or member == DIRECT_GROUP_TAG:
                if allow_direct and member in direct_tags:
                    continue
                raise ValueError(
                    f"all-proxy group {group['tag']} lists a direct outbound: {member}"
                )
        if group.get("default") in direct_tags or group.get("default") == DIRECT_GROUP_TAG:
            # nasipv6 / 订阅更新 may *default* to direct (家庭 NAS / 订阅放行).
            if group.get("tag") in {NASIPV6_TAG, SUB_UPDATE_TAG} and group.get(
                "default"
            ) in direct_tags:
                continue
            raise ValueError(
                f"all-proxy group {group['tag']} defaults to a direct outbound"
            )

    route = cfg.get("route") or {}
    for rule in route.get("rules") or []:
        target = rule.get("outbound")
        if not target:
            continue
        if target in direct_tags:
            if keeps_direct_target(rule):
                continue
            # Home NAS / Emby IPv6-only DDNS is an intentional DIRECT exception.
            if (
                target == NAS_DIRECT_TAG
                and rule.get("domain_suffix") == [NAS_DDNS_SUFFIX]
            ):
                continue
            # Subscription hosts that refuse proxied updates (VPN detect).
            # Require a non-empty suffix set (emptyset.issubset is always true).
            _suf = set(rule.get("domain_suffix") or [])
            if (
                target == DIRECT_TAG
                and _suf
                and _suf.issubset(set(SUBSCRIPTION_DIRECT_SUFFIXES))
            ):
                continue
            raise ValueError(f"all-proxy rule still routes direct: {rule}")
        leaked = automatic_path_tags(cfg, [target]) & direct_tags
        if leaked:
            # nasipv6 / 订阅更新 automatic path is DIRECT by design.
            if target in {NASIPV6_TAG, SUB_UPDATE_TAG}:
                continue
            raise ValueError(
                f"all-proxy rule targets {target}, which auto-reaches direct via "
                f"{', '.join(sorted(leaked))}"
            )

    final = route.get("final")
    if final != FINAL_TAG:
        raise ValueError(f"all-proxy route.final must be {FINAL_TAG}, got {final!r}")
    # Panel catch-all must default into 免流 (or another non-direct proxy).
    final_ob = next((o for o in outbounds if o.get("tag") == FINAL_TAG), None)
    if not final_ob or final_ob.get("default") != MIANLIU_TAG:
        raise ValueError(
            f"all-proxy {FINAL_TAG} must default to {MIANLIU_TAG}, got "
            f"{(final_ob or {}).get('default')!r}"
        )
    leaked = automatic_path_tags(cfg, [final]) & direct_tags
    if leaked:
        raise ValueError(
            f"all-proxy route.final auto-reaches direct via {', '.join(sorted(leaked))}"
        )

    dns = cfg.get("dns") or {}
    servers = {s["tag"]: s for s in dns.get("servers") or []}
    bootstrap = servers.get("bootstrap")
    if not bootstrap:
        raise ValueError("all-proxy profile has no bootstrap resolver")
    if bootstrap.get("type") != "udp" or bootstrap.get("server") != BOOTSTRAP_DNS_SERVER:
        raise ValueError(
            f"all-proxy bootstrap must be UDP {BOOTSTRAP_DNS_SERVER}, got "
            f"{bootstrap.get('type')!r}/{bootstrap.get('server')!r}"
        )
    if bootstrap.get("detour"):
        raise ValueError("all-proxy bootstrap must not detour (it resolves the proxy servers)")
    if "nodes" in servers:
        raise ValueError("all-proxy profile must not carry the direct node resolver")
    if (servers.get("fakeip") or {}).get("type") != "fakeip":
        raise ValueError("all-proxy profile needs the internal fakeip resolver")

    for tag, server in servers.items():
        if tag == "bootstrap":
            continue
        if server.get("type") == "fakeip":
            continue
        detour = server.get("detour")
        if not detour:
            raise ValueError(f"all-proxy DNS server {tag} has no detour (direct query)")
        if detour not in tags:
            raise ValueError(f"all-proxy DNS server {tag} detours to missing outbound {detour}")
        leaked = automatic_path_tags(cfg, [detour]) & direct_tags
        if leaked:
            raise ValueError(
                f"all-proxy DNS server {tag} detours to {detour}, which auto-reaches direct"
            )

    resolver = route.get("default_domain_resolver") or {}
    if resolver.get("server") != "bootstrap" or resolver.get("strategy") != "ipv4_only":
        raise ValueError(
            "all-proxy route.default_domain_resolver must be "
            '{"server": "bootstrap", "strategy": "ipv4_only"}'
        )

    if dns.get("final") == "bootstrap":
        raise ValueError("all-proxy dns.final must not be bootstrap (client DNS is proxied)")
    for rule in dns.get("rules") or []:
        if rule.get("server") != "bootstrap":
            continue
        keys = set(rule)
        # 1) Exact node-hostname list (no TTL rewrite).
        if keys == {"domain", "server"} and rule.get("domain"):
            continue
        # 2) Home NAS / Emby DDNS: IPv6-only names must resolve for real before
        #    the global AAAA→fakeip rule (rewrite_ttl is intentional).
        if (
            keys == {"domain_suffix", "server", "rewrite_ttl"}
            and rule.get("domain_suffix") == [NAS_DDNS_SUFFIX]
        ):
            continue
        # 3) Subscription DIRECT hosts (VPN-detect stubs if resolved/dialed
        #    via proxy). Same shape as the NAS bootstrap exception.
        _suf = set(rule.get("domain_suffix") or [])
        if (
            keys == {"domain_suffix", "server", "rewrite_ttl"}
            and _suf
            and _suf.issubset(set(SUBSCRIPTION_DIRECT_SUFFIXES))
        ):
            continue
        raise ValueError(
            "all-proxy DNS may use bootstrap only for node hostnames, "
            f"{NAS_DDNS_SUFFIX} DDNS, or subscription DIRECT suffixes"
        )


def build_config(
    clash: dict[str, Any],
    base: str,
    provider_tags: set[str],
    profile: str = "base",
    clash_secret: str = "",
    ebpf_interface: str = "br-lan",
    ebpf_shared_data_plane: str = "packet_rewrite",
    ebpf_local_data_plane: str = "cgroup",
) -> dict[str, Any]:
    all_proxy = profile in ALL_PROXY_PROFILES
    # Pre-parse rules to discover used rule-set tags.
    used_tags: set[str] = set(EXTRA_RULE_SET_TAGS)
    for raw in clash.get("rules") or []:
        parsed = parse_rule(raw)
        if not parsed:
            continue
        kind, value = parsed
        if kind != "rule":
            continue
        stack = [value]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                if "rule_set" in cur:
                    used_tags.update(cur["rule_set"])
                stack.extend(cur.get("rules") or [])

    outbounds: list[dict[str, Any]] = []
    resolver = "bootstrap" if all_proxy else "ali"
    for p in clash.get("proxies") or []:
        converted = convert_proxy(p, resolver)
        if converted:
            outbounds.append(converted)
    outbounds.append({"type": "block", "tag": REJECT_DROP_TAG})
    outbounds.append(nas_direct_outbound("bootstrap" if all_proxy else "ali"))
    outbounds.extend(synthetic_groups(all_proxy))
    for g in clash.get("proxy-groups") or []:
        outbounds.append(convert_group(g, provider_tags, all_proxy))

    providers: list[dict[str, Any]] = []
    for idx, (name, p) in enumerate((clash.get("proxy-providers") or {}).items(), 1):
        if name not in provider_tags:
            continue
        hc = p.get("health-check") or {}
        providers.append(
            remote_provider_entry(
                name=name,
                idx=idx,
                url=str(p.get("url") or ""),
                user_agent=_provider_user_agent(p),
                health_check_url=hc.get("url") or "https://www.gstatic.com/generate_204",
                health_check_interval=fmt_duration(hc.get("interval"), "10m"),
                base=base,
                all_proxy=all_proxy,
            )
        )

    # Always land unmatched traffic on 🐟 漏网之鱼.  All-proxy only changes
    # that group's default (→ 🚀 免流模式); it must not skip the selector.
    final = FINAL_TAG

    log_options: dict[str, Any] = {"level": "info", "timestamp": True}
    if base:
        log_options["output"] = f"{base}/state/sing-box.log"

    if profile.startswith("ebpf"):
        # Separate fake-ip/DNS cache: a test instance must not clobber the
        # production cache.db (stale fake-ip mappings are hard to diagnose).
        cache_name = "cache.ebpf.db"
    else:
        cache_name = "cache.db"
    experimental: dict[str, Any] = {
        "cache_file": {
            "enabled": True,
            "path": f"{base}/{cache_name}" if base else cache_name,
            "store_fakeip": True,
            "store_dns": True,
        },
        "clash_api": {
            "external_controller": "0.0.0.0:9999",
            "external_ui": f"{base}/ui" if base else "ui",
            "secret": clash_secret,
            "default_mode": "Rule",
        },
    }
    if profile != "base":
        # Observed via /observability/v1 (Prometheus + JSON).  expose_sensitive
        # stays off: recent-connection queries must not leak domains/processes.
        experimental["observability"] = {
            "enabled": True,
            "recent_connections": 2000,
            "recent_ttl": "1h",
            "top_k_size": 100,
            "expose_sensitive": False,
        }

    route = build_route(clash, base, final, used_tags, all_proxy)
    if profile.startswith("ebpf"):
        # An eBPF inbound has no TUN, so there is no auto_redirect bypass mark
        # and mwan3's own rules (which match mark 0x0/0x3f00) see an unmarked
        # socket: every proxied flow would keep the default route, i.e. the 5G
        # card only.  Stamping the same mark the TUN stack uses puts
        # singbox-wan-balance.sh's jhash chain back in the path.
        # ``route.default_mark`` conflicts with ``tun.auto_redirect``, so it
        # must stay out of the TUN profiles.
        route["default_mark"] = PROXY_MARK

    node_domains = {
        str(o["server"]).strip("[]")
        for o in outbounds
        if o.get("server") and not _is_ip_literal(str(o["server"]))
    }
    cfg = {
        "log": log_options,
        "dns": build_dns(clash, all_proxy, node_domains),
        "inbounds": build_inbounds(
            profile, ebpf_interface, ebpf_shared_data_plane, ebpf_local_data_plane
        ),
        "outbounds": outbounds,
        "providers": providers,
        "route": route,
        "experimental": experimental,
    }
    if profile != "base":
        # Loopback-only API for the eBPF diagnostics CLI
        # (``sing-box api ebpf --url http://127.0.0.1:8088 --deep``).  gRPC,
        # unlike the Clash controller on 9999.  No dashboard and no secret:
        # it listens on 127.0.0.1 only, and the panel stays passwordless.
        cfg["services"] = [
            {
                "type": "api",
                "tag": "diagnostics-api",
                "listen": "127.0.0.1",
                "listen_port": DIAGNOSTICS_API_PORT,
            }
        ]
    if all_proxy:
        validate_zero_direct(cfg)
    return cfg


def validate_config(cfg: dict[str, Any]) -> None:
    tags = [o["tag"] for o in cfg.get("outbounds") or []]
    if len(tags) != len(set(tags)):
        raise ValueError("duplicate outbound tags")
    tag_set = set(tags)
    provider_tags = {p["tag"] for p in cfg.get("providers") or []}
    rule_set_tags = {r["tag"] for r in cfg.get("route", {}).get("rule_set") or []}

    for outbound in cfg.get("outbounds") or []:
        for ref in outbound.get("outbounds") or []:
            if ref not in tag_set:
                raise ValueError(f"outbound {outbound['tag']} references missing {ref}")
        default = outbound.get("default")
        if default and default not in tag_set:
            raise ValueError(f"outbound {outbound['tag']} default missing {default}")
        for prov in outbound.get("providers") or []:
            if prov not in provider_tags:
                raise ValueError(f"outbound {outbound['tag']} references missing provider {prov}")
        for key in ("include", "exclude"):
            value = outbound.get(key) or ""
            if "(?=" in value or "(?!" in value:
                raise ValueError(f"outbound {outbound['tag']} {key} still has lookahead")

    def check_rules(rules: list[dict[str, Any]]) -> None:
        for rule in rules:
            for ref in rule.get("rule_set") or []:
                if ref not in rule_set_tags:
                    raise ValueError(f"rule references missing rule-set {ref}")
            target = rule.get("outbound")
            if target and target not in tag_set:
                raise ValueError(f"rule references missing outbound {target}")
            if rule.get("type") == "logical":
                check_rules(rule.get("rules") or [])

    check_rules(cfg.get("route", {}).get("rules") or [])
    final = cfg.get("route", {}).get("final")
    if final and final not in tag_set:
        raise ValueError(f"route.final missing {final}")
    for rule in cfg.get("dns", {}).get("rules") or []:
        for ref in rule.get("rule_set") or []:
            if ref not in rule_set_tags:
                raise ValueError(f"dns rule references missing rule-set {ref}")

    graph = {
        o["tag"]: [r for r in o.get("outbounds") or [] if r in tag_set]
        for o in cfg.get("outbounds") or []
        if o.get("type") in ("selector", "urltest", "loadbalance")
    }
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node: str) -> None:
        if node in visited:
            return
        if node in visiting:
            raise ValueError(f"group cycle at {node}")
        visiting.add(node)
        for child in graph.get(node, []):
            visit(child)
        visiting.remove(node)
        visited.add(node)

    for node in graph:
        visit(node)


def prepare_providers(clash: dict[str, Any], out_dir: Path, refresh: bool) -> tuple[set[str], list[str]]:
    """Fetch ``?target=singbox`` subscriptions into local provider files.

    Every provider stays in the config.  If a subscription is temporarily
    unavailable, a socks sink placeholder is written so local providers are
    never empty (empty ``outbounds`` → ``no servers found`` / core won't
    stay up).  Group ``exclude`` always merges ``DEAD_NODE_EXCLUDE`` so
    urltest cannot health-check the sink via provider-name geography
    (e.g. ``中国`` in ``1.中国国际机场/订阅暂不可用``).  The device updater
    replaces the file when the subscription recovers.
    """
    prov_dir = out_dir / "providers"
    prov_dir.mkdir(parents=True, exist_ok=True)
    included: set[str] = set()
    pending: list[str] = []
    conf_lines = ["# tag\tfile\turl\tuser-agent\tclash-api-name"]
    placeholder = {
        "outbounds": [
            {"type": "socks", "tag": "订阅暂不可用", "server": "127.0.0.1", "server_port": 1}
        ]
    }
    for idx, (name, p) in enumerate((clash.get("proxy-providers") or {}).items(), 1):
        url = normalize_subscription_url(p["url"])
        ua = _provider_user_agent(p)
        dest = prov_dir / f"p{idx}.json"
        ok = False
        try:
            print(f"provider {name:<18} <- {url}", flush=True)
            data = fetch(url, CACHE / f"provider-p{idx}.json", refresh)
            obj = json.loads(data)
            outbounds = obj.get("outbounds")
            if not isinstance(outbounds, list) or not outbounds:
                raise ValueError("provider has no outbounds")
            if _provider_outbounds_are_dead(outbounds):
                raise ValueError("provider returned dead placeholder only")
            dest.write_bytes(data)
            ok = True
        except Exception as exc:  # noqa: BLE001 - provider availability is external
            print(f"WARN: provider {name} pending: {exc}", file=sys.stderr)
            try:
                obj = json.loads(dest.read_text(encoding="utf-8"))
                outbounds = obj.get("outbounds") or []
                ok = bool(outbounds) and not _provider_outbounds_are_dead(outbounds)
            except Exception:
                ok = False
            if not ok:
                dest.write_text(
                    json.dumps(placeholder, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
                )
                pending.append(name)
        if dest.is_file():
            n = patch_provider_v6_domain_resolver(dest, resolver="bootstrap")
            if n:
                print(f"provider {name}: patched {n} v6 node domain_resolver=ipv6_only", flush=True)
        included.add(name)
        # 5th column: Clash-API path encoding for update-providers.sh PUT.
        conf_lines.append(f"{name}\t{idx}\t{url}\t{ua}\t{quote(name, safe='')}")
    (out_dir / "providers.conf").write_text("\n".join(conf_lines) + "\n", encoding="utf-8", newline="\n")
    return included, pending


def prepare_rule_files(clash: dict[str, Any], out_dir: Path, refresh: bool) -> None:
    tags: set[str] = set()
    for raw in clash.get("rules") or []:
        parsed = parse_rule(raw)
        if not parsed:
            continue
        kind, value = parsed
        if kind != "rule":
            continue
        stack = [value]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                if "rule_set" in cur:
                    tags.update(cur["rule_set"])
                stack.extend(cur.get("rules") or [])
    tags.update(EXTRA_RULE_SET_TAGS)
    for tag in sorted(tags):
        spec = TAG_TO_SPEC[tag]
        if spec.kind == "srs":
            dest = out_dir / "rules" / f"{tag}.srs"
            dest.parent.mkdir(parents=True, exist_ok=True)
            print(f"fetching {tag:<16} <- {spec.url}", flush=True)
            dest.write_bytes(fetch(spec.url, CACHE / f"{tag}.srs", refresh))
            print(f"rule-set {tag:<16} {dest.stat().st_size / 1024:7.1f} KiB  (binary)")
            continue
        dest = out_dir / "rules" / f"{tag}.json"
        dest.parent.mkdir(parents=True, exist_ok=True)
        print(f"fetching {tag:<16} <- {spec.url}", flush=True)
        dest.write_text(json.dumps(rule_set_source(spec, refresh), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"rule-set {tag:<16} {dest.stat().st_size / 1024:7.1f} KiB  <- {spec.url}")


def check_profile_args(profile: str, clash_secret: str) -> None:
    """Validate the profile name.  An empty secret is allowed by design.

    Standing user rule (HANDOVER §29): the sing-box / Clash control panel keeps
    **no password** — ``experimental.clash_api.secret`` stays ``""`` and
    Zashboard opens without a token.  ``--clash-secret`` is still accepted for
    temporary experiments, but it is never required; the API is LAN-only by
    firewall/topology, not by a token.
    """
    if profile not in PROFILES:
        raise ValueError(f"unknown profile {profile!r}; expected one of {', '.join(PROFILES)}")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--device-root", default="/data/sing-box")
    ap.add_argument("--refresh", action="store_true", help="re-download cached source lists")
    ap.add_argument(
        "--profile",
        choices=list(PROFILES),
        default="base",
        help="base = current TUN stack (default); observability = base + metrics/Top-K API; "
        "ebpf-local = eBPF cgroup local only; ebpf-full = eBPF local + shared (LAN clients); "
        "ebpf-local-only = migration phase 1: eBPF local only with explicit ipv6 (LAN clients "
        "stay uncaptured, so this is a short test window and not a resting state); "
        "ebpf-local-shared = migration phase 2: eBPF local + shared on the LAN bridge with "
        "explicit ipv6 and empty bypass_port (same zero-direct stack as ebpf-allproxy); "
        "ebpf-allproxy = ebpf-full with no direct leaks (empty bypass_port, no DIRECT "
        "rule outside LAN/private, no direct group/member/default anywhere, every DNS "
        "server except bootstrap detoured, final 免流, no udp/443 reject, no ip_version:6 "
        "rule); "
        "tun-allproxy = the same all-proxy routing on the production TUN stack "
        "(fallback when eBPF shared stalls LAN TCP)",
    )
    ap.add_argument(
        "--clash-secret",
        default=os.environ.get("SINGBOX_CLASH_SECRET", ""),
        help="optional clash_api / observability bearer token; empty (default) keeps the "
        "panel passwordless per user rule (HANDOVER §29); env SINGBOX_CLASH_SECRET also works",
    )
    ap.add_argument(
        "--ebpf-interface",
        default="br-lan",
        help="downstream interface for eBPF shared mode (default br-lan)",
    )
    ap.add_argument(
        "--ebpf-shared-data-plane",
        choices=list(SHARED_DATA_PLANES),
        default="packet_rewrite",
        help="shared TC hook data plane for ebpf profiles with a shared hook: "
        "packet_rewrite (default, production value) or socket_assign (experimental A/B)",
    )
    ap.add_argument(
        "--ebpf-local-data-plane",
        type=cli_local_data_plane,
        metavar="{" + ",".join(LOCAL_DATA_PLANES) + "}",
        default="cgroup",
        help="local hook data plane for ebpf profiles: cgroup (default, device-originated "
        "traffic) or socket_assign (experimental A/B); tc is rejected by name, no alias",
    )
    return ap


def main() -> int:
    ap = build_parser()
    args = ap.parse_args()

    clash_secret = args.clash_secret.strip()
    try:
        check_profile_args(args.profile, clash_secret)
    except ValueError as exc:
        ap.error(str(exc))
    if args.profile != "base" and not clash_secret:
        print("note: no --clash-secret; /observability/v1 and Zashboard stay "
              "unauthenticated by design (user rule, HANDOVER §29)")

    clash = yaml.safe_load(args.input.read_text(encoding="utf-8"))
    args.out.mkdir(parents=True, exist_ok=True)

    provider_tags, pending_providers = prepare_providers(clash, args.out, args.refresh)
    prepare_rule_files(clash, args.out, args.refresh)

    if args.profile == "base":
        local_cfg = build_config(clash, "", provider_tags)
        validate_config(local_cfg)
        device_cfg = build_config(clash, args.device_root, provider_tags)
        validate_config(device_cfg)
        (args.out / "config.local.json").write_text(
            json.dumps(local_cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        (args.out / "config.device.json").write_text(
            json.dumps(device_cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
        )

        lab_cfg = json.loads(json.dumps(device_cfg))
        lab_cfg["inbounds"] = [
            {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7891}
        ]
        lab_cfg["experimental"]["clash_api"]["external_controller"] = "127.0.0.1:9095"
        lab_cfg["experimental"]["cache_file"]["path"] = args.device_root + "/lab-cache.db"
        (args.out / "config.lab.json").write_text(
            json.dumps(lab_cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        outputs = ["config.local.json", "config.device.json", "config.lab.json"]
    else:
        cfg = build_config(
            clash,
            args.device_root,
            provider_tags,
            profile=args.profile,
            clash_secret=clash_secret,
            ebpf_interface=args.ebpf_interface,
            ebpf_shared_data_plane=args.ebpf_shared_data_plane,
            ebpf_local_data_plane=args.ebpf_local_data_plane,
        )
        validate_config(cfg)
        name = f"config.{args.profile}.json"
        (args.out / name).write_text(
            json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        outputs = [name]
        # The base config keeps pointing at the production TUN stack; a profile
        # run never overwrites it.  deploy.sh --config picks the variant.

    manifest = {
        "source": str(args.input),
        "profile": args.profile,
        "clash_secret_set": bool(clash_secret),
        "ebpf_interface": args.ebpf_interface if args.profile.startswith("ebpf") else None,
        "ebpf_shared_data_plane": (
            args.ebpf_shared_data_plane
            if args.profile.startswith("ebpf") and EBPF_PROFILES[args.profile].shared
            else None
        ),
        # Every ebpf-* profile has a local hook, so this needs no extra gate.
        "ebpf_local_data_plane": (
            args.ebpf_local_data_plane if args.profile.startswith("ebpf") else None
        ),
        "proxies": len(clash.get("proxies") or []),
        "groups": len(clash.get("proxy-groups") or []),
        "rules": len(clash.get("rules") or []),
        "providers_included": sorted(provider_tags),
        "providers_pending": pending_providers,
        "rule_sets": sorted({spec.tag for spec in TAG_TO_SPEC.values()}),
        "outputs": outputs,
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    for name in outputs:
        print(f"wrote {args.out / name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
