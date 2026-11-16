#!/usr/bin/env python3
"""Trae 每日签到（GitHub Actions 无人值守运行）。

依赖两个环境变量（来自仓库 Secrets）：
  TRAE_TOKEN      Trae 登录态里的 accessToken（Cloud-IDE-JWT）
  TRAE_DEVICE_ID  客户端设备 ID，签到接口的 x-device-id 头，缺了会返回 9004

凭据只在本进程内存中使用，不打印、不落盘。
幂等：先查 status，今天已签到就直接跳过。

退出码：
  0  成功（本次领取成功，或今天已签到而跳过）
  1  其他失败（网络、服务端异常、签到被拒）
  2  令牌失效（本地 exp 已过期，或服务端拒绝鉴权）——需要本机重新同步令牌
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

API_BASE = "https://api.trae.cn"
STATUS_PATH = "/trae/api/v2/ug/checkin_credits/status"
CLAIM_PATH = "/trae/api/v2/ug/checkin_credits/claim"
TIMEOUT = 25
MAX_ATTEMPTS = 3


def log(msg):
    print(msg, flush=True)


def fail(msg, code):
    log("FAILED: " + msg)
    sys.exit(code)


def jwt_exp(token):
    """不校验签名，只取 exp 做本地过期预判，避免把过期令牌当成"功能已下线"。"""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        return int(data["exp"])
    except Exception:
        return None


def post(path, token, device_id):
    """带退避重试的 POST。返回 (http_status, 原始响应体, 是否可重试失败)。"""
    body = json.dumps({}).encode("utf-8")
    delay = 5
    last = (0, "未知错误")
    for attempt in range(1, MAX_ATTEMPTS + 1):
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
            raw = exc.read().decode("utf-8", "replace")
            # 4xx 是确定性问题，重试无意义
            if 400 <= exc.code < 500 and exc.code != 429:
                return exc.code, raw
            last = (exc.code, raw)
        except urllib.error.URLError as exc:
            last = (0, "网络错误: %s" % exc.reason)
        except Exception as exc:  # 超时、连接重置等
            last = (0, "请求异常: %s" % exc)

        if attempt < MAX_ATTEMPTS:
            log("第 %d/%d 次请求 %s 失败（HTTP %s），%d 秒后重试"
                % (attempt, MAX_ATTEMPTS, path, last[0], delay))
            time.sleep(delay)
            delay *= 3
    return last[0], last[1]


def parse(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return None


def credits_text(data):
    return "%s + 额外 %s" % (data.get("credits", 0), data.get("extra_credits", 0))


def clean(value):
    """去掉首尾空白与 BOM（Windows 端写入 Secret 时可能带上 \\ufeff）。"""
    return value.strip().lstrip("\ufeff").strip()


def check_token_expiry(token):
    exp = jwt_exp(token)
    if exp is None:
        fail("令牌格式无法解析，请在本机重新运行 sync-secret.ps1 同步令牌", 2)
    left = exp - int(time.time())
    if left <= 0:
        fail("令牌已于 %d 小时前过期。请在本机运行 scripts\\token-keeper.ps1 完成续期同步"
             % (-left // 3600), 2)
    if left < 24 * 3600:
        log("提醒：令牌将在 %.1f 小时后过期，请尽快在本机运行 token-keeper.ps1 同步"
            % (left / 3600))


def main():
    token = clean(os.environ.get("TRAE_TOKEN", ""))
    device_id = clean(os.environ.get("TRAE_DEVICE_ID", ""))
    if not token:
        fail("缺少 Secret: TRAE_TOKEN", 2)
    if not device_id:
        fail("缺少 Secret: TRAE_DEVICE_ID", 2)

    # 先本地判过期，避免过期令牌让 status 返回 enable=false 时被误判为"功能下线"
    check_token_expiry(token)

    code, raw = post(STATUS_PATH, token, device_id)
    if code in (401, 403):
        fail("服务端拒绝鉴权（HTTP %s），令牌已失效，请在本机重新同步" % code, 2)
    if code != 200:
        fail("查询签到状态失败（HTTP %s）：%s" % (code, raw[:200]), 1)

    status = parse(raw)
    if status is None:
        fail("签到状态响应不是合法 JSON：%s" % raw[:200], 1)

    if status.get("checked_in"):
        log("今日已签到，跳过。积分：%s" % credits_text(status))
        return

    if not status.get("enable"):
        # 令牌 exp 仍有效却被判不可签，通常是服务端已吊销该令牌或签到功能调整
        fail("签到接口返回 enable=false（令牌未过期但被服务端拒绝）。"
             "请在本机运行 scripts\\token-keeper.ps1 -Force 重新同步令牌", 1)

    code, raw = post(CLAIM_PATH, token, device_id)
    if code in (401, 403):
        fail("签到请求被拒绝（HTTP %s），令牌已失效" % code, 2)
    if code != 200:
        fail("签到请求失败（HTTP %s）：%s" % (code, raw[:200]), 1)

    result = parse(raw) or {}
    body_code = str(result.get("code", ""))
    if body_code != "0":
        msg = result.get("message", raw[:200])
        if str(result.get("code")) == "9004":
            fail("签到被拒：code=9004（设备 ID 不匹配），请在本机重新同步 TRAE_DEVICE_ID", 2)
        fail("签到未成功：code=%s message=%s" % (body_code, msg), 1)

    code, raw = post(STATUS_PATH, token, device_id)
    latest = parse(raw) if code == 200 else None
    if latest and latest.get("checked_in"):
        log("签到成功！本次积分：%s" % credits_text(latest))
    else:
        log("签到接口返回成功（code=0），但复核状态未确认，请手动登录 Trae 核对。")


if __name__ == "__main__":
    main()
