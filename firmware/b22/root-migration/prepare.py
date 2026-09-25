#!/usr/bin/env python3
"""Recreate the verified migration payload from a privately owned stock rc.local."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
STOCK_SHA256 = "21ab5b3c49c4b9b96e6fb69f5e73ea6dcd6ceb840ea5a2bf34d8da5570bc0280"
PATCHED_SHA256 = "ff99d5f4468c6d18b76d63176b07fca557a0865f76fe27c41922454256d1d350"
HOOK = (b"# MU5252 B22 root ADB migration\n"
        b"/data/local/root-b22/boot-root.sh\n"
        b"# End MU5252 B22 root ADB migration\n")


def prepare(stock, destination):
    data = stock.read_bytes()
    if hashlib.sha256(data).hexdigest() != STOCK_SHA256:
        raise ValueError("rc.local is not the audited stock B22 file")
    patched = data.replace(b"#!/bin/sh\n", b"#!/bin/sh\n" + HOOK, 1)
    if hashlib.sha256(patched).hexdigest() != PATCHED_SHA256:
        raise ValueError("generated rc.local hash mismatch")
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    names = ["boot-root.sh", "adb_shell", "90-mu5252-b22-root"]
    for name in names:
        shutil.copy2(HERE / name, destination / name)
    (destination / "rc.local.b22-root").write_bytes(patched)
    names.append("rc.local.b22-root")
    sums = []
    for name in names:
        path = destination / name
        path.chmod(0o755)
        subprocess.run(["sh", "-n", str(path)], check=True)
        sums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {name}\n")
    (destination / "SHA256SUMS").write_text("".join(sums))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stock_rc_local", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        prepare(args.stock_rc_local, args.destination)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Migration preparation failed: {exc}\n")
    print(f"Verified migration payload prepared in {args.destination}; not deployed")
