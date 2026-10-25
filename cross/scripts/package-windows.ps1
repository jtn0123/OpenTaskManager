<#
.SYNOPSIS
  Packages the Windows release build: a portable zip, and the installer when
  Inno Setup 6 is installed (CI installs it; without it the installer is
  skipped and the zip is still made).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File cross\scripts\package-windows.ps1 -Exe cross\target\release\opentaskmanager.exe
#>
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Out = (Join-Path $PSScriptRoot '..\dist')
)
$ErrorActionPreference = 'Stop'
$cross = Resolve-Path (Join-Path $PSScriptRoot '..')
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$version = (Select-String -Path (Join-Path $cross 'Cargo.toml') -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value

# Portable: the program, its licence and a note on where it keeps settings.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) "otm-package-$PID"
New-Item -ItemType Directory -Force $staging | Out-Null
try {
    Copy-Item $Exe (Join-Path $staging 'opentaskmanager.exe')
    Copy-Item (Join-Path $cross '..\LICENSE') (Join-Path $staging 'LICENSE.txt')
    $note = "OpenTaskManager $version`r`n`r`nRun opentaskmanager.exe. It needs no installation and no administrator rights.`r`n" +
        "Settings are kept in %APPDATA%\OpenTaskManager. Start at sign-in, in the window's bottom bar, adds a value to your account's Run key.`r`n"
    Set-Content -Path (Join-Path $staging 'README.txt') -Value $note -NoNewline
    $zip = Join-Path $Out "OpenTaskManager-$version-windows-x64.zip"
    Remove-Item $zip -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
    Write-Output "zip: $zip"
} finally {
    Remove-Item -Recurse -Force $staging
}

$iscc = @(
    (Get-Command iscc -ErrorAction SilentlyContinue).Source,
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) {
    Write-Output 'installer: skipped (Inno Setup 6 is not installed)'
    return
}
$script = Join-Path $cross 'packaging\windows\opentaskmanager.iss'
& $iscc /Q "/DVersion=$version" "/DSource=$(Split-Path $Exe)" "/DOutputDir=$Out" $script
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)." }
Write-Output ("installer: " + (Join-Path $Out "OpenTaskManager-$version-windows-x64-setup.exe"))
