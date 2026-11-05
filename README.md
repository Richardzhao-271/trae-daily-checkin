# Trae 每日自动签到

不用开电脑：由 GitHub 的云端机器每天自动帮你完成 Trae 的每日签到并领取积分。

- 每天北京时间 **08:30** 自动运行（GitHub 定时任务可能延迟几分钟，不影响积分）
- 也可以在仓库 **Actions** 页面点 **Run workflow** 手动立即执行
- 签到是幂等的：今天已经签过会自动跳过，不会重复调用

## 首次配置（只需做一次）

1. 确保本机已安装并登录 Trae 客户端，且已安装 GitHub CLI（`gh auth status` 能通过）。
2. 在本仓库根目录执行（把 `你的用户名` 换成实际 GitHub 用户名）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sync-secret.ps1 -Repo "你的用户名/trae-daily-checkin"
```

脚本会从本机 Trae 登录态里解密出令牌和设备 ID，直接写入仓库 Secrets（`TRAE_TOKEN`、`TRAE_DEVICE_ID`）。
令牌只在内存中流转，不打印、不落盘。

3. 到仓库 **Actions** 页面手动运行一次，确认日志出现「签到成功」或「今日已签到，跳过」。

## 令牌会过期

Trae 的 accessToken 大约 **12 天**过期。到期后工作流会失败并给你发 GitHub 通知邮件，此时重新执行上面那条命令即可。

当前令牌有效期会在同步脚本输出里显示（北京时间）。

## 说明

- 只访问 `api.trae.cn` 官方域名，不上传任何第三方数据。
- 签到属于官方活动，绕开前端直连后端接口为个人用法；请勿高频调用，避免触发风控。
- 同一设备/同一账号每天只能签到一次，重复运行不会多给积分。
