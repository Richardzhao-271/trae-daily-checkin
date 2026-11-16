# Trae 每日自动签到

不用开电脑也能签到：GitHub 云端每天跑两次；本机开机时由守护任务自动续期令牌并补签兜底。

## 为什么之前会失败

Trae 的签到令牌（accessToken）**只有约 14 天有效期**。令牌过期后，`checkin_credits/status` 接口不会返回 401，
而是返回 `HTTP 200` + `enable=false`，看起来像"签到功能已下线"。旧脚本把这个响应当成正常情况并以 0 退出，
于是工作流一路显示绿色成功，实际连续 6 天没有签到。

现在的脚本会先在本地解析 JWT 的 `exp` 字段判过期，过期直接以退出码 2 失败，不再被 `enable=false` 掩盖。

## 整体结构

```
GitHub Actions（云端，无需开机）
  每天 08:30 / 20:30 各跑一次 trae_checkin.py
        ↑ 读取 Secrets: TRAE_TOKEN / TRAE_DEVICE_ID
        │
        │  开机时自动推送新令牌
        │
本机 token-keeper.ps1（Windows 计划任务，每 30 分钟）
  ├─ 读取并解密 Trae 客户端登录态（storage.json）
  ├─ 令牌剩余 < 48 小时 → 启动/等待 Trae 客户端自动续期
  ├─ 令牌变化 → 推送到 GitHub Secrets
  ├─ 本机直接补签（GitHub 定时被跳过时兜底）
  └─ 续期成功后触发一次云端签到，验证链路恢复
```

令牌续期由 Trae 客户端自己完成（refreshToken 有效期约 6 个月），本方案只负责"发现快过期 → 保证客户端在跑 → 把新令牌同步上去"。

## 首次安装（只需一次）

1. 本机已安装并登录 Trae 客户端，已安装 GitHub CLI 且 `gh auth status` 通过。
2. 注册守护任务：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-keeper.ps1 -Repo "你的用户名/trae-daily-checkin"
```

脚本会把运行文件复制到 `%LOCALAPPDATA%\TraeCheckinKeeper\scripts`，并注册计划任务 `TraeCheckinKeeper`
（登录时执行一次，之后每 30 分钟一次；仅在开机登录状态下运行，错过的时段开机后会补跑）。

3. 立即验证一次：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckinKeeper\scripts\token-keeper.ps1" -Repo "你的用户名/trae-daily-checkin"
```

看到 `Secrets 同步完成` 和 `今日已签到` 即正常。

## 日常维护

基本无需干预。查看状态：

```powershell
# 守护任务日志（保留 30 天）
Get-Content "$env:LOCALAPPDATA\TraeCheckinKeeper\logs\keeper-$(Get-Date -f yyyyMMdd).log" -Tail 20

# 上次运行结果
Get-ScheduledTask -TaskName TraeCheckinKeeper | Get-ScheduledTaskInfo

# 云端运行历史
gh run list --repo 你的用户名/trae-daily-checkin --limit 10
```

需要人工介入的唯一情况：日志出现 `刷新令牌已过期` 或 `无法自动续期`。
这表示 refreshToken（约 6 个月）也过期了，打开 Trae 客户端重新登录一次即可，之后守护任务会自动恢复。

## 常用参数

| 脚本 | 参数 | 说明 |
| --- | --- | --- |
| token-keeper.ps1 | `-Force` | 令牌未变化也强制重新推送 Secrets |
| token-keeper.ps1 | `-ExpiryWarningHours 72` | 提前多久开始尝试续期（默认 48 小时） |
| token-keeper.ps1 | `-RenewWaitMinutes 20` | 等待客户端续期的最长时间（默认 10 分钟） |
| token-keeper.ps1 | `-NoLocalFallback` | 不做本机补签，只同步令牌 |
| token-keeper.ps1 | `-NoDispatch` | 续期后不触发云端验证 |
| install-keeper.ps1 | `-Uninstall` | 删除计划任务 |
| sync-secret.ps1 | `-Force` | 手动同步令牌（日常不需要） |

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 正常 |
| 1 | 其他错误（网络、服务端异常） |
| 2 | 令牌过期且无法自动续期 → 需要重新登录 Trae |
| 3 | GitHub Secrets 同步失败（下次运行自动重试） |

## 说明

- 只访问 `api.trae.cn` 官方域名与 GitHub，不上传任何第三方数据。
- 令牌仅在内存中流转，写入 Secrets 后不落盘；日志只记录账号、到期时间和结果。
- 签到幂等：同一设备同一天只会领取一次，重复运行不会多给积分。
