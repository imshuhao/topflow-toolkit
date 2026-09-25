import { readFileSync, writeFileSync } from "node:fs";

if (process.argv.length !== 6) {
  console.error("usage: node patch-webui.mjs INPUT_INDEX INPUT_MENU OUTPUT_INDEX OUTPUT_MENU");
  process.exit(2);
}

const [, , inputIndex, inputMenu, outputIndex, outputMenu] = process.argv;
let index = readFileSync(inputIndex, "utf8");
let menu = readFileSync(inputMenu, "utf8");

const hash = "#mihomo_manager";
const route =
  '{hash:"#mihomo_manager",path:"auth/adm/mihomo_manager",requireLogin:!0,checkSIMStatus:!1}';

// Upgrade the old bare child link, which has no styling at the sidebar root.
index = index.replace(
  /<li class="nav"><a href="#mihomo_manager" class="children-link">Mihomo 代理与网关管理<\/a><\/li>\r?\n?/g,
  "",
);

if (!index.includes(`href="${hash}"`)) {
  const mobileLogout = index.indexOf('<div id="mobileLogout"');
  if (mobileLogout < 0) throw new Error("Could not find the mobile logout boundary in index.html");
  const menuEnd = index.lastIndexOf("</ul>", mobileLogout);
  if (menuEnd < 0) throw new Error("Could not find the sidebar list boundary in index.html");
  const entry =
    '<!-- Start TopFlow Mihomo menu. -->\n' +
    '<li class="navigation-drawer -router"><a href="#mihomo_manager" class="parent-link link">Mihomo 代理与网关管理</a></li>\n' +
    '<!-- End TopFlow Mihomo menu. -->\n';
  index = `${index.slice(0, menuEnd)}${entry}${index.slice(menuEnd)}`;
}

if (!menu.includes(`hash:"${hash}"`)) {
  const terminator = /\]\}\);\s*$/;
  if (!terminator.test(menu)) throw new Error("Could not find the route-array terminator in menu.js");
  menu = menu.replace(terminator, `,${route}]});\n`);
}

if (!index.includes(`href="${hash}"`) || !menu.includes(route)) {
  throw new Error("WebUI patch validation failed");
}

writeFileSync(outputIndex, index);
writeFileSync(outputMenu, menu);
