# Trae 登录态 -> GitHub Secrets 同步脚本（Windows PowerShell 5.1）
#
# 作用：从本机 Trae 客户端解密出 accessToken 与设备 ID，直接写入 GitHub 仓库 Secrets，
#       供 .github/workflows/trae-checkin.yml 在云端签到使用。
#       令牌只在内存里流转，不打印、不落盘。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\sync-secret.ps1 -Repo "你的用户名/trae-daily-checkin"
#
# 前置：gh 已登录（gh auth status 通过）、本机 Trae 客户端已登录。
# 说明：accessToken 约 12 天过期，过期后云端会报 401，重新运行本脚本即可。

param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [string]$TokenSecretName = "TRAE_TOKEN",
    [string]$DeviceSecretName = "TRAE_DEVICE_ID"
)

$ErrorActionPreference = "Stop"

function Fail([string]$msg) { Write-Host "[失败] $msg" -ForegroundColor Red; exit 1 }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "未找到 gh（GitHub CLI），请先安装并执行 gh auth login"
}

$ghUser = (& gh api user --jq .login 2>$null)
if (-not $ghUser) { Fail "gh 未登录，请先执行：gh auth login" }

# ---------- 找到并解密 storage.json ----------
$appNames = @("TRAE SOLO CN", "Trae CN", "TRAE SOLO", "Trae")
$storagePath = $null
foreach ($app in $appNames) {
    $p = Join-Path $env:APPDATA "$app\User\globalStorage\storage.json"
    if (Test-Path $p) { $storagePath = $p; break }
}
if (-not $storagePath) { Fail "未找到 Trae 登录态，请确认客户端已安装并登录" }

$storage = Get-Content -Path $storagePath -Raw -Encoding UTF8 | ConvertFrom-Json
$enc = $storage."iCubeAuthInfo://icube.cloudide"
if (-not $enc) { Fail "storage.json 中没有登录态字段，请在 Trae 客户端里重新登录一次" }

$buf = [Convert]::FromBase64String($enc)

$saltA = [byte[]](82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37)
$saltB = [byte[]](31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125)

$salt = New-Object byte[] 64
for ($i = 0; $i -lt 64; $i++) { $salt[$i] = $saltA[$i] -bxor $saltB[$i] }

$random = New-Object byte[] 32
[Array]::Copy($buf, 6, $random, 0, 32)
$cipher = New-Object byte[] ($buf.Length - 38)
[Array]::Copy($buf, 38, $cipher, 0, $cipher.Length)

$sha = [System.Security.Cryptography.SHA512]::Create()
$first = $sha.ComputeHash($random)
$combined = New-Object byte[] 128
[Array]::Copy($first, 0, $combined, 0, 64)
[Array]::Copy($salt, 0, $combined, 64, 64)
$derived = $sha.ComputeHash($combined)

$key = New-Object byte[] 16
[Array]::Copy($derived, 0, $key, 0, 16)
$iv = New-Object byte[] 16
[Array]::Copy($derived, 16, $iv, 0, 16)

$aes = [System.Security.Cryptography.Aes]::Create()
$aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$aes.Key = $key
$aes.IV = $iv
$plainAll = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)

$plain = New-Object byte[] ($plainAll.Length - 64)
[Array]::Copy($plainAll, 64, $plain, 0, $plain.Length)

$auth = [System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
$token = $auth.token
if (-not $token) { Fail "解密结果中没有 token，请在客户端重新登录一次" }

$dcKey = ($storage.PSObject.Properties.Name | Where-Object { $_ -like "iCubeAuthInfo://icube-dc:*" } | Select-Object -First 1)
$deviceId = if ($dcKey) { $dcKey.Substring("iCubeAuthInfo://icube-dc:".Length) } else { $storage."telemetry.devDeviceId" }
if (-not $deviceId) { Fail "未取到设备 ID，请启动一次 Trae 客户端后重试" }

# ---------- 写入 GitHub Secrets ----------
# 必须用 --body 传值：Windows PowerShell 5.1 下通过管道喂给 gh 会被写成空值
& gh secret set $TokenSecretName --repo $Repo --body $token
if ($LASTEXITCODE -ne 0) { Fail "写入 Secret $TokenSecretName 失败（检查仓库名与 gh 权限）" }
& gh secret set $DeviceSecretName --repo $Repo --body $deviceId
if ($LASTEXITCODE -ne 0) { Fail "写入 Secret $DeviceSecretName 失败（检查仓库名与 gh 权限）" }

# ---------- 只报告结果，不输出任何凭据 ----------
$expText = "未知"
try {
    $payload = $token.Split(".")[1].Replace("-", "+").Replace("_", "/")
    switch ($payload.Length % 4) { 2 { $payload += "==" } 3 { $payload += "=" } }
    $jwt = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    if ($jwt.exp) {
        $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$jwt.exp).UtcDateTime.AddHours(8)
        $expText = $exp.ToString("yyyy-MM-dd HH:mm") + "（北京时间）"
    }
} catch {}

Write-Host "[成功] 已更新 $Repo 的 $TokenSecretName / $DeviceSecretName" -ForegroundColor Green
Write-Host "        设备 ID 长度：$($deviceId.Length)"
Write-Host "        当前令牌有效期至：$expText"
