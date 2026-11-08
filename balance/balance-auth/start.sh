#!/bin/sh
# balance-auth — 余量授信旁路（WebSSH 入口链到此）
set -eu
DIR=${DIR:-/data/local/balance}
BIN=${BIN:-$DIR/balance-auth}
LISTEN=${LISTEN:-192.168.0.1:8898}
cd "$DIR" || exit 1
ulimit -n 4096 2>/dev/null || true
exec "$BIN" -listen "$LISTEN" -accounts "$DIR/accounts.json" -dir "$DIR"
