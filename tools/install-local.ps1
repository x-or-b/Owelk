# Builds Owelk from this checkout and installs it for the current user on Windows. Run it again after
# `git pull` to update; your library, notes and settings are kept (they live in the data folder).
#
#   powershell -ExecutionPolicy Bypass -File tools\install-local.ps1           build and install
#   powershell -ExecutionPolicy Bypass -File tools\install-local.ps1 -Clean    start the build from scratch
#   powershell -ExecutionPolicy Bypass -File tools\install-local.ps1 -Yes      do not ask before installing tools
#
# Windows 10/11 on x64. Needs Visual Studio 2022 Build Tools (C++) and Python 3.10+; missing ones are
# installed with winget (after asking). The official Qt 6.11 goes to %USERPROFILE%\Qt (about 2 GB,
# once); Owelk is built with MSVC and installed to %LOCALAPPDATA%\Programs\Owelk with a Start menu entry.
# Unlike macOS and Linux the Qt libraries are copied next to the program: Windows has no other way to
# find them.
param([switch]$Clean, [switch]$Yes, [switch]$Help)
$ErrorActionPreference = 'Stop'

$QtVersion = if ($env:OWELK_QT_VERSION) { $env:OWELK_QT_VERSION } else { '6.11.3' }
$QtModules = @('qtpdf', 'qtwebengine', 'qtwebchannel', 'qtpositioning', 'qtimageformats', 'qtshadertools')
# The Qt downloader. Qt 6.11 for Windows sits in a new folder layout that the 3.3.0 release cannot read
# yet; this commit can. Back to plain `aqtinstall` once a newer release is out.
$AqtSource = 'https://github.com/miurahr/aqtinstall/archive/076e1659807d0b362a3ed684d54c2e9c775eb9c7.zip'
$Root = Split-Path -Parent $PSScriptRoot
$Build = Join-Path $Root 'build-release'

function Say([string]$text) { Write-Host "`n$text" -ForegroundColor Cyan }
function Fail([string]$text) { Write-Host "`nOwelk install: $text" -ForegroundColor Red; exit 1 }
function Ask([string]$question) {
    if ($Yes) { return $true }
    return (Read-Host "$question [y/N]") -match '^[Yy]'
}
# Programs just installed with winget are on PATH for new windows only; this one reads it again.
function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Winget([string]$id, [string[]]$extra = @()) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "winget is not available. Install $id by hand and run this again."
    }
    & winget install --id $id -e --accept-package-agreements --accept-source-agreements @extra
    if ($LASTEXITCODE -ne 0) { Fail "winget could not install $id." }
    Update-Path
}

# A Python 3.10 or newer (what the Qt downloader needs): the py launcher, or python on PATH.
function Test-Python([string]$exe, [string[]]$extra) {
    & $exe @extra -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
    return $LASTEXITCODE -eq 0
}
function Find-Python {
    foreach ($candidate in @('py', 'python')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        # The "python" that only opens the Microsoft Store lives in WindowsApps; it cannot run anything.
        if (-not $command -or $command.Source -like '*\WindowsApps\*') { continue }
        $extra = if ($candidate -eq 'py') { @('-3') } else { @() }
        if (Test-Python $command.Source $extra) { $script:PythonExe = $command.Source; $script:PythonArgs = $extra; return $true }
    }
    return $false
}

if ($Help) { Get-Content $PSCommandPath | Select-Object -First 12 | ForEach-Object { $_ -replace '^# ?', '' }; exit 0 }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Fail "This script covers 64-bit Intel and AMD Windows (found $env:PROCESSOR_ARCHITECTURE)." }

# --- Visual Studio Build Tools: the C++ compiler, CMake and Ninja --------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
function Find-VisualStudio {
    if (-not (Test-Path $vswhere)) { return $null }
    $found = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($found) { return ($found | Select-Object -First 1) } else { return $null }
}
$vs = Find-VisualStudio
if (-not $vs) {
    Say 'Visual Studio 2022 Build Tools (C++) are needed to build Owelk (about 6 GB).'
    if (-not (Ask 'Install them with winget?')) { Fail 'Install "Desktop development with C++" from Visual Studio Build Tools and run this again.' }
    Winget 'Microsoft.VisualStudio.2022.BuildTools' @('--override', '--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
    $vs = Find-VisualStudio
    if (-not $vs) { Fail 'The C++ build tools are still missing. Open the Visual Studio Installer and add "Desktop development with C++".' }
}
# The developer environment of that installation (compiler, Windows SDK, its CMake and Ninja).
Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
foreach ($tool in @('cmake', 'ninja')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool is missing. In the Visual Studio Installer, add 'C++ CMake tools for Windows' and run this again."
    }
}

# --- Qt 6.11 in %USERPROFILE%\Qt (or OWELK_QT=C:\path\to\Qt\<version>\msvc2022_64) ---------------------
$qt = if ($env:OWELK_QT) { $env:OWELK_QT } else { Join-Path $HOME "Qt\$QtVersion\msvc2022_64" }
if (-not (Test-Path (Join-Path $qt 'bin\qmake.exe'))) {
    if (-not (Find-Python)) {
        Say 'Python 3.10 or newer is needed once, to download Qt.'
        if (-not (Ask 'Install Python 3.12 with winget?')) { Fail 'Install Python 3.10 or newer and run this again.' }
        Winget 'Python.Python.3.12'
        if (-not (Find-Python)) { Fail 'Python is installed but not found yet. Open a new PowerShell window and run this again.' }
    }
    Say "Downloading Qt $QtVersion into $HOME\Qt (about 2 GB, once)"
    $tools = Join-Path $env:LOCALAPPDATA 'Owelk\install-tools'
    $venvPython = Join-Path $tools 'venv\Scripts\python.exe'
    # A virtual environment left by an older Python is made again.
    if ((Test-Path $venvPython) -and -not (Test-Python $venvPython @())) { Remove-Item -Recurse -Force (Join-Path $tools 'venv') }
    if (-not (Test-Path $venvPython)) {
        & $script:PythonExe @script:PythonArgs -m venv (Join-Path $tools 'venv')
        if ($LASTEXITCODE -ne 0) { Fail 'Could not set up Python for the Qt download.' }
    }
    & $venvPython -m pip install --quiet --upgrade $AqtSource
    if ($LASTEXITCODE -ne 0) { Fail 'Could not install aqtinstall (the Qt downloader).' }
    & (Join-Path $tools 'venv\Scripts\aqt.exe') install-qt windows desktop $QtVersion win64_msvc2022_64 -m @QtModules -O (Join-Path $HOME 'Qt')
    if ($LASTEXITCODE -ne 0) { Fail "Could not download Qt $QtVersion." }
}

# --- Build ---------------------------------------------------------------------------------------------
if ($Clean -and (Test-Path $Build)) { Remove-Item -Recurse -Force $Build }
Say 'Building Owelk (Release) in build-release\'
& cmake -S $Root -B $Build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF "-DCMAKE_PREFIX_PATH=$qt"
if ($LASTEXITCODE -ne 0) { Fail 'CMake could not configure the build.' }
& cmake --build $Build --parallel
if ($LASTEXITCODE -ne 0) { Fail 'The build failed.' }

# --- Install -------------------------------------------------------------------------------------------
$target = if ($env:OWELK_APP_DIR) { $env:OWELK_APP_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\Owelk' }
$exe = Join-Path $target 'bin\owelk.exe'
# A running Owelk keeps its files open (and would receive files meant for the new one).
while (Get-Process owelk -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
    if ($Yes) { Fail 'Owelk is running. Close it and run this again.' }
    Read-Host 'Owelk is running. Close it, then press Enter' | Out-Null
}
Say "Installing $target"
# Only the program folder is replaced; the library lives in %LOCALAPPDATA%\Owelk.
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
& cmake --install $Build --prefix $target
if ($LASTEXITCODE -ne 0) { Fail 'Installing failed.' }
if (-not (Test-Path $exe)) { Fail "The program is missing from $target." }

# A Start menu entry (search "Owelk"); pin it to the taskbar from there.
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Owelk.lnk'))
$link.TargetPath = $exe
$link.WorkingDirectory = Split-Path $exe
$link.IconLocation = "$exe,0"
$link.Description = 'Owelk'
$link.Save()
Say 'Done. Start Owelk from the Start menu.'
