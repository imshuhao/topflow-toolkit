#!/bin/sh
# Refresh sing-box providers from providers.conf.
# Prefers Clash API PUT (remote providers → panel「更新」same path).
# Falls back to curl + atomic file replace when the API is down.
# Cron: 30 */6 * * *  (align with NAS cn-intl-bridge; was 0 4 * * *) /data/sing-box/update-providers.sh

BASE="${SINGBOX_BASE:-/data/sing-box}"
CONF="$BASE/providers.conf"
LOG="${SINGBOX_PROVIDER_LOG:-/tmp/sing-box-providers.log}"
LOCK="$BASE/state/provider-update.lock"
API="${SINGBOX_CLASH_API:-http://127.0.0.1:9999}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

[ -f "$CONF" ] || exit 0
mkdir -p "$BASE/state" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

api_up=0
if curl -fsS --connect-timeout 2 --max-time 5 "$API/version" >/dev/null 2>&1; then
    api_up=1
fi

TAB=$(printf '\t')
while IFS="$TAB" read -r tag idx url ua enc; do
    case "$tag" in
        ''|'#'*) continue ;;
    esac
    idx=$(printf '%s' "$idx" | tr -d '\r')
    ua=$(printf '%s' "$ua" | tr -d '\r')
    enc=$(printf '%s' "$enc" | tr -d '\r')
    url=$(printf '%s' "$url" | tr -d '\r')
    [ -n "$idx" ] || continue
    tmp="$BASE/providers/p$idx.json.tmp"
    dst="$BASE/providers/p$idx.json"

    # 1) Clash API PUT — same as Zashboard provider refresh for type:remote.
    if [ "$api_up" -eq 1 ] && [ -n "$enc" ]; then
        log "PUT $tag"
        code=$(curl -sS -o /tmp/sb-prov-put.body -w '%{http_code}' \
            --connect-timeout 20 --max-time 180 \
            -X PUT "$API/providers/proxies/$enc" 2>/dev/null || echo 000)
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$BASE/state/provider-p${idx}.last-ok"
            log "OK PUT $tag http=$code size=$(wc -c < "$dst" 2>/dev/null | tr -d ' ')"
            continue
        fi
        log "PUT_FAIL $tag http=$code body=$(head -c 160 /tmp/sb-prov-put.body 2>/dev/null | tr '\n' ' ')"
    fi

    # 2) Fallback: curl URL → (optional clashsub2sb) → atomic replace.
    log "fetch $tag"
    ok=0
    attempt=0
    while [ "$attempt" -lt 4 ]; do
        attempt=$((attempt + 1))
        if [ -n "$ua" ]; then
            curl -fsSL --connect-timeout 20 --max-time 180 -A "$ua" -o "$tmp" "$url" && ok=1 && break
        else
            curl -fsSL --connect-timeout 20 --max-time 180 -o "$tmp" "$url" && ok=1 && break
        fi
        log "retry $tag attempt=$attempt"
        sleep $((attempt * 3))
    done
    if [ "$ok" -ne 1 ]; then
        rm -f "$tmp"
        if [ -s "$dst" ]; then
            log "FAIL $tag (kept old $(wc -c < "$dst") bytes)"
        else
            log "FAIL $tag (no previous file)"
        fi
        continue
    fi
    if [ -s "$tmp" ] && ! grep -q '"outbounds"' "$tmp" && grep -qE '^proxies:|^mixed-port:' "$tmp"; then
        _conv="$BASE/clashsub2sb"
        if [ -x "$_conv" ]; then
            _json="$tmp.sb.json"
            if "$_conv" "$tmp" "$_json" 2>>"$LOG"; then
                rm -f "$tmp"
                tmp="$_json"
                log "CONVERTED $tag clash->singbox $(wc -c < "$tmp") bytes"
            else
                rm -f "$tmp" "$_json"
                log "CONVERT_FAIL $tag (kept old)"
                continue
            fi
        else
            rm -f "$tmp"
            log "CLASH_YAML $tag but no clashsub2sb (kept old)"
            continue
        fi
    fi
    if [ -s "$tmp" ] && grep -q '"outbounds"' "$tmp"; then
        _new=$(wc -c < "$tmp" | tr -d ' ')
        if [ "$_new" -lt 2048 ] && grep -qE '订阅暂不可用|请前往官网|暂不可用' "$tmp"; then
            rm -f "$tmp"
            if [ -s "$dst" ]; then
                log "PLACEHOLDER $tag (kept old $(wc -c < "$dst") bytes)"
            else
                printf '%s\n' '{"outbounds":[{"type":"socks","tag":"订阅暂不可用","server":"127.0.0.1","server_port":1}]}' >"$dst"
                log "PLACEHOLDER $tag (seeded sink)"
            fi
            continue
        fi
        if [ -s "$dst" ]; then
            _old=$(wc -c < "$dst" | tr -d ' ')
            _new=$(wc -c < "$tmp" | tr -d ' ')
            if [ "$_old" -gt 4096 ] && [ "$_new" -lt $((_old / 2)) ]; then
                rm -f "$tmp"
                log "REJECT $tag shrink ${_old}->${_new} (kept old)"
                continue
            fi
        fi
        mv "$tmp" "$dst"
        if [ -f "$BASE/patch-provider-v6-resolver.py" ]; then
            for py in python3 python; do
                if command -v "$py" >/dev/null 2>&1; then
                    n=$("$py" "$BASE/patch-provider-v6-resolver.py" "$dst" 2>/dev/null | tail -1)
                    log "v6-resolver $tag $n"
                    break
                fi
            done
        fi
        printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$BASE/state/provider-p${idx}.last-ok"
        log "OK $tag $(wc -c < "$dst") bytes"
        # Remote providers only re-read after PUT; nudge core if API is up.
        if [ "$api_up" -eq 1 ] && [ -n "$enc" ]; then
            curl -sS -o /dev/null --connect-timeout 5 --max-time 60 \
                -X PUT "$API/providers/proxies/$enc" 2>/dev/null || true
        fi
    else
        rm -f "$tmp"
        if [ -s "$dst" ]; then
            log "INVALID $tag (kept old)"
        else
            log "INVALID $tag"
        fi
    fi
done < "$CONF"

if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    tail -c 524288 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
