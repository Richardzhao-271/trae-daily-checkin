# Trae 签到公共库：登录态解密、令牌有效期判定、接口调用、GitHub Secrets 同步。
# 由 token-keeper.ps1 / sync-secret.ps1 点源（dot-source）引用。兼容 PowerShell 5.1。

$script:TraeApiBase = "https://api.trae.cn"
$script:TraeApps = @("TRAE SOLO CN", "Trae CN", "TRAE SOLO", "Trae")
$script:TraeLogFile = $null

function Initialize-TraeLog {
    param([string]$LogDirectory)
    if (-not $LogDirectory) {
        $LogDirectory = Join-Path $env:LOCALAPPDATA "TraeCheckinKeeper\logs"
    }
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $script:TraeLogFile = Join-Path $LogDirectory ("keeper-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
    Get-ChildItem $LogDirectory -Filter "keeper-*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-TraeLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")][string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    if ($script:TraeLogFile) {
        try { Add-Content -Path $script:TraeLogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Get-TraeStoragePath {
    $found = @()
    foreach ($app in $script:TraeApps) {
        $p = Join-Path $env:APPDATA "$app\User\globalStorage\storage.json"
        if (Test-Path $p) {
            $found += [pscustomobject]@{
                Path  = $p
                App   = $app
                Mtime = (Get-Item $p).LastWriteTime
            }
        }
    }
    if ($found.Count -eq 0) { return $null }
    # 多客户端并存时取最新写入的那份
    return ($found | Sort-Object Mtime -Descending | Select-Object -First 1)
}

function ConvertFrom-JwtExp {
    param([string]$Token)
    if (-not $Token) { return $null }
    $parts = $Token.Split(".")
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace("-", "+").Replace("_", "/")
    switch ($payload.Length % 4) {
        2 { $payload += "==" }
        3 { $payload += "=" }
    }
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($json.exp) { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$json.exp).LocalDateTime }
    } catch { }
    return $null
}

function Read-TraeAuth {
    param([string]$StoragePath)

    if (-not $StoragePath) {
        $storage = Get-TraeStoragePath
        if (-not $storage) { throw "未找到 Trae 登录态文件 storage.json，请确认客户端已安装并登录" }
        $StoragePath = $storage.Path
    }

    # Trae 写入时可能短暂占用文件，重试读取
    $storage = $null
    for ($i = 1; $i -le 3; $i++) {
        try {
            $storage = Get-Content -Path $StoragePath -Raw -Encoding UTF8 | ConvertFrom-Json
            break
        } catch {
            if ($i -eq 3) { throw "读取 storage.json 失败：$($_.Exception.Message)" }
            Start-Sleep -Milliseconds 500
        }
    }

    $enc = $storage."iCubeAuthInfo://icube.cloudide"
    if (-not $enc) { throw "storage.json 中没有登录态字段，请在 Trae 客户端重新登录一次" }

    $buf = [Convert]::FromBase64String($enc)

    $saltA = [byte[]](82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251, 124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203, 84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78, 8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37)
    $saltB = [byte[]](31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95, 96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239, 160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97, 23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125)

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
    if (-not $auth.token) { throw "解密结果中没有 token，请在客户端重新登录一次" }

    $dcKey = ($storage.PSObject.Properties.Name | Where-Object { $_ -like "iCubeAuthInfo://icube-dc:*" } | Select-Object -First 1)
    if ($dcKey) {
        $deviceId = $dcKey.Substring("iCubeAuthInfo://icube-dc:".Length)
    } else {
        $deviceId = $storage."telemetry.devDeviceId"
    }
    if (-not $deviceId) { throw "未取到设备 ID，请启动一次 Trae 客户端后重试" }

    $exp = ConvertFrom-JwtExp $auth.token
    $refreshExp = $null
    if ($auth.refreshExpiredAt) {
        try { $refreshExp = ([datetime]$auth.refreshExpiredAt).ToLocalTime() } catch { }
    }

    return [pscustomobject]@{
        Token                = $auth.token
        RefreshToken         = $auth.refreshToken
        Account              = $auth.account.username
        ExpiresAt            = $exp
        RefreshExpiresAt     = $refreshExp
        DeviceId             = $deviceId
        StoragePath          = $StoragePath
        StorageMtime         = (Get-Item $StoragePath).LastWriteTime
    }
}

function Invoke-TraeApi {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 25
    )

    $headers = @{
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
        "Authorization" = "Cloud-IDE-JWT $Token"
        "Origin"        = "https://www.trae.cn"
        "Referer"       = "https://www.trae.cn/"
        "x-device-id"   = $DeviceId
        "User-Agent"    = "Mozilla/5.0"
    }

    $delay = 5
    $lastMessage = "未知错误"
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri ($script:TraeApiBase + $Path) -Method POST -Headers $headers `
                -Body "{}" -TimeoutSec $TimeoutSec -UseBasicParsing
            $body = $null
            try { $body = $resp.Content | ConvertFrom-Json } catch { }
            return [pscustomobject]@{ Ok = $true; Status = [int]$resp.StatusCode; Body = $body; Raw = $resp.Content }
        } catch {
            $status = 0
            $raw = ""
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $raw = $_.ErrorDetails.Message }
            $lastMessage = "HTTP $status $($_.Exception.Message)"

            # 4xx 属于确定性错误，不重试（429 限流除外）
            if ($status -ge 400 -and $status -lt 500 -and $status -ne 429) {
                $body = $null
                try { $body = $raw | ConvertFrom-Json } catch { }
                return [pscustomobject]@{ Ok = $false; Status = $status; Body = $body; Raw = $raw }
            }

            Write-TraeLog "请求 $Path 第 $attempt/$MaxAttempts 次失败（$lastMessage）" "WARN"
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $delay
                $delay = $delay * 3
            }
        }
    }
    return [pscustomobject]@{ Ok = $false; Status = -1; Body = $null; Raw = "重试 $MaxAttempts 次仍失败：$lastMessage" }
}

function Resolve-TraeExe {
    # 优先取正在运行的进程路径
    foreach ($name in @("Trae CN", "Trae", "TRAE SOLO CN", "TRAE SOLO")) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
        if ($p) { return $p.Path }
    }

    # 常见安装位置
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Trae CN\Trae CN.exe",
        "$env:ProgramFiles\Trae CN\Trae CN.exe",
        "${env:ProgramFiles(x86)}\Trae CN\Trae CN.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

    # 注册表卸载项里的安装目录
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        $items = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Trae*" -and $_.InstallLocation }
        foreach ($item in $items) {
            $exe = Get-ChildItem $item.InstallLocation -Filter "Trae*.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

function Resolve-GhPath {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\GitHubCLI\gh.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Sync-GitHubSecrets {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [int]$MaxAttempts = 3
    )

    $gh = Resolve-GhPath
    if (-not $gh) { throw "未找到 gh CLI，请先安装 GitHub CLI 并执行 gh auth login" }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $out = & $gh secret set TRAE_TOKEN --repo $Repo --body $Token 2>&1
            if ($LASTEXITCODE -ne 0) { throw "写入 TRAE_TOKEN 失败：$out" }
            $out = & $gh secret set TRAE_DEVICE_ID --repo $Repo --body $DeviceId 2>&1
            if ($LASTEXITCODE -ne 0) { throw "写入 TRAE_DEVICE_ID 失败：$out" }
            return $true
        } catch {
            Write-TraeLog "同步 Secrets 第 $attempt/$MaxAttempts 次失败：$($_.Exception.Message)" "WARN"
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (5 * $attempt) }
        }
    }
    return $false
}

function Get-TraeKeeperState {
    param([string]$StateDir)
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA "TraeCheckinKeeper" }
    $file = Join-Path $StateDir "state.json"
    if (Test-Path $file) {
        try {
            return (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch { }
    }
    return [pscustomobject]@{
        LastSyncedExp  = $null
        LastSyncAt     = $null
        LastCheckinDay = $null
        LastResult     = $null
        LastSeenAt     = $null
    }
}

function Save-TraeKeeperState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$StateDir
    )
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA "TraeCheckinKeeper" }
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $StateDir "state.json") -Encoding UTF8
}
