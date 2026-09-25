import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const patcher = resolve(here, "../patch-webui.mjs");
const redirect =
  '["#TracingTool","#modem_log","#syslog_level","#tcpdump_menu"].every(Boolean)' +
  '||licenseChecked&&window.location.replace("#check_license")';

for (const legacy of [false, true]) test(`deduplicates Manager and full menu and remains idempotent (legacy=${legacy})`, () => {
  const work = mkdtempSync(resolve(tmpdir(), "topflow-full-menu-test-"));
  try {
    const index = resolve(work, "index.html");
    const menu = resolve(work, "menu.js");
    const router = resolve(work, "router.js");
    const nck = resolve(work, "network_lock.html");
    const first = resolve(work, "first");
    const second = resolve(work, "second");

    writeFileSync(
      index,
      '<div id="sidebarMenu"><ul><li>stock</li></ul></div><div id="mobileLogout"></div>\n',
    );
    writeFileSync(menu, 'define(function(){return[{hash:"#home"}]});\n');
    writeFileSync(router, "function route(){" + redirect + ";}\n");
    writeFileSync(
      nck,
      '<h1 data-trans="Home"></h1><p class="colorRed font18" data-trans="network_locked"></p>' +
        '<div data-bind="visible:supportUnlock && times()>0"></div>' +
        '<p data-trans="network_locked_explain"></p>' +
        '<p data-bind="visible:supportUnlock && times()==0" data-trans="network_locked_zero_times"></p>\n',
    );

    // Exercise both the deployed legacy input and the fixed Manager layer.
    if (legacy) {
      writeFileSync(index, readFileSync(index, "utf8").replace("</ul>",
        '<li class="nav"><a href="#mihomo_manager" class="children-link">Mihomo 代理与网关管理</a></li></ul>'));
    } else execFileSync(process.execPath, [
      resolve(here, "../../mihomo-manager/patch-webui.mjs"),
      index, menu, index, menu,
    ]);

    execFileSync(process.execPath, [
      patcher,
      index,
      menu,
      router,
      nck,
      first,
      "--include-mihomo",
    ]);
    execFileSync(process.execPath, [
      patcher,
      resolve(first, "index.html"),
      resolve(first, "menu.js"),
      resolve(first, "router.js"),
      resolve(first, "network_lock.html"),
      second,
      "--include-mihomo",
    ]);

    const patchedIndex = readFileSync(resolve(first, "index.html"), "utf8");
    const patchedMenu = readFileSync(resolve(first, "menu.js"), "utf8");
    const patchedRouter = readFileSync(resolve(first, "router.js"), "utf8");
    const patchedNck = readFileSync(resolve(first, "network_lock.html"), "utf8");

    assert.equal(patchedIndex.match(/Start TopFlow full menu/g)?.length, 1);
    assert.equal(patchedIndex.match(/href="#mihomo_manager"/g)?.length, 1);
    assert.equal(patchedMenu.match(/hash:"#mihomo_manager"/g)?.length, 1);
    assert.doesNotMatch(patchedRouter, /licenseChecked/);
    assert.match(patchedNck, /运营商网络解锁（NCK）/);
    assert.equal(readFileSync(resolve(second, "index.html"), "utf8"), patchedIndex);
    assert.equal(readFileSync(resolve(second, "menu.js"), "utf8"), patchedMenu);
    assert.equal(readFileSync(resolve(second, "router.js"), "utf8"), patchedRouter);
    assert.equal(readFileSync(resolve(second, "network_lock.html"), "utf8"), patchedNck);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
