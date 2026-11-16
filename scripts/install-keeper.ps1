# 安装 / 卸载 Trae 签到令牌守护任务（Windows 计划任务）
#
# 作用：把 token-keeper.ps1 及相关脚本复制到本机固定目录，并注册计划任务，
#       在开机登录后每 30 分钟检查一次令牌状态；电脑关机期间不运行，开机后自动补跑。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install-keeper.ps1 -Repo "用户名/仓库名"
#   powershell -ExecutionPolicy Bypass -File install-keeper.ps1 -Uninstall

param(
    [string]$Repo = "Richardzhao-271/trae-daily-checkin",
    [int]$IntervalMinutes = 30,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$taskName = "TraeCheckinKeeper"
$installDir = Join-Path $env:LOCALAPPDATA "TraeCheckinKeeper"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "[成功] 已删除计划任务 $taskName" -ForegroundColor Green
    } else {
        Write-Host "[提示] 未找到计划任务 $taskName"
    }
    Write-Host "脚本目录仍保留在 $installDir（可手动删除）"
    exit 0
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:ProgramFiles\GitHub CLI\gh.exe")) {
    Write-Host "[失败] 未找到 gh CLI，请先安装 GitHub CLI 并执行 gh auth login" -ForegroundColor Red
    exit 1
}

# 1. 复制脚本到固定目录（不依赖仓库路径，仓库删了也不影响）
$target = Join-Path $installDir "scripts"
if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
foreach ($f in @("trae-lib.ps1", "token-keeper.ps1")) {
    Copy-Item (Join-Path $scriptDir $f) (Join-Path $target $f) -Force
}

# 2. 记录仓库配置
@{ repo = $Repo; installedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") } |
    ConvertTo-Json | Set-Content -Path (Join-Path $installDir "config.json") -Encoding UTF8

$keeper = Join-Path $target "token-keeper.ps1"
$arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$keeper`" -Repo `"$Repo`""

# 3. 注册计划任务：登录时 + 每 N 分钟重复
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments

$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(3) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes))
)

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 5)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal -Force | Out-Null

$installed = Get-ScheduledTask -TaskName $taskName
Write-Host "[成功] 已注册计划任务 $taskName（状态：$($installed.State)）" -ForegroundColor Green
Write-Host "        脚本目录：$target"
Write-Host "        执行频率：登录后立即一次，此后每 $IntervalMinutes 分钟一次（仅开机状态下）"
Write-Host "        日志目录：$(Join-Path $installDir 'logs')"
Write-Host ""
Write-Host "立即验证一次："
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$keeper`" -Repo `"$Repo`""
