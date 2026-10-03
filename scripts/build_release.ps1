param(
    [Parameter(Mandatory = $true)][string]$VersionName,
    [Parameter(Mandatory = $true)][int]$VersionCode,
    [Parameter(Mandatory = $true)][string]$NotesFile,
    [string]$Flutter = 'flutter',
    [string]$Repository = 'codepa1o/daily-consume-app'
)
$ErrorActionPreference = 'Stop'
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must be OWNER/REPO.' }
$manifestUrl = "https://github.com/$Repository/releases/latest/download/latest.json"
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($VersionName -notmatch '^\d+\.\d+\.\d+$' -or $VersionCode -le 0) {
    throw 'VersionName must be x.y.z and VersionCode must be positive.'
}
$pubspecFile = Join-Path $projectRoot 'pubspec.yaml'
$pubspecText = Get-Content -LiteralPath $pubspecFile -Raw -Encoding utf8
$current = [regex]::Match($pubspecText, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (!$current.Success -or $VersionCode -le [int]$current.Groups[2].Value) {
    throw 'VersionCode must increase. To rebuild the current version, run flutter build apk --release.'
}
$notes = @(Get-Content -LiteralPath $NotesFile -Encoding utf8 | ForEach-Object {
    $_.Trim() -replace '^[-*\u2022]\s*', ''
} | Where-Object { $_.Length -gt 0 })
if (!$notes.Count -or ($notes -join '').Length -gt 32000) {
    throw 'NotesFile must contain non-empty UTF-8 release notes, one item per line, at most 32000 characters.'
}
if (!(Test-Path -LiteralPath (Join-Path $projectRoot 'android/key.properties'))) {
    throw 'android/key.properties is required. Restore the original signing key before building an update.'
}
$pubspecText = [regex]::Replace($pubspecText, '(?m)^version:.*$', "version: $VersionName+$VersionCode")
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($pubspecFile, $pubspecText, $utf8)
$releaseNotes = @{ versionName = $VersionName; versionCode = $VersionCode; updateManifestUrl = $manifestUrl; releaseNotes = $notes } | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path $projectRoot 'assets/release_notes.json'), $releaseNotes, $utf8)
Push-Location $projectRoot
try {
    & $Flutter build apk --release "--dart-define=UPDATE_MANIFEST_URL=$manifestUrl"
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed. Version and release notes remain saved for correction/rebuild.' }
    Write-Output 'APK ready: build/app/outputs/flutter-apk/app-release.apk'
    Write-Output "Publish with: python scripts/publish_github_release.py --repo $Repository"
} finally {
    Pop-Location
}
