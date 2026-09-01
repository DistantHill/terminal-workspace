[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "WTwork requires PowerShell 7 (pwsh)."
}

$releaseBase = "https://github.com/DistanceHill/SaveTerminalWorkSpace/releases/latest/download"
$archiveUrl = "$releaseBase/WTwork.zip"
$checksumUrl = "$releaseBase/WTwork.zip.sha256"

if ($DryRun) {
    [ordered]@{
        archiveUrl = $archiveUrl
        checksumUrl = $checksumUrl
        installRoot = Join-Path $env:LOCALAPPDATA "WTwork"
        command = "WTwork"
    } | ConvertTo-Json
    exit 0
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "WTwork-install-$([guid]::NewGuid().ToString('N'))"
$archivePath = Join-Path $temporaryRoot "WTwork.zip"
$checksumPath = Join-Path $temporaryRoot "WTwork.zip.sha256"
$extractPath = Join-Path $temporaryRoot "package"

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath
    Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath

    $checksumText = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
    if ($checksumText -notmatch '^(?<hash>[A-Fa-f0-9]{64})(?:\s|$)') {
        throw "The GitHub Release checksum file is invalid."
    }
    $expectedHash = $Matches.hash.ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "WTwork.zip SHA256 verification failed."
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
    $installer = Join-Path $extractPath "Install-WTwork.ps1"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "The release archive does not contain Install-WTwork.ps1."
    }
    & $installer
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
