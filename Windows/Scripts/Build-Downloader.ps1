# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([ValidateSet('win-x64','win-x86','win-arm64')][string]$Runtime='win-x64', [Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
& (Join-Path $PSScriptRoot 'Prepare-Downloader.ps1')
$source=Join-Path $repo 'Build/Windows/depotdownloader'
$project=Join-Path $source 'DepotDownloader/DepotDownloader.csproj'
& dotnet.exe publish $project -c Release -r $Runtime --self-contained -p:EnforceCodeStyleInBuild=false -p:NoWarn=IDE0055 -o $Destination --nologo
if ($LASTEXITCODE) { throw 'Native downloader build failed.' }
Copy-Item (Join-Path $source 'LICENSE') (Join-Path $Destination 'LICENSE-GPL-2.txt')
$marker=@{schema=1;protocol='READY_DOWNLOAD_V1';privateCredentialStdin=$true;originalSourceVersion='3.4.0';realDownloadVerified=$false}
[IO.File]::WriteAllText((Join-Path $Destination '.ready-download-protocol.json'),($marker|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
# Test the exact source in a separate copy; never add fixtures to production.
$scratch=Join-Path $repo ('Build/Windows/depot-checks-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
foreach ($item in (Get-ChildItem $source -Force)) {
    if ($item.Name -eq 'DepotDownloader') {
        $folder=Join-Path $scratch 'DepotDownloader'; New-Item -ItemType Directory $folder | Out-Null
        Get-ChildItem $item.FullName -Force | Where-Object Name -notin @('bin','obj') | Copy-Item -Destination $folder -Recurse
    } else { Copy-Item $item.FullName $scratch -Recurse }
}
Copy-Item (Join-Path $repo 'Scripts/steam_depot_progress_checks.cs') (Join-Path $scratch 'DepotDownloader/ReadyDepotDownloadChecks.cs')
& dotnet.exe build (Join-Path $scratch 'DepotDownloader/DepotDownloader.csproj') -c Release -p:StartupObject=DepotDownloader.ReadyDepotDownloadChecks -p:EnforceCodeStyleInBuild=false -p:NoWarn=IDE0055 -o (Join-Path $scratch 'output') --nologo
if ($LASTEXITCODE) { throw 'Native downloader fixture build failed.' }
$env:READY_DOWNLOAD_PROGRESS_JSON='1'
try { $records=@(& dotnet.exe (Join-Path $scratch 'output/DepotDownloader.dll') (Join-Path $scratch 'data')); if ($LASTEXITCODE) { throw 'Native downloader source checks failed.' } }
finally { Remove-Item Env:READY_DOWNLOAD_PROGRESS_JSON }
$line=$records | Where-Object { $_ -like '{"fixtureOnly":*' } | Select-Object -Last 1
if (-not $line -or -not ($line|ConvertFrom-Json).passed) { throw 'Missing downloader fixture result.' }
$evidence=Join-Path $repo "Build/Windows/checks/$Runtime"; New-Item -ItemType Directory -Force $evidence | Out-Null
[IO.File]::WriteAllText((Join-Path $evidence 'downloader-source.json'),$line,[Text.UTF8Encoding]::new($false))
Write-Host 'Five native downloader source checks passed; no account/CDN used.'
