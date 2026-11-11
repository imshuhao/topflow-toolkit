#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""联通短信登录：发验证码 → 换 token_online（PC 备用）。

流程对齐 ChinaTelecomOperators 10010_send_sms / 10010_sms_sign 的真实请求：
  1) POST m.client.10010.com/mobileService/sendRadomNum.htm
  2) POST m.client.10010.com/mobileService/radomLogin.htm

用法：
  python balance/unicom-sms-login.py send 186xxxxxxxx
  python balance/unicom-sms-login.py login 186xxxxxxxx 123456
  python balance/unicom-sms-login.py interactive 186xxxxxxxx   # 发码后提示输入验证码
"""

from __future__ import annotations

import argparse
import base64
import json
import random
import string
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

import requests
from Crypto.Cipher import PKCS1_v1_5
from Crypto.PublicKey import RSA

PUBLIC_KEY_PEM = """-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDc+CZK9bBA9IU+gZUOc6FUGu7y
O9WpTNB0PzmgFBh96Mg1WrovD1oqZ+eIF4LjvxKXGOdI79JRdve9NPhQo07+uqGQ
gE4imwNnRx7PFtCRryiIEcUoavuNtuRVoBAm6qdB0SrctgaqGfLgKvZHOnwTjyNq
jBUxzMeQlEC2czEMSwIDAQAB
-----END PUBLIC KEY-----"""

# 短信登录未绑定设备时的占位 appId；成功后以响应里的 appId 为准
PLACEHOLDER_APP_ID = "ChinaunicomMobileBusiness"
SEND_URL = "https://m.client.10010.com/mobileService/sendRadomNum.htm"
LOGIN_URL = "https://m.client.10010.com/mobileService/radomLogin.htm"
SEND_UA = (
    "Dalvik/2.1.0 (Linux; U; Android 14; 2211133C Build/UKQ1.230804.001);"
    "unicom{version:android@11.0900}"
)
LOGIN_UA = (
    "Dalvik/2.1.0 (Linux; U; Android 13; SM-S908U Build/TP1A.220624.014);"
    "unicom{version:android@10.0100}"
)


def rsa_encrypt(content: str) -> str:
    """联通客户端惯例：明文后拼 6 位随机字母数字再 RSA PKCS#1 v1.5。"""
    text = str(content) + "".join(
        random.choices(string.ascii_letters + string.digits, k=6)
    )
    key = RSA.import_key(PUBLIC_KEY_PEM)
    cipher = PKCS1_v1_5.new(key)
    return base64.b64encode(cipher.encrypt(text.encode("utf-8"))).decode("ascii")


def new_device_ids() -> tuple[str, str]:
    device_id = uuid.uuid4().hex
    android_id = device_id[8:24]
    return device_id, android_id


def _post(url: str, data: dict[str, str], ua: str, timeout: float = 25.0) -> dict[str, Any]:
    headers = {
        "User-Agent": ua,
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "*/*",
        "Connection": "keep-alive",
    }
    resp = requests.post(url, data=urlencode(data), headers=headers, timeout=timeout)
    text = resp.text.strip()
    try:
        body = resp.json()
    except Exception:
        raise RuntimeError(f"HTTP {resp.status_code} 非 JSON: {text[:240]}") from None
    if not isinstance(body, dict):
        raise RuntimeError(f"HTTP {resp.status_code} 异常体: {text[:240]}")
    return body


def _result_code(body: dict[str, Any]) -> str:
    for k in ("code", "rsp_code", "rspCode", "resultCode", "status"):
        v = body.get(k)
        if v is not None and str(v).strip() != "":
            return str(v).strip()
    return ""


def _result_msg(body: dict[str, Any]) -> str:
    for k in ("dsc", "desc", "rsp_desc", "rspDesc", "msg", "message"):
        v = body.get(k)
        if v is not None and str(v).strip() != "":
            return str(v).strip()
    return ""


def _ok(code: str) -> bool:
    return code in ("0", "0000", "00000")


def send_sms(mobile: str, app_id: str = "") -> dict[str, Any]:
    mobile = mobile.strip()
    if not mobile.isdigit() or len(mobile) != 11:
        raise ValueError("手机号须为 11 位数字")
    app = (app_id or "").strip() or PLACEHOLDER_APP_ID
    form = {
        "mobile": rsa_encrypt(mobile),
        "version": "android@11.0900",
        "isFirstInstall": "1",
        "appId": app,
    }
    body = _post(SEND_URL, form, SEND_UA)
    code = _result_code(body)
    dsc = _result_msg(body)
    # 有的成功响应只有 rsp_code；也兼容文案
    if not _ok(code) and "验证码已发送" not in dsc:
        raise RuntimeError(f"发码失败 code={code or '?'} {dsc or body}")
    return body


def login_sms(mobile: str, sms_code: str, app_id: str = "") -> dict[str, Any]:
    mobile = mobile.strip()
    sms_code = sms_code.strip()
    if not mobile.isdigit() or len(mobile) != 11:
        raise ValueError("手机号须为 11 位数字")
    if not sms_code.isdigit() or len(sms_code) < 4:
        raise ValueError("验证码格式不对")
    app = (app_id or "").strip() or PLACEHOLDER_APP_ID
    device_id, android_id = new_device_ids()
    form = {
        "deviceOS": "android13",
        "mobile": rsa_encrypt(mobile),
        "password": rsa_encrypt(sms_code),
        "deviceId": device_id,
        "keyVersion": "",
        "deviceBrand": "",
        "provinceChanel": "general",
        "androidId": android_id,
        "deviceModel": "V1936A",
        "version": "android@10.0100",
        "timestamp": time.strftime("%Y%m%d%H%M%S"),
        "isFirstInstall": "1",
        "appId": app,
    }
    body = _post(LOGIN_URL, form, LOGIN_UA)
    code = _result_code(body)
    dsc = _result_msg(body)
    if not _ok(code):
        raise RuntimeError(f"登录失败 code={code or '?'} {dsc or body}")
    token = str(body.get("token_online") or "").strip()
    if not token:
        raise RuntimeError(f"登录成功但无 token_online: {json.dumps(body, ensure_ascii=False)[:400]}")
    return body


def mask_phone(p: str) -> str:
    p = p.strip()
    if len(p) < 7:
        return p
    return p[:3] + "****" + p[-4:]


def print_login_result(body: dict[str, Any], mobile: str) -> None:
    token = str(body.get("token_online") or "")
    app_id = str(body.get("appId") or body.get("appid") or "")
    ecs = str(body.get("ecs_token") or "")
    des = str(body.get("desmobile") or mobile)
    print()
    print("=== 登录成功 ===")
    print(f"手机号: {mask_phone(des)}")
    print(f"appId:  {app_id or '(空，查询时会用占位/默认)'}")
    print(f"token_online ({len(token)} chars):")
    print(token)
    if ecs:
        print(f"ecs_token: {ecs[:24]}…")
    out = Path(__file__).resolve().parent / "unicom-token.last.json"
    payload = {
        "phone": des,
        "token_online": token,
        "app_id": app_id,
        "ecs_token": ecs,
        "raw_keys": sorted(body.keys()),
        "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n已写入 {out}")
    print("把 token_online（和 app_id，若有）填进 accounts.json 的联通卡即可。")


def cmd_send(args: argparse.Namespace) -> int:
    print(f"向 {mask_phone(args.mobile)} 发送联通登录验证码…")
    body = send_sms(args.mobile, args.app_id or "")
    print("发码成功:", json.dumps(body, ensure_ascii=False)[:300])
    print("请查收短信，再用: python balance/unicom-sms-login.py login <手机号> <验证码>")
    return 0


def cmd_login(args: argparse.Namespace) -> int:
    print(f"用验证码登录 {mask_phone(args.mobile)} …")
    body = login_sms(args.mobile, args.code, args.app_id or "")
    print_login_result(body, args.mobile)
    return 0


def cmd_interactive(args: argparse.Namespace) -> int:
    print(f"向 {mask_phone(args.mobile)} 发送联通登录验证码…")
    body = send_sms(args.mobile, args.app_id or "")
    print("发码成功:", json.dumps(body, ensure_ascii=False)[:300])
    try:
        code = input("请输入短信验证码: ").strip()
    except EOFError:
        print("未读到验证码（非交互环境）。请另行运行 login 子命令。", file=sys.stderr)
        return 2
    body = login_sms(args.mobile, code, args.app_id or "")
    print_login_result(body, args.mobile)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="联通短信换 token_online")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument(
            "--app-id",
            default="",
            help="可选；默认用 ChinaunicomMobileBusiness",
        )

    s = sub.add_parser("send", help="发送短信验证码")
    s.add_argument("mobile")
    add_common(s)
    s.set_defaults(func=cmd_send)

    l = sub.add_parser("login", help="验证码换 token")
    l.add_argument("mobile")
    l.add_argument("code")
    add_common(l)
    l.set_defaults(func=cmd_login)

    i = sub.add_parser("interactive", help="发码后交互输入验证码")
    i.add_argument("mobile")
    add_common(i)
    i.set_defaults(func=cmd_interactive)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
