#!/usr/bin/env pwsh
# Trae 签到令牌守护进程（Windows 计划任务定期调用）
#
# 职责：
#   1. 检测本机 Trae 登录态令牌的有效期
#   2. 令牌临近过期或已过期、且本机已开机时，触发续期（启动客户端 / 等待客户端刷新）
#   3. 令牌变化后同步到 GitHub Secrets，并触发一次云端签到验证链路已恢复
#   4. 本机在线时直接补签，避免 GitHub 定时被跳过造成漏签
#
# 退出码：0 正常  1 其他错误  2 令牌过期且续期失败（需人工重新登录）  3 Secrets 同步失败
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File token-keeper.ps1 -Repo "用户名/仓库名"
#   可选：-Force 强制重新同步（令牌未变也推）  -NoLocalFallback 不做本机补签  -NoDispatch 不触发云端

param(
    [string]$Repo = "Richardzhao-271/trae-daily-checkin",
    [int]$ExpiryWarningHours = 48,
    [int]$RenewWaitMinutes = 10,
    [switch]$Force,
    [switch]$NoLocalFallback,
    [switch]$NoDispatch,
    [string]$StateDir
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "trae-lib.ps1")

Initialize-TraeLog
Write-TraeLog "===== 开始检查 ====="

if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA "TraeCheckinKeeper" }
$state = Get-TraeKeeperState -StateDir $StateDir

# ---------- 1. 读取登录态 ----------
try {
    $auth = Read-TraeAuth
} catch {
    Write-TraeLog $_.Exception.Message "ERROR"
    Write-TraeLog "结论：本机没有可用登录态，请在 Trae 客户端重新登录后重试" "ERROR"
    exit 2
}

Write-TraeLog ("账号：{0}  令牌到期：{1}  刷新令牌到期：{2}" -f `
    $auth.Account, $auth.ExpiresAt, $auth.RefreshExpiresAt)

if (-not $auth.ExpiresAt) {
    Write-TraeLog "无法解析令牌有效期，令牌格式异常" "ERROR"
    exit 2
}

$hoursLeft = [math]::Round(($auth.ExpiresAt - (Get-Date)).TotalHours, 1)
Write-TraeLog ("剩余有效期：{0} 小时" -f $hoursLeft)

# ---------- 2. 必要时续期 ----------
$renewed = $false
if ($hoursLeft -le $ExpiryWarningHours) {
    Write-TraeLog ("令牌将在 {0} 小时内过期，尝试续期" -f $hoursLeft) "WARN"

    if ($auth.RefreshExpiresAt -and $auth.RefreshExpiresAt -lt (Get-Date)) {
        Write-TraeLog ("刷新令牌已于 {0} 过期，无法自动续期，需要人工在 Trae 客户端重新登录" -f $auth.RefreshExpiresAt) "ERROR"
        exit 2
    }

    # 续期依赖 Trae 客户端自身的刷新逻辑：保证进程在跑
    $proc = Get-Process -Name "Trae CN", "Trae", "TRAE SOLO CN", "TRAE SOLO" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) {
        $exe = Resolve-TraeExe
        if ($exe) {
            Write-TraeLog "Trae 未运行，启动客户端以触发令牌续期：$exe"
            try { Start-Process -FilePath $exe | Out-Null } catch {
                Write-TraeLog "启动 Trae 失败：$($_.Exception.Message)" "ERROR"
            }
        } else {
            Write-TraeLog "Trae 未运行且未找到可执行文件，请手动打开客户端" "WARN"
        }
    }

    $oldToken = $auth.Token
    $deadline = (Get-Date).AddMinutes($RenewWaitMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try { $fresh = Read-TraeAuth } catch { continue }
        if ($fresh.Token -ne $oldToken -and $fresh.ExpiresAt -gt (Get-Date)) {
            $auth = $fresh
            $renewed = $true
            Write-TraeLog ("客户端已续期，新到期时间：{0}（剩余 {1} 小时）" -f `
                $auth.ExpiresAt, [math]::Round(($auth.ExpiresAt - (Get-Date)).TotalHours, 1))
            break
        }
    }

    if (-not $renewed) {
        if ((Get-Date) -lt $auth.ExpiresAt) {
            Write-TraeLog "客户端尚未触发续期，但当前令牌仍然有效，先同步现有令牌" "WARN"
        } else {
            Write-TraeLog ("令牌已过期且 {0} 分钟内未完成自动续期。请打开 Trae 客户端停留几分钟，或重新登录" -f $RenewWaitMinutes) "ERROR"
            exit 2
        }
    }
}

# ---------- 3. 同步到 GitHub Secrets ----------
$currentExp = [int64]([DateTimeOffset]$auth.ExpiresAt).ToUnixTimeSeconds()
$needSync = $Force -or $renewed -or (-not $state.LastSyncedExp) -or ([int64]$state.LastSyncedExp -ne $currentExp)

if ($needSync) {
    Write-TraeLog "开始同步令牌到 $Repo"
    $ok = Sync-GitHubSecrets -Repo $Repo -Token $auth.Token -DeviceId $auth.DeviceId
    if (-not $ok) {
        Write-TraeLog "Secrets 同步失败，下次运行会重试" "ERROR"
        $state.LastResult = "sync-failed"
        Save-TraeKeeperState -State $state -StateDir $StateDir
        exit 3
    }
    $state.LastSyncedExp = $currentExp
    $state.LastSyncAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-TraeLog "Secrets 同步完成"
} else {
    Write-TraeLog "令牌未变化，跳过同步（上次同步：$($state.LastSyncAt)）"
}

# ---------- 4. 本机在线的补签兜底 ----------
$today = (Get-Date).ToString("yyyy-MM-dd")
$checkinOk = $false
if (-not $NoLocalFallback) {
    $status = Invoke-TraeApi -Path "/trae/api/v2/ug/checkin_credits/status" -Token $auth.Token -DeviceId $auth.DeviceId
    if (-not $status.Ok -or -not $status.Body) {
        Write-TraeLog "查询签到状态失败：$($status.Raw)" "WARN"
    } elseif ($status.Body.checked_in) {
        Write-TraeLog ("今日已签到，积分：{0} + 额外 {1}" -f $status.Body.credits, $status.Body.extra_credits)
        $checkinOk = $true
    } elseif (-not $status.Body.enable) {
        Write-TraeLog "服务端返回 enable=false，本次不签到（令牌可能已被吊销，考虑 -Force 重新同步）" "WARN"
    } else {
        $claim = Invoke-TraeApi -Path "/trae/api/v2/ug/checkin_credits/claim" -Token $auth.Token -DeviceId $auth.DeviceId
        $code = ""
        if ($claim.Body -and $null -ne $claim.Body.code) { $code = [string]$claim.Body.code }
        if ($claim.Ok -and $code -eq "0") {
            $after = Invoke-TraeApi -Path "/trae/api/v2/ug/checkin_credits/status" -Token $auth.Token -DeviceId $auth.DeviceId
            if ($after.Ok -and $after.Body -and $after.Body.checked_in) {
                Write-TraeLog ("本机补签成功，积分：{0} + 额外 {1}" -f $after.Body.credits, $after.Body.extra_credits)
                $checkinOk = $true
            } else {
                Write-TraeLog "补签接口返回成功，但复核未确认，请到 Trae 客户端核对" "WARN"
            }
        } else {
            Write-TraeLog ("本机补签失败：code={0} {1} {2}" -f $code, $claim.Raw, $claim.Body.message) "ERROR"
        }
    }
    if ($checkinOk) { $state.LastCheckinDay = $today }
}

# ---------- 5. 续期后验证云端链路 ----------
if ($renewed -and $needSync -and -not $NoDispatch) {
    $gh = Resolve-GhPath
    if ($gh) {
        Write-TraeLog "触发一次云端签到，验证链路已恢复"
        $null = & $gh workflow run trae-checkin.yml --repo $Repo 2>&1
        if ($LASTEXITCODE -eq 0) {
            Start-Sleep -Seconds 20
            $runs = & $gh run list --repo $Repo --limit 1 --json databaseId,status,conclusion 2>$null | ConvertFrom-Json
            if ($runs -and $runs.Count -gt 0) {
                $run = $runs[0]
                for ($i = 0; $i -lt 6 -and $run.status -ne "completed"; $i++) {
                    Start-Sleep -Seconds 15
                    $run = (& $gh run list --repo $Repo --limit 1 --json databaseId,status,conclusion | ConvertFrom-Json)[0]
                }
                Write-TraeLog ("云端验证结果：{0}（run {1}）" -f $run.conclusion, $run.databaseId)
                if ($run.conclusion -eq "success") { Write-TraeLog "云端链路已恢复" }
                else { Write-TraeLog "云端验证未通过，请查看 Actions 日志" "WARN" }
            }
        } else {
            Write-TraeLog "触发云端签到失败（gh workflow run 返回 $LASTEXITCODE）" "WARN"
        }
    }
}

$state.LastResult = if ($checkinOk) { "ok" } else { "unknown" }
Save-TraeKeeperState -State $state -StateDir $StateDir
Write-TraeLog "===== 检查结束 ====="
exit 0
