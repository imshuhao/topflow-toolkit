"use strict";

let accessToken = document.getElementById("access-token").content || null;
let sessionId = null;
let challengeVersion = 0;
let sliderGeometry = null;
let dragStart = null;
let dragTrack = [];
let dragEnd = null;
let currentDeviceId = null;

const element = (id) => document.getElementById(id);
const result = element("result");
const slider = element("slider");

function show(message) {
  result.textContent = message;
}

async function api(path, payload) {
  if (!accessToken) {
    throw new Error("访问授权已失效，请刷新页面");
  }
  const response = await fetch(path, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
    cache: "no-store",
    credentials: "omit",
    redirect: "error",
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401) accessToken = null;
    throw new Error(data.error || "请求失败");
  }
  return data;
}

async function refreshStatus() {
  try {
    const r = await fetch("/api/status", { cache: "no-store" });
    const data = await r.json();
    element("status-box").textContent = JSON.stringify(data, null, 2);
  } catch (e) {
    element("status-box").textContent = String(e);
  }
}

document.querySelectorAll(".tabs button").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tabs button").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    const tab = btn.dataset.tab;
    element("panel-unicom").hidden = tab !== "unicom";
    element("panel-telecom").hidden = tab !== "telecom";
  });
});

element("refresh-status").addEventListener("click", refreshStatus);
refreshStatus();

element("u-send").addEventListener("click", async () => {
  const btn = element("u-send");
  btn.disabled = true;
  show("正在发送联通验证码…");
  try {
    await api("/api/unicom/send", { phone: element("u-phone").value });
    show("联通验证码已发送，请查收后填写。");
  } catch (e) {
    show(e.message);
  } finally {
    btn.disabled = false;
  }
});

element("u-login").addEventListener("click", async () => {
  const btn = element("u-login");
  btn.disabled = true;
  show("正在登录联通…");
  try {
    const data = await api("/api/unicom/login", {
      phone: element("u-phone").value,
      code: element("u-code").value,
    });
    show(`联通授信成功：${data.phone}，token 已写入 accounts.json（长度 ${data.token_len}）。`);
    element("u-code").value = "";
    refreshStatus();
  } catch (e) {
    show(e.message);
  } finally {
    btn.disabled = false;
  }
});

function imageSource(value) {
  if (/^[A-Za-z0-9+/=\r\n]+$/.test(value)) {
    return `data:image/png;base64,${value}`;
  }
  if (/^data:image\/(png|jpeg);base64,[A-Za-z0-9+/=\r\n]+$/.test(value)) {
    return value;
  }
  throw new Error("滑块图片格式无效");
}

function opaqueBounds(piece) {
  const canvas = document.createElement("canvas");
  canvas.width = piece.naturalWidth;
  canvas.height = piece.naturalHeight;
  const context = canvas.getContext("2d");
  if (!context || canvas.width <= 0 || canvas.height <= 0) {
    throw new Error("滑块图片尺寸无效");
  }
  context.drawImage(piece, 0, 0);
  const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
  let left = canvas.width, top = canvas.height, right = -1, bottom = -1;
  for (let y = 0; y < canvas.height; y += 1) {
    for (let x = 0; x < canvas.width; x += 1) {
      if (pixels[(y * canvas.width + x) * 4 + 3] > 128) {
        left = Math.min(left, x);
        top = Math.min(top, y);
        right = Math.max(right, x);
        bottom = Math.max(bottom, y);
      }
    }
  }
  if (right < left || bottom < top) throw new Error("滑块图片没有不透明内容");
  return { x: left, y: top, width: right - left + 1, height: bottom - top + 1 };
}

function normalizedDistance() {
  const maximum = Number(slider.max);
  return maximum > 0 ? Number(slider.value) / maximum : 0;
}

function moveSliderPiece() {
  if (sliderGeometry === null) return;
  const background = element("background");
  const piece = element("slider-piece");
  const scale = background.clientWidth / sliderGeometry.backgroundWidth;
  const nativeLeft = normalizedDistance() * sliderGeometry.travel - sliderGeometry.x;
  piece.style.width = `${sliderGeometry.canvasWidth * scale}px`;
  piece.style.left = `${nativeLeft * scale}px`;
}

function resetWorkflow() {
  sessionId = null;
  sliderGeometry = null;
  dragStart = null;
  dragTrack = [];
  dragEnd = null;
  slider.value = "0";
  slider.disabled = true;
  element("slider-piece").style.left = "0px";
  element("challenge-images").hidden = true;
  element("refresh-button").disabled = true;
  element("send-button").disabled = true;
  element("sms-code").value = "";
  element("sms-code").disabled = true;
  element("submit-button").disabled = true;
  element("service-password").value = "";
  element("service-password").disabled = true;
  element("complete-button").disabled = true;
}

function beginDrag() {
  if (dragStart === null) {
    dragStart = Date.now();
    dragTrack = [];
    dragEnd = null;
  }
}

slider.addEventListener("pointerdown", beginDrag);
slider.addEventListener("keydown", beginDrag);
slider.addEventListener("input", () => {
  beginDrag();
  dragTrack.push(`${normalizedDistance().toFixed(3)}#0.000#${Date.now()}`);
  dragEnd = Date.now();
  moveSliderPiece();
  element("send-button").disabled = false;
});

element("challenge-button").addEventListener("click", async () => {
  const version = ++challengeVersion;
  const button = element("challenge-button");
  resetWorkflow();
  button.disabled = true;
  show("正在获取滑块…");
  try {
    const data = await api("/api/telecom/challenge", { phone: element("phone").value });
    if (version !== challengeVersion) return;
    const challenge = data.challenge;
    const background = element("background");
    const piece = element("slider-piece");
    background.src = imageSource(challenge.background_img);
    piece.src = imageSource(challenge.slider_img);
    await Promise.all([background.decode(), piece.decode()]);
    if (version !== challengeVersion) return;
    const bounds = opaqueBounds(piece);
    const travel = background.naturalWidth - bounds.width;
    if (background.naturalWidth <= 0 || travel <= 0) throw new Error("滑块图片尺寸无效");
    sliderGeometry = { backgroundWidth: background.naturalWidth, canvasWidth: piece.naturalWidth, x: bounds.x, travel };
    sessionId = data.session_id;
    element("challenge-images").hidden = false;
    slider.max = String(travel);
    slider.value = "0";
    slider.disabled = false;
    element("refresh-button").disabled = false;
    moveSliderPiece();
    show("请手动拖动滑块。会话十分钟后过期。");
  } catch (error) {
    if (version === challengeVersion) show(error.message);
  } finally {
    if (version === challengeVersion) button.disabled = false;
  }
});

element("refresh-button").addEventListener("click", async () => {
  const version = challengeVersion;
  const button = element("refresh-button");
  button.disabled = true;
  show("正在刷新滑块…");
  try {
    const data = await api("/api/telecom/refresh", { session_id: sessionId });
    if (version !== challengeVersion) return;
    const challenge = data.challenge;
    const background = element("background");
    const piece = element("slider-piece");
    background.src = imageSource(challenge.background_img);
    piece.src = imageSource(challenge.slider_img);
    await Promise.all([background.decode(), piece.decode()]);
    const bounds = opaqueBounds(piece);
    const travel = background.naturalWidth - bounds.width;
    sliderGeometry = { backgroundWidth: background.naturalWidth, canvasWidth: piece.naturalWidth, x: bounds.x, travel };
    slider.max = String(travel);
    slider.value = "0";
    dragStart = null;
    dragTrack = [];
    dragEnd = null;
    moveSliderPiece();
    show("已刷新滑块，请重新拖动。");
  } catch (error) {
    if (version === challengeVersion) show(error.message);
  } finally {
    if (version === challengeVersion) button.disabled = false;
  }
});

element("send-button").addEventListener("click", async () => {
  const version = challengeVersion;
  const button = element("send-button");
  button.disabled = true;
  try {
    if (!sessionId || dragStart === null || dragEnd === null || dragTrack.length === 0) {
      throw new Error("请先手动拖动滑块");
    }
    await api("/api/telecom/send-sms", {
      session_id: sessionId,
      distance: normalizedDistance(),
      track: dragTrack.join("%"),
      start_time: dragStart,
      end_time: dragEnd,
    });
    if (version !== challengeVersion) return;
    element("sms-code").disabled = false;
    element("submit-button").disabled = false;
    show("短信已请求。请查收后输入六位验证码。");
  } catch (error) {
    if (version === challengeVersion) show(error.message);
  }
});

element("submit-button").addEventListener("click", async () => {
  const version = challengeVersion;
  const button = element("submit-button");
  button.disabled = true;
  try {
    const data = await api("/api/telecom/submit-sms", {
      session_id: sessionId,
      code: element("sms-code").value,
    });
    if (version !== challengeVersion) return;
    currentDeviceId = data.device_id;
    element("device-id-value").textContent = currentDeviceId;
    element("device-id-section").hidden = false;
    element("service-password").disabled = false;
    element("complete-button").disabled = false;
    show("短信登录成功，DeviceId 已写入 accounts；建议再填服务密码验证。");
    refreshStatus();
  } catch (error) {
    if (version === challengeVersion) {
      button.disabled = false;
      show(error.message);
    }
  }
});

element("complete-button").addEventListener("click", async () => {
  const version = challengeVersion;
  const button = element("complete-button");
  button.disabled = true;
  try {
    await api("/api/telecom/complete", {
      session_id: sessionId,
      password: element("service-password").value,
    });
    if (version !== challengeVersion) return;
    show("电信授信完成：服务密码 + DeviceId 已写入。");
    refreshStatus();
  } catch (error) {
    if (version === challengeVersion) {
      button.disabled = false;
      show(error.message);
    }
  }
});

element("copy-button").addEventListener("click", async () => {
  if (!currentDeviceId) {
    show("请先完成短信登录");
    return;
  }
  try {
    await navigator.clipboard.writeText(currentDeviceId);
    show("DeviceId 已复制");
  } catch {
    show("复制失败，请手动选择");
  }
});
