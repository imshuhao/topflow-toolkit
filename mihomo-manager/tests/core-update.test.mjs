import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../web/mihomo_manager.js", import.meta.url), "utf8");
const status = (overrides = {}) => ({
  ok: true, service_enabled: true, service_running: true,
  namespace_present: true, controller_listening: true, pid: "100",
  version: "Mihomo Meta v1.19.30 linux arm64 with go1.26.6 build",
  ...overrides,
});
const updated = (overrides = {}) => status({
  version: "Mihomo Meta v1.19.31 linux arm64 with go1.26.8 build", pid: "200", ...overrides,
});

function page(initial = status()) {
  const elements = new Map();
  const pending = [];
  const requests = [];
  const timers = [];
  let now = 0;
  let interval;
  let module;
  function $(selector) {
    if (typeof selector !== "string") return selector;
    if (!elements.has(selector)) {
      elements.set(selector, {
        value: "", props: {}, classes: new Set(), events: {},
        text(value) { if (value === undefined) return this.value; this.value = value; return this; },
        attr(name, value) { if (value === undefined) return this.props[name]; this.props[name] = value; return this; },
        prop(name, value) { return this.attr(name, value); },
        toggleClass(name, enabled) { if (enabled) this.classes.add(name); else this.classes.delete(name); return this; },
        removeClass(names) { names.split(" ").forEach(name => this.classes.delete(name)); return this; },
        addClass(name) { this.classes.add(name); return this; },
        filter() { return this; },
        on(event, handler) { this.events[event] = handler; return this; },
      });
    }
    return elements.get(selector);
  }
  $.ajax = options => {
    const request = {
      method: JSON.parse(options.data)[0].method, options,
      done(fn) { this.success = fn; return this; },
      fail(fn) { this.failure = fn; return this; },
      reply(data) { this.success([{ result: [0, data] }]); },
      disconnect(code = 0) { this.failure({ status: code }); },
    };
    requests.push(request);
    pending.push(request);
    return request;
  };
  vm.runInNewContext(source, {
    define(_deps, factory) { module = factory($, { createRequest: (_api, method) => ({ method }) }); },
    Date: { now: () => now },
    window: { confirm: () => true, setTimeout: (fn, delay) => timers.push({ fn, at: now + delay }) },
    addInterval(fn) { interval = fn; },
  });
  function take(method) {
    const index = pending.findIndex(request => request.method === method);
    assert.notEqual(index, -1, `Expected ${method} request`);
    return pending.splice(index, 1)[0];
  }
  function tick(ms) {
    const end = now + ms;
    timers.sort((a, b) => a.at - b.at);
    while (timers.length && timers[0].at <= end) {
      const timer = timers.shift();
      now = timer.at;
      timer.fn();
      timers.sort((a, b) => a.at - b.at);
    }
    now = end;
  }
  module.init();
  take("status").reply(initial);
  tick(700);
  take("core_update_check").reply({ ok: true, latest_version: "v1.19.31", update_available: true });
  return {
    $, take, tick, pending, requests, poll: () => interval(),
    start() { $("#mm-core-update").events.click(); return take("core_update_apply"); },
    locked: () => $(".mihomo-manager .mm-action").props.disabled,
    message: () => $("#mm-core-message").value,
    error: () => $("#mm-core-message").classes.has("error"),
  };
}

test("lost update response waits through restart and confirms the version without repeating the write", () => {
  const p = page();
  p.start().disconnect();
  assert.equal(p.locked(), true);
  assert.equal(p.error(), false);
  assert.match(p.message(), /正在确认/);
  assert.equal(p.take("status").options.timeout, 5000);
  // The timed-out read has the same recovery behavior as a disconnected read.
  p.requests.at(-1).disconnect();
  p.tick(2000);
  p.take("status").reply(updated({ service_running: false, controller_listening: false }));
  assert.equal(p.locked(), true);
  p.tick(2000);
  p.take("status").reply(updated());
  assert.equal(p.locked(), false);
  assert.equal(p.error(), false);
  assert.match(p.message(), /v1.19.31.*恢复运行/);
  assert.equal(p.$("#mm-core-update").props.disabled, true);
  assert.equal(p.requests.filter(r => r.method === "core_update_apply").length, 1);
});

test("an installed binary is not success while the old process is still running", () => {
  const p = page();
  p.start().disconnect();
  p.take("status").reply(updated({ pid: "100" }));
  assert.equal(p.locked(), true);
  p.tick(2000);
  p.take("status").reply(updated());
  assert.equal(p.locked(), false);
});

test("a successful response still waits for controller recovery", () => {
  const p = page();
  p.start().reply({ ok: true, message: "核心已更新到 v1.19.31，Mihomo 已重启" });
  p.take("status").disconnect();
  assert.equal(p.error(), false);
  p.tick(2000);
  p.take("status").reply(updated({ controller_listening: false }));
  assert.equal(p.locked(), true);
  p.tick(2000);
  p.take("status").reply(updated());
  assert.equal(p.locked(), false);
  assert.match(p.message(), /已重启/);
});

test("updating a stopped service does not require starting it", () => {
  const p = page(status({ service_enabled: false, service_running: false, pid: "" }));
  p.start().disconnect();
  p.take("status").reply(updated({ service_enabled: false, service_running: false, controller_listening: false, pid: "" }));
  assert.equal(p.locked(), false);
  assert.equal(p.message(), "核心已更新到 v1.19.31");
});

for (const code of [401, 403]) test(`HTTP ${code} remains an explicit error`, () => {
  const p = page();
  p.start().disconnect(code);
  assert.equal(p.locked(), false);
  assert.equal(p.error(), true);
  assert.match(p.message(), /重新登录/);
  assert.equal(p.pending.length, 0);
});

test("an RPC permission rejection remains an explicit error", () => {
  const p = page();
  p.start().success([{ result: [6] }]);
  assert.equal(p.error(), true);
  assert.equal(p.pending.length, 0);
});

test("a real update failure is preserved", () => {
  const p = page();
  p.start().reply({ ok: false, message: "新核心启动失败，原核心已恢复" });
  assert.equal(p.locked(), false);
  assert.equal(p.error(), true);
  assert.equal(p.message(), "新核心启动失败，原核心已恢复");
  assert.equal(p.pending.length, 0);
});

for (const unavailable of [true, false]) test(`recovery is bounded and never claims success (unavailable=${unavailable})`, () => {
  const p = page();
  p.start().disconnect();
  for (let i = 0; i <= 60; i++) {
    const read = p.take("status");
    if (unavailable) read.disconnect(); else read.reply(status());
    if (i < 60) p.tick(2000);
  }
  assert.equal(p.locked(), false);
  assert.equal(p.error(), true);
  assert.match(p.message(), /暂未确认更新完成/);
  assert.equal(p.pending.length, 0);
});

test("a poll already in flight cannot overwrite update progress", () => {
  const p = page();
  p.poll();
  const stale = p.take("status");
  p.start();
  stale.disconnect();
  assert.equal(p.$("#mm-message").value, "");
  assert.equal(p.error(), false);
  assert.equal(p.message(), "正在更新核心…");
});

test("a later successful status poll clears an earlier connection error", () => {
  const p = page();
  p.poll();
  p.take("status").disconnect();
  assert.equal(p.$("#mm-message").classes.has("error"), true);
  p.poll();
  p.take("status").reply(status());
  assert.equal(p.$("#mm-message").value, "");
  assert.equal(p.$("#mm-message").classes.has("error"), false);
});
