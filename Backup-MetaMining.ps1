param(
    [string]$SourcePath = '\\wsl.localhost\Ubuntu\home\dev\MetaMining',
    [string]$DestinationPath = 'C:\MetaMining\MetaMining'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "Source folder not found: $SourcePath"
}

New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

& robocopy $SourcePath $DestinationPath /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ
$robocopyExitCode = $LASTEXITCODE

if ($robocopyExitCode -ge 8) {
    throw "Backup failed. Robocopy exited with code $robocopyExitCode."
}

Write-Host "Backup completed: '$SourcePath' -> '$DestinationPath'"
