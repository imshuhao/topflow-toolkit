import { readFileSync, writeFileSync } from "node:fs";

// Adds or removes the #singbox_manager menu entry and route in the live
// MU5252 WebUI files. The files are the ones bind-mounted by mihomo-manager
// (/data/mihomo-manager/web-root), so the Mihomo entry must be preserved.
//
// usage: node patch-webui.mjs add|remove INPUT_INDEX INPUT_MENU OUTPUT_INDEX OUTPUT_MENU

const [, , mode, inputIndex, inputMenu, outputIndex, outputMenu] = process.argv;
if (!["add", "remove"].includes(mode) || !outputMenu) {
  console.error("usage: node patch-webui.mjs add|remove INPUT_INDEX INPUT_MENU OUTPUT_INDEX OUTPUT_MENU");
  process.exit(2);
}

const hash = "#singbox_manager";
const route =
  '{hash:"#singbox_manager",path:"auth/adm/singbox_manager",requireLogin:!0,checkSIMStatus:!1}';
const label = "Sing-box 代理管理";

let index = readFileSync(inputIndex, "utf8");
let menu = readFileSync(inputMenu, "utf8");
const eol = index.includes("\r\n") ? "\r\n" : "\n";
const hadMihomo =
  index.includes('href="#mihomo_manager"') || menu.includes('hash:"#mihomo_manager"');

function addEntry() {
  // Always relocate: remove a previous copy first, then insert at the top so
  // the entry is visible without scrolling the (long) full menu list.
  removeEntry();
  const entry = `                        <li class="nav"><a href="${hash}" class="children-link">${label}</a></li>${eol}`;
  const home = index.match(/^[ \t]*<li class="navigation-drawer -home">[\s\S]*?<\/li>[ \t]*(?:\r?\n|$)/m);
  if (home) {
    const at = home.index + home[0].length;
    index = index.slice(0, at) + entry + index.slice(at);
    return;
  }
  const mihomo = index.match(/^[ \t]*<li class="nav"><a href="#mihomo_manager"[^\r\n]*<\/li>(?:\r?\n|$)/m);
  if (mihomo) {
    const at = mihomo.index + mihomo[0].length;
    index = index.slice(0, at) + entry + index.slice(at);
    return;
  }
  const mobileLogout = index.indexOf('<div id="mobileLogout"');
  if (mobileLogout < 0) throw new Error("Could not find the mobile logout boundary in index.html");
  const menuEnd = index.lastIndexOf("</ul>", mobileLogout);
  if (menuEnd < 0) throw new Error("Could not find the sidebar list boundary in index.html");
  index = `${index.slice(0, menuEnd)}${entry}${index.slice(menuEnd)}`;
}

function removeEntry() {
  index = index.replace(
    new RegExp('^[ \\t]*<li class="nav"><a href="#singbox_manager"[^\\r\\n]*</li>(?:\\r?\\n|$)', "m"),
    ""
  );
}

function addRoute() {
  if (menu.includes(`hash:"${hash}"`)) return;
  const terminator = /\]\}\);\s*$/;
  if (!terminator.test(menu)) throw new Error("Could not find the route-array terminator in menu.js");
  menu = menu.replace(terminator, `,${route}]});\n`);
}

function removeRoute() {
  menu = menu.replace(/,\{hash:"#singbox_manager"[^{}]*\}/, "");
}

if (mode === "add") {
  addEntry();
  addRoute();
  if (!index.includes(`href="${hash}"`) || !menu.includes(`hash:"${hash}"`)) {
    throw new Error("WebUI patch validation failed (sing-box entry missing)");
  }
} else {
  removeEntry();
  removeRoute();
  if (index.includes(`href="${hash}"`) || menu.includes(`hash:"${hash}"`)) {
    throw new Error("WebUI unpatch validation failed (sing-box entry still present)");
  }
}

// Both modes must leave the Mihomo entry untouched.
if (hadMihomo && (!index.includes('href="#mihomo_manager"') || !menu.includes('hash:"#mihomo_manager"'))) {
  throw new Error("Refusing to write: the Mihomo manager entry disappeared");
}

writeFileSync(outputIndex, index);
writeFileSync(outputMenu, menu);
