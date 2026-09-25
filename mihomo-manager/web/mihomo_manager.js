define(["jquery", "service_helper"], function ($, serviceHelper) {
    "use strict";

    var state = null;
    var busy = false;
    var configDirty = false;
    var configLoaded = false;
    var logsLoaded = false;
    var coreUpdateAvailable = false;
    var coreChecking = false;

    function rpc(method, params, done, timeout) {
        var request = serviceHelper.createRequest("mihomo.api", method, params || {});
        $.ajax({
            type: "POST",
            url: "/ubus/?t=" + Date.now(),
            data: JSON.stringify([request]),
            dataType: "json",
            contentType: "application/json",
            headers: { "Z-Mode": "0", "Z-Tag": method },
            cache: false,
            timeout: timeout || 0
        }).done(function (response) {
            var entry = response && response[0];
            if (!entry || entry.error || !entry.result || entry.result[0] !== 0) {
                done(new Error("设备拒绝了此操作，请重新登录后再试"));
                return;
            }
            done(null, entry.result[1] || {});
        }).fail(function (xhr) {
            var rejected = xhr && (xhr.status === 401 || xhr.status === 403);
            var error = new Error(rejected ? "设备拒绝了此操作，请重新登录后再试" : "无法连接设备管理接口");
            error.connectionLost = !rejected;
            done(error);
        });
    }

    function setMessage(message, isError) {
        $("#mm-message").text(message || "").toggleClass("error", !!isError);
    }

    function setLocalMessage(selector, message, isError) {
        $(selector).text(message || "").attr("title", message || "").toggleClass("error", !!isError);
    }

    function setModeMessage(message, isError, details) {
        $("#mm-mode-message").text(message || "").attr("title", details || message || "").toggleClass("error", !!isError);
    }

    function setBusy(value) {
        busy = value;
        $(".mihomo-manager .mm-action").prop("disabled", value);
        if (!value) updateConditionalButtons();
    }

    function updateConditionalButtons() {
        if (busy) return;
        $("#mm-open-panel").prop("disabled", !state || !state.controller_listening);
        $("#mm-core-update").prop("disabled", !coreUpdateAvailable);
        $("#mm-toggle-service").prop("disabled", !state);
        $("#mm-restart").prop("disabled", !state || !state.service_enabled || !state.service_running);
        $("#mm-toggle-dhcp").prop("disabled", !state || !state.service_running || !state.transparent_enabled);
        $(".mm-mode-button").prop("disabled", !state || !state.controller_listening);
    }

    function formatMemory(kb) {
        if (!kb) return "—";
        return (kb / 1024).toFixed(1) + " MB";
    }

    function modeText(mode) {
        if (mode === "SMULTIWAN") return "聚合模式";
        if (mode === "MULTIWAN") return "普通模式";
        if (mode === "NORMAL" || mode === "WAN") return "普通模式";
        return mode || "未知";
    }

    function setSwitch(selector, enabled) {
        $(selector).attr("aria-checked", enabled ? "true" : "false");
    }

    function setInlineStatus(selector, enabled, onText, offText) {
        setInlineState(selector, enabled ? onText : offText, enabled ? "good" : "off");
    }

    function setInlineState(selector, text, kind) {
        $(selector)
            .text(text)
            .removeClass("good warn off")
            .addClass(kind);
    }

    function versionParts(version) {
        var match = (version || "").match(/^Mihomo Meta (v[^ ]+) linux ([^ ]+)(?: with ([^ ]+) (.*))?$/);
        if (!match) return { version: version || "—", build: "" };
        return {
            version: "Mihomo " + match[1],
            build: [match[2], match[3], match[4]].filter(function (part) { return !!part; }).join(" · ")
        };
    }

    function renderHealth(data) {
        var kind = "warn";
        var title = "部分功能未启用";
        var detail = "Mihomo 正在运行，但客户端流量没有完整接管";
        if (!data.service_enabled) {
            kind = "off";
            title = "Mihomo 服务已禁用";
            detail = "客户端正在使用设备原始网络";
        } else if (data.start_pending) {
            kind = "warn";
            title = "Mihomo 等待启动";
            detail = "正在等待可信系统时间，恢复后自动启动";
        } else if (!data.service_running) {
            kind = "off";
            title = "Mihomo 已停止";
            detail = data.manual_stop ? "已手动停止，客户端正在使用设备原始网络" : "客户端正在使用设备原始网络";
        } else if (!data.namespace_present) {
            kind = "off";
            title = "网络组件异常";
            detail = "Mihomo 已运行，但网络命名空间不存在";
        } else if (!data.controller_listening) {
            kind = "warn";
            title = "Mihomo 正在启动";
            detail = "核心已启动，控制接口仍在初始化";
        } else if (data.transparent_enabled && data.dhcp_enabled && data.lan_ipv6_disabled) {
            kind = "good";
            title = "透明网关运行正常";
            detail = "客户端流量由 Mihomo 接管，IPv6 绕过已阻止";
        } else if (data.transparent_enabled && data.dhcp_enabled) {
            title = "透明网关已启用";
            detail = "IPv6 仍可绕过当前透明代理";
        } else if (data.transparent_enabled) {
            title = "透明代理已就绪";
            detail = "尚未通过 DHCP 向客户端下发虚拟网关";
        }
        detail = modeText(data.wan_mode) + " · " + detail;
        $("#mm-health").removeClass("good warn off").addClass(kind);
        $("#mm-health-title").text(title);
        $("#mm-health-detail").text(detail);
    }

    function render(data) {
        var version = versionParts(data.version);
        var rangePrefix = (data.namespace_ip || "192.168.11.11").replace(/\.[0-9]+$/, ".");
        var controllerEndpoint = (data.controller_url || "").replace(/^https?:\/\//, "").replace(/\/.*$/, "");
        var serviceText;
        var serviceKind;
        var runtimeMeta;
        state = data;
        renderHealth(data);
        setSwitch("#mm-toggle-transparent", data.transparent_enabled);
        setSwitch("#mm-toggle-dhcp", data.dhcp_enabled);
        setSwitch("#mm-toggle-ipv6", data.lan_ipv6_disabled);
        if (data.start_pending) {
            setInlineState("#mm-namespace", "等待启动", "warn");
            setInlineState("#mm-controller", "等待启动", "warn");
        } else {
            setInlineStatus("#mm-namespace", data.namespace_present, "正常", "不存在");
            if (data.service_running && !data.controller_listening) {
                setInlineState("#mm-controller", "初始化中", "warn");
            } else {
                setInlineStatus("#mm-controller", data.controller_listening, controllerEndpoint || "可用", "不可用");
            }
        }
        $("#mm-transparent-state").text(data.transparent_enabled ? (data.service_running ? "已开启" : "已配置") : "已关闭");
        $("#mm-transparent-detail").text(data.transparent_enabled ?
            (data.service_running ? "TUN 正在接管经过虚拟网关的流量" : (data.service_enabled ? "Mihomo 启动后自动生效" : "重新启用服务后生效")) :
            "Mihomo 不接管客户端转发流量");
        $("#mm-dhcp-state").text(data.dhcp_enabled ? "已下发" : "未下发");
        $("#mm-dhcp-detail").text(data.dhcp_enabled ? "客户端网关和 DNS 指向 " + (data.namespace_ip || "虚拟网关") :
            (data.dhcp_desired && !data.service_enabled ? "重新启用服务后自动恢复下发" :
                (data.dhcp_desired && (data.start_pending || data.service_running) ? "Mihomo 就绪后自动恢复下发" :
                    (data.transparent_enabled ? "客户端仍使用设备默认网关" : "需先启动服务并开启透明代理"))));
        $("#mm-ipv6-state").text(data.lan_ipv6_disabled ? "已启用" : "未启用");
        $("#mm-ipv6-detail").text(data.lan_ipv6_disabled ? "LAN IPv6 已关闭，避免绕过 IPv4 代理" : "客户端 IPv6 流量不会经过 Mihomo");
        if (!data.service_enabled) {
            serviceText = "已禁用";
            serviceKind = "off";
            runtimeMeta = "当前及开机后均不运行";
        } else if (data.start_pending) {
            serviceText = "等待启动";
            serviceKind = "warn";
            runtimeMeta = "等待可信系统时间后自动启动";
        } else if (!data.service_running) {
            serviceText = "异常";
            serviceKind = "off";
            runtimeMeta = "服务已启用，但核心没有运行";
        } else if (!data.controller_listening) {
            serviceText = "启动中";
            serviceKind = "warn";
            runtimeMeta = "PID " + (data.pid || "—") + " · " + formatMemory(data.rss_kb) + " · 控制接口初始化中";
        } else {
            serviceText = "运行中";
            serviceKind = "good";
            runtimeMeta = "PID " + (data.pid || "—") + " · " + formatMemory(data.rss_kb);
        }
        $("#mm-service").text(serviceText);
        $("#mm-service-dot").removeClass("good warn off").addClass(serviceKind);
        $("#mm-runtime-meta").text(runtimeMeta);
        $("#mm-service-enabled-text").text(data.service_enabled ? "服务已启用，开机后自动运行" : "服务已禁用，重启后保持关闭");
        $("#mm-toggle-service")
            .text(data.service_enabled ? "禁用服务" : "启用服务")
            .toggleClass("mm-button-danger", !!data.service_enabled)
            .toggleClass("mm-button-primary", !data.service_enabled);
        $("#mm-gateway").text(data.namespace_ip || "—");
        $("#mm-range").text(data.dhcp_start && data.dhcp_end ? rangePrefix + data.dhcp_start + "–" + data.dhcp_end : "—");
        $("#mm-mode").text(modeText(data.wan_mode));
        $("#mm-network-meta").text("网关 " + (data.namespace_ip || "—") + " · 地址池 " + (data.dhcp_start && data.dhcp_end ? rangePrefix + data.dhcp_start + "–" + data.dhcp_end : "—"));
        $(".mm-mode-button").attr("aria-pressed", "false").filter('[data-mode="' + (data.proxy_mode || "") + '"]').attr("aria-pressed", "true");
        $("#mm-version").text(version.version).attr("title", data.version || "");
        $("#mm-version-build").text(version.build || "版本信息不可用");
        $("#mm-dhcp-desired").text(data.dhcp_desired ? "继续下发" : "保持关闭");
        $("#mm-updated").text("刚刚更新 · 每 5 秒自动刷新");
        updateConditionalButtons();
    }

    function loadStatus(silent) {
        if (busy) return;
        if (!silent) setMessage("正在读取设备状态……", false);
        rpc("status", {}, function (error, data) {
            // A poll started before an update must not overwrite its progress.
            if (busy) return;
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
            window.setTimeout(function () { loadStatus(true); }, 500);
        });
    }

    function setProxyMode(mode) {
        if (busy || !state || !state.controller_listening || state.proxy_mode === mode) return;
        setBusy(true);
        setModeMessage("切换中", false);
        rpc("proxy_mode_set", { mode: mode }, function (error, data) {
            setBusy(false);
            if (error) {
                setModeMessage("失败", true, error.message);
                return;
            }
            if (data.ok) {
                state.proxy_mode = mode;
                $(".mm-mode-button").attr("aria-pressed", "false").filter('[data-mode="' + mode + '"]').attr("aria-pressed", "true");
            }
            setModeMessage(data.ok ? "已切换" : "失败", !data.ok, data.message || "");
            window.setTimeout(function () { loadStatus(true); }, 300);
        });
    }

    function checkCoreUpdate(silent) {
        if (busy || coreChecking) return;
        coreChecking = true;
        if (!silent) {
            setBusy(true);
            setLocalMessage("#mm-core-message", "正在检查官方版本……", false);
        }
        $("#mm-latest-version").text("检查中……");
        rpc("core_update_check", {}, function (error, data) {
            coreChecking = false;
            if (error || !data.ok) {
                coreUpdateAvailable = false;
                $("#mm-latest-version").text("检查失败");
                if (!silent) {
                    setBusy(false);
                    setLocalMessage("#mm-core-message", error ? error.message : (data.message || "检查更新失败"), true);
                }
                return;
            }
            coreUpdateAvailable = !!data.update_available;
            $("#mm-latest-version").text(data.latest_version || "未知");
            if (!silent) {
                setBusy(false);
                setLocalMessage("#mm-core-message", data.message || "检查完成", false);
            } else {
                updateConditionalButtons();
            }
        });
    }

    function confirmCoreUpdate(latest, previousState, confirmedMessage) {
        var deadline = Date.now() + 120000;
        var wasRunning = previousState && previousState.service_running;
        var previousPid = previousState && previousState.pid;
        setLocalMessage("#mm-core-message", confirmedMessage ?
            "等待服务恢复…" : "正在确认更新…", false);

        function poll() {
            rpc("status", {}, function (error, data) {
                if (error && !error.connectionLost) {
                    setBusy(false);
                    setLocalMessage("#mm-core-message", error.message, true);
                    return;
                }
                if (!error && data.ok) {
                    render(data);
                    setMessage("", false);
                    var versionMatches = versionParts(data.version).version === "Mihomo " + latest;
                    var serviceReady = !wasRunning || (data.service_running && data.namespace_present && data.controller_listening);
                    // The installed binary can change before the old process stops.
                    var restarted = !!confirmedMessage || !wasRunning || (data.pid && previousPid && data.pid !== previousPid);
                    if (versionMatches && serviceReady && restarted) {
                        coreUpdateAvailable = false;
                        setBusy(false);
                        setLocalMessage("#mm-core-message", confirmedMessage ||
                            ("核心已更新到 " + latest + (wasRunning ? "，Mihomo 已恢复运行" : "")), false);
                        return;
                    }
                }
                if (Date.now() >= deadline) {
                    setBusy(false);
                    setLocalMessage("#mm-core-message", "暂未确认更新完成，请检查设备连接和运行日志后再试", true);
                    return;
                }
                window.setTimeout(poll, 2000);
            }, Math.min(5000, Math.max(1, deadline - Date.now())));
        }
        poll();
    }

    function applyCoreUpdate() {
        if (busy || !coreUpdateAvailable) return;
        var latest = $("#mm-latest-version").text();
        if (!window.confirm("更新到 " + latest + " 会重启 Mihomo，是否继续？")) return;
        var previousState = state;
        setBusy(true);
        setMessage("", false);
        setLocalMessage("#mm-core-message", "正在更新核心…", false);
        rpc("core_update_apply", {}, function (error, data) {
            // Never repeat the write: a lost response can mean the restart succeeded.
            if ((error && error.connectionLost) || (!error && data.ok)) {
                confirmCoreUpdate(latest, previousState, error ? "" : (data.message || "核心更新完成"));
                return;
            }
            if (error) {
                setBusy(false);
                setLocalMessage("#mm-core-message", error.message, true);
                return;
            }
            setBusy(false);
            setLocalMessage("#mm-core-message", data.message || "核心更新失败", true);
        });
    }

    function configText() {
        return $("#mm-config-editor").val() || "";
    }

    function escapeHtml(text) {
        return text.replace(/[&<>]/g, function (character) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[character];
        });
    }

    function yamlSpan(type, text) {
        return '<span class="mm-yaml-' + type + '">' + escapeHtml(text) + "</span>";
    }

    function yamlCommentIndex(line) {
        var quote = "";
        var escaped = false;
        for (var i = 0; i < line.length; i += 1) {
            var character = line.charAt(i);
            if (quote === '"') {
                if (escaped) escaped = false;
                else if (character === "\\") escaped = true;
                else if (character === quote) quote = "";
            } else if (quote === "'") {
                if (character === "'" && line.charAt(i + 1) === "'") i += 1;
                else if (character === quote) quote = "";
            } else if (character === '"' || character === "'") {
                quote = character;
            } else if (character === "#" && (i === 0 || /\s/.test(line.charAt(i - 1)))) {
                return i;
            }
        }
        return -1;
    }

    function yamlKeyColon(line) {
        var prefix = line.match(/^\s*(?:-\s+)?/)[0].length;
        var quote = "";
        var escaped = false;
        for (var i = prefix; i < line.length; i += 1) {
            var character = line.charAt(i);
            if (quote === '"') {
                if (escaped) escaped = false;
                else if (character === "\\") escaped = true;
                else if (character === quote) quote = "";
            } else if (quote === "'") {
                if (character === "'" && line.charAt(i + 1) === "'") i += 1;
                else if (character === quote) quote = "";
            } else if (character === '"' || character === "'") {
                quote = character;
            } else if (character === "[" || character === "{") {
                return -1;
            } else if (character === ":" && (i + 1 === line.length || /\s/.test(line.charAt(i + 1)))) {
                return i;
            }
        }
        return -1;
    }

    function highlightYamlValue(value) {
        var output = "";
        var i = 0;
        while (i < value.length) {
            var rest = value.slice(i);
            var character = value.charAt(i);
            var match;
            if (character === '"' || character === "'") {
                var quote = character;
                var end = i + 1;
                var escaped = false;
                while (end < value.length) {
                    var current = value.charAt(end);
                    if (quote === '"') {
                        if (escaped) escaped = false;
                        else if (current === "\\") escaped = true;
                        else if (current === quote) { end += 1; break; }
                    } else if (current === "'" && value.charAt(end + 1) === "'") {
                        end += 2;
                        continue;
                    } else if (current === quote) {
                        end += 1;
                        break;
                    }
                    end += 1;
                }
                output += yamlSpan("string", value.slice(i, end));
                i = end;
            } else if ((character === "&" || character === "*" || character === "!") && (match = rest.match(/^[&*!][A-Za-z0-9_.-]+/))) {
                output += yamlSpan("anchor", match[0]);
                i += match[0].length;
            } else if ((match = rest.match(/^(?:true|false|null|yes|no|on|off|~)(?![A-Za-z0-9_-])/i))) {
                output += yamlSpan("bool", match[0]);
                i += match[0].length;
            } else if ((match = rest.match(/^[+-]?(?:0x[0-9a-f]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)(?![A-Za-z0-9_-])/i)) && !/^\d+\.\d+\./.test(rest)) {
                output += yamlSpan("number", match[0]);
                i += match[0].length;
            } else if (/^[\[\]{},:|>]/.test(character)) {
                output += yamlSpan("punct", character);
                i += 1;
            } else if (character === "-" && (i === 0 || /\s/.test(value.charAt(i - 1))) && /\s/.test(value.charAt(i + 1))) {
                output += yamlSpan("dash", character);
                i += 1;
            } else {
                output += escapeHtml(character);
                i += 1;
            }
        }
        return output;
    }

    function highlightYamlLine(line) {
        var commentAt = yamlCommentIndex(line);
        var code = commentAt < 0 ? line : line.slice(0, commentAt);
        var comment = commentAt < 0 ? "" : line.slice(commentAt);
        var colonAt = yamlKeyColon(code);
        var output;
        if (colonAt < 0) {
            output = highlightYamlValue(code);
        } else {
            var prefixLength = code.match(/^\s*(?:-\s+)?/)[0].length;
            output = highlightYamlValue(code.slice(0, prefixLength));
            output += yamlSpan("key", code.slice(prefixLength, colonAt));
            output += yamlSpan("punct", ":");
            output += highlightYamlValue(code.slice(colonAt + 1));
        }
        if (comment) output += yamlSpan("comment", comment);
        return output;
    }

    function updateConfigHighlight() {
        var html = configText().split("\n").map(highlightYamlLine).join("\n");
        $("#mm-config-highlight").html(html + "\n");
        syncConfigScroll();
    }

    function syncConfigScroll() {
        var editor = $("#mm-config-editor")[0];
        var highlight = $("#mm-config-highlight")[0];
        if (!editor || !highlight) return;
        highlight.scrollTop = editor.scrollTop;
        highlight.scrollLeft = editor.scrollLeft;
    }

    function setConfigResult(message, details, isError) {
        var output = message || "";
        if (details) output += "\n\n" + details;
        $("#mm-config-result").text(output).toggleClass("error", !!isError);
    }

    function updateConfigMeta(label) {
        $("#mm-config-meta").text(label || "已修改");
    }

    function loadConfig(confirmOverwrite) {
        if (busy) return;
        if (confirmOverwrite && configDirty && !window.confirm("重新读取会覆盖编辑区内容，是否继续？")) return;
        setBusy(true);
        setConfigResult("正在读取配置……");
        rpc("config_get", {}, function (error, data) {
            setBusy(false);
            if (error || !data.ok) {
                setConfigResult(error ? error.message : (data.message || "读取配置失败"), "", true);
                return;
            }
            $("#mm-config-editor").val(data.content || "");
            updateConfigHighlight();
            configDirty = false;
            configLoaded = true;
            $("#mm-config-editor").attr("placeholder", "");
            updateConfigMeta(((data.size || 0) / 1024).toFixed(1) + " KB · 已同步");
            setConfigResult("");
        });
    }

    function validateConfig() {
        if (busy) return;
        var content = configText();
        if (!content) {
            setConfigResult("配置为空", "", true);
            return;
        }
        setBusy(true);
        setConfigResult("正在检查配置……");
        rpc("config_validate", { content: content }, function (error, data) {
            setBusy(false);
            if (error) {
                setConfigResult(error.message, "", true);
                return;
            }
            setConfigResult(data.message, data.details, !data.ok);
        });
    }

    function applyConfig() {
        if (busy) return;
        var content = configText();
        if (!content) {
            setConfigResult("配置为空", "", true);
            return;
        }
        if (!window.confirm("应用配置会重启 Mihomo，是否继续？")) return;
        setBusy(true);
        setConfigResult("正在检查并应用配置……");
        rpc("config_apply", { content: content }, function (error, data) {
            setBusy(false);
            if (error) {
                setConfigResult(error.message, "", true);
                return;
            }
            setConfigResult(data.message, data.details, !data.ok);
            if (data.ok) {
                configDirty = false;
                updateConfigMeta((new Blob([content]).size / 1024).toFixed(1) + " KB · 已应用");
                window.setTimeout(function () { loadStatus(true); }, 500);
            }
        });
    }

    function downloadConfig() {
        if (!configText()) {
            setConfigResult("尚未读取配置", "", true);
            return;
        }
        var blob = new Blob([configText()], { type: "text/yaml;charset=utf-8" });
        var url = window.URL.createObjectURL(blob);
        var link = document.createElement("a");
        link.href = url;
        link.download = "mihomo-config.yaml";
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        window.URL.revokeObjectURL(url);
        setConfigResult("配置已下载");
    }

    function loadLogs() {
        if (busy) return;
        setBusy(true);
        $("#mm-logs-meta").text("正在读取……").removeClass("error");
        $("#mm-logs").text("正在读取日志……");
        rpc("logs", { lines: 120 }, function (error, data) {
            setBusy(false);
            if (error) {
                $("#mm-logs-meta").text("读取失败").addClass("error");
                $("#mm-logs").text(error.message);
                return;
            }
            var output = data.log || "没有 Mihomo 运行日志。";
            if (data.action_log) output += "\n\n—— 最近一次管理操作 ——\n" + data.action_log;
            $("#mm-logs").text(output);
            $("#mm-logs-meta").text("最近 120 行 · 已读取").removeClass("error");
            logsLoaded = true;
        });
    }

    function bindActions() {
        $("#mm-refresh").on("click", function () { loadStatus(false); });
        $(".mm-mode-button").on("click", function () { setProxyMode($(this).attr("data-mode")); });
        $("#mm-restart").on("click", function () {
            action("service_restart", {}, "重启期间代理会短暂中断，是否继续？", "#mm-service-message");
        });
        $("#mm-toggle-service").on("click", function () {
            if (!state) return;
            var enabling = !state.service_enabled;
            var warning = enabling ? "" : "禁用服务会停止 Mihomo 并暂时撤销 DHCP 下发；重新启用后会按原设置恢复。是否继续？";
            action("service_set", { enabled: enabling }, warning, "#mm-service-message");
        });
        $("#mm-toggle-transparent").on("click", function () {
            if (!state) return;
            var enabling = !state.transparent_enabled;
            var warning = enabling
                ? "开启透明代理会重启 Mihomo，但不会自动向客户端下发网关。是否继续？"
                : "关闭透明代理会先撤销 DHCP 下发并重启 Mihomo。是否继续？";
            action("transparent_set", { enabled: enabling }, warning, "#mm-traffic-message");
        });
        $("#mm-toggle-dhcp").on("click", function () {
            if (!state) return;
            var enabling = !state.dhcp_enabled;
            var warning = enabling
                ? "开启后，DHCP Wi-Fi 客户端会短暂断开并自动重连，然后使用 192.168.11.11 作为网关和 DNS。是否继续？"
                : "关闭后，DHCP Wi-Fi 客户端会短暂断开并自动重连，恢复设备默认网关。是否继续？";
            action("dhcp_set", { enabled: enabling }, warning, "#mm-traffic-message");
        });
        $("#mm-toggle-ipv6").on("click", function () {
            if (!state) return;
            var disabled = !state.lan_ipv6_disabled;
            var warning = disabled
                ? "关闭 LAN IPv6 可以避免客户端通过 IPv6 绕过当前 IPv4 透明代理。是否继续？"
                : "恢复 LAN IPv6 后，客户端 IPv6 流量不会经过当前 Mihomo 透明网关。是否继续？";
            action("lan_ipv6_set", { disabled: disabled }, warning, "#mm-traffic-message");
        });
        $("#mm-open-panel").on("click", function () {
            if (state && state.controller_url) window.open(state.controller_url, "_blank", "noopener");
        });
        $("#mm-core-check").on("click", function () { checkCoreUpdate(false); });
        $("#mm-core-update").on("click", applyCoreUpdate);
        $("#mm-load-logs").on("click", loadLogs);
        $("#mm-config-load").on("click", function () { loadConfig(true); });
        $("#mm-config-import").on("click", function () { $("#mm-config-file").trigger("click"); });
        $("#mm-config-file").on("change", function () {
            var file = this.files && this.files[0];
            if (!file) return;
            if (file.size > 1048576) {
                setConfigResult("文件不能超过 1 MB", "", true);
                this.value = "";
                return;
            }
            var reader = new FileReader();
            reader.onload = function () {
                $("#mm-config-editor").val(reader.result || "");
                updateConfigHighlight();
                configDirty = true;
                updateConfigMeta(file.name);
                setConfigResult("文件已导入，尚未应用");
            };
            reader.onerror = function () { setConfigResult("读取文件失败", "", true); };
            reader.readAsText(file);
            this.value = "";
        });
        $("#mm-config-download").on("click", downloadConfig);
        $("#mm-config-validate").on("click", validateConfig);
        $("#mm-config-apply").on("click", applyConfig);
        $("#mm-config-editor").on("input", function () {
            configDirty = true;
            updateConfigMeta("已修改");
            updateConfigHighlight();
        });
        $("#mm-config-editor").on("scroll", syncConfigScroll);
        $("#mm-config-details").on("toggle", function () {
            if (this.open && !configLoaded) loadConfig(false);
        });
        $("#mm-logs-details").on("toggle", function () {
            if (this.open && !logsLoaded) loadLogs();
        });
    }

    function init() {
        bindActions();
        loadStatus(false);
        window.setTimeout(function () { checkCoreUpdate(true); }, 700);
        if (typeof addInterval === "function") addInterval(function () { loadStatus(true); }, 5000);
    }

    return { init: init };
});
