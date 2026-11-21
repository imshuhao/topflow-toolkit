define(["jquery", "service_helper"], function ($, serviceHelper) {
    "use strict";

    var state = null;
    var busy = false;
    var logsLoaded = false;

    function rpc(method, params, done) {
        var request = serviceHelper.createRequest("singbox.api", method, params || {});
        $.ajax({
            type: "POST",
            url: "/ubus/?t=" + Date.now(),
            data: JSON.stringify([request]),
            dataType: "json",
            contentType: "application/json",
            headers: { "Z-Mode": "0", "Z-Tag": method },
            cache: false
        }).done(function (response) {
            var entry = response && response[0];
            if (!entry || entry.error || !entry.result || entry.result[0] !== 0) {
                done(new Error("设备拒绝了此操作，请重新登录后再试"));
                return;
            }
            done(null, entry.result[1] || {});
        }).fail(function () {
            done(new Error("无法连接设备管理接口"));
        });
    }

    function setMessage(message, isError) {
        $("#sb-message").text(message || "").toggleClass("error", !!isError);
    }

    function setLocalMessage(selector, message, isError) {
        $(selector).text(message || "").attr("title", message || "").toggleClass("error", !!isError);
    }

    function setBusy(value) {
        busy = value;
        $(".singbox-manager .sb-action").prop("disabled", value);
        if (!value) updateConditionalButtons();
    }

    function setInlineStatus(selector, enabled, onText, offText) {
        setInlineState(selector, enabled ? onText : offText, enabled ? "good" : "off");
    }

    function setInlineState(selector, text, kind) {
        $(selector).text(text).removeClass("good warn off").addClass(kind);
    }

    function formatBytes(bytes) {
        var value = Number(bytes) || 0;
        if (value < 1024) return value + " B";
        var units = ["KB", "MB", "GB", "TB"];
        var index = -1;
        do {
            value /= 1024;
            index++;
        } while (value >= 1024 && index < units.length - 1);
        return value.toFixed(value >= 100 ? 0 : 1) + " " + units[index];
    }

    function formatMemory(kb) {
        if (!kb) return "—";
        return (kb / 1024).toFixed(1) + " MB";
    }

    function modeText(mode) {
        var key = (mode || "").toLowerCase();
        if (key === "rule") return "规则（Rule）";
        if (key === "global") return "全局（Global）";
        if (key === "direct") return "直连（Direct）";
        return mode || "未知";
    }

    function updateConditionalButtons() {
        if (busy) return;
        var running = !!(state && state.service_running);
        var rollbackActive = !!(state && state.engine === "mihomo");
        $("#sb-open-panel").prop("disabled", !state || !state.api_ok);
        $("#sb-start").prop("disabled", !state || running);
        $("#sb-stop").prop("disabled", !state || !running);
        $("#sb-restart").prop("disabled", !state || !running);
        $("#sb-switchover").prop("disabled", !state || running);
        $("#sb-rollback").prop("disabled", !state || rollbackActive);
    }

    function renderHealth(data) {
        var kind = "warn";
        var title = "状态未知";
        var detail = "";
        if (data.engine === "mihomo") {
            kind = "warn";
            title = "当前为 mihomo 回滚态";
            detail = "sing-box 未接管；需要恢复请点『切到 sing-box』";
        } else if (data.service_state === "running") {
            var inbound = data.inbound_mode || "tun";
            var captureOk = (typeof data.capture_ok === "boolean") ?
                data.capture_ok :
                (inbound === "ebpf" ?
                    !!(data.service_running && data.api_ok && !data.tun_up) :
                    !!data.tun_up);
            if (!captureOk) {
                kind = "warn";
                title = "核心运行中，数据面未就绪";
                detail = inbound === "ebpf" ?
                    "eBPF 配置异常或残留 sbtun0；客户端可能没有走代理" :
                    "sbtun0 不存在，客户端可能没有走代理";
            } else if (!(data.dhcp_gateway_ok && data.dhcp_dns_ok)) {
                kind = "warn";
                title = "透明网关运行中，DHCP 未指向本机";
                detail = "客户端网关/DNS 应为 192.168.0.1";
            } else {
                kind = "good";
                title = "sing-box 透明网关运行正常";
                detail = inbound === "ebpf" ?
                    "eBPF 数据面已接管，DHCP 3/6 = 192.168.0.1" :
                    "TUN 已接管，DHCP 3/6 = 192.168.0.1";
            }
        } else if (data.service_state === "starting") {
            kind = "warn";
            title = "核心已启动，API 初始化中";
            detail = "通常 3–10 秒后可用";
        } else if (data.service_state === "stopped_manual") {
            kind = "off";
            title = "已手动停止";
            detail = "客户端正在直连；点『启动』可恢复正常代理";
        } else {
            kind = "off";
            title = "sing-box 已停止";
            detail = data.dhcp_points_to_mihomo ?
                "DHCP 仍指向 192.168.0.254，请确认 mihomo 是否在运行" :
                "客户端正在直连，未经代理";
        }
        $("#sb-health").removeClass("good warn off").addClass(kind);
        $("#sb-health-title").text(title);
        $("#sb-health-detail").text(detail);
    }

    function render(data) {
        state = data;
        renderHealth(data);

        $("#sb-engine").text(
            data.engine === "sing-box" ? "sing-box" :
                (data.engine === "mihomo" ? "mihomo（回滚）" : "无")
        );
        $("#sb-mode").text(modeText(data.proxy_mode));
        $("#sb-traffic").text(formatBytes(data.download_total) + " / " + formatBytes(data.upload_total));

        var serviceText;
        var serviceKind;
        var runtimeMeta;
        if (data.service_state === "running") {
            serviceText = "运行中";
            serviceKind = "good";
            runtimeMeta = "PID " + (data.pid || "—") + " · 内存 " + formatMemory(data.rss_kb);
        } else if (data.service_state === "starting") {
            serviceText = "启动中";
            serviceKind = "warn";
            runtimeMeta = "PID " + (data.pid || "—") + " · 等待控制接口";
        } else if (data.service_state === "mihomo_active") {
            serviceText = "未运行（mihomo 接管）";
            serviceKind = "warn";
            runtimeMeta = "回滚态：mihomo netns 正在工作";
        } else if (data.service_state === "stopped_manual") {
            serviceText = "已停止";
            serviceKind = "off";
            runtimeMeta = "手动停止标记存在";
        } else {
            serviceText = "已停止";
            serviceKind = "off";
            runtimeMeta = "核心未运行";
        }
        $("#sb-service").text(serviceText);
        $("#sb-service-dot").removeClass("good warn off").addClass(serviceKind);
        $("#sb-runtime-meta").text(runtimeMeta);

        var inbound = data.inbound_mode || "tun";
        var captureOk = (typeof data.capture_ok === "boolean") ?
            data.capture_ok :
            (inbound === "ebpf" ?
                !!(data.service_running && data.api_ok && !data.tun_up) :
                !!data.tun_up);
        var plane = data.capture_plane || (inbound === "ebpf" ? "unknown" : "tun");
        var iface = data.capture_iface || (inbound === "ebpf" ? "-" : "sbtun0");
        setInlineStatus("#sb-tun", captureOk, "已接管", "未就绪");
        if (inbound === "ebpf") {
            $("#sb-tun-addr").text(plane + " · " + iface +
                (data.tun_up ? "（残留 sbtun0）" : ""));
        } else {
            var addresses = [];
            if (data.tun_addr) addresses.push(data.tun_addr);
            if (data.tun_addr6) addresses.push(data.tun_addr6);
            $("#sb-tun-addr").text(addresses.length ?
                ("sbtun0 · " + addresses.join(" · ")) : "sbtun0");
        }

        if (data.dhcp_gateway_ok && data.dhcp_dns_ok) {
            setInlineState("#sb-dhcp", "3/6 = 192.168.0.1（正常）", "good");
        } else if (data.dhcp_points_to_mihomo) {
            setInlineState("#sb-dhcp", "指向 192.168.0.254（mihomo）", "warn");
        } else if (data.dhcp_options) {
            setInlineState("#sb-dhcp", data.dhcp_options + "（异常）", "off");
        } else {
            setInlineState("#sb-dhcp", "未下发", "off");
        }

        $("#sb-providers").text((data.providers || 0) + " 个");
        setInlineStatus("#sb-watchdog", data.watchdog_running, "运行中", "未运行");
        setInlineStatus("#sb-keeper", data.keeper_running, "运行中", "未运行");
        if (data.manual_stop) {
            setInlineState("#sb-manual", "存在（停止后不会自动拉起）", "warn");
        } else {
            setInlineState("#sb-manual", "无", "good");
        }

        $("#sb-version").text(data.version || "核心未运行").attr("title", data.version || "");
        if (inbound === "ebpf") {
            $("#sb-version-build").text(
                "eBPF " + plane + " · " + iface + " · mixed 7890 · 控制 API 9999");
        } else {
            $("#sb-version-build").text("TUN sbtun0 · mixed 7890 · 控制 API 9999");
        }
        $("#sb-updated").text("刚刚更新 · 每 5 秒自动刷新");
        updateConditionalButtons();
    }

    function loadStatus(silent) {
        if (busy) return;
        if (!silent) setMessage("正在读取设备状态……", false);
        rpc("status", {}, function (error, data) {
            if (error) {
                setMessage(error.message, true);
                return;
            }
            render(data);
            setMessage("", false);
        });
    }

    function action(method, params, confirmText, messageSelector) {
        if (busy) return;
        if (confirmText && !window.confirm(confirmText)) return;
        setBusy(true);
        setLocalMessage(messageSelector, "正在执行……", false);
        rpc(method, params || {}, function (error, data) {
            setBusy(false);
            if (error) {
                setLocalMessage(messageSelector, error.message, true);
                return;
            }
            setLocalMessage(messageSelector, data.message || (data.ok ? "操作完成" : "操作失败"), !data.ok);
            window.setTimeout(function () { loadStatus(true); }, 600);
        });
    }

    function engineSwitch(method, firstWarning, secondWarning) {
        if (busy) return;
        if (!window.confirm(firstWarning)) return;
        if (!window.confirm(secondWarning)) return;
        setBusy(true);
        $("#sb-switch-meta").text("执行中……").removeClass("error");
        $("#sb-switch-result").text("正在执行，请不要关闭页面……");
        rpc(method, {}, function (error, data) {
            setBusy(false);
            if (error) {
                $("#sb-switch-meta").text("失败").addClass("error");
                $("#sb-switch-result").text(error.message);
                return;
            }
            var output = data.message || (data.ok ? "操作完成" : "操作失败");
            if (data.details) output += "\n\n" + data.details;
            $("#sb-switch-result").text(output);
            $("#sb-switch-meta").text(data.ok ? "完成" : "失败").toggleClass("error", !data.ok);
            window.setTimeout(function () { loadStatus(true); }, 800);
        });
    }

    function checkConfig() {
        if (busy) return;
        setBusy(true);
        $("#sb-config-meta").text("检查中……").removeClass("error");
        $("#sb-config-result").text("正在执行 sing-box check……");
        rpc("config_check", {}, function (error, data) {
            setBusy(false);
            if (error) {
                $("#sb-config-meta").text("失败").addClass("error");
                $("#sb-config-result").text(error.message);
                return;
            }
            var output = data.message || "";
            if (data.details) output += "\n\n" + data.details;
            $("#sb-config-result").text(output);
            $("#sb-config-meta").text(data.ok ? "通过" : "失败").toggleClass("error", !data.ok);
        });
    }

    function loadLogs() {
        if (busy) return;
        setBusy(true);
        $("#sb-logs-meta").text("正在读取……").removeClass("error");
        $("#sb-logs").text("正在读取日志……");
        rpc("logs", { lines: 120 }, function (error, data) {
            setBusy(false);
            if (error) {
                $("#sb-logs-meta").text("读取失败").addClass("error");
                $("#sb-logs").text(error.message);
                return;
            }
            $("#sb-logs").text(data.log || "日志为空。");
            $("#sb-logs-meta").text("最近 120 行 · 已读取").removeClass("error");
            logsLoaded = true;
        });
    }

    function bindActions() {
        $("#sb-refresh").on("click", function () { loadStatus(false); });
        $("#sb-open-panel").on("click", function () {
            if (state && state.ui_url) window.open(state.ui_url, "_blank", "noopener");
        });
        $("#sb-start").on("click", function () {
            action("service_start", {}, "", "#sb-service-message");
        });
        $("#sb-stop").on("click", function () {
            action("service_stop", {},
                "停止后所有客户端将直连（不再经过代理），是否继续？", "#sb-service-message");
        });
        $("#sb-restart").on("click", function () {
            action("service_restart", {},
                "重启期间代理会中断约 5–15 秒，是否继续？", "#sb-service-message");
        });
        $("#sb-switchover").on("click", function () {
            engineSwitch("switchover",
                "将停用 mihomo、把 DHCP 网关/DNS 改为 192.168.0.1，并启动 sing-box。执行期间客户端会短暂断网。是否继续？",
                "二次确认：确定切换到 sing-box？");
        });
        $("#sb-rollback").on("click", function () {
            engineSwitch("rollback",
                "将停止 sing-box、把 DHCP 网关/DNS 改为 192.168.0.254，并启动 mihomo netns。该回滚路径尚未演练，失败会导致整网断网，需要 adb 救回。是否继续？",
                "二次确认：确定切回 mihomo？");
        });
        $("#sb-config-check").on("click", checkConfig);
        $("#sb-load-logs").on("click", loadLogs);
        $("#sb-logs-details").on("toggle", function () {
            if (this.open && !logsLoaded) loadLogs();
        });
    }

    function init() {
        bindActions();
        loadStatus(false);
        if (typeof addInterval === "function") addInterval(function () { loadStatus(true); }, 5000);
    }

    return { init: init };
});
