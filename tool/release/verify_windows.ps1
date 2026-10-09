$ErrorActionPreference = 'Stop'
# Configure the hook's existing build directory so tests use the same DLL.
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$native = "$repo/packages/torrent_engine/.dart_tool/native_build/windows-x64"
$openssl = "$repo/.dart_tool/native_dependencies/vcpkg/x64-windows-static"
$log = "$repo/.dart_tool/windows-native-verification.log"
New-Item -ItemType Directory -Force "$repo/.dart_tool" | Out-Null
Remove-Item $log -ErrorAction SilentlyContinue
function Invoke-Checked([string] $Program, [string[]] $Arguments) {
    & $Program @Arguments 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
    if (Select-String -Path $log -Pattern 'LNK4098|LNK2038|LNK2005|conflicts with use of other libs|mismatch detected for .RuntimeLibrary') {
        throw 'The native build reports conflicting C/C++ runtimes.'
    }
}
Invoke-Checked cmake @('-S', "$repo/packages/torrent_engine/native", '-B', $native, '-A', 'x64', '-DTE_BUILD_TESTS=ON', "-DOPENSSL_ROOT_DIR=$openssl", '-DOPENSSL_MSVC_STATIC_RT=TRUE')
Invoke-Checked cmake @('--build', $native, '--config', 'Release', '--parallel', $env:NUMBER_OF_PROCESSORS)
# CMake places the fixture in Release and the engine DLL in lib.
$env:PATH = "$native/lib;$env:PATH"
$env:TORRENT_ENGINE_FIXTURE = "$native/Release/torrent_engine_integration.exe"
if (!(Test-Path $env:TORRENT_ENGINE_FIXTURE)) { throw 'Missing native integration fixture' }
Invoke-Checked ctest @('--test-dir', $native, '-C', 'Release', '--output-on-failure')
Push-Location "$repo/packages/torrent_engine"
try {
    Invoke-Checked dart @('pub', 'get')
    Invoke-Checked dart @('test')
} finally { Pop-Location }
