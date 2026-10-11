param(
    [ValidateSet('apk', 'web', 'run-web')][string]$Target = 'apk',
    [string]$Flutter = 'flutter',
    [string]$Repository = 'codepa1o/daily-consume-app'
)
$ErrorActionPreference = 'Stop'
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must be OWNER/REPO.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $projectRoot '.env'
if (!(Test-Path -LiteralPath $envFile)) { throw '项目根目录缺少 .env 文件。' }

# 只读取客户端地图所需配置，不把服务端密钥传给 Flutter。
$dotenv = @{}
foreach ($line in Get-Content -LiteralPath $envFile -Encoding utf8) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $key = $Matches[1]
        $value = $Matches[2]
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $dotenv[$key] = $value
    }
}
$amapWebKey = $dotenv['AMAP_WEB_JS_KEY']
if ([string]::IsNullOrWhiteSpace($amapWebKey)) {
    throw '项目根目录 .env 缺少 AMAP_WEB_JS_KEY。'
}

$defines = @(
    "--dart-define=UPDATE_MANIFEST_URL=https://github.com/$Repository/releases/latest/download/latest.json",
    "--dart-define=AMAP_WEB_JS_KEY=$amapWebKey"
)
if (![string]::IsNullOrWhiteSpace($dotenv['AMAP_WEB_JS_SECURITY_CODE'])) {
    $defines += "--dart-define=AMAP_WEB_JS_SECURITY_CODE=$($dotenv['AMAP_WEB_JS_SECURITY_CODE'])"
}
Push-Location $projectRoot
try {
    if ($Target -eq 'run-web') {
        & $Flutter run -d chrome --web-port 8080 @defines
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Web 调试启动失败。' }
    } else {
        & $Flutter build $Target --release @defines
        if ($LASTEXITCODE -ne 0) { throw "Flutter $Target release 构建失败。" }
        if ($Target -eq 'apk') {
            Write-Output 'APK ready: build/app/outputs/flutter-apk/app-release.apk'
        } else {
            Write-Output 'Web build ready: build/web/'
        }
    }
} finally {
    Pop-Location
}
