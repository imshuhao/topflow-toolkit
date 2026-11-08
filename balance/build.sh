#!/bin/sh
# Cross-compile balance-query for device (linux/arm64 static).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$ROOT/balance-query"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$ROOT/balance-query.arm64" .
ls -la "$ROOT/balance-query.arm64"
echo "push: adb push balance/balance-query.arm64 /data/local/balance/balance-query"
