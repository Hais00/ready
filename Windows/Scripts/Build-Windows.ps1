# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-x86','win-arm64')][string]$Runtime = 'win-x64',
    [switch]$SkipSteam,
    [switch]$GraphicsChecks,
    [switch]$SessionChecks
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$windows = Join-Path $repo 'Windows'
$destination = Join-Path $repo "Build/Windows/publish/$Runtime"
$evidence = Join-Path $repo "Build/Windows/checks/$Runtime"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
function Dotnet([string[]]$Arguments) {
    & dotnet.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet failed with exit code $LASTEXITCODE" }
}
Push-Location $windows
try {
    # Embedded SPIR-V is architecture independent and does not require a shader
    # compiler/native SPIRV-Cross DLL on the end user's ARM64 or x86 machine.
    $shaders = Join-Path $windows 'Ready.Windows/Shaders'
    $lock = Get-Content (Join-Path $shaders 'shaders.lock.json') -Raw | ConvertFrom-Json
    foreach ($entry in $lock.files.PSObject.Properties) {
        $actual = (Get-FileHash (Join-Path $shaders $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $entry.Value) { throw "Shader source/binary mismatch: $($entry.Name). Recompile with Compile-Shaders.ps1." }
    }
    Dotnet -Arguments @('restore','Ready.Windows.slnx','--locked-mode')
    Dotnet -Arguments @('build','Ready.Windows.slnx','-c','Release','--no-restore','--nologo')
    Dotnet -Arguments @('run','--project','Ready.Windows.Checks','-c','Release','--no-build')
    Dotnet -Arguments @('publish','Ready.Windows','-c','Release','-r',$Runtime,'--self-contained','-o',$destination,'--nologo')
    Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $destination 'LICENSE.txt')
    Copy-Item (Join-Path $repo 'THIRD_PARTY_NOTICES.md') $destination
    Copy-Item (Join-Path $repo 'LICENSES/veldrid-MIT.txt') $destination
    if (-not $SkipSteam) {
        & (Join-Path $PSScriptRoot 'Prepare-SteamKit.ps1')
        $serviceOutput = @(Dotnet -Arguments @('run','--project','Ready.SteamBridge.Checks','-c','Release','-p:TargetFrameworks=net10.0'))
        $serviceLine = $serviceOutput | Where-Object { $_ -like '{"passed":*' } | Select-Object -Last 1
        if (-not $serviceLine) { throw 'Steam service checks did not produce a result.' }
        $serviceResult = $serviceLine | ConvertFrom-Json
        if (-not $serviceResult.passed) { throw 'Steam service checks failed.' }
        New-Item -ItemType Directory -Force $evidence | Out-Null
        [IO.File]::WriteAllText((Join-Path $evidence 'steam-service.json'), $serviceLine, [Text.UTF8Encoding]::new($false))
        Write-Host "Steam service: $($serviceResult.checkCount) offline checks passed."
        Dotnet -Arguments @('publish','Ready.SteamBridge','-c','Release','-r',$Runtime,'--self-contained','-p:TargetFrameworks=net10.0','-o',(Join-Path $destination 'SteamBridge'),'--nologo')
        if ($Runtime -ne 'win-arm64' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
            & (Join-Path $PSScriptRoot 'Test-SteamBridge.ps1') -Executable (Join-Path $destination 'SteamBridge/ReadySteamBridge.exe') -Report (Join-Path $evidence 'steam-adapter.json')
        }
    }
    if ($GraphicsChecks -or $SessionChecks) {
        if ($Runtime -eq 'win-arm64' -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') { throw 'ARM64 execution needs ARM64 Windows hardware.' }
        New-Item -ItemType Directory -Force $evidence | Out-Null
        $fixtureOutput = Join-Path $repo "Build/Windows/fixtures/$Runtime"
        if ($SessionChecks) { Dotnet -Arguments @('publish','Ready.SessionFixture','-c','Release','-r',$Runtime,'--self-contained','-o',$fixtureOutput,'--nologo') }
        $checks = @(); if ($GraphicsChecks) { $checks += 'graphics' }; if ($SessionChecks) { $checks += @('session','window') }
        foreach ($check in $checks) {
            $data = Join-Path $evidence ($check + '-' + [guid]::NewGuid().ToString('N'))
            $arguments = "--$check-self-test --data-root `"$data`" --report `"$(Join-Path $evidence ($check + '.json'))`""
            if ($SessionChecks) { $arguments += " --fixture `"$(Join-Path $fixtureOutput 'Ready.SessionFixture.exe')`"" }
            $process = Start-Process (Join-Path $destination 'Ready.exe') -ArgumentList $arguments -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "$check failed; inspect $evidence and $data" }
        }
    }
    Write-Host "Windows development build: $destination"
}
finally { Pop-Location }
