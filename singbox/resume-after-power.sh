#!/bin/sh
# After the device powers on: deploy latest scripts/config, install boot hook,
# start sing-box, and print status. Run from the repo root.
set -eu
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

# shellcheck disable=SC1007  # CDPATH= prefix: defend the subshell cd against a hostile CDPATH
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ADB="${ADB:-adb}"

"$ADB" wait-for-device
"$ADB" shell 'echo device: $(cat /proc/sys/kernel/hostname)'

sh "$ROOT/deploy.sh"
"$ADB" shell '/data/sing-box/install-boot.sh'
"$ADB" shell '/data/sing-box/sing-box.sh start'
"$ADB" shell '/data/sing-box/sing-box.sh status'
"$ADB" shell 'curl -s -m 3 http://127.0.0.1:9999/version; echo'
"$ADB" shell 'curl -4 -s -o /dev/null -w "gstatic:%{http_code}\n" --max-time 20 -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204'
"$ADB" shell 'curl -4 -s -o /dev/null -w "taobao:%{http_code}\n" --max-time 20 -x http://127.0.0.1:7890 https://www.taobao.com/'
echo "resume complete"
