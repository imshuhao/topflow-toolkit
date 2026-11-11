import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const patcher = resolve(here, "../patch-webui.mjs");

const mihomoIndex =
  '<div id="sidebarMenu"><ul class="main-navigation-list">\n' +
  '                        <li class="navigation-drawer -home">\n' +
  '                            <a href="#home" class="parent-link link" data-trans="home"></a>\n' +
  "                        </li>\n" +
  '                        <li class="nav"><a href="#mihomo_manager" class="children-link">Mihomo</a></li>\n' +
  "</ul></div>\n" +
  '<div id="mobileLogout"></div>\n';
const mihomoMenu =
  'define(function(){return[{hash:"#home"},{hash:"#mihomo_manager",path:"auth/adm/mihomo_manager",requireLogin:!0,checkSIMStatus:!1}]});\n';

function run(mode, work, suffix) {
  const outIndex = resolve(work, `index.${suffix}.html`);
  const outMenu = resolve(work, `menu.${suffix}.js`);
  execFileSync(process.execPath, [
    patcher,
    mode,
    resolve(work, "index.html"),
    resolve(work, "menu.js"),
    outIndex,
    outMenu,
  ]);
  return { index: readFileSync(outIndex, "utf8"), menu: readFileSync(outMenu, "utf8") };
}

test("adds one sing-box entry after Home and stays idempotent", () => {
  const work = mkdtempSync(resolve(tmpdir(), "mu5252-singbox-webui-test-"));
  try {
    writeFileSync(resolve(work, "index.html"), mihomoIndex);
    writeFileSync(resolve(work, "menu.js"), mihomoMenu);

    const first = run("add", work, "first");
    assert.equal(first.index.match(/href="#singbox_manager"/g)?.length, 1);
    assert.equal(first.index.match(/href="#mihomo_manager"/g)?.length, 1);
    assert.equal(first.menu.match(/hash:"#singbox_manager"/g)?.length, 1);
    assert.equal(first.menu.match(/hash:"#mihomo_manager"/g)?.length, 1);
    assert.match(first.menu, /requireLogin:!0/);
    // Placed near the top (right after Home) so it is visible without scrolling.
    assert.ok(
      first.index.indexOf("#singbox_manager") > first.index.indexOf('href="#home"'),
    );
    assert.ok(
      first.index.indexOf("#singbox_manager") < first.index.indexOf("#mihomo_manager"),
    );

    writeFileSync(resolve(work, "index.html"), first.index);
    writeFileSync(resolve(work, "menu.js"), first.menu);
    const second = run("add", work, "second");
    assert.equal(second.index, first.index);
    assert.equal(second.menu, first.menu);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("remove restores the exact Mihomo-only files", () => {
  const work = mkdtempSync(resolve(tmpdir(), "mu5252-singbox-webui-test-"));
  try {
    writeFileSync(resolve(work, "index.html"), mihomoIndex);
    writeFileSync(resolve(work, "menu.js"), mihomoMenu);

    const added = run("add", work, "added");
    writeFileSync(resolve(work, "index.html"), added.index);
    writeFileSync(resolve(work, "menu.js"), added.menu);

    const removed = run("remove", work, "removed");
    assert.equal(removed.index, mihomoIndex);
    assert.equal(removed.menu, mihomoMenu);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("remove tolerates files without a Mihomo entry", () => {
  const work = mkdtempSync(resolve(tmpdir(), "mu5252-singbox-webui-test-"));
  try {
    writeFileSync(resolve(work, "index.html"), '<div id="sidebarMenu"><ul></ul></div>\n<div id="mobileLogout"></div>\n');
    writeFileSync(resolve(work, "menu.js"), 'define(function(){return[{hash:"#home"}]});\n');

    const result = run("remove", work, "stock");
    assert.ok(!result.index.includes("#singbox_manager"));
    assert.ok(!result.menu.includes("#singbox_manager"));
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
