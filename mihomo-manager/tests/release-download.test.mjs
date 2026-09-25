import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const source = readFileSync(new URL("../mihomo-manager.sh", import.meta.url), "utf8");
const download = source.match(/download_release_file\(\) \{[\s\S]*?\n\}/)[0];

function fetchFile({ running = true, namespace = true, proxyFails = false, directFails = false, core = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "mihomo-release-test-"));
  try {
    const result = spawnSync("sh", ["-c", `
      ACTION_LOG="$WORK/action.log"
      service_running() { test "$RUNNING" = true; }
      namespace_present() { test "$NAMESPACE" = true; }
      local_proxy_url() { printf '%s' 'http://127.0.0.1:7890'; }
      curl() {
        printf '%s\\n' "$*" >>"$WORK/requests"
        route=direct
        target=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --proxy) route=proxy; shift ;;
            -o) shift; target=$1 ;;
          esac
          shift
        done
        # A proxy failure's partial output must not survive into the retry.
        test ! -f "$target" || return 99
        printf '%s' "$route" >"$target"
        if [ "$route" = proxy ]; then test "$PROXY_FAILS" = false; else test "$DIRECT_FAILS" = false; fi
      }
      ${download}
      if [ "$CORE" = true ]; then
        download_release_file "$WORK/release" https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-arm64-v1.19.31.gz
      else
        download_release_file "$WORK/release" https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 10 4
      fi
    `], {
      encoding: "utf8",
      env: { ...process.env, WORK: dir, RUNNING: String(running), NAMESPACE: String(namespace),
        PROXY_FAILS: String(proxyFails), DIRECT_FAILS: String(directFails), CORE: String(core) },
    });
    return { status: result.status, requests: readFileSync(join(dir, "requests"), "utf8").trim().split("\n"),
      body: readFileSync(join(dir, "release"), "utf8") };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("version requests use the running local proxy with a bounded metadata budget", () => {
  const result = fetchFile();
  assert.equal(result.status, 0);
  assert.equal(result.body, "proxy");
  assert.equal(result.requests.length, 1);
  assert.match(result.requests[0], /--proxy http:\/\/127\.0\.0\.1:7890/);
  assert.match(result.requests[0], /--connect-timeout 4 --max-time 10/);
  assert.match(result.requests[0], /https:\/\/api\.github\.com\/repos\/MetaCubeX\/mihomo\/releases\/latest$/);
});

test("a failed proxy request removes partial output and falls back to direct", () => {
  const result = fetchFile({ proxyFails: true });
  assert.equal(result.status, 0);
  assert.equal(result.body, "direct");
  assert.equal(result.requests.length, 2);
  assert.doesNotMatch(result.requests[1], /--proxy/);
  for (const request of result.requests) assert.match(request, /--max-time 10/);
});

for (const unavailable of [{ running: false }, { namespace: false }]) test(`without a ready proxy use direct (${JSON.stringify(unavailable)})`, () => {
  const result = fetchFile(unavailable);
  assert.equal(result.status, 0);
  assert.equal(result.requests.length, 1);
  assert.equal(result.body, "direct");
  assert.doesNotMatch(result.requests[0], /--proxy/);
});

test("failure on both routes is propagated", () => {
  const result = fetchFile({ proxyFails: true, directFails: true });
  assert.notEqual(result.status, 0);
  assert.equal(result.requests.length, 2);
});

test("core packages retain their existing longer download budget", () => {
  const result = fetchFile({ core: true });
  assert.equal(result.status, 0);
  assert.match(result.requests[0], /--connect-timeout 15 --max-time 300/);
});
