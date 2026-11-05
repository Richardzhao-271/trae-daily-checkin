#!/usr/bin/env python3
"""Trae 每日签到（在 GitHub Actions 里无人值守运行）。

依赖两个环境变量（来自仓库 Secrets）：
  TRAE_TOKEN      Trae 登录态里的 accessToken（Cloud-IDE-JWT）
  TRAE_DEVICE_ID  客户端设备 ID，签到接口的 x-device-id 头，缺了会返回 9004

凭据只在本进程内存中使用，不打印、不落盘。
幂等：先查 status，今天已签到就直接跳过。
"""

import json
import os
import sys
import urllib.error
import urllib.request

API_BASE = "https://api.trae.cn"
STATUS_PATH = "/trae/api/v2/ug/checkin_credits/status"
CLAIM_PATH = "/trae/api/v2/ug/checkin_credits/claim"
TIMEOUT = 25


def log(msg):
    print(msg, flush=True)


def fail(msg):
    log("FAILED: " + msg)
    sys.exit(1)


def post(path, token, device_id):
    body = json.dumps({}).encode("utf-8")
    req = urllib.request.Request(
        API_BASE + path,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Cloud-IDE-JWT " + token,
            "Origin": "https://www.trae.cn",
            "Referer": "https://www.trae.cn/",
            "x-device-id": device_id,
            "User-Agent": "Mozilla/5.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except urllib.error.URLError as exc:
        return 0, "network error: %s" % exc.reason


def parse(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return None


def credits_text(data):
    return "%s + 额外 %s" % (data.get("credits", 0), data.get("extra_credits", 0))


def clean(value):
    """去掉首尾空白与 BOM（Windows 端写入 Secret 时可能带上 \ufeff）。"""
    return value.strip().lstrip("\ufeff").strip()


def main():
    token = clean(os.environ.get("TRAE_TOKEN", ""))
    device_id = clean(os.environ.get("TRAE_DEVICE_ID", ""))
    if not token:
        fail("缺少 Secret: TRAE_TOKEN")
    if not device_id:
        fail("缺少 Secret: TRAE_DEVICE_ID")

    code, raw = post(STATUS_PATH, token, device_id)
    if code in (401, 403):
        fail("令牌已过期（HTTP %s）。在本机重新运行 scripts/sync-secret.ps1 上传新令牌" % code)
    if code == 0:
        fail("网络请求失败：%s" % raw)
    if code != 200:
        fail("查询签到状态失败（HTTP %s）：%s" % (code, raw[:200]))

    status = parse(raw)
    if status is None:
        fail("签到状态响应不是合法 JSON：%s" % raw[:200])

    if status.get("checked_in"):
        log("今日已签到，跳过。积分：%s" % credits_text(status))
        return

    if not status.get("enable"):
        log("服务端已关闭签到功能（enable=false），本次不做任何操作。")
        return

    code, raw = post(CLAIM_PATH, token, device_id)
    if code in (401, 403):
        fail("令牌已过期（HTTP %s）。在本机重新运行 scripts/sync-secret.ps1 上传新令牌" % code)
    if code == 0:
        fail("签到请求网络失败：%s" % raw)

    result = parse(raw) or {}
    body_code = str(result.get("code", ""))
    if body_code != "0":
        # 9004 = 设备头缺失/不匹配；1001 = 认证失败
        fail("签到未成功：code=%s message=%s" % (body_code, result.get("message", raw[:200])))

    code, raw = post(STATUS_PATH, token, device_id)
    latest = parse(raw) if code == 200 else None
    if latest and latest.get("checked_in"):
        log("签到成功！本次积分：%s" % credits_text(latest))
    else:
        log("签到接口返回成功（code=0），但复核状态未确认，请手动登录 Trae 核对。")


if __name__ == "__main__":
    main()
