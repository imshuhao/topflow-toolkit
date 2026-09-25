import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const args = process.argv.slice(2);
const includeMihomo = args.includes("--include-mihomo");
const paths = args.filter((arg) => arg !== "--include-mihomo");

if (paths.length !== 5) {
  console.error(
    "usage: node patch-webui.mjs INPUT_INDEX INPUT_MENU INPUT_ROUTER INPUT_NCK OUTPUT_DIR [--include-mihomo]",
  );
  process.exit(2);
}

const [inputIndex, inputMenu, inputRouter, inputNck, outputDir] = paths;
let index = readFileSync(inputIndex, "utf8");
let menu = readFileSync(inputMenu, "utf8");
let router = readFileSync(inputRouter, "utf8");
let networkLock = readFileSync(inputNck, "utf8");

const addedRoutes = [
  ["#dns_settings", "auth/adm/dns_settings"],
  ["#dual_sim_switch", "auth/adm/dual_sim_switch"],
  ["#gearup", "auth/adm/gearup"],
  ["#ims_settings", "auth/adm/ims_settings"],
  ["#key_log_setting", "auth/adm/key_log_setting"],
  ["#plugins", "auth/adm/plugins"],
  ["#sim_switch", "auth/adm/sim_switch"],
  ["#sntp", "auth/adm/sntp"],
  ["#tr069config", "auth/adm/tr069config"],
  ["#working_mode", "auth/adm/working_mode"],
  ["#port_forward", "auth/firewall/port_forward"],
  ["#port_map", "auth/firewall/port_map"],
  ["#qos", "auth/firewall/qos"],
  ["#vpn_client", "auth/firewall/vpn_client"],
  ["#mesh_guide", "auth/mesh/guide_step"],
  ["#mesh_device_list", "auth/mesh/mesh_network_device_list"],
  ["#network_lock", "auth/network_lock"],
  ["#sim_messages", "auth/sms/sim_messages"],
  ["#sms_setting", "auth/sms/sms_setting"],
  ["#voip_setting", "auth/voip/voip_setting"],
  ["#voip_settings", "auth/voip/voip_settings"],
  ["#voip_advanced_settings", "auth/voip/voip_advanced_settings"],
  ["#voip_supplementary_service", "auth/voip/voip_supplementary_service"],
  ["#voip_user_details", "auth/voip/voip_user_details"],
  ["#sleep_settings", "auth/wifi/sleep_settings"],
];

if (includeMihomo) {
  addedRoutes.push(["#mihomo_manager", "auth/adm/mihomo_manager"]);
}

const begin = "<!-- Start TopFlow full menu. -->";
const end = "<!-- End TopFlow full menu. -->";
const hadGeneratedMenu = index.includes(begin);
const existingBlock = new RegExp(
  begin.replace(/[.*+?^()|[\]\\]/g, "\\$&") +
    "[\\s\\S]*?" +
    end.replace(/[.*+?^()|[\]\\]/g, "\\$&") +
    "\\s*",
  "g",
);
index = index.replace(existingBlock, "");

// The full menu owns the one Mihomo link while this overlay is installed.
// Its lower Manager layer retains the standalone entry for uninstall/rollback.
if (includeMihomo) {
  index = index
    .replace(/<!-- Start TopFlow Mihomo menu\. -->[\s\S]*?<!-- End TopFlow Mihomo menu\. -->\s*/g, "")
    .replace(/<li class="nav"><a href="#mihomo_manager" class="children-link">Mihomo 代理与网关管理<\/a><\/li>\r?\n?/g, "");
}

const mihomoEntry = includeMihomo
  ? '<li class="nav"><a href="#mihomo_manager" class="children-link">Mihomo 代理与网关管理</a></li>'
  : "";
const menuBlock = [
  begin,
  '<li class="navigation-drawer -router">',
  '<div class="label"><a href="#" class="parent-link">高级与实验功能</a></div>',
  '<ul class="sub-navigation sub-hide">',
  '<li class="nav"><a href="#url_filter" class="children-link">网址访问过滤</a></li>',
  '<li class="nav"><a href="#port_forward" class="children-link">端口转发（端口范围）</a></li>',
  '<li class="nav"><a href="#port_map" class="children-link">端口映射（源/目标端口）</a></li>',
  '<li class="nav"><a href="#dns_settings" class="children-link">WAN DNS 手动设置</a></li>',
  '<li class="nav"><a href="#vpn_client" class="children-link">VPN 客户端</a></li>',
  '<li class="nav"><a href="#sntp" class="children-link">日期、时区与 NTP 同步</a></li>',
  '<li class="nav"><a href="#sms_setting" class="children-link">短信中心与送达设置</a></li>',
  '<li class="nav"><a href="#dual_sim_switch" class="children-link">双卡、卡槽与智能切换</a></li>',
  '<li class="nav"><a href="#gearup" class="children-link">网易 UU 游戏加速</a></li>',
  '<li class="nav"><a href="#qos" class="children-link">QoS 限速与流量优先级</a></li>',
  '<li class="nav"><a href="#working_mode" class="children-link">业务场景模式</a></li>',
  '<li class="nav"><a href="#mesh_guide" class="children-link">Mesh 组网与设备管理</a></li>',
  '<li class="nav"><a href="#sleep_settings" class="children-link">Wi-Fi 定时开关</a></li>',
  '<li class="nav"><a href="#online_auth" class="children-link">终端上网认证管理</a></li>',
  mihomoEntry,
  "</ul></li>",
  '<li class="navigation-drawer -system">',
  '<div class="label"><a href="#" class="parent-link">高风险功能（谨慎操作）</a></div>',
  '<ul class="sub-navigation sub-hide">',
  '<li class="nav"><a href="#plugins" class="children-link">IPK 插件安装与卸载</a></li>',
  '<li class="nav"><a href="#network_lock" class="children-link">运营商网络解锁（NCK）</a></li>',
  '<li class="nav"><a href="#tr069config" class="children-link">TR-069 远程管理服务器</a></li>',
  '<li class="nav"><a href="#ims_settings" class="children-link">IMS 注册开关</a></li>',
  '<li class="nav"><a href="#voip_setting" class="children-link">语音模式切换</a></li>',
  '<li class="nav"><a href="#voip_settings" class="children-link">SIP 服务器配置</a></li>',
  '<li class="nav"><a href="#voip_advanced_settings" class="children-link">SIP 高级参数</a></li>',
  '<li class="nav"><a href="#voip_supplementary_service" class="children-link">呼叫转移与等待</a></li>',
  '<li class="nav"><a href="#voip_user_details" class="children-link">SIP 账号信息</a></li>',
  '<li class="nav"><a href="#key_log_setting" class="children-link">设备与售后日志</a></li>',
  "</ul></li>",
  '<li class="navigation-drawer -system">',
  '<div class="label"><a href="#" class="parent-link">诊断工具</a></div>',
  '<ul class="sub-navigation sub-hide">',
  '<li class="nav"><a href="#TracingTool" class="children-link">网络流量抓包</a></li>',
  '<li class="nav"><a href="#modem_log" class="children-link">蜂窝基带日志</a></li>',
  '<li class="nav"><a href="#syslog_level" class="children-link">系统日志级别与模块</a></li>',
  "</ul></li>",
  end,
]
  .filter(Boolean)
  .join("\n");

const mobileLogout = index.indexOf('<div id="mobileLogout"');
if (mobileLogout < 0) {
  throw new Error("Could not find the mobile logout boundary in index.html");
}
const menuEnd = index.lastIndexOf("</ul>", mobileLogout);
if (menuEnd < 0) {
  throw new Error("Could not find the sidebar list boundary in index.html");
}
index = index.slice(0, menuEnd) + menuBlock + "\n" + index.slice(menuEnd);

for (const [hash, path] of addedRoutes) {
  if (menu.includes('hash:"' + hash + '"')) continue;
  const route =
    '{hash:"' +
    hash +
    '",path:"' +
    path +
    '",requireLogin:!0,checkSIMStatus:!1}';
  const terminator = /\]\}\);\s*$/;
  if (!terminator.test(menu)) {
    throw new Error("Could not find the route-array terminator in menu.js");
  }
  menu = menu.replace(terminator, "," + route + "]});\n");
}

const diagnosticRedirectNeedle = "licenseChecked&&window.location.replace";
const redirectCount = router.split(diagnosticRedirectNeedle).length - 1;
if (redirectCount > 1) {
  throw new Error("Diagnostic redirect was not unique");
}
if (redirectCount === 0 && !hadGeneratedMenu) {
  throw new Error("Could not find the B20 diagnostic redirect boundary");
}
if (redirectCount === 1) {
  const redirectIndex = router.indexOf(diagnosticRedirectNeedle);
  const start = router.lastIndexOf('"#TracingTool"', redirectIndex);
  const endMarker = '"#check_license")';
  const endIndex = router.indexOf(endMarker, redirectIndex);
  const candidate =
    start >= 0 && endIndex >= 0
      ? router.slice(start, endIndex + endMarker.length)
      : "";
  for (const hash of ["#TracingTool", "#modem_log", "#syslog_level", "#tcpdump_menu"]) {
    if (!candidate.includes(hash)) {
      throw new Error("Diagnostic redirect did not match the expected B20 structure");
    }
  }
  router =
    router.slice(0, start) + "void 0" + router.slice(endIndex + endMarker.length);
}

const replaceAll = (source, search, replacement) =>
  source.split(search).join(replacement);
networkLock = replaceAll(
  networkLock,
  '<h1 data-trans="Home"></h1>',
  "<h1>运营商网络解锁（NCK）</h1>",
);
networkLock = replaceAll(
  networkLock,
  '<p class="colorRed font18" data-trans="network_locked"></p>',
  "<p>此页面仅用于解除运营商施加的 NCK 网络锁，不是 Wi-Fi 密码、频段锁或后台登录锁。</p>",
);
networkLock = replaceAll(
  networkLock,
  "data-bind=\"visible:supportUnlock && times()>0\"",
  "data-bind=\"visible:times()>0\"",
);
networkLock = replaceAll(
  networkLock,
  '<p data-trans="network_locked_explain"></p>',
  '<p class="colorRed font18">输入错误代码会减少剩余次数，请只使用运营商提供的正确代码。</p>',
);
networkLock = replaceAll(
  networkLock,
  '<p data-bind="visible:supportUnlock && times()==0" data-trans="network_locked_zero_times"></p>',
  '<p data-bind="visible:times()==0">当前没有可用的 NCK 解锁尝试；SIM 正常时无需解锁。</p>',
);

if (!index.includes(begin) || !networkLock.includes("运营商网络解锁（NCK）")) {
  throw new Error("WebUI patch validation failed");
}
for (const [hash] of addedRoutes) {
  if (!menu.includes('hash:"' + hash + '"')) {
    throw new Error("Missing generated route: " + hash);
  }
}

mkdirSync(outputDir, { recursive: true });
writeFileSync(resolve(outputDir, "index.html"), index);
writeFileSync(resolve(outputDir, "menu.js"), menu);
writeFileSync(resolve(outputDir, "router.js"), router);
writeFileSync(resolve(outputDir, "network_lock.html"), networkLock);
