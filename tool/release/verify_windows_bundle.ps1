param([Parameter(Mandatory=$true)][string] $Bundle)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Bundle 'playgta5_launcher.exe'
$engine = @(Get-ChildItem $Bundle -Recurse -File -Filter torrent_engine.dll)
if (!(Test-Path $exe) -or $engine.Count -ne 1 -or !(Test-Path (Join-Path $Bundle 'data/flutter_assets'))) {
    throw 'Incomplete Windows bundle: executable, native engine or assets are missing'
}
foreach ($file in @($exe, $engine[0].FullName)) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) {
        throw "Expected an x64 PE binary: $file"
    }
    Write-Host "Verified x64 binary: $file"
}
