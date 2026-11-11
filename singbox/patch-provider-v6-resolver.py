#!/usr/bin/env python3
"""Patch provider JSON files so v6-labelled nodes use ipv6_only domain_resolver."""
from __future__ import annotations

import sys
from pathlib import Path

# Allow running as `python singbox/patch-provider-v6-resolver.py …`
sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} <provider.json> [provider.json...]", file=sys.stderr)
        return 2
    total = 0
    for raw in argv[1:]:
        path = Path(raw)
        n = convert.patch_provider_v6_domain_resolver(path, resolver="bootstrap")
        print(f"{path}: patched {n}")
        total += n
    return 0 if total >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
