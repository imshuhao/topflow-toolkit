import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const patcher = resolve(here, "../patch-webui.mjs");

for (const legacy of [false, true]) test(`styles one authenticated route and remains idempotent (legacy=${legacy})`, () => {
  const work = mkdtempSync(resolve(tmpdir(), "mu5252-webui-test-"));
  try {
    const inputIndex = resolve(work, "index.html");
    const inputMenu = resolve(work, "menu.js");
    const firstIndex = resolve(work, "first.html");
    const firstMenu = resolve(work, "first.js");
    const secondIndex = resolve(work, "second.html");
    const secondMenu = resolve(work, "second.js");

    writeFileSync(
      inputIndex,
      '<div id="sidebarMenu"><ul><li>stock</li>' +
        (legacy ? '<li class="nav"><a href="#mihomo_manager" class="children-link">Mihomo 代理与网关管理</a></li>' : '') +
        '</ul></div><div id="mobileLogout"></div>\n',
    );
    writeFileSync(inputMenu, 'define(function(){return[{hash:"#home"}]});\n');

    execFileSync(process.execPath, [patcher, inputIndex, inputMenu, firstIndex, firstMenu]);
    execFileSync(process.execPath, [patcher, firstIndex, firstMenu, secondIndex, secondMenu]);

    const index = readFileSync(firstIndex, "utf8");
    const menu = readFileSync(firstMenu, "utf8");
    assert.equal(index.match(/href="#mihomo_manager"/g)?.length, 1);
    assert.match(index, /<li class="navigation-drawer -router">\s*<a href="#mihomo_manager" class="parent-link link">/);
    assert.equal(menu.match(/hash:"#mihomo_manager"/g)?.length, 1);
    assert.match(menu, /requireLogin:!0/);
    assert.equal(readFileSync(secondIndex, "utf8"), index);
    assert.equal(readFileSync(secondMenu, "utf8"), menu);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
