#!/bin/sh
# Deploy a generated sing-box config to the device.
# Does NOT start the core; run the switchover/maintenance procedure separately.
#
# Usage:
#   sh deploy.sh                          # push generated/config.device.json (TUN stack)
#   sh deploy.sh --config config.observability.json
#   sh deploy.sh --config config.ebpf-local-shared.json   # migration phase 2
#   sh deploy.sh --config config.ebpf-local-shared.json --verify
#   sh deploy.sh --binary /path/to/sing-box               # also replace the core
#   ANDROID_SERIAL=<serial> sh deploy.sh ...              # pick a device
#
# Safety contract:
#   1. existing scripts are archived; replacement scripts pass sh -n before swap;
#   2. backup-config.sh save auto snapshots the CURRENT config.json;
#   3. config.json.new passes core check and optional --verify static gates
#      before the atomic rename, so a failed gate leaves config.json intact;
#   4. runtime checks require a restarted core and an independent LAN client.
#
# Exit codes: 0 deployed, 1 pre-flight/deploy/verify failure, 2 bad usage.
set -eu
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

# shellcheck disable=SC1007  # CDPATH= prefix: defend the subshell cd against a hostile CDPATH
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v cygpath >/dev/null 2>&1; then
    ROOT=$(cygpath -w "$ROOT")
fi
GEN="$ROOT/generated"
DEV="${SINGBOX_BASE:-/data/sing-box}"
ADB="${ADB:-adb}"
SERIAL="${ANDROID_SERIAL:-}"
CONFIG=config.device.json
BINARY=
DO_VERIFY=0

# adb_cmd keeps ANDROID_SERIAL support in one place (several cards/phones may be
# attached at the same time; `adb` would fail with "more than one device").
adb_cmd() {
    if [ -n "$SERIAL" ]; then
        "$ADB" -s "$SERIAL" "$@"
    else
        "$ADB" "$@"
    fi
}

usage() {
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="${2:?--config needs a file name}"; shift 2 ;;
        --config=*) CONFIG="${1#*=}"; shift ;;
        --binary) BINARY="${2:?--binary needs a path}"; shift 2 ;;
        --binary=*) BINARY="${1#*=}"; shift ;;
        --verify) DO_VERIFY=1; shift ;;
        --backup) shift ;;  # always on; kept so older notes keep working
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$GEN/$CONFIG" ]; then
    echo "missing $GEN/$CONFIG" >&2
    echo "generate it first, e.g.:" >&2
    echo "  python $ROOT/convert.py --profile ebpf-local-shared" >&2
    exit 1
fi
if [ ! -f "$ROOT/backup-config.sh" ] \
    && ! adb_cmd shell "[ -f '$DEV/backup-config.sh' ]" >/dev/null 2>&1; then
    echo "missing backup-config.sh (device $DEV or $ROOT/backup-config.sh);" >&2
    echo "refusing to overwrite a live config without a phase-tagged backup" >&2
    exit 1
fi

adb_cmd shell "mkdir -p '$DEV/rules' '$DEV/providers' '$DEV/ui' '$DEV/state' '$DEV/diagnostics'"
if [ -n "$BINARY" ]; then
    adb_cmd push "$BINARY" "$DEV/sing-box"
    adb_cmd shell "chmod 755 '$DEV/sing-box'"
fi

# Scripts land first: backup-config.sh and verify-ebpf.sh are executed below.
SCRIPT_BACKUP="$DEV/state/deploy-scripts-$(date -u +%Y%m%dT%H%M%SZ)-$$"
adb_cmd shell "mkdir -p '$SCRIPT_BACKUP'"

push_script() {
    _script="$1"
    adb_cmd push "$ROOT/$_script" "/tmp/$_script" >/dev/null
    adb_cmd shell "set -e; tr -d '\r' < '/tmp/$_script' > '$DEV/$_script.new'; sh -n '$DEV/$_script.new'; if [ -f '$DEV/$_script' ]; then cp -p '$DEV/$_script' '$SCRIPT_BACKUP/$_script'; fi; chmod 755 '$DEV/$_script.new'; mv -f '$DEV/$_script.new' '$DEV/$_script'"
}

for s in update-providers.sh sing-box.sh singbox-watchdog.sh singbox-dhcp-keeper.sh singbox-wan-balance.sh singbox-capture-flush.sh install-boot.sh ebpf-probe.sh verify-ebpf.sh ebpf-snapshot.sh ebpf-fragment-guard.sh ebpf-trial.sh backup-config.sh monitor-ebpf.sh diagnose-stall.sh; do
    push_script "$s"
done

# 'save auto' inspects the OLD config.json (ebpf+shared -> phase2-ebpf-shared,
# eBPF -> phase1-ebpf-local, else tun) and is a no-op when that phase already
# holds this md5.  Non-zero means "no trustworthy snapshot" -> stop here.
if ! BACKUP_OUT=$(adb_cmd shell "sh '$DEV/backup-config.sh' save auto"); then
    echo "backup failed; config.json left untouched" >&2
    exit 1
fi
BACKUP_OUT=$(printf '%s' "$BACKUP_OUT" | tr -d '\r')
echo "backup: ${BACKUP_OUT:-see $DEV/state/backup-index.tsv}"

adb_cmd push "$GEN/rules/." "$DEV/rules/"
adb_cmd push "$GEN/providers/." "$DEV/providers/"
adb_cmd push "$GEN/providers.conf" /tmp/providers.conf >/dev/null
adb_cmd shell "tr -d '\\r' < /tmp/providers.conf > '$DEV/providers.conf'"

# Stage -> check -> atomic swap.  Rules/providers are already in place, so the
# checker resolves every local rule-set and provider path for real.
adb_cmd push "$GEN/$CONFIG" "$DEV/config.json.new"
if ! CHECK_OUT=$(adb_cmd shell "cd '$DEV' && ./sing-box check -c config.json.new" 2>&1); then
    CHECK_OUT=$(printf '%s' "$CHECK_OUT" | tr -d '\r')
    echo "sing-box check FAILED on the staged config; live config.json untouched" >&2
    printf '%s\n' "$CHECK_OUT" >&2
    echo "staged file kept for inspection: $DEV/config.json.new" >&2
    exit 1
fi
if [ "$DO_VERIFY" -eq 1 ]; then
    echo "== staged static verification ($CONFIG) =="
    if ! adb_cmd shell "SINGBOX_CONFIG='$DEV/config.json.new' sh '$DEV/verify-ebpf.sh' --static"; then
        echo "static verification failed; config.json left untouched" >&2
        exit 1
    fi
fi
adb_cmd shell "cd '$DEV' && mv -f config.json.new config.json"

adb_cmd shell "if [ -f '$DEV/ui/index.html' ]; then [ -f '$DEV/ui/index.html.bak-pre-baseurl' ] || cp '$DEV/ui/index.html' '$DEV/ui/index.html.bak-pre-baseurl'; sed -i 's#data-base-url=\"http://127.0.0.1:9090\"#data-base-url=\"\"#' '$DEV/ui/index.html'; fi"

case "$CONFIG" in
    *ebpf*)
        echo ""
        echo "NOTE: eBPF profile deployed. Before starting the core:"
        echo "  1) sh $DEV/ebpf-probe.sh          # capability probe, then review artifacts"
        echo "  2) route.default_mark must be 8228; wan-balance must report source: default."
        echo "     Verify actual LAN clients and three-card counters after startup."
        echo "  3) the data plane is chosen at generation time: --ebpf-local-data-plane"
        echo "     cgroup|socket_assign, --ebpf-shared-data-plane packet_rewrite|socket_assign."
        echo "     Check what actually attached with: sh $DEV/sing-box.sh status"
        echo "     and: $DEV/sing-box api ebpf --url http://127.0.0.1:8088 --deep"
        echo "  4) A/B runs go through: sh $DEV/ebpf-trial.sh <candidate.json> 90"
        echo "     (TUN baseline snapshot -> check -> static gates -> watchdog off ->"
        echo "      plane confirmation -> timed window -> exact TUN restore)"
        echo "  5) rollback: sh $DEV/backup-config.sh restore tun"
        ;;
esac

if [ "$DO_VERIFY" -eq 1 ]; then
    echo "staged static verification passed before config swap."
    echo ""
    echo "runtime verification after the restart:"
    echo "  sh $DEV/sing-box.sh restart && sh $DEV/verify-ebpf.sh"
fi

echo "deployed $CONFIG to $DEV (not started; config archive: ${BACKUP_OUT:-see $DEV/state/backup-index.tsv}; scripts: $SCRIPT_BACKUP)"
