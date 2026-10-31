# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = Join-Path $repo 'Build/Windows'
$target = Join-Path $build 'depotdownloader'
$source = $null
foreach ($entry in (Get-Content (Join-Path $repo 'StoreBridge/dependencies.lock.json') -Raw | ConvertFrom-Json)) {
    if ($entry.name -eq 'depotdownloader') { $source = $entry; break }
}
if (-not $source) { throw 'Pinned downloader source missing.' }
$lock = Get-Content (Join-Path $repo 'Scripts/steam_depot_progress.lock.json') -Raw | ConvertFrom-Json
function Hash([string]$path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
$patch = Join-Path $repo 'Scripts/steam_depot_progress.patch'
$helper = Join-Path $repo 'Scripts/steam_depot_progress.cs'
if ((Hash $patch) -ne $lock.patchSHA256 -or (Hash $helper) -ne $lock.helperSHA256) { throw 'Pinned downloader patch/helper changed.' }
if (Test-Path (Join-Path $target '.ready-source.json')) {
    foreach ($entry in $lock.files.PSObject.Properties) {
        if ((Hash (Join-Path $target ('DepotDownloader/' + $entry.Name))) -ne $entry.Value.patchedUTF8SHA256) { throw 'Prepared downloader source changed.' }
    }
    if ((Hash (Join-Path $target 'DepotDownloader/ReadyDownloadProgress.cs')) -ne $lock.helperSHA256) { throw 'Prepared downloader helper changed.' }
    if ((Hash (Join-Path $target 'DepotDownloader/AccountSettingsStore.cs')) -ne '6470ac538a1bb324b4f5522758cfbf74cb232c7a67335e4a70daae45ba8142e2') { throw 'Prepared private credential handling changed.' }
    Write-Host 'Pinned Windows downloader source is prepared.'; return
}
if (Test-Path $target) { throw 'Unknown downloader build directory retained.' }
New-Item -ItemType Directory -Force $build | Out-Null
$archive = Join-Path $build 'depotdownloader-source.tar.gz'
if (-not (Test-Path $archive)) { Invoke-WebRequest $source.source_url -OutFile $archive }
if ((Hash $archive) -ne $source.source_sha256) { throw 'Downloader source archive mismatch.' }
$scratch = Join-Path $build ('depot-extract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
& tar -xf $archive -C $scratch
if ($LASTEXITCODE) { throw 'Downloader extraction failed.' }
$extracted = @(Get-ChildItem $scratch -Directory)
if ($extracted.Count -ne 1) { throw 'Unexpected downloader archive layout.' }
$project = Join-Path $extracted[0].FullName 'DepotDownloader'
$utf8 = [Text.UTF8Encoding]::new($false)
# Same independent private-stdin adaptation as Scripts/store_bootstrap.py.
$file = Join-Path $project 'Program.cs'; $text = [IO.File]::ReadAllText($file)
$needle = 'ContentDownloader.Config.RememberPassword = HasParameter(args, "-remember-password");'
$replacement = @'
// Ready patch: credentials arrive through private stdin, never process arguments.
            if (Environment.GetEnvironmentVariable("READY_TOKEN_STDIN") == "1")
            {
                using var readyDoc = System.Text.Json.JsonDocument.Parse(Console.ReadLine() ?? "{}");
                username = readyDoc.RootElement.GetProperty("username").GetString();
                var readyToken = readyDoc.RootElement.GetProperty("refresh_token").GetString();
                if (string.IsNullOrEmpty(username) || string.IsNullOrEmpty(readyToken)) return 1;
                AccountSettingsStore.Instance.LoginTokens[username] = readyToken;
            }
            ContentDownloader.Config.RememberPassword = HasParameter(args, "-remember-password");
'@
if (-not $text.Contains($needle)) { throw 'Downloader private-stdin preimage missing.' }
[IO.File]::WriteAllText($file, $text.Replace($needle,$replacement.Replace("`r`n","`n")), $utf8)
$file = Join-Path $project 'AccountSettingsStore.cs'; $text = [IO.File]::ReadAllText($file)
$needle = 'if (IsolatedStorage.FileExists(filename))'
$replacement = @'
if (Environment.GetEnvironmentVariable("READY_TOKEN_STDIN") == "1")
            {
                Instance = new AccountSettingsStore(); Instance.FileName = filename; return;
            }
            if (IsolatedStorage.FileExists(filename))
'@
if (-not $text.Contains($needle)) { throw 'Downloader credential-load preimage missing.' }
$text = $text.Replace($needle,$replacement.Replace("`r`n","`n"))
$needle = "public static void Save()`n        {"
if (-not $text.Contains($needle)) { throw 'Downloader credential-save preimage missing.' }
$text = $text.Replace($needle, $needle + "`n            if (Environment.GetEnvironmentVariable(`"READY_TOKEN_STDIN`") == `"1`") return;")
[IO.File]::WriteAllText($file,$text,$utf8)
foreach ($entry in $lock.files.PSObject.Properties) {
    if ((Hash (Join-Path $project $entry.Name)) -ne $entry.Value.baseSHA256) { throw "Downloader patch preimage mismatch: $($entry.Name)" }
}
# Apply the retained unified diff with exact old-line checks. No git/bash needed.
$lines = [IO.File]::ReadAllLines($patch); $at = 0
while ($at -lt $lines.Length) {
    if (-not $lines[$at].StartsWith('--- a/')) { $at++; continue }
    $name = $lines[$at].Substring(6); $at++
    if ($at -ge $lines.Length -or $lines[$at] -ne ('+++ b/' + $name) -or $name.Contains('..') -or [IO.Path]::IsPathRooted($name)) { throw 'Invalid downloader patch path.' }
    $at++; $path = Join-Path $project $name
    $original = [IO.File]::ReadAllText($path).Split([char]10)
    $result = [Collections.Generic.List[string]]::new(); $cursor = 0
    while ($at -lt $lines.Length -and -not $lines[$at].StartsWith('--- a/')) {
        $header = [regex]::Match($lines[$at], '^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
        if (-not $header.Success) { $at++; continue }
        $start = [int]$header.Groups[1].Value - 1
        if ($start -lt $cursor) { throw 'Overlapping downloader patch hunk.' }
        while ($cursor -lt $start) { $result.Add($original[$cursor]); $cursor++ }
        $at++
        while ($at -lt $lines.Length -and -not $lines[$at].StartsWith('@@ ') -and -not $lines[$at].StartsWith('--- a/')) {
            $line = $lines[$at]; $at++
            if ($line.StartsWith('\')) { continue }
            if ($line.Length -eq 0) { throw 'Unexpected empty patch instruction.' }
            $kind = $line[0]; $body = $line.Substring(1)
            if ($kind -eq ' ' -or $kind -eq '-') {
                if ($cursor -ge $original.Length -or $original[$cursor] -cne $body) { throw "Downloader hunk context mismatch: $name" }
                $cursor++
            }
            if ($kind -eq ' ' -or $kind -eq '+') { $result.Add($body) }
        }
    }
    while ($cursor -lt $original.Length) { $result.Add($original[$cursor]); $cursor++ }
    [IO.File]::WriteAllText($path, ($result -join "`n"), $utf8)
}
foreach ($entry in $lock.files.PSObject.Properties) {
    if ((Hash (Join-Path $project $entry.Name)) -ne $entry.Value.patchedUTF8SHA256) { throw "Downloader patched source mismatch: $($entry.Name)" }
}
Copy-Item $helper (Join-Path $project 'ReadyDownloadProgress.cs')
$file = Join-Path $project 'DepotDownloader.csproj'; $text = [IO.File]::ReadAllText($file)
if (-not $text.Contains('<TargetFramework>net9.0</TargetFramework>')) { throw 'Unexpected pinned downloader framework.' }
$text = $text.Replace('<TargetFramework>net9.0</TargetFramework>','<TargetFramework>net10.0</TargetFramework><RuntimeIdentifiers>win-x64;win-x86;win-arm64</RuntimeIdentifiers>')
[IO.File]::WriteAllText($file,$text,$utf8)
$receipt = @{schema=1;sourceArchiveSHA256=$source.source_sha256;progressPatchSHA256=$lock.patchSHA256;helperSHA256=$lock.helperSHA256;sourceOnly=$true}
[IO.File]::WriteAllText((Join-Path $extracted[0].FullName '.ready-source.json'),($receipt|ConvertTo-Json),$utf8)
Move-Item $extracted[0].FullName $target
Remove-Item $scratch
Write-Host 'Pinned downloader source and private stdin/progress adaptations prepared.'
