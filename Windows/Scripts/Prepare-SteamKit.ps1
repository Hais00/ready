# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $repo 'Build/Windows'
$archive = Join-Path $output 'steamkit-source.tar.gz'
$target = Join-Path $output 'steamkit'
$sourceLock = $null
foreach ($entry in (Get-Content (Join-Path $repo 'sources.lock.json') -Raw | ConvertFrom-Json)) {
    if ($entry.name -eq 'steamkit') { $sourceLock = $entry; break }
}
if ($null -eq $sourceLock -or -not $sourceLock.url) { throw 'Pinned SteamKit source missing from sources.lock.json.' }
$patchLock = Get-Content (Join-Path $repo 'Scripts/steamkit_websocket_close.lock.json') -Raw | ConvertFrom-Json
$patch = Join-Path $repo 'Scripts/steamkit_websocket_close.patch'
function Hash([string]$path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
if ((Hash $patch) -ne $patchLock.patchSHA256) { throw 'SteamKit patch hash changed.' }
$sourceFile = Join-Path $target $patchLock.path
if (Test-Path $sourceFile) {
    if ((Hash $sourceFile) -eq $patchLock.patchedSHA256) { Write-Host 'Pinned SteamKit source is prepared.'; return }
    throw 'Existing build copy is not the pinned patched SteamKit; preserve it and use a separate checkout.'
}
New-Item -ItemType Directory -Force $output | Out-Null
if (-not (Test-Path $archive)) { Invoke-WebRequest $sourceLock.url -OutFile $archive }
if ((Hash $archive) -ne $sourceLock.sha256) { throw 'SteamKit source archive hash mismatch.' }
$scratch = Join-Path $output ('steamkit-extract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
& tar -xf $archive -C $scratch
if ($LASTEXITCODE) { throw 'SteamKit source extraction failed.' }
$extracted = @(Get-ChildItem $scratch -Directory)
if ($extracted.Count -ne 1) { throw 'Unexpected SteamKit archive layout.' }
$file = Join-Path $extracted[0].FullName $patchLock.path
if ((Hash $file) -ne $patchLock.baseSHA256) { throw 'SteamKit patch preimage mismatch.' }
$hunk = @(); $collect = $false
foreach ($line in (Get-Content $patch)) {
    if ($line -like '@@*') { if ($collect) { throw 'Expected one SteamKit patch hunk.' }; $collect = $true; continue }
    if ($collect) { $hunk += $line }
}
# The retained patch has one hunk. Reconstruct both exact text ranges and bind
# the output to its retained SHA256, without git, bash or a platform patch tool.
$before = (@($hunk | Where-Object { -not $_.StartsWith('+') } | ForEach-Object { $_.Substring(1) }) -join "`n") + "`n"
$after = (@($hunk | Where-Object { -not $_.StartsWith('-') } | ForEach-Object { $_.Substring(1) }) -join "`n") + "`n"
$text = [IO.File]::ReadAllText($file)
if (-not $text.Contains($before) -or $text.IndexOf($before) -ne $text.LastIndexOf($before)) { throw 'SteamKit patch context is not unique.' }
$originalBytes = [IO.File]::ReadAllBytes($file)
$hasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 239 -and $originalBytes[1] -eq 187 -and $originalBytes[2] -eq 191
[IO.File]::WriteAllText($file, $text.Replace($before, $after), [Text.UTF8Encoding]::new($hasBom))
if ((Hash $file) -ne $patchLock.patchedSHA256) { throw 'SteamKit patch output mismatch.' }
Move-Item $extracted[0].FullName $target
Remove-Item $scratch # Empty, owned extraction directory only.
Write-Host 'Pinned SteamKit and bounded WebSocket shutdown fix prepared for Windows.'
