import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const source = readFileSync(new URL("../mihomo-manager.sh", import.meta.url), "utf8");
const body = source.slice(source.indexOf("restore_policy()"), source.indexOf("write_tun_setting()"));
for (const scenario of ["healthy", "unreachable", "timeout"]) {
  test("policy trial " + scenario, () => {
    const dir = mkdtempSync(join(tmpdir(), "mu-policy-"));
    try {
      const result = spawnSync("sh", ["-c", `
        BASE=$WORK
        CONFIG=$BASE/config.yaml
        ACTION_LOG=$BASE/action.log
        SERVICE=restart_from_disk
        mkdir "$BASE/run"
        echo working >"$CONFIG"
        acquire_lock() { return 0; }
        prepare_policy() { echo imported >"$candidate"; }
        service_running() { return 0; }
        result() { echo "result=$1"; }
        ${body}
        internet_status() { echo 3; }
        load_policy() {
          if [ "$1" = "$CONFIG" ]; then echo rollback; return 0; fi
          test "$SCENARIO" != timeout
        }
        policy_health() {
          test "$(cat "$CONFIG")" = working || exit 99
          test "$SCENARIO" = healthy
        }
        restart_from_disk() { echo restart >>"$BASE/recovery"; }
        config_apply_stdin
        cat "$CONFIG"
        if [ -f "$BASE/recovery" ]; then cat "$BASE/recovery"; fi
      `], { env: { ...process.env, WORK: dir, SCENARIO: scenario }, encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      const expected = {
        healthy: "result=1\nimported",
        unreachable: "rollback\nresult=0\nworking",
        timeout: "result=0\nworking\nrestart",
      };
      assert.equal(result.stdout.trim(), expected[scenario]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}
