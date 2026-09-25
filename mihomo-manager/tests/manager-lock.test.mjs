import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const hasFlock = !spawnSync("flock", ["--help"]).error;
test("manager lock lifecycle (requires flock; also run on the device)", { skip: !hasFlock }, () => {
  execFileSync("sh", [fileURLToPath(new URL("manager-lock.sh", import.meta.url))], { timeout: 15000 });
});
