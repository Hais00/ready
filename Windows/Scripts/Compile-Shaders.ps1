# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Compiler)
$ErrorActionPreference = 'Stop'
$folder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Ready.Windows/Shaders'))
$files = [ordered]@{}
foreach ($name in @('canvas.vert','canvas.frag')) {
    & $Compiler -V (Join-Path $folder $name) -o (Join-Path $folder ($name + '.spv'))
    if ($LASTEXITCODE -ne 0) { throw "Shader compilation failed: $name" }
    foreach ($file in @($name, ($name + '.spv'))) { $files[$file] = (Get-FileHash (Join-Path $folder $file) -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$version = (& $Compiler --version | Select-Object -First 1)
[IO.File]::WriteAllText((Join-Path $folder 'shaders.lock.json'), ([ordered]@{schema=1;compiler=$version;files=$files} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
