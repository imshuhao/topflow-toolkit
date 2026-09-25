#!/bin/sh
set -eu

MANAGER=${1:-$(dirname "$0")/../mihomo-manager.sh}
WORK=$(mktemp -d)
holder=""
contender_a=""
contender_b=""
cleanup() {
    for child in "$holder" "$contender_a" "$contender_b"; do
        [ -z "$child" ] || kill "$child" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Load only the real locking functions; never execute device control code.
awk '/^acquire_lock\(\)/ { copy=1 } /^result\(\)/ { copy=0 } copy' "$MANAGER" >"$WORK/locking.sh"
cat >"$WORK/worker.sh" <<'EOF'
#!/bin/sh
LOCK_DIR=$1
TEMP_FILES=""
. "$2"
acquire_lock || { echo busy; exit 2; }
echo acquired
if [ "$3" = hold ]; then read -r release; fi
EOF

run() { sh "$WORK/worker.sh" "$WORK/lock" "$WORK/locking.sh" "$1"; }
wait_ready() {
    attempts=0
    while ! grep -q acquired "$1"; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 5 ] || { echo "worker did not acquire lock" >&2; exit 1; }
        sleep 1
    done
}

run once >"$WORK/normal"
test ! -d "$WORK/lock"

# Keep the holder blocked without a child inheriting its lock or stdin.
mkfifo "$WORK/input"
exec 8<>"$WORK/input"
sh "$WORK/worker.sh" "$WORK/lock" "$WORK/locking.sh" hold <&8 >"$WORK/holder" &
holder=$!
wait_ready "$WORK/holder"
test "$(cat "$WORK/lock/pid")" = "$holder"
if run once >"$WORK/busy"; then echo "active lock was stolen" >&2; exit 1; fi
test "$(cat "$WORK/busy")" = busy

# A SIGKILL cannot run a trap: the next caller must recover the dead owner.
kill -9 "$holder"
wait "$holder" 2>/dev/null || true
holder=""
test -d "$WORK/lock"
sh "$WORK/worker.sh" "$WORK/lock" "$WORK/locking.sh" hold <&8 >"$WORK/a" &
contender_a=$!
sh "$WORK/worker.sh" "$WORK/lock" "$WORK/locking.sh" hold <&8 >"$WORK/b" &
contender_b=$!
attempts=0
while [ "$(cat "$WORK/a" "$WORK/b" | wc -l | tr -d ' ')" -lt 2 ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 5 ] || exit 1
    sleep 1
done
test "$(cat "$WORK/a" "$WORK/b" | grep -c '^acquired$')" = 1
test "$(cat "$WORK/a" "$WORK/b" | grep -c '^busy$')" = 1
printf 'release\n' >&8
wait "$contender_a" 2>/dev/null || true
wait "$contender_b" 2>/dev/null || true
contender_a=""
contender_b=""
test ! -d "$WORK/lock"

# Unknown legacy ownership must be inspected, never removed automatically.
mkdir "$WORK/lock"
if run once >/dev/null; then echo "ownerless lock was stolen" >&2; exit 1; fi
test -d "$WORK/lock"
rmdir "$WORK/lock"
run once >/dev/null
test ! -d "$WORK/lock"
echo "manager-lock: exit cleanup, active exclusion, killed-owner recovery and concurrent acquisition passed"
