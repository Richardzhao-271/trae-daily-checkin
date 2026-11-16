# 手动同步 Trae 登录态到 GitHub Secrets（日常无需运行，token-keeper.ps1 会自动完成）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\sync-secret.ps1 -Repo "用户名/仓库名"
#   -Force 表示令牌未变化也强制推送

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "trae-lib.ps1")

Initialize-TraeLog

try {
    $auth = Read-TraeAuth
} catch {
    Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-TraeLog ("账号：{0}" -f $auth.Account)
Write-TraeLog ("令牌到期：{0}（剩余 {1} 小时）" -f $auth.ExpiresAt, [math]::Round(($auth.ExpiresAt - (Get-Date)).TotalHours, 1))

if ($auth.ExpiresAt -lt (Get-Date)) {
    Write-Host "[失败] 本机令牌已过期，请先打开 Trae 客户端让它自动续期，再重试" -ForegroundColor Red
    exit 2
}

$ok = Sync-GitHubSecrets -Repo $Repo -Token $auth.Token -DeviceId $auth.DeviceId
if (-not $ok) {
    Write-Host "[失败] 写入 GitHub Secrets 失败，请检查 gh auth status 与仓库名" -ForegroundColor Red
    exit 3
}

$stateDir = Join-Path $env:LOCALAPPDATA "TraeCheckinKeeper"
$state = Get-TraeKeeperState -StateDir $stateDir
$state.LastSyncedExp = [int64]([DateTimeOffset]$auth.ExpiresAt).ToUnixTimeSeconds()
$state.LastSyncAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
Save-TraeKeeperState -State $state -StateDir $stateDir

Write-Host "[成功] 已更新 $Repo 的 TRAE_TOKEN / TRAE_DEVICE_ID" -ForegroundColor Green
Write-Host "        令牌到期：$($auth.ExpiresAt)"
