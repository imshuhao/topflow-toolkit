#!/bin/sh
# 在 /etc/rc.local 最后一个 exit 0 之前插入 webssh 自启块（幂等）。
set -eu
RC=/etc/rc.local
MARKER_BEGIN='# >>> webssh >>>'
MARKER_END='# <<< webssh <<<'
BLOCK=$(cat <<'EOF'
# >>> webssh >>>
if [ -x /data/webssh/webssh ]; then
    ulimit -n 4096 2>/dev/null
    if [ -f /tmp/webssh.log ] && [ "$(wc -c < /tmp/webssh.log)" -gt 1048576 ]; then : > /tmp/webssh.log; fi
    start-stop-daemon -S -b -x /data/webssh/start.sh -m -p /tmp/webssh.pid >/dev/null 2>&1
fi
# <<< webssh <<<
EOF
)

if [ ! -f "$RC" ]; then
  echo "missing $RC" >&2
  exit 1
fi
if grep -q "$MARKER_BEGIN" "$RC"; then
  echo "webssh rc.local block already present"
  exit 0
fi
cp -p "$RC" "/data/webssh/rc.local.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || cp -p "$RC" /tmp/rc.local.bak-webssh
tmp=$(mktemp)
awk -v block="$BLOCK" '
  BEGIN { inserted=0 }
  /^exit 0[[:space:]]*$/ && !inserted {
    print block
    inserted=1
  }
  { print }
  END {
    if (!inserted) {
      print block
    }
  }
' "$RC" > "$tmp"
sh -n "$tmp"
cat "$tmp" > "$RC"
rm -f "$tmp"
echo "installed webssh block into $RC"