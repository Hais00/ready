# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Executable, [Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$Report = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Report)
$start = [Diagnostics.ProcessStartInfo]::new($Executable)
$start.UseShellExecute = $false; $start.CreateNoWindow = $true
$start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
$start.Arguments = '--service'
$process = [Diagnostics.Process]::new(); $process.StartInfo = $start
$started = $false
try {
    if (-not $process.Start()) { throw 'Steam service did not start.' }
    $started = $true
    $errorTask = $process.StandardError.ReadToEndAsync()
    $profile = [guid]::NewGuid().ToString('D'); $generation = [guid]::NewGuid().ToString('D')
    $snapshot = [guid]::NewGuid().ToString('D')
    $request = @{id=$snapshot;profileID=$profile;profileGeneration=$generation;operation='snapshot'} | ConvertTo-Json -Compress
    $process.StandardInput.WriteLine($request); $process.StandardInput.Flush()
    $deadline = [Diagnostics.Stopwatch]::StartNew(); $observed = $false
    while ($deadline.Elapsed.TotalSeconds -lt 15) {
        $line = $process.StandardOutput.ReadLineAsync()
        if (-not $line.Wait(15000 - [int]$deadline.Elapsed.TotalMilliseconds)) { throw 'Steam snapshot timeout.' }
        if ($null -eq $line.Result) { throw 'Steam service closed before snapshot.' }
        $event = $line.Result | ConvertFrom-Json
        if ($event.id -eq $snapshot -and $event.type -eq 'result') {
            if ($event.state -ne 'offline' -or $event.backendSessionReady -ne $false -or -not ($event.capabilities -contains 'authenticate')) { throw 'Unexpected offline Steam snapshot.' }
            $observed = $true; break
        }
    }
    if (-not $observed) { throw 'Steam snapshot was not received.' }
    $process.StandardInput.WriteLine((@{id=[guid]::NewGuid().ToString('D');profileID=$profile;profileGeneration=$generation;operation='shutdown'} | ConvertTo-Json -Compress))
    $process.StandardInput.Close()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit(15000) -or $process.ExitCode -ne 0) { throw 'Steam service shutdown failed.' }
    if ($errorTask.GetAwaiter().GetResult().Length -ne 0) { throw 'Steam service wrote unexpected stderr.' }
    $null = $outputTask.GetAwaiter().GetResult()
    $receipt = [ordered]@{schema=1;passed=$true;checks=@('Actual SteamKit adapter offline snapshot','No backend-ready claim','Private stdin profile/generation binding','Bounded process shutdown');
        executableSHA256=(Get-FileHash $Executable -Algorithm SHA256).Hash.ToLowerInvariant();
        assemblySHA256=(Get-FileHash ([IO.Path]::ChangeExtension($Executable,'.dll')) -Algorithm SHA256).Hash.ToLowerInvariant();
        scope='Actual adapter without connect/authenticate requests or credentials. No game, headless login, account, ticket or network-denial claim.'}
    New-Item -ItemType Directory -Force (Split-Path -Parent ([IO.Path]::GetFullPath($Report))) | Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Report), ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}
finally { if ($started -and -not $process.HasExited) { $process.Kill(); $null=$process.WaitForExit(5000) }; $process.Dispose() }
