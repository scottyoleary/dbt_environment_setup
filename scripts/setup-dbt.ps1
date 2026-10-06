<#
.SYNOPSIS
    Creates or repairs a project-local dbt Core + Microsoft Fabric Data Warehouse development
    environment (Python venv, pinned packages, lock file, VS Code wiring, dbt profile template)
    without admin rights.

.DESCRIPTION
    Run it from the VS Code integrated terminal at the root of a new or existing dbt repo. The
    script can live anywhere inside that repo; typically it arrives as a git subtree or submodule
    of the shared setup repo at .\tools\dbt-setup (a copy in .\scripts works too):

        powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1

    Everything it does is scoped to THIS project and the current user. It never needs elevation,
    never writes to Program Files, HKLM or the system PATH, never changes the execution policy
    beyond the process it runs in, and never installs packages globally or with --user.

    Steps:
      1.  Preflight: PowerShell edition, project root, path length, OneDrive, proxy/pip settings.
      2.  requirements.txt: created, or checked against the VERSION PINS block below.
      3.  Existing .venv: does it start, which Python, 64-bit, pip present, no community fork.
      4.  Base Python (only when .venv must be built): -PythonExe, py launcher (3.12, then 3.13),
          python on PATH (Microsoft Store alias skipped), known per-user installs. If none is
          compatible, installs Python 3.12 per-user: uv first, python.org installer as fallback.
      5.  Creates or rebuilds <ProjectRoot>\.venv.
      6.  Upgrades pip inside .venv, then installs from requirements-lock.txt when it exists;
          otherwise resolves requirements.txt in a fresh .venv and writes the lock.
      7.  Verifies the pins, runs pip check, and imports the adapter and mssql-python.
      8.  Merges .vscode\settings.json and .vscode\extensions.json (never overwrites them).
      9.  Appends any missing .gitignore entries.
      10. Creates a dbt profile template under ~\.dbt if the project has no profile yet.
      11. Checks dbt --version against the pins; runs dbt debug when a project and profile exist.

    Re-running is safe. A correct environment is left untouched and needs no network access.

.PARAMETER ProjectRoot
    Folder to set up. Default: the git repo that contains this script. When the script sits in
    a git submodule (e.g. .\tools\dbt-setup), that is the parent repo, not the submodule.
    Outside git: the parent of a .\scripts folder, the grandparent of .\tools\<name>, or else
    the script's own folder.

.PARAMETER Recreate
    Delete and rebuild .venv from scratch, then install from the lock (or resolve and write it).

.PARAMETER UpdateLock
    Re-resolve requirements.txt in a fresh .venv and rewrite requirements-lock.txt. Use after
    changing requirements.txt. Implies a rebuild of .venv.

.PARAMETER CheckOnly
    Report what is wrong or would change; install and write nothing. Exit code 0 = in the
    desired state, 2 = changes needed, 1 = error.

.PARAMETER PythonExe
    Full path to a 64-bit Python 3.12 or 3.13 python.exe to build .venv from. Skips discovery.

.PARAMETER PythonInstallMethod
    What to do when no compatible Python exists. Auto (default) tries uv, then the python.org
    installer. Uv or PythonOrg force one method. None never downloads anything and stops with
    manual instructions.

.PARAMETER ProfileName
    dbt profile name to create when the repo has no dbt_project.yml yet. Default: the project
    folder name, lower-cased, with non-alphanumerics replaced by "_". Ignored when
    dbt_project.yml exists (its "profile:" key wins).

.PARAMETER AuthMethod
    Authentication written into a NEW profile template. CLI (default) uses your Azure CLI sign-in
    ("az login"). ActiveDirectoryInteractive opens a browser sign-in and needs no Azure CLI.
    Existing profiles are never changed.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1

    Standard run from the repo root, in Windows PowerShell 5.1. The -ExecutionPolicy switch
    applies only to that one process.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1 -Recreate

    Rebuild .venv from scratch with PowerShell 7.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1 -CheckOnly

    Report drift without changing anything (useful when asking for help, or in CI).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1 -PythonExe "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"

    Build .venv from a specific interpreter.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1 -UpdateLock

    After editing requirements.txt: re-resolve in a fresh .venv and rewrite requirements-lock.txt.

.NOTES
    Exit codes: 0 success, 1 failure, 2 (-CheckOnly only) changes are needed.
    Do not dot-source this script; run it as shown above.
    Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [switch]$Recreate,
    [switch]$UpdateLock,
    [switch]$CheckOnly,
    [string]$PythonExe,
    [ValidateSet('Auto', 'Uv', 'PythonOrg', 'None')]
    [string]$PythonInstallMethod = 'Auto',
    [string]$ProfileName,
    [ValidateSet('CLI', 'ActiveDirectoryInteractive')]
    [string]$AuthMethod = 'CLI'
)

# =====================================================================================
# VERSION PINS -- team standard, single source of truth.
# requirements.txt must agree (the script stops if it does not). Do not bump these
# casually: dbt-fabric 1.10.x declares dbt-core >=1.10.0 with no upper bound, and
# dbt-core 1.12.x pulls dbt-core-experimental-parser, which is published as sdist only.
# =====================================================================================
$DbtCoreVersion       = '1.10.15'
$DbtFabricVersion     = '1.10.1'
$PythonAcceptedMinors = @('3.12', '3.13')   # dbt-fabric 1.10.1: Requires-Python >=3.12,<3.14
$PythonInstallMinor   = '3.12'              # installed per-user when nothing compatible exists
$UvVersion            = '0.12.23'           # downloaded only if no usable uv (>= 0.8.0) exists
$MinUvVersion         = [version]'0.8.0'    # first uv with --no-bin / --no-registry
$PythonOrgVersion     = '3.12.10'           # last 3.12 release with Windows installers (fallback)

# =====================================================================================
# Other settings
# =====================================================================================
$GitIgnoreEntries      = @('.venv/', 'target/', 'dbt_packages/', 'logs/')
$VsCodeInterpreterPath = '${workspaceFolder}\.venv\Scripts\python.exe'
$RecommendedExtensions = @('ms-python.python')
$ProfileEnvVars        = @('DBT_FABRIC_SERVER', 'DBT_FABRIC_DATABASE', 'DBT_FABRIC_SCHEMA')
# Longest file path inside .venv for this pin set, relative to the project root
# (".venv\Lib\site-packages\" + the deepest dbt-fabric 1.10.1 macro file = ~171 chars).
$VenvLongestRelativePath = 175

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is much faster without the progress bar

# Script state
$script:StepIndex     = 0
$script:StepTotal     = 11
$script:Warnings      = New-Object System.Collections.Generic.List[string]
$script:Changes       = New-Object System.Collections.Generic.List[string]
$script:NextSteps     = New-Object System.Collections.Generic.List[string]
$script:Drift         = $false
$script:FatalShown    = $false
$script:Succeeded     = $false
$script:SavedEnv      = @{}
$script:SavedOutputEncoding   = $null
$script:SavedSecurityProtocol = $null
$script:Utf8NoBom     = New-Object System.Text.UTF8Encoding($false)
$script:Root          = $null
$script:VenvDir       = $null
$script:VenvPython    = $null
$script:ReqPath       = $null
$script:LockPath      = $null
$script:UvLocalExe    = $null
$script:BasePython    = $null
$script:VenvInfo      = $null
$script:VenvStatus    = $null
$script:Installed     = $null
$script:PipUpgraded   = $false
$script:DbtProjectDir = $null
$script:ProfileNameUsed = $null
$script:ProfilePath   = $null
$script:ProfileState  = $null
$script:ProfileAuth   = $null
$script:ProfileEnv    = @()
$script:ProfileCreated = $false
$script:BlockedFailure = $null     # set when Windows App Control blocks native modules in .venv
$script:BlockedSteps  = New-Object System.Collections.Generic.List[string]
$script:UserHome      = [Environment]::GetFolderPath('UserProfile')
$script:SelfPath      = $PSCommandPath
$script:SelfRelative  = 'setup-dbt.ps1'                     # set in preflight, e.g. tools/dbt-setup/setup-dbt.ps1
$script:SelfCommand   = 'powershell -NoProfile -ExecutionPolicy Bypass -File <path>\setup-dbt.ps1'

# =====================================================================================
# Output helpers
# =====================================================================================
function Write-Step {
    param([string]$Title)
    $script:StepIndex++
    Write-Host ''
    Write-Host ('[{0}/{1}] {2}' -f $script:StepIndex, $script:StepTotal, $Title) -ForegroundColor Cyan
}
function Write-Ok     { param([string]$Message) Write-Host ('  [ OK ] ' + $Message) -ForegroundColor Green }
function Write-Info   { param([string]$Message) Write-Host ('  [INFO] ' + $Message) }
function Write-Fail   { param([string]$Message) Write-Host ('  [FAIL] ' + $Message) -ForegroundColor Red }
function Write-Warn {
    param([string]$Message)
    Write-Host ('  [WARN] ' + $Message) -ForegroundColor Yellow
    $script:Warnings.Add($Message)
}
function Write-Plan {
    param([string]$Message)
    $script:Drift = $true
    Write-Host ('  [TODO] ' + $Message + '  (not done: -CheckOnly)') -ForegroundColor Yellow
}
function Write-Detail {
    param([string[]]$Lines)
    foreach ($line in $Lines) { Write-Host ('         ' + $line) -ForegroundColor DarkGray }
}
function Add-Change {
    param([string]$Message)
    $script:Changes.Add($Message)
    Write-Ok $Message
}
function Add-NextStep {
    param([string]$Message)
    if (-not $script:NextSteps.Contains($Message)) { $script:NextSteps.Add($Message) }
}
function Stop-Setup {
    # Print a failure with remediation lines, then abort the run.
    param([string]$Message, [string[]]$Help = @())
    Write-Fail $Message
    if ($Help.Count -gt 0) { Write-Detail $Help }
    $script:FatalShown = $true
    throw $Message
}

# =====================================================================================
# Process-scoped environment (restored on exit, so a dot-sourced or in-session run
# leaves the caller's shell exactly as it was)
# =====================================================================================
function Set-ProcessEnv {
    param([string]$Name, [string]$Value)
    if (-not $script:SavedEnv.ContainsKey($Name)) {
        $script:SavedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    if ($Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Name, $null, 'Process') }
}
function Restore-ProcessState {
    foreach ($name in @($script:SavedEnv.Keys)) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name], 'Process')
    }
    if ($null -ne $script:SavedOutputEncoding) {
        try { [Console]::OutputEncoding = $script:SavedOutputEncoding } catch { }
    }
    if ($null -ne $script:SavedSecurityProtocol) {
        try { [Net.ServicePointManager]::SecurityProtocol = $script:SavedSecurityProtocol } catch { }
    }
}

# =====================================================================================
# Native command runner. Native programs do not throw in PowerShell, and in Windows
# PowerShell 5.1 a redirected stderr line becomes a terminating error under
# $ErrorActionPreference = 'Stop'. This wrapper runs the program with 'Continue',
# captures stdout+stderr as text, and checks the exit code explicitly.
# =====================================================================================
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Description,
        [switch]$Quiet,          # capture only; do not echo output
        [switch]$AllowFailure    # return the result instead of throwing on a non-zero exit code
    )
    if (-not $Description) { $Description = Split-Path -Leaf $FilePath }
    if ($FilePath.Contains('\') -or $FilePath.Contains('/')) {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            throw ('{0}: executable not found: {1}' -f $Description, $FilePath)
        }
    }
    elseif (-not (Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue)) {
        throw ('{0}: "{1}" is not on PATH.' -f $Description, $FilePath)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $text = $_.Exception.Message }
            else { $text = [string]$_ }
            $lines.Add($text)
            if (-not $Quiet) { Write-Host ('         ' + $text) -ForegroundColor DarkGray }
        }
        $exitCode = $global:LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    $result = New-Object psobject -Property @{ ExitCode = $exitCode; Output = $lines.ToArray() }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ($Quiet) { Write-Detail @($lines | Select-Object -Last 25) }
        throw ('{0} failed with exit code {1}.' -f $Description, $exitCode)
    }
    return $result
}

# =====================================================================================
# Small utilities
# =====================================================================================
function Get-NormalizedName {
    # PEP 503 name normalization: lower-case, runs of -_. become a single dash.
    param([string]$Name)
    return ($Name.Trim().ToLowerInvariant() -replace '[-_.]+', '-')
}

function Test-PathUnder {
    param([string]$Path, [string]$Parent)
    if (-not $Path -or -not $Parent) { return $false }
    $separator = [IO.Path]::DirectorySeparatorChar
    $child = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + $separator
    $root  = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + $separator
    return $child.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsElevated {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Test-LongPathsEnabled {
    # Read-only check of the machine policy; changing it needs admin, so we only report it.
    try {
        $value = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction Stop
        return ($value.LongPathsEnabled -eq 1)
    }
    catch { return $false }
}

function Hide-Credential {
    param([string]$Text)
    return ($Text -replace '://[^/@\s]+@', '://***@')
}

function New-TempDir {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('dbt-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Test-Utf16File {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 2
        $count = $stream.Read($bytes, 0, 2)
    }
    finally { $stream.Dispose() }
    return ($count -eq 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))
}

function Write-TextFile {
    # UTF-8 without BOM, CRLF line endings.
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), $script:Utf8NoBom)
}

function Add-TextLines {
    # Append lines, keeping the file's newline style; refuses UTF-16 files rather than corrupt them.
    param([string]$Path, [string[]]$Lines)
    if (Test-Utf16File $Path) { throw ('{0} is UTF-16 encoded; re-save it as UTF-8 and re-run.' -f $Path) }
    $existing = [IO.File]::ReadAllText($Path)
    $newline = "`r`n"
    if ($existing.Contains("`n") -and -not $existing.Contains("`r`n")) { $newline = "`n" }
    $prefix = ''
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $prefix = $newline }
    [IO.File]::AppendAllText($Path, $prefix + ($Lines -join $newline) + $newline, $script:Utf8NoBom)
}

function Invoke-Download {
    # Uses HTTPS_PROXY when set, otherwise the Windows (WinINet) proxy settings.
    param([string]$Uri, [string]$OutFile)
    $params = @{ Uri = $Uri; OutFile = $OutFile; UseBasicParsing = $true; ErrorAction = 'Stop' }
    $proxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process')
    if ($proxy) {
        $params['Proxy'] = $proxy
        $params['ProxyUseDefaultCredentials'] = $true
    }
    Invoke-WebRequest @params
}

function Get-WindowsArch {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'AMD64') { return 'amd64' }
    if ($arch -eq 'ARM64') { return 'arm64' }
    throw ('Unsupported processor architecture "{0}": mssql-python ships only 64-bit (x64 and ARM64) Windows wheels.' -f $arch)
}

function Get-ManualPythonHelp {
    $arch = 'amd64'
    try { $arch = Get-WindowsArch } catch { }
    return @(
        'Install a 64-bit Python 3.12 yourself (no admin needed), then re-run this script:',
        '  - Preferred: ask IT for Python 3.12 (64-bit) via Company Portal / Software Center, or',
        ('  - Download https://www.python.org/ftp/python/{0}/python-{0}-{1}.exe on a network that allows it' -f $PythonOrgVersion, $arch),
        '    and choose "Install Now" with "Add python.exe to PATH" unticked (installs for you only), or',
        '  - If your company mirrors python-build-standalone, set UV_PYTHON_INSTALL_MIRROR and re-run.',
        'Then re-run (optionally pointing at it):',
        ('  ' + $script:SelfCommand + ' -PythonExe "<path>\python.exe"'),
        'Hosts this script downloads from: github.com (uv and uv-managed Python), www.python.org (fallback).',
        'Proxy: HTTPS_PROXY if set, otherwise the Windows proxy settings. PAC/auto-config proxies need HTTPS_PROXY.'
    )
}

function Get-NetworkHelp {
    return @(
        'pip could not install the packages. Check, in this order:',
        '  - Proxy: set it for this session, e.g.  $env:HTTPS_PROXY = "http://proxy.example.com:8080"',
        '  - Internal index: PIP_INDEX_URL or pip.ini [global] index-url ("python -m pip config list" shows them)',
        '  - TLS inspection: pip 24.2+ trusts the Windows certificate store. If it still fails, get the',
        '    corporate root CA as a PEM file and set PIP_CERT to it. Do not use --trusted-host.',
        '  - Private index credentials: pip runs with --no-input here, so put them in pip.ini, keyring or netrc.',
        '  - Long paths: see the path-length check in step 1.'
    )
}

# =====================================================================================
# Python discovery and installation
# =====================================================================================
# The probe is passed with -I (isolated mode), so a json.py or platform.py in the current folder
# cannot shadow the standard library. It prints ASCII-only JSON, so console encoding cannot mangle paths.
$script:PyProbeCode = 'import sys, json, struct, platform; print(json.dumps(dict(exe=sys.executable, base=getattr(sys, ''_base_executable'', sys.executable), version=''%d.%d.%d'' % sys.version_info[:3], minor=''%d.%d'' % sys.version_info[:2], bits=struct.calcsize(''P'') * 8, venv=(sys.prefix != sys.base_prefix), machine=platform.machine())))'

function Get-PythonInfo {
    param([string]$FilePath, [string[]]$PrefixArgs = @())
    try {
        $result = Invoke-Native -FilePath $FilePath -ArgumentList ($PrefixArgs + @('-I', '-c', $script:PyProbeCode)) -Quiet -AllowFailure -Description 'python probe'
    }
    catch { return $null }
    if ($result.ExitCode -ne 0) { return $null }
    $json = $result.Output | Where-Object { $_ -like '{*}' } | Select-Object -Last 1
    if (-not $json) { return $null }
    try { return (ConvertFrom-Json -InputObject $json) } catch { return $null }
}

function Test-PythonInfo {
    # Returns $null when the interpreter is acceptable, otherwise the reason it is not.
    param($Info)
    if (-not $Info) { return 'not installed, or it did not start' }
    if ($PythonAcceptedMinors -notcontains $Info.minor) {
        return ('Python {0}; dbt-fabric {1} needs {2}' -f $Info.version, $DbtFabricVersion, ($PythonAcceptedMinors -join ' or '))
    }
    if ([int]$Info.bits -ne 64) {
        return ('{0}-bit Python; mssql-python ships only 64-bit Windows wheels' -f $Info.bits)
    }
    return $null
}

function Invoke-PythonSnippet {
    # Runs a multi-line Python snippet from a private temp folder in isolated mode (-I), so nothing
    # in the current folder or in a shared temp folder can be imported by accident.
    param([string]$Python, [string]$Code, [string[]]$Arguments = @())
    $dir = New-TempDir
    try {
        $file = Join-Path $dir 'snippet.py'
        [IO.File]::WriteAllText($file, $Code, $script:Utf8NoBom)
        return (Invoke-Native -FilePath $Python -ArgumentList (@('-I', $file) + $Arguments) -Quiet -AllowFailure -Description 'python helper')
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Select-PythonCandidate {
    param([string]$Label, [string]$FilePath, [string[]]$PrefixArgs = @())
    $info = Get-PythonInfo -FilePath $FilePath -PrefixArgs $PrefixArgs
    $reason = Test-PythonInfo $info
    if (-not $reason -and $info.venv) {
        # A virtual environment's interpreter: build from its base interpreter instead.
        $baseInfo = $null
        if ($info.base -and (Test-Path -LiteralPath $info.base)) { $baseInfo = Get-PythonInfo -FilePath $info.base }
        if ($baseInfo -and -not (Test-PythonInfo $baseInfo) -and -not $baseInfo.venv) { $info = $baseInfo }
        else { $reason = 'it is a virtual environment interpreter' }
    }
    if (-not $reason -and (Test-PathUnder $info.exe $script:VenvDir)) { $reason = 'it is this project''s own .venv' }
    if ($reason) {
        if ($info) { Write-Info ('{0}: {1} -> rejected ({2})' -f $Label, $info.exe, $reason) }
        else { Write-Info ('{0}: rejected ({1})' -f $Label, $reason) }
        return $null
    }
    Write-Ok ('{0}: Python {1} ({2}) at {3}' -f $Label, $info.version, $info.machine, $info.exe)
    $info | Add-Member -NotePropertyName Source -NotePropertyValue $Label -Force
    return $info
}

function Set-UvTlsEnv {
    # uv bundles Mozilla roots; behind TLS inspection it must use the Windows certificate store.
    # This changes which roots are trusted, it never disables verification. User settings win.
    param([version]$Version)
    if ($env:UV_SYSTEM_CERTS -or $env:UV_NATIVE_TLS -or $env:SSL_CERT_FILE) { return }
    if ($Version -ge [version]'0.11.0') { Set-ProcessEnv 'UV_SYSTEM_CERTS' 'true' }
    else { Set-ProcessEnv 'UV_NATIVE_TLS' 'true' }
}

function Get-UvExe {
    # An existing uv (on PATH, or the copy this script downloaded earlier); never downloads.
    $candidates = New-Object System.Collections.Generic.List[string]
    $onPath = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates.Add($onPath.Source) }
    $candidates.Add($script:UvLocalExe)
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try { $result = Invoke-Native -FilePath $candidate -ArgumentList @('--version') -Quiet -AllowFailure -Description 'uv --version' }
        catch { continue }
        $line = $result.Output | Where-Object { $_ -match '^uv (\d+\.\d+\.\d+)' } | Select-Object -First 1
        if ($result.ExitCode -ne 0 -or -not $line) { continue }
        $null = $line -match '^uv (\d+\.\d+\.\d+)'
        $version = [version]$Matches[1]
        if ($version -lt $MinUvVersion) {
            Write-Info ('uv {0} at {1} is older than {2}; not using it' -f $version, $candidate, $MinUvVersion)
            continue
        }
        Set-UvTlsEnv $version
        return $candidate
    }
    return $null
}

function Install-Uv {
    # Downloads a pinned uv release zip from GitHub, checks its published SHA-256, and copies
    # uv.exe into %LOCALAPPDATA%\Programs\uv\<version>. PATH is not modified.
    $arch = 'x86_64'
    if ((Get-WindowsArch) -eq 'arm64') { $arch = 'aarch64' }
    $asset = 'uv-{0}-pc-windows-msvc.zip' -f $arch
    $baseUrl = 'https://github.com/astral-sh/uv/releases/download/{0}/' -f $UvVersion
    $tmp = New-TempDir
    try {
        $zip = Join-Path $tmp $asset
        Write-Info ('Downloading uv {0} ({1}) from GitHub releases' -f $UvVersion, $asset)
        Invoke-Download -Uri ($baseUrl + $asset) -OutFile $zip
        Invoke-Download -Uri ($baseUrl + $asset + '.sha256') -OutFile ($zip + '.sha256')
        $expected = ((Get-Content -LiteralPath ($zip + '.sha256') -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { throw ('uv download checksum mismatch (expected {0}, got {1}).' -f $expected, $actual) }
        $extractDir = Join-Path $tmp 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force
        $uvFile = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'uv.exe' | Select-Object -First 1
        if (-not $uvFile) { throw 'uv.exe was not found in the downloaded archive.' }
        $destDir = Split-Path -Parent $script:UvLocalExe
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $uvFile.FullName -Destination $script:UvLocalExe -Force
        Add-Change ('installed uv {0} to {1} (user profile; PATH unchanged)' -f $UvVersion, $destDir)
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Set-UvTlsEnv ([version]$UvVersion)
    return $script:UvLocalExe
}

function Find-UvManagedPython {
    param([string]$UvExe, [string]$Minor, [string]$Label)
    $result = Invoke-Native -FilePath $UvExe -ArgumentList @('python', 'find', $Minor, '--managed-python', '--no-project') -Quiet -AllowFailure -Description 'uv python find'
    if ($result.ExitCode -ne 0) { return $null }
    $path = $result.Output | Where-Object { $_ -match '\.exe\s*$' } | Select-Object -Last 1
    if (-not $path) { return $null }
    $path = $path.Trim()
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Select-PythonCandidate -Label $Label -FilePath $path)
}

function Find-BasePython {
    if ($PythonExe) {
        $info = Select-PythonCandidate -Label '-PythonExe' -FilePath $PythonExe
        if (-not $info) {
            Stop-Setup ('The interpreter passed with -PythonExe is not usable: ' + $PythonExe) @(
                'Pass a 64-bit Python 3.12 or 3.13 python.exe, or omit -PythonExe to let the script search.')
        }
        return $info
    }

    # 1. py launcher. PYTHON_MANAGER_AUTOMATIC_INSTALL=false (set in preflight) stops the new
    #    Python install manager from installing a runtime as a side effect of this probe.
    if (Get-Command py -CommandType Application -ErrorAction SilentlyContinue) {
        foreach ($minor in $PythonAcceptedMinors) {
            $info = Select-PythonCandidate -Label ('py -' + $minor) -FilePath 'py' -PrefixArgs @('-' + $minor)
            if ($info) { return $info }
        }
    }
    else { Write-Info 'py launcher: not installed' }

    # 2. python on PATH, skipping the Microsoft Store app execution alias in WindowsApps.
    $onPath = @(Get-Command python -CommandType Application -All -ErrorAction SilentlyContinue)
    if ($onPath.Count -eq 0) { Write-Info 'python on PATH: none' }
    foreach ($command in $onPath) {
        $source = $command.Source
        if ($source -like '*\Microsoft\WindowsApps\*') {
            Write-Info ('python on PATH: {0} -> skipped (Microsoft Store app execution alias)' -f $source)
            continue
        }
        $info = Select-PythonCandidate -Label 'python on PATH' -FilePath $source
        if ($info) { return $info }
    }

    # 3. Per-user installs from earlier runs: PEP 514 registrations under HKCU (read-only),
    #    the python.org per-user default folders, and uv-managed Pythons.
    $seen = @{}
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($minor in $PythonAcceptedMinors) {
        $folder = 'Python' + $minor.Replace('.', '')
        foreach ($suffix in @('', '-64', '-arm64')) {
            $paths.Add((Join-Path $local ('Programs\Python\' + $folder + $suffix + '\python.exe')))
        }
    }
    $pep514 = 'HKCU:\Software\Python\PythonCore'
    if (Test-Path -LiteralPath $pep514) {
        foreach ($key in @(Get-ChildItem -LiteralPath $pep514 -ErrorAction SilentlyContinue)) {
            $installKey = $key.PSPath + '\InstallPath'
            $exe = $null
            try { $exe = (Get-ItemProperty -LiteralPath $installKey -Name 'ExecutablePath' -ErrorAction Stop).ExecutablePath } catch { }
            if ($exe) { $paths.Add($exe) }
        }
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $full = [IO.Path]::GetFullPath($path)
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        $info = Select-PythonCandidate -Label 'per-user install' -FilePath $full
        if ($info) { return $info }
    }
    $uv = Get-UvExe
    if ($uv) {
        foreach ($minor in $PythonAcceptedMinors) {
            $info = Find-UvManagedPython -UvExe $uv -Minor $minor -Label 'uv-managed Python'
            if ($info) { return $info }
        }
    }
    return $null
}

function Install-PythonWithUv {
    $uv = Get-UvExe
    if (-not $uv) { $uv = Install-Uv }
    Write-Info ('uv python install {0} --no-bin --no-registry  (into {1})' -f $PythonInstallMinor, $env:UV_PYTHON_INSTALL_DIR)
    $null = Invoke-Native -FilePath $uv -ArgumentList @('python', 'install', $PythonInstallMinor, '--no-bin', '--no-registry') -Description 'uv python install'
    $info = Find-UvManagedPython -UvExe $uv -Minor $PythonInstallMinor -Label 'uv-managed Python (new)'
    if (-not $info) { throw 'uv reported success but "uv python find" did not return a usable interpreter.' }
    Add-Change ('installed Python {0} per-user with uv: {1}' -f $info.version, $info.exe)
    return $info
}

function Install-PythonFromPythonOrg {
    $arch = Get-WindowsArch
    $fileName = 'python-{0}-{1}.exe' -f $PythonOrgVersion, $arch
    $url = 'https://www.python.org/ftp/python/{0}/{1}' -f $PythonOrgVersion, $fileName
    $tmp = New-TempDir
    try {
        $installer = Join-Path $tmp $fileName
        $log = Join-Path $tmp 'python-install.log'
        Write-Info ('Downloading ' + $url)
        Invoke-Download -Uri $url -OutFile $installer
        $signature = Get-AuthenticodeSignature -FilePath $installer
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
            throw ('installer signature check failed (status: {0}).' -f $signature.Status)
        }
        # Per-user, quiet, nothing added to PATH. InstallLauncherAllUsers defaults to 1 (needs
        # admin), so the launcher is turned off entirely. Options from the CPython Windows docs.
        $installerArgs = @('/quiet', 'InstallAllUsers=0', 'PrependPath=0', 'AppendPath=0',
            'Include_launcher=0', 'InstallLauncherAllUsers=0', 'AssociateFiles=0', 'Shortcuts=0',
            'Include_doc=0', 'Include_test=0', 'Include_tcltk=0', '/log', ('"' + $log + '"'))
        Write-Info ('Running the installer per-user: ' + (($installerArgs | Select-Object -First 11) -join ' '))
        # One pre-quoted string: Start-Process joins array elements without quoting them.
        $process = Start-Process -FilePath $installer -ArgumentList ($installerArgs -join ' ') -Wait -PassThru
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            $keptLog = Join-Path ([IO.Path]::GetTempPath()) 'dbt-setup-python-install.log'
            Copy-Item -LiteralPath $log -Destination $keptLog -Force -ErrorAction SilentlyContinue
            throw ('the python.org installer exited with code {0} (1625 = blocked by policy). Log: {1}' -f $process.ExitCode, $keptLog)
        }
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $folder = 'Python' + $PythonInstallMinor.Replace('.', '')
    foreach ($suffix in @('', '-64', '-arm64')) {
        $exe = Join-Path $local ('Programs\Python\' + $folder + $suffix + '\python.exe')
        if (Test-Path -LiteralPath $exe) {
            $info = Select-PythonCandidate -Label 'python.org per-user (new)' -FilePath $exe
            if ($info) {
                Add-Change ('installed Python {0} per-user from python.org: {1}' -f $info.version, $info.exe)
                return $info
            }
        }
    }
    throw ('the installer finished but no Python {0} was found under {1}\Programs\Python' -f $PythonInstallMinor, $local)
}

function Install-BasePython {
    # uv is preferred: it needs no installer engine (MSI policies do not apply), installs a current
    # 3.12 security build (python.org stopped shipping 3.12 Windows installers after 3.12.10), and
    # stays out of PATH and the registry. The python.org installer is the fallback.
    $methods = @(switch ($PythonInstallMethod) {
            'Auto'      { 'Uv'; 'PythonOrg' }
            'Uv'        { 'Uv' }
            'PythonOrg' { 'PythonOrg' }
            default     { }
        })
    if ($methods.Count -eq 0) {
        Stop-Setup 'No compatible Python found, and -PythonInstallMethod None forbids installing one.' (Get-ManualPythonHelp)
    }
    foreach ($method in $methods) {
        try {
            if ($method -eq 'Uv') { return (Install-PythonWithUv) }
            return (Install-PythonFromPythonOrg)
        }
        catch {
            Write-Warn ('Python install via {0} failed: {1}' -f $method, $_.Exception.Message)
        }
    }
    Stop-Setup ('Could not install Python {0} per-user (downloads blocked, or the installer was refused).' -f $PythonInstallMinor) (Get-ManualPythonHelp)
}

# =====================================================================================
# Virtual environment
# =====================================================================================
function Get-VenvFreeze {
    $result = Invoke-Native -FilePath $script:VenvPython -ArgumentList @('-m', 'pip', 'freeze', '--disable-pip-version-check') -Quiet -Description 'pip freeze'
    $lines = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($line in $result.Output) {
        $match = [regex]::Match($line, '^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)$')
        if ($match.Success) {
            $lines.Add($line)
            $map[(Get-NormalizedName $match.Groups[1].Value)] = $match.Groups[2].Value
            continue
        }
        $direct = [regex]::Match($line, '^([A-Za-z0-9][A-Za-z0-9._-]*)\s+@\s+')
        if ($direct.Success) {
            $lines.Add($line)
            $map[(Get-NormalizedName $direct.Groups[1].Value)] = '(direct reference)'
        }
    }
    return New-Object psobject -Property @{ Lines = $lines.ToArray(); Map = $map }
}

function Get-VenvStatus {
    $status = New-Object psobject -Property @{ Exists = $false; IsVenv = $false; Healthy = $false; Reason = ''; Info = $null; Freeze = $null }
    if (-not (Test-Path -LiteralPath $script:VenvDir)) { return $status }
    $status.Exists = $true
    $item = Get-Item -LiteralPath $script:VenvDir -Force
    if (-not $item.PSIsContainer) {
        Stop-Setup ('{0} is a file, not a folder.' -f $script:VenvDir) @('Rename or remove it, then re-run.')
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Stop-Setup ('{0} is a junction or symbolic link.' -f $script:VenvDir) @(
            'This script never deletes or rebuilds a linked .venv (deleting through a link can remove the target).',
            'Remove the link yourself, then re-run.')
    }
    $status.IsVenv = (Test-Path -LiteralPath (Join-Path $script:VenvDir 'pyvenv.cfg')) -or
                     (Test-Path -LiteralPath (Join-Path $script:VenvDir 'Lib\site-packages')) -or
                     (Test-Path -LiteralPath (Join-Path $script:VenvDir 'Scripts\activate.bat'))
    if (-not $status.IsVenv) { $status.Reason = 'not a Python virtual environment'; return $status }
    if (-not (Test-Path -LiteralPath $script:VenvPython)) { $status.Reason = 'Scripts\python.exe is missing'; return $status }
    $info = Get-PythonInfo -FilePath $script:VenvPython
    if (-not $info) { $status.Reason = 'its python.exe does not start (was the base Python moved or uninstalled?)'; return $status }
    $status.Info = $info
    $reason = Test-PythonInfo $info
    if ($reason) { $status.Reason = $reason; return $status }
    try { $status.Freeze = Get-VenvFreeze }
    catch { $status.Reason = 'pip does not work inside it'; return $status }
    $status.Healthy = $true
    return $status
}

function Remove-Venv {
    param([string]$Reason)
    Write-Info ('Deleting .venv ({0})' -f $Reason)
    try { Remove-Item -LiteralPath $script:VenvDir -Recurse -Force }
    catch {
        Stop-Setup ('Could not delete .venv: ' + $_.Exception.Message) @(
            'Something is still using it: the VS Code Python/Pylance extension, a terminal running dbt, or Jupyter.',
            'Close the VS Code windows for this folder, run the script from a standalone PowerShell window,',
            'and re-run with -Recreate.')
    }
}

function New-Venv {
    param($Base)
    Write-Info ('Creating .venv with {0} (Python {1})' -f $Base.exe, $Base.version)
    $null = Invoke-Native -FilePath $Base.exe -ArgumentList @('-I', '-m', 'venv', $script:VenvDir) -Description 'python -m venv'
    $info = Get-PythonInfo -FilePath $script:VenvPython
    $reason = Test-PythonInfo $info
    if ($reason) { Stop-Setup ('The new .venv failed verification: ' + $reason) }
    Add-Change ('created .venv (Python {0})' -f $info.version)
    return $info
}

# =====================================================================================
# requirements.txt and the lock file
# =====================================================================================
function Read-RequirementSpecs {
    # Returns @{ normalized-name = 'spec without spaces' } for plain requirement lines.
    param([string]$Path)
    $map = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith('-')) { continue }
        $comment = $line.IndexOf(' #')
        if ($comment -ge 0) { $line = $line.Substring(0, $comment).Trim() }
        $match = [regex]::Match($line, '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*(.*)$')
        if (-not $match.Success) { continue }
        $map[(Get-NormalizedName $match.Groups[1].Value)] = ($match.Groups[3].Value -replace '\s', '')
    }
    return $map
}

function Get-RequirementsTemplate {
    return @(
        '# Direct Python dependencies of this dbt project.',
        ('# dbt-core and dbt-fabric are pinned to the team standard; {0} checks these' -f $script:SelfRelative),
        '# lines against its VERSION PINS block and stops if they differ. Both are listed so that pip',
        '# resolves them together: dbt-fabric 1.10.x allows any dbt-core >=1.10.0.',
        '# Add other direct dependencies with exact pins (==), then run the setup script with -UpdateLock.',
        ('dbt-core=={0}' -f $DbtCoreVersion),
        ('dbt-fabric=={0}' -f $DbtFabricVersion)
    )
}

function Sync-RequirementsFile {
    if (-not (Test-Path -LiteralPath $script:ReqPath)) {
        if ($CheckOnly) { Write-Plan 'create requirements.txt with the dbt-core and dbt-fabric pins'; return }
        Write-TextFile -Path $script:ReqPath -Lines (Get-RequirementsTemplate)
        Add-Change 'created requirements.txt'
        return
    }
    $specs = Read-RequirementSpecs $script:ReqPath
    if ($specs.ContainsKey('dbt-fabric-samdebruyn')) {
        Stop-Setup 'requirements.txt lists dbt-fabric-samdebruyn (community fork of the Fabric adapter).' @(
            'This project standardizes on Microsoft''s dbt-fabric. Remove that line and re-run with -UpdateLock.')
    }
    $wanted = [ordered]@{ 'dbt-core' = $DbtCoreVersion; 'dbt-fabric' = $DbtFabricVersion }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $wanted.Keys) {
        $expected = '==' + $wanted[$name]
        if (-not $specs.ContainsKey($name)) { $missing.Add($name + $expected); continue }
        if ($specs[$name] -ne $expected) {
            $found = $specs[$name]
            if (-not $found) { $found = ' (unpinned)' }
            Stop-Setup ('requirements.txt has {0}{1}, but the team standard is {0}{2}.' -f $name, $found, $expected) @(
                'Fix the line in requirements.txt. If the team standard itself changed, update the VERSION PINS',
                'block at the top of this script as well, then re-run with -UpdateLock.')
        }
    }
    foreach ($name in $specs.Keys) {
        if (-not $wanted.Contains($name) -and -not $specs[$name].StartsWith('==')) {
            Write-Warn ('requirements.txt: "{0}" is not pinned with ==; the lock file pins it, but pin it here too.' -f $name)
        }
    }
    if ($missing.Count -eq 0) {
        Write-Ok ('requirements.txt pins dbt-core=={0} and dbt-fabric=={1}' -f $DbtCoreVersion, $DbtFabricVersion)
        return
    }
    if ($CheckOnly) { Write-Plan ('add to requirements.txt: ' + ($missing -join ', ')); return }
    Add-TextLines -Path $script:ReqPath -Lines (@(('# dbt pins (team standard; enforced by {0})' -f $script:SelfRelative)) + $missing.ToArray())
    Add-Change ('requirements.txt: added ' + ($missing -join ', '))
}

function Read-LockFile {
    # Accepts pip-freeze output and uv pip compile output (comments and --hash lines are ignored).
    param([string]$Path)
    $pins = @{}
    $python = $null
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line.StartsWith('#')) {
            if (-not $python -and $line -cmatch '\bPython (\d+\.\d+)') { $python = $Matches[1] }
            continue
        }
        if ($line -eq '' -or $line.StartsWith('-')) { continue }
        $match = [regex]::Match($line, '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*([^\s;#\\]+)')
        if ($match.Success) { $pins[(Get-NormalizedName $match.Groups[1].Value)] = $match.Groups[2].Value }
    }
    return New-Object psobject -Property @{ Pins = $pins; Python = $python }
}

function Compare-LockToVenv {
    param([hashtable]$LockPins, [hashtable]$Installed)
    $diff = New-Object System.Collections.Generic.List[string]
    foreach ($name in ($LockPins.Keys | Sort-Object)) {
        if (-not $Installed.ContainsKey($name)) { $diff.Add(('{0} missing' -f $name)) }
        elseif ($Installed[$name] -ne $LockPins[$name]) { $diff.Add(('{0} {1} (lock: {2})' -f $name, $Installed[$name], $LockPins[$name])) }
    }
    $extra = @($Installed.Keys | Where-Object { -not $LockPins.ContainsKey($_) } | Sort-Object)
    return New-Object psobject -Property @{ Diff = $diff.ToArray(); Extra = $extra }
}

function Test-LockFile {
    # Stops when the lock disagrees with the pins or no longer covers requirements.txt.
    param($Lock)
    $help = @('Re-resolve it in a fresh .venv:  ' + $script:SelfCommand + ' -UpdateLock')
    foreach ($pair in @(@('dbt-core', $DbtCoreVersion), @('dbt-fabric', $DbtFabricVersion))) {
        $locked = $Lock.Pins[$pair[0]]
        if ($locked -ne $pair[1]) {
            if (-not $locked) { $locked = '<missing>' }
            Stop-Setup ('requirements-lock.txt has {0} {1}, but the team standard is {2}.' -f $pair[0], $locked, $pair[1]) $help
        }
    }
    if ($Lock.Pins.ContainsKey('dbt-fabric-samdebruyn')) {
        Stop-Setup 'requirements-lock.txt contains the community fork dbt-fabric-samdebruyn.' $help
    }
    if (Test-Path -LiteralPath $script:ReqPath) {
        $specs = Read-RequirementSpecs $script:ReqPath
        foreach ($name in $specs.Keys) {
            $spec = $specs[$name]
            if (-not $Lock.Pins.ContainsKey($name)) {
                Stop-Setup ('requirements.txt lists {0}, which requirements-lock.txt does not contain (stale lock).' -f $name) $help
            }
            if ($spec.StartsWith('==') -and -not $spec.Contains(';') -and $spec.Substring(2) -ne $Lock.Pins[$name]) {
                Stop-Setup ('requirements.txt pins {0}{1}, but requirements-lock.txt has {2} (stale lock).' -f $name, $spec, $Lock.Pins[$name]) $help
            }
        }
    }
}

function Write-LockFile {
    param($Freeze)
    $direct = @($Freeze.Lines | Where-Object { $_ -match '\s@\s' })
    if ($direct.Count -gt 0) {
        Write-Warn ('The lock contains direct references that may not exist on other machines: ' + ($direct -join '; '))
    }
    $header = @(
        ('# requirements-lock.txt -- generated by {0} from "pip freeze"; do not edit by hand.' -f $script:SelfRelative),
        ('# Resolved from requirements.txt on Python {0} (Windows {1}) at {2} UTC.' -f $script:VenvInfo.version, $script:VenvInfo.machine, (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')),
        '# Commit this file: the setup script installs from it whenever it exists, so every developer gets',
        '# the same transitive versions. To re-resolve after editing requirements.txt, run it with -UpdateLock.'
    )
    Write-TextFile -Path $script:LockPath -Lines ($header + $Freeze.Lines)
}

function Update-Pip {
    if ($script:PipUpgraded) { return }
    Write-Info 'Upgrading pip inside .venv'
    $null = Invoke-Native -FilePath $script:VenvPython -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip',
        '--disable-pip-version-check', '--no-input', '--progress-bar', 'off') -Description 'pip install --upgrade pip'
    $script:PipUpgraded = $true
}

function Sync-Packages {
    $lock = $null
    if ((Test-Path -LiteralPath $script:LockPath) -and -not $UpdateLock) {
        $lock = Read-LockFile $script:LockPath
        Test-LockFile $lock
        if ($lock.Python -and $script:VenvInfo -and $lock.Python -ne $script:VenvInfo.minor) {
            Write-Warn ('requirements-lock.txt was resolved on Python {0}; this .venv runs {1}. Fine for this pin set, but regenerate with -UpdateLock if pip reports a missing wheel.' -f $lock.Python, $script:VenvInfo.minor)
        }
    }

    $freeze = $script:VenvStatus.Freeze
    if (-not $freeze -or $script:PipUpgraded -or -not $script:VenvStatus.Healthy) { $freeze = Get-VenvFreeze }

    try {
        if ($lock) {
            $comparison = Compare-LockToVenv -LockPins $lock.Pins -Installed $freeze.Map
            if ($comparison.Diff.Count -eq 0) {
                Write-Ok ('.venv matches requirements-lock.txt ({0} packages); nothing to install' -f $lock.Pins.Count)
            }
            else {
                Write-Info ('.venv differs from requirements-lock.txt in {0} package(s): {1}' -f $comparison.Diff.Count, (($comparison.Diff | Select-Object -First 6) -join '; '))
                if ($CheckOnly) { Write-Plan 'install from requirements-lock.txt'; $script:Installed = $freeze.Map; return }
                Update-Pip
                Write-Info 'pip install -r requirements-lock.txt'
                $null = Invoke-Native -FilePath $script:VenvPython -ArgumentList @('-m', 'pip', 'install', '-r', $script:LockPath,
                    '--disable-pip-version-check', '--no-input', '--progress-bar', 'off') -Description 'pip install -r requirements-lock.txt'
                $freeze = Get-VenvFreeze
                $comparison = Compare-LockToVenv -LockPins $lock.Pins -Installed $freeze.Map
                Add-Change '.venv packages installed/corrected from requirements-lock.txt'
                if ($comparison.Diff.Count -gt 0) {
                    Write-Warn ('After installing, these still differ from the lock: ' + ($comparison.Diff -join '; '))
                }
            }
            if ($comparison.Extra.Count -gt 0) {
                Write-Warn ('.venv has packages that are not in the lock: {0}. Re-run with -Recreate for a clean .venv.' -f ($comparison.Extra -join ', '))
            }
        }
        else {
            if ($CheckOnly) {
                Write-Plan 'resolve requirements.txt in a fresh .venv and write requirements-lock.txt'
                $script:Installed = $freeze.Map
                return
            }
            Update-Pip
            # requirements.txt pins dbt-core and dbt-fabric together, so this is one resolve with both pins.
            Write-Info 'pip install -r requirements.txt'
            $null = Invoke-Native -FilePath $script:VenvPython -ArgumentList @('-m', 'pip', 'install', '-r', $script:ReqPath,
                '--disable-pip-version-check', '--no-input', '--progress-bar', 'off') -Description 'pip install -r requirements.txt'
            $freeze = Get-VenvFreeze
            $existed = Test-Path -LiteralPath $script:LockPath
            Write-LockFile $freeze
            if ($existed) { Add-Change ('rewrote requirements-lock.txt ({0} packages)' -f $freeze.Lines.Count) }
            else { Add-Change ('created requirements-lock.txt ({0} packages) - commit it' -f $freeze.Lines.Count) }
        }
    }
    catch {
        if ($script:FatalShown) { throw }
        Stop-Setup $_.Exception.Message (Get-NetworkHelp)
    }
    $script:Installed = $freeze.Map
}

# =====================================================================================
# Verification of packages and driver
# =====================================================================================
function Test-VcRuntime {
    $system32 = Join-Path $env:SystemRoot 'System32'
    $missing = @(@('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $system32 $_)) })
    if ($missing.Count -eq 0) { Write-Ok 'VC++ 2015-2022 runtime DLLs are present in System32' }
    else {
        Write-Info ('VC++ runtime DLLs not in System32: {0}. Usually fine: Python ships vcruntime140*.dll and the mssql-python wheel bundles msvcp140.dll. The import test below decides.' -f ($missing -join ', '))
    }
}

function Get-SmartAppControlState {
    # Read-only. Documented values: 0 = Off, 1 = On (enforcement), 2 = Evaluation.
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop).VerifiedAndReputablePolicyState
        switch ([int]$value) { 0 { return 'Off' } 1 { return 'On' } 2 { return 'Evaluation' } }
    }
    catch { }
    return 'Unknown'
}

function Write-NativeBinaryReport {
    # Lists every native binary in .venv (.pyd/.dll/.exe) with its Authenticode status, signer and
    # SHA-256, so IT can review an App Control allow request. Written inside .venv (gitignored).
    # pip's own launcher templates (pip\_vendor\distlib\*.exe) are skipped: they are never executed.
    $siteDir = Join-Path $script:VenvDir 'Lib\site-packages'
    $scriptsDir = Join-Path $script:VenvDir 'Scripts'
    $extensions = @('.pyd', '.dll', '.exe')
    $files = @()
    foreach ($dir in @($siteDir, $scriptsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $recurse = ($dir -eq $siteDir)
        $files += @(Get-ChildItem -LiteralPath $dir -File -Force -Recurse:$recurse -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '[\\/]pip[\\/]_vendor[\\/]distlib[\\/]' })
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $status = 'Unknown'
        $signer = ''
        try {
            $signature = Get-AuthenticodeSignature -FilePath $file.FullName
            $status = [string]$signature.Status
            if ($signature.SignerCertificate) {
                $signer = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            }
        }
        catch { }
        $hash = ''
        try { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash } catch { }
        $package = '(Scripts)'
        if ($file.FullName.StartsWith($siteDir, [StringComparison]::OrdinalIgnoreCase)) {
            $package = ($file.FullName.Substring($siteDir.Length).TrimStart('\', '/') -split '[\\/]')[0]
        }
        $rows.Add([pscustomobject]@{
                Path      = $file.FullName.Substring($script:Root.TrimEnd('\', '/').Length).TrimStart('\', '/')
                Package   = $package
                Signature = $status
                Signer    = $signer
                SHA256    = $hash
                Bytes     = $file.Length
            })
    }
    $reportPath = Join-Path $script:VenvDir 'app-control-report.csv'
    $rows | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    $unsigned = @($rows | Where-Object { $_.Signature -ne 'Valid' }).Count
    return New-Object psobject -Property @{ Path = $reportPath; Total = $rows.Count; Unsigned = $unsigned }
}

function Register-AppControlBlock {
    # Windows App Control (Smart App Control, or an organization's App Control for Business / WDAC
    # policy) refused to load a native module. Nothing here can, or should, work around a security
    # policy: report it precisely, give IT what they need, and let the remaining setup steps finish.
    param([string]$Module, [string[]]$Output)
    Write-Fail ('Windows App Control blocked a native Python module ({0}) in .venv from loading.' -f $Module)
    Write-Detail @($Output | Select-Object -Last 3)
    $report = $null
    try { $report = Write-NativeBinaryReport } catch { Write-Info ('Could not write the binary report: ' + $_.Exception.Message) }
    $sac = Get-SmartAppControlState
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('This is not a VC++ runtime or install problem: python.exe is signed and loads, but the compiled')
    $lines.Add('modules that pip installs from PyPI (.pyd files, and the dbt.exe launcher) are unsigned, and an')
    $lines.Add('App Control policy only allows signed or explicitly allowed code. rpds is simply the first one dbt')
    $lines.Add('imports; pydantic-core, msgpack, cryptography and others will hit the same block.')
    if ($report) {
        $lines.Add(('Report for IT: {0}' -f $report.Path))
        $lines.Add(('  {0} native binaries in .venv, {1} not validly signed, with package, signer and SHA-256.' -f $report.Total, $report.Unsigned))
    }
    $lines.Add('Blocks are logged in Event Viewer > Applications and Services Logs > Microsoft > Windows >')
    $lines.Add('CodeIntegrity > Operational (event ID 3077 when enforced).')
    if ($sac -eq 'On') {
        $lines.Add('Smart App Control is ON on this PC, which is the likely source of this block.')
        $script:BlockedSteps.Add('Work PC: raise it with IT (see below). Personal PC: Smart App Control can be turned off in Windows Security > App & browser control > Smart App Control settings; check first how to turn it back on on your Windows version.')
    }
    elseif ($sac -eq 'Off') {
        $lines.Add('Smart App Control is off, so the block comes from your organization''s App Control for Business (WDAC) policy.')
    }
    else {
        $lines.Add(('Smart App Control state: {0}. The block most likely comes from your organization''s App Control for Business (WDAC) policy.' -f $sac))
    }
    $ticket = 'Open an IT/security ticket asking for an App Control allow rule for this project''s .venv'
    if ($report) { $ticket += (' and attach ' + $report.Path) }
    $ticket += '. Because requirements-lock.txt pins exact versions, these binaries only change when the lock changes, so rules generated from the folder (e.g. with the App Control for Business Wizard) stay valid until then.'
    $script:BlockedSteps.Add($ticket)
    $script:BlockedSteps.Add(('After IT confirms the rule is deployed, re-run:  ' + $script:SelfCommand))
    Write-Detail $lines.ToArray()
    $script:BlockedFailure = 'Windows App Control blocks the native modules in .venv, so dbt cannot run yet.'
}

function Test-Packages {
    $core = $script:Installed['dbt-core']
    $fabric = $script:Installed['dbt-fabric']
    if ($core -ne $DbtCoreVersion -or $fabric -ne $DbtFabricVersion) {
        if (-not $core) { $core = '<missing>' }
        if (-not $fabric) { $fabric = '<missing>' }
        if ($CheckOnly) {
            Write-Plan ('installed dbt-core {0} / dbt-fabric {1}; required {2} / {3}' -f $core, $fabric, $DbtCoreVersion, $DbtFabricVersion)
            return
        }
        Stop-Setup ('Installed dbt-core {0} / dbt-fabric {1}, but the pins are {2} / {3}.' -f $core, $fabric, $DbtCoreVersion, $DbtFabricVersion) @('Re-run with -Recreate.')
    }
    if ($script:Installed.ContainsKey('dbt-fabric-samdebruyn')) {
        Stop-Setup 'The community fork dbt-fabric-samdebruyn is installed next to dbt-fabric.' @('Re-run with -Recreate.')
    }
    $mssql = $script:Installed['mssql-python']
    if (-not $mssql) { $mssql = '<missing>' }
    Write-Ok ('dbt-core {0}, dbt-fabric {1}, mssql-python {2} (bundles its own SQL Server driver; no ODBC install)' -f $core, $fabric, $mssql)

    $check = Invoke-Native -FilePath $script:VenvPython -ArgumentList @('-m', 'pip', 'check', '--disable-pip-version-check') -Quiet -AllowFailure -Description 'pip check'
    if ($check.ExitCode -eq 0) { Write-Ok 'pip check: no dependency conflicts' }
    else {
        Write-Warn 'pip check reported conflicts (often a leftover package; -Recreate gives a clean .venv):'
        Write-Detail $check.Output
    }

    Test-VcRuntime
    $import = Invoke-Native -FilePath $script:VenvPython -ArgumentList @('-I', '-c', 'import dbt.adapters.fabric, mssql_python; print(''import ok'')') -Quiet -AllowFailure -Description 'adapter import'
    if ($import.ExitCode -eq 0) { Write-Ok 'dbt.adapters.fabric and mssql_python import cleanly' }
    else {
        $text = $import.Output -join "`n"
        if ($text -match 'Application Control policy has blocked|0x800711C7') {
            $module = 'a native module'
            if ($text -match 'while importing ([A-Za-z0-9_.]+)') { $module = $Matches[1] }
            Register-AppControlBlock -Module $module -Output $import.Output
            return
        }
        $help = @('Output:') + @($import.Output | Select-Object -Last 15)
        if ($text -match 'DLL load failed') {
            $help += @('A native DLL could not load. If the message mentions a missing module or dependency, the',
                'Microsoft Visual C++ 2015-2022 Redistributable (x64) may be missing (Python ships vcruntime140*.dll',
                'and mssql-python bundles msvcp140.dll, so this is rare); installing it needs admin, so ask IT.')
        }
        Stop-Setup 'The Fabric adapter does not import from .venv.' $help
    }
}

# =====================================================================================
# VS Code wiring (text edits, so comments and formatting in existing files survive)
# =====================================================================================
function ConvertTo-JsonText {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-JsonText $_ })
        return ('[' + ($items -join ', ') + ']')
    }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in ([string]$Value).ToCharArray()) {
        if ($char -eq [char]'"') { [void]$builder.Append('\"') }
        elseif ($char -eq [char]'\') { [void]$builder.Append('\\') }
        elseif ([int]$char -lt 32) { [void]$builder.Append(('\u{0:x4}' -f [int]$char)) }
        else { [void]$builder.Append($char) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-JsonEntryLines {
    param($Desired)
    $lines = New-Object System.Collections.Generic.List[string]
    $keys = @($Desired.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $separator = ','
        if ($i -eq $keys.Count - 1) { $separator = '' }
        $lines.Add('    ' + (ConvertTo-JsonText $keys[$i]) + ': ' + (ConvertTo-JsonText $Desired[$keys[$i]]) + $separator)
    }
    return $lines.ToArray()
}

function Test-JsonValueEquivalent {
    param($Actual, $Expected)
    if ($Expected -is [bool]) { return ($Actual -is [bool] -and $Actual -eq $Expected) }
    if ($null -eq $Actual) { return $false }
    $a = ([string]$Actual).Replace('/', '\')
    $e = ([string]$Expected).Replace('/', '\')
    return [string]::Equals($a, $e, [StringComparison]::OrdinalIgnoreCase)
}

function Read-JsonForEdit {
    # Returns $null (after printing manual instructions) when the file cannot be edited safely.
    param([string]$Path, [string]$Label, [string[]]$ManualLines)
    if (Test-Utf16File $Path) {
        Write-Warn ('{0} is UTF-16 encoded - left unchanged. Add these entries yourself:' -f $Label)
        Write-Detail $ManualLines
        return $null
    }
    $text = [IO.File]::ReadAllText($Path)
    $object = $null
    if ($text.Trim() -ne '') {
        $object = ConvertFrom-JsonOrNull $text
        if (-not $object) {
            Write-Warn ('{0} could not be parsed (comments or trailing commas are not supported by ConvertFrom-Json in Windows PowerShell 5.1) - left unchanged. Add these entries yourself:' -f $Label)
            Write-Detail $ManualLines
            return $null
        }
    }
    $newline = "`n"
    if ($text.Contains("`r`n")) { $newline = "`r`n" }
    $indent = '    '
    $indentMatch = [regex]::Match($text, '\n([ \t]+)"')
    if ($indentMatch.Success) { $indent = $indentMatch.Groups[1].Value }
    return New-Object psobject -Property @{ Text = $text; Object = $object; Newline = $newline; Indent = $indent }
}

function ConvertFrom-JsonOrNull {
    param([string]$Text)
    try { $parsed = ConvertFrom-Json -InputObject $Text } catch { return $null }
    if ($parsed -is [System.Management.Automation.PSCustomObject]) { return $parsed }
    return $null
}

function Save-EditedJson {
    # The caller re-parses the edited text and passes the verdict; a broken file is never written.
    param([string]$Path, [string]$Label, [string]$NewText, [bool]$Valid, [string[]]$ManualLines, [string]$ChangeMessage)
    if (-not $Valid) {
        Write-Warn ('Could not merge into {0} safely - left unchanged. Add these entries yourself:' -f $Label)
        Write-Detail $ManualLines
        return
    }
    [IO.File]::WriteAllText($Path, $NewText, $script:Utf8NoBom)
    Add-Change $ChangeMessage
}

function Update-VsCodeSettings {
    $label = '.vscode\settings.json'
    $path = Join-Path $script:Root '.vscode\settings.json'
    $desired = [ordered]@{
        'python.defaultInterpreterPath'       = $VsCodeInterpreterPath
        'python.terminal.activateEnvironment' = $true
    }
    $manual = @('{') + (Get-JsonEntryLines $desired) + @('}')

    if (-not (Test-Path -LiteralPath $path)) {
        if ($CheckOnly) { Write-Plan ('create ' + $label); return }
        Write-TextFile -Path $path -Lines $manual
        Add-Change ('created ' + $label)
        return
    }
    $doc = Read-JsonForEdit -Path $path -Label $label -ManualLines $manual
    if (-not $doc) { return }
    if (-not $doc.Object -or $doc.Text.Trim() -match '^\{\s*\}$') {
        if ($CheckOnly) { Write-Plan ('fill empty ' + $label); return }
        Write-TextFile -Path $path -Lines $manual
        Add-Change ('wrote empty ' + $label)
        return
    }

    $replace = New-Object System.Collections.Generic.List[string]
    $insert = New-Object System.Collections.Generic.List[string]
    foreach ($key in $desired.Keys) {
        $property = $doc.Object.PSObject.Properties[$key]
        if (-not $property) { $insert.Add($key) }
        elseif (-not (Test-JsonValueEquivalent $property.Value $desired[$key])) {
            Write-Info ('{0}: "{1}" is {2}; will set it to {3}' -f $label, $key, (ConvertTo-JsonText $property.Value), (ConvertTo-JsonText $desired[$key]))
            $replace.Add($key)
        }
    }
    if ($replace.Count -eq 0 -and $insert.Count -eq 0) { Write-Ok ($label + ' already points at .venv'); return }
    if ($CheckOnly) { Write-Plan ('update {0}: {1}' -f $label, ((@($replace) + @($insert)) -join ', ')); return }

    $text = $doc.Text
    foreach ($key in $replace) {
        $pattern = '"' + [regex]::Escape($key) + '"\s*:\s*("(?:[^"\\]|\\.)*"|true|false|null|-?\d+(?:\.\d+)?)'
        $match = [regex]::Match($text, $pattern)
        if (-not $match.Success) { Write-Warn ('{0}: could not locate "{1}" - left unchanged. Set it yourself:' -f $label, $key); Write-Detail $manual; return }
        $group = $match.Groups[1]
        $text = $text.Substring(0, $group.Index) + (ConvertTo-JsonText $desired[$key]) + $text.Substring($group.Index + $group.Length)
    }
    if ($insert.Count -gt 0) {
        $brace = $text.IndexOf('{')
        $hasMembers = (@($doc.Object.PSObject.Properties).Count -gt 0)
        $added = ''
        for ($i = 0; $i -lt $insert.Count; $i++) {
            $key = $insert[$i]
            $entry = $doc.Newline + $doc.Indent + (ConvertTo-JsonText $key) + ': ' + (ConvertTo-JsonText $desired[$key])
            if ($i -lt $insert.Count - 1 -or $hasMembers) { $entry += ',' }
            $added += $entry
        }
        $text = $text.Substring(0, $brace + 1) + $added + $text.Substring($brace + 1)
    }
    $expectedCount = @($doc.Object.PSObject.Properties).Count + $insert.Count
    $parsed = ConvertFrom-JsonOrNull $text
    $valid = $false
    if ($parsed -and @($parsed.PSObject.Properties).Count -eq $expectedCount) {
        $valid = $true
        foreach ($key in $desired.Keys) {
            $property = $parsed.PSObject.Properties[$key]
            if (-not $property -or -not (Test-JsonValueEquivalent $property.Value $desired[$key])) { $valid = $false }
        }
    }
    Save-EditedJson -Path $path -Label $label -NewText $text -Valid $valid -ManualLines $manual -ChangeMessage ('merged interpreter settings into ' + $label)
}

function Update-VsCodeExtensions {
    $label = '.vscode\extensions.json'
    $path = Join-Path $script:Root '.vscode\extensions.json'
    $manual = @('{', ('    "recommendations": ' + (ConvertTo-JsonText ([object[]]$RecommendedExtensions))), '}')

    if (-not (Test-Path -LiteralPath $path)) {
        if ($CheckOnly) { Write-Plan ('create ' + $label); return }
        Write-TextFile -Path $path -Lines $manual
        Add-Change ('created ' + $label)
        return
    }
    $doc = Read-JsonForEdit -Path $path -Label $label -ManualLines $manual
    if (-not $doc) { return }
    if (-not $doc.Object -or $doc.Text.Trim() -match '^\{\s*\}$') {
        if ($CheckOnly) { Write-Plan ('fill empty ' + $label); return }
        Write-TextFile -Path $path -Lines $manual
        Add-Change ('wrote empty ' + $label)
        return
    }
    $unwanted = @()
    if ($doc.Object.PSObject.Properties['unwantedRecommendations']) { $unwanted = @($doc.Object.unwantedRecommendations) }
    $recommendations = $doc.Object.PSObject.Properties['recommendations']
    $current = @()
    if ($recommendations) {
        if (-not ($recommendations.Value -is [array])) {
            Write-Warn ('{0}: "recommendations" is not an array - left unchanged.' -f $label)
            return
        }
        $current = @($recommendations.Value)
    }
    foreach ($id in $RecommendedExtensions) {
        if ($unwanted -contains $id) { Write-Info ('{0}: {1} is listed in unwantedRecommendations; respecting that' -f $label, $id) }
    }
    $add = @($RecommendedExtensions | Where-Object { $current -notcontains $_ -and $unwanted -notcontains $_ })
    if ($add.Count -eq 0) { Write-Ok ($label + ' already recommends the Python extension'); return }
    if ($CheckOnly) { Write-Plan ('add {0} to {1}' -f ($add -join ', '), $label); return }

    $text = $doc.Text
    $quoted = (@($add | ForEach-Object { ConvertTo-JsonText $_ }) -join ', ')
    if ($recommendations) {
        $match = [regex]::Match($text, '"recommendations"\s*:\s*\[')
        if (-not $match.Success) { Write-Warn ('{0}: could not locate the recommendations array - left unchanged.' -f $label); Write-Detail $manual; return }
        if ($current.Count -gt 0) { $quoted += ', ' }
        $position = $match.Index + $match.Length
        $text = $text.Substring(0, $position) + $quoted + $text.Substring($position)
    }
    else {
        $brace = $text.IndexOf('{')
        $entry = $doc.Newline + $doc.Indent + '"recommendations": [' + $quoted + ']'
        if (@($doc.Object.PSObject.Properties).Count -gt 0) { $entry += ',' }
        $text = $text.Substring(0, $brace + 1) + $entry + $text.Substring($brace + 1)
    }
    $parsed = ConvertFrom-JsonOrNull $text
    $valid = $false
    if ($parsed -and $parsed.PSObject.Properties['recommendations']) {
        $list = @($parsed.recommendations)
        $valid = $true
        foreach ($id in $add) { if ($list -notcontains $id) { $valid = $false } }
    }
    Save-EditedJson -Path $path -Label $label -NewText $text -Valid $valid -ManualLines $manual -ChangeMessage ('added {0} to {1}' -f ($add -join ', '), $label)
}

# =====================================================================================
# .gitignore
# =====================================================================================
function Update-GitIgnore {
    $path = Join-Path $script:Root '.gitignore'
    $present = @{}
    if (Test-Path -LiteralPath $path) {
        if (Test-Utf16File $path) {
            Write-Warn ('.gitignore is UTF-16 encoded - left unchanged. Make sure it contains: ' + ($GitIgnoreEntries -join ' '))
            return
        }
        foreach ($raw in [IO.File]::ReadAllLines($path)) {
            $line = $raw.Trim()
            if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith('!')) { continue }
            $present[$line.Trim('/').ToLowerInvariant()] = $true
        }
    }
    $missing = @($GitIgnoreEntries | Where-Object { -not $present.ContainsKey($_.Trim('/').ToLowerInvariant()) })
    if ($missing.Count -eq 0) { Write-Ok ('.gitignore already ignores ' + ($GitIgnoreEntries -join ' ')); return }
    if ($CheckOnly) { Write-Plan ('add to .gitignore: ' + ($missing -join ' ')); return }
    $block = @(('# dbt / Python local artifacts (added by {0})' -f $script:SelfRelative)) + $missing
    if (Test-Path -LiteralPath $path) {
        Add-TextLines -Path $path -Lines (@('') + $block)
        Add-Change ('.gitignore: added ' + ($missing -join ' '))
    }
    else {
        Write-TextFile -Path $path -Lines $block
        Add-Change ('created .gitignore with ' + ($missing -join ' '))
    }
}

# =====================================================================================
# dbt project, profile and sign-in
# =====================================================================================
$script:PyReadProjectProfile = @'
import sys
sys.stdout.reconfigure(encoding='utf-8')
try:
    import yaml
    with open(sys.argv[1], encoding='utf-8-sig') as f:
        d = yaml.safe_load(f)
except Exception as e:
    print('ERROR ' + (str(e).splitlines() or [''])[0])
    sys.exit(0)
p = d.get('profile') if isinstance(d, dict) else None
print('PROFILE ' + str(p) if p else 'NONE')
'@

$script:PyCheckProfile = @'
import sys, json, re
sys.stdout.reconfigure(encoding='utf-8')
try:
    import yaml
    with open(sys.argv[1], encoding='utf-8-sig') as f:
        d = yaml.safe_load(f)
except Exception as e:
    print('PARSE_ERROR ' + (str(e).splitlines() or [''])[0])
    sys.exit(0)
if d is None:
    d = {}
if not isinstance(d, dict):
    print('PARSE_ERROR the top level is not a mapping')
    sys.exit(0)
name = sys.argv[2]
if name not in d:
    print('MISSING')
    sys.exit(0)
prof = d[name] if isinstance(d[name], dict) else {}
outputs = prof.get('outputs') if isinstance(prof.get('outputs'), dict) else {}
out = outputs.get(prof.get('target'))
if not isinstance(out, dict):
    out = prof
auth = str(out.get('authentication', out.get('auth', '')))
names = sorted(set(re.findall(r'env_var\(\s*\\?[\x27\x22]([A-Za-z0-9_]+)\\?[\x27\x22]\s*\)', json.dumps(out))))
print('FOUND auth=' + auth + ' env=' + ','.join(names))
'@

function Find-DbtProjectDir {
    if (Test-Path -LiteralPath (Join-Path $script:Root 'dbt_project.yml')) { return $script:Root }
    $skip = @('.venv', '.git', '.vscode', 'dbt_packages', 'target', 'logs', 'node_modules')
    $found = @(Get-ChildItem -LiteralPath $script:Root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name -and (Test-Path -LiteralPath (Join-Path $_.FullName 'dbt_project.yml')) })
    if ($found.Count -eq 1) { return $found[0].FullName }
    if ($found.Count -gt 1) {
        Write-Info ('Several dbt projects found ({0}); run dbt debug from the one you work on.' -f ((@($found | ForEach-Object { $_.Name })) -join ', '))
    }
    return $null
}

function ConvertTo-ProfileName {
    param([string]$Text)
    $name = ($Text.ToLowerInvariant() -replace '[^a-z0-9_]+', '_').Trim('_')
    if (-not $name) { $name = 'dbt_project' }
    if ($name -match '^[0-9]') { $name = 'p_' + $name }
    return $name
}

function Get-ProfileTemplate {
    param([string]$Name)
    $quotedName = "'" + $Name.Replace("'", "''") + "'"
    if ($AuthMethod -eq 'CLI') {
        $authNote = @(
            '# authentication: CLI uses your Azure CLI sign-in (run "az login" first).',
            '# No Azure CLI? Use  authentication: ActiveDirectoryInteractive  (browser sign-in, Windows only).')
    }
    else {
        $authNote = @(
            '# authentication: ActiveDirectoryInteractive opens a browser sign-in (Windows only).',
            '# With Azure CLI installed you can use  authentication: CLI  (reuses "az login").')
    }
    return @(
        ('# dbt profile "{0}" -- added by setup-dbt.ps1 on {1}.' -f $Name, (Get-Date -Format 'yyyy-MM-dd')),
        '# Adapter: Microsoft dbt-fabric 1.10.x. It connects through mssql-python, which bundles its own',
        '# driver, so no ODBC driver and no "driver:" key are needed.',
        '# Connection values come from environment variables; nothing tenant-specific is stored here:',
        '#   DBT_FABRIC_SERVER    warehouse SQL connection string host (<id>.datawarehouse.fabric.microsoft.com)',
        '#   DBT_FABRIC_DATABASE  warehouse name',
        '#   DBT_FABRIC_SCHEMA    your development schema, e.g. dbt_<yourname>'
    ) + $authNote + @(
        ($quotedName + ':'),
        '  target: dev',
        '  outputs:',
        '    dev:',
        '      type: fabric',
        '      server: "{{ env_var(''DBT_FABRIC_SERVER'') }}"',
        '      database: "{{ env_var(''DBT_FABRIC_DATABASE'') }}"',
        '      schema: "{{ env_var(''DBT_FABRIC_SCHEMA'') }}"',
        ('      authentication: ' + $AuthMethod),
        '      threads: 4'
    )
}

function Get-ProfileState {
    # State: NoFile | Missing | Found | ParseError, plus the target's auth and required env vars.
    param([string]$Path, [string]$Name)
    $state = New-Object psobject -Property @{ State = 'NoFile'; Auth = $null; EnvVars = @(); Message = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    if ($script:VenvInfo -and (Test-Path -LiteralPath $script:VenvPython)) {
        $result = Invoke-PythonSnippet -Python $script:VenvPython -Code $script:PyCheckProfile -Arguments @($Path, $Name)
        $line = $result.Output | Where-Object { $_ -match '^(FOUND|MISSING|PARSE_ERROR)' } | Select-Object -Last 1
        if ($line -match '^FOUND auth=(.*) env=(.*)$') {
            $state.State = 'Found'
            $state.Auth = $Matches[1].Trim()
            $state.EnvVars = @($Matches[2].Split(',') | Where-Object { $_ })
            return $state
        }
        if ($line -eq 'MISSING') { $state.State = 'Missing'; return $state }
        if ($line) { $state.State = 'ParseError'; $state.Message = ($line -replace '^PARSE_ERROR\s*', ''); return $state }
    }
    # Fallback without a working .venv: a top-level key match.
    $pattern = '^[''"]?' + [regex]::Escape($Name) + '[''"]?\s*:'
    $state.State = 'Missing'
    foreach ($raw in [IO.File]::ReadAllLines($Path)) { if ($raw -match $pattern) { $state.State = 'Found'; break } }
    return $state
}

function Get-DbtProjectProfileName {
    param([string]$ProjectFile)
    if ($script:VenvInfo -and (Test-Path -LiteralPath $script:VenvPython)) {
        $result = Invoke-PythonSnippet -Python $script:VenvPython -Code $script:PyReadProjectProfile -Arguments @($ProjectFile)
        $line = $result.Output | Where-Object { $_ -match '^(PROFILE|NONE|ERROR)' } | Select-Object -Last 1
        if ($line -match '^PROFILE (.+)$') { return $Matches[1].Trim() }
        if ($line -like 'ERROR*') { Write-Warn ('dbt_project.yml could not be parsed: ' + ($line -replace '^ERROR\s*', '')) }
        return $null
    }
    foreach ($raw in [IO.File]::ReadAllLines($ProjectFile)) {
        if ($raw -match '^profile:\s*[''"]?([^''"#]+?)[''"]?\s*(#.*)?$') { return $Matches[1].Trim() }
    }
    return $null
}

function Initialize-DbtProfile {
    $script:DbtProjectDir = Find-DbtProjectDir
    $name = $null
    if ($script:DbtProjectDir) {
        Write-Ok ('dbt project: ' + (Join-Path $script:DbtProjectDir 'dbt_project.yml'))
        $name = Get-DbtProjectProfileName (Join-Path $script:DbtProjectDir 'dbt_project.yml')
        if (-not $name) { Write-Warn 'dbt_project.yml has no "profile:" key; add one, then re-run.'; return }
        if ($name.Contains('{{')) { Write-Warn ('The profile name in dbt_project.yml is templated ({0}); not checking profiles.' -f $name); return }
        if ($ProfileName -and $ProfileName -ne $name) { Write-Info ('-ProfileName ignored: dbt_project.yml uses profile "{0}"' -f $name) }
    }
    else {
        $name = $ProfileName
        if (-not $name) { $name = ConvertTo-ProfileName (Split-Path -Leaf $script:Root) }
        Write-Info ('No dbt_project.yml yet; using profile name "{0}"' -f $name)
        Add-NextStep ('Create the dbt project (no prompts):  dbt init <project_name> --skip-profile-setup   then set  profile: ''{0}''  in its dbt_project.yml' -f $name)
    }
    $script:ProfileNameUsed = $name

    # Same lookup order as dbt-core 1.10: --profiles-dir, DBT_PROFILES_DIR, current directory, ~\.dbt.
    $workDir = $script:DbtProjectDir
    if (-not $workDir) { $workDir = $script:Root }
    $kind = 'home'
    if ($env:DBT_PROFILES_DIR) { $file = Join-Path $env:DBT_PROFILES_DIR 'profiles.yml'; $kind = 'DBT_PROFILES_DIR' }
    elseif (Test-Path -LiteralPath (Join-Path $workDir 'profiles.yml')) { $file = Join-Path $workDir 'profiles.yml'; $kind = 'project' }
    else { $file = Join-Path (Join-Path $script:UserHome '.dbt') 'profiles.yml' }
    $script:ProfilePath = $file

    $state = Get-ProfileState -Path $file -Name $name
    $script:ProfileState = $state.State
    $template = Get-ProfileTemplate $name
    if ($state.State -eq 'Found') {
        $script:ProfileAuth = $state.Auth
        $script:ProfileEnv = $state.EnvVars
        Write-Ok ('Profile "{0}" found in {1} (left unchanged)' -f $name, $file)
        if ($kind -eq 'project') { Write-Info 'That profiles.yml is inside the repo: keep it free of secrets (use env_var()) or gitignore it.' }
        return
    }
    if ($state.State -eq 'ParseError') {
        Write-Warn ('{0} could not be parsed ({1}) - left unchanged. Add this profile yourself:' -f $file, $state.Message)
        Write-Detail $template
        return
    }
    if ($kind -ne 'home') {
        Write-Warn ('Profile "{0}" is missing from {1} ({2}). Not writing there; add this yourself:' -f $name, $file, $kind)
        Write-Detail $template
        return
    }
    if ($CheckOnly) { Write-Plan ('create profile "{0}" in {1}' -f $name, $file); return }

    if ($state.State -eq 'NoFile') {
        Write-TextFile -Path $file -Lines $template
        $script:ProfileCreated = $true
        $script:ProfileState = 'Found'
        $script:ProfileAuth = $AuthMethod
        $script:ProfileEnv = $ProfileEnvVars
        Add-Change ('created {0} with profile "{1}" (outside the repo)' -f $file, $name)
        return
    }
    # The file exists without this profile: append the block (dbt init does the same), keep a backup.
    $backup = $file + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $file -Destination $backup
    try { Add-TextLines -Path $file -Lines (@('') + $template) }
    catch { Write-Warn ('Could not append to {0}: {1}. Add this profile yourself:' -f $file, $_.Exception.Message); Write-Detail $template; return }
    $after = Get-ProfileState -Path $file -Name $name
    if ($after.State -ne 'Found') {
        Copy-Item -LiteralPath $backup -Destination $file -Force
        Write-Warn ('Appending the profile did not produce valid YAML; {0} was restored. Add this profile yourself:' -f $file)
        Write-Detail $template
        return
    }
    $script:ProfileCreated = $true
    $script:ProfileState = 'Found'
    $script:ProfileAuth = $AuthMethod
    $script:ProfileEnv = $ProfileEnvVars
    Add-Change ('added profile "{0}" to {1} (backup: {2})' -f $name, $file, (Split-Path -Leaf $backup))
}

function Test-AzureCli {
    $auth = $script:ProfileAuth
    if (-not $auth) { $auth = $AuthMethod }
    if ($auth -ne 'CLI') {
        Write-Info ('Profile authentication is "{0}": Azure CLI not required.' -f $auth)
        if ($auth -eq 'ActiveDirectoryInteractive') { Add-NextStep 'Expect a browser sign-in window the first time dbt connects.' }
        return
    }
    $az = Get-Command az -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $az) {
        Write-Warn 'Azure CLI (az) not found; "authentication: CLI" needs it.'
        Write-Detail @(
            'Get it without admin rights (Microsoft''s ZIP package):',
            '  1. Download https://aka.ms/installazurecliwindowszipx64 and extract it, e.g. to %LOCALAPPDATA%\Programs\AzureCLI',
            '  2. Add <that folder>\bin to your user PATH: Start > "Edit environment variables for your account"',
            '  3. Open a new terminal and run: az login',
            'Alternatives: ask IT to deploy Azure CLI, or use  authentication: ActiveDirectoryInteractive  in the profile.')
        Add-NextStep 'Install Azure CLI per-user (ZIP package, see the warning above), open a new terminal, run: az login'
        return
    }
    Write-Ok ('Azure CLI: ' + $az.Source)
    $result = Invoke-Native -FilePath $az.Source -ArgumentList @('account', 'show', '--output', 'none') -Quiet -AllowFailure -Description 'az account show'
    if ($result.ExitCode -eq 0) { Write-Ok 'Azure CLI is signed in' }
    else {
        Write-Info 'Azure CLI is not signed in'
        Add-NextStep 'Sign in:  az login   (add --tenant <tenant-id> if you have several tenants)'
    }
}

function Test-Dbt {
    $dbtExe = Join-Path $script:VenvDir 'Scripts\dbt.exe'
    if (-not (Test-Path -LiteralPath $dbtExe)) { Stop-Setup ('dbt.exe not found at ' + $dbtExe) @('Re-run with -Recreate.') }
    $result = Invoke-Native -FilePath $dbtExe -ArgumentList @('--version') -Quiet -AllowFailure -Description 'dbt --version'
    $text = $result.Output -join "`n"
    Write-Detail @($result.Output | Where-Object { $_.Trim() -ne '' } | Select-Object -First 8)
    $core = [regex]::Match($text, 'installed:\s*(\d+\.\d+\.\d+\S*)')
    $fabric = [regex]::Match($text, '(?m)^\s*-\s*fabric:\s*(\d+\.\d+\.\d+\S*)')
    $coreVersion = '<not reported>'
    $fabricVersion = '<not reported>'
    if ($core.Success) { $coreVersion = $core.Groups[1].Value }
    if ($fabric.Success) { $fabricVersion = $fabric.Groups[1].Value }
    if ($result.ExitCode -ne 0 -or $coreVersion -ne $DbtCoreVersion -or $fabricVersion -ne $DbtFabricVersion) {
        if ($CheckOnly) {
            Write-Plan ('dbt --version reports dbt-core {0} and fabric {1}; required {2} and {3}' -f $coreVersion, $fabricVersion, $DbtCoreVersion, $DbtFabricVersion)
            return
        }
        Stop-Setup ('dbt --version reports dbt-core {0} and fabric {1}; required {2} and {3}.' -f $coreVersion, $fabricVersion, $DbtCoreVersion, $DbtFabricVersion) @(
            'The environment does not match the team pins. Re-run with -Recreate; if it persists, delete',
            'requirements-lock.txt only after checking requirements.txt, then run with -UpdateLock.')
    }
    Write-Ok ('dbt --version: dbt-core {0}, fabric plugin {1}' -f $coreVersion, $fabricVersion)
    if ($text -match 'Update available') { Write-Info '"Update available" is expected: the versions are pinned to the team standard.' }

    if (-not $script:DbtProjectDir) { Write-Info 'dbt debug skipped: no dbt_project.yml in this repo yet.'; return }
    if ($script:ProfileState -ne 'Found') { Write-Info 'dbt debug skipped: no profile for this project yet.'; return }
    if ($script:ProfileCreated) {
        Write-Info 'dbt debug skipped: the profile was just created; set its environment variables and sign in first.'
        Add-NextStep 'Then run:  dbt debug   (from the folder that contains dbt_project.yml)'
        return
    }
    $unset = @($script:ProfileEnv | Where-Object { -not [Environment]::GetEnvironmentVariable($_, 'Process') })
    if ($unset.Count -gt 0) {
        Write-Info ('dbt debug skipped: environment variable(s) not set: ' + ($unset -join ', '))
        Add-NextStep 'Then run:  dbt debug   (from the folder that contains dbt_project.yml)'
        return
    }
    Write-Info 'Running dbt debug'
    Push-Location -LiteralPath $script:DbtProjectDir
    try { $debug = Invoke-Native -FilePath $dbtExe -ArgumentList @('debug') -AllowFailure -Description 'dbt debug' }
    finally { Pop-Location }
    if ($debug.ExitCode -eq 0) { Write-Ok 'dbt debug: all checks passed' }
    else {
        Write-Warn 'dbt debug failed (see output above). Usual causes: not signed in, wrong DBT_FABRIC_* values, no access to the warehouse, network/firewall.'
        Add-NextStep 'Fix the dbt debug errors above, then re-run:  dbt debug'
    }
}

# =====================================================================================
# Preflight
# =====================================================================================
function Resolve-ProjectRoot {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Container)) { Stop-Setup ('-ProjectRoot does not exist or is not a folder: ' + $Explicit) }
        $path = (Get-Item -LiteralPath $Explicit).FullName
    }
    else {
        $start = $PSScriptRoot
        if (-not $start) { $start = (Get-Location).ProviderPath }
        $path = $null
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($git) {
            # In a git submodule (e.g. tools\dbt-setup) --show-toplevel is the submodule itself;
            # the project is the parent repo, which --show-superproject-working-tree returns
            # (empty when the script is not in a submodule).
            foreach ($query in @('--show-superproject-working-tree', '--show-toplevel')) {
                $result = Invoke-Native -FilePath $git.Source -ArgumentList @('-C', $start, 'rev-parse', $query) -Quiet -AllowFailure -Description 'git rev-parse'
                if ($result.ExitCode -ne 0) {
                    $reason = $result.Output | Select-Object -First 1
                    if ($reason -and $reason -notmatch 'not a git repository') { Write-Info ('git: ' + $reason) }
                    break
                }
                $top = $result.Output | Where-Object { $_ -and $_ -notmatch '^(fatal|warning|error):' } | Select-Object -Last 1
                if ($top) {
                    $candidate = [IO.Path]::GetFullPath($top.Trim())
                    if (Test-Path -LiteralPath $candidate -PathType Container) { $path = $candidate; break }
                }
            }
        }
        if (-not $path) {
            $path = $start
            $leaf = (Split-Path -Leaf $start).ToLowerInvariant()
            $parentLeaf = (Split-Path -Leaf (Split-Path -Parent $start)).ToLowerInvariant()
            if (@('scripts', 'script') -contains $leaf) { $path = Split-Path -Parent $start }
            elseif ($parentLeaf -eq 'tools') { $path = Split-Path -Parent (Split-Path -Parent $start) }
            elseif ($leaf -eq 'tools') { $path = Split-Path -Parent $start }
        }
    }
    if ($path.Length -gt 3) { $path = $path.TrimEnd('\') }
    return $path
}

function Write-NetworkConfig {
    $shown = 0
    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'PIP_INDEX_URL', 'PIP_EXTRA_INDEX_URL', 'PIP_CERT',
            'PIP_CONFIG_FILE', 'REQUESTS_CA_BUNDLE', 'SSL_CERT_FILE', 'UV_PYTHON_INSTALL_MIRROR')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($value) { Write-Info ('{0} = {1}' -f $name, (Hide-Credential $value)); $shown++ }
    }
    foreach ($file in @((Join-Path $env:APPDATA 'pip\pip.ini'), (Join-Path $env:ProgramData 'pip\pip.ini'), (Join-Path $script:UserHome 'pip\pip.ini'))) {
        if (Test-Path -LiteralPath $file) { Write-Info ('pip config file: ' + $file); $shown++ }
    }
    if ($shown -eq 0) { Write-Info 'No proxy or pip overrides found; pip uses PyPI and the Windows proxy settings.' }
    Write-Info 'Used as-is: TLS verification stays on and no --trusted-host is ever added.'
}

function Invoke-Preflight {
    if ($env:OS -ne 'Windows_NT') { Stop-Setup 'This script supports Windows only.' }
    Write-Ok ('PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    if ($CheckOnly -and ($Recreate -or $UpdateLock)) { Stop-Setup '-CheckOnly cannot be combined with -Recreate or -UpdateLock.' }
    if (Test-IsElevated) { Write-Warn 'Running as Administrator is not needed. Prefer a normal terminal so the environment matches daily use.' }

    $script:Root       = Resolve-ProjectRoot $ProjectRoot
    $script:VenvDir    = Join-Path $script:Root '.venv'
    $script:VenvPython = Join-Path $script:VenvDir 'Scripts\python.exe'
    $script:ReqPath    = Join-Path $script:Root 'requirements.txt'
    $script:LockPath   = Join-Path $script:Root 'requirements-lock.txt'
    $script:UvLocalExe = Join-Path $env:LOCALAPPDATA ('Programs\uv\' + $UvVersion + '\uv.exe')
    Write-Ok ('Project root: ' + $script:Root)
    $display = '.\setup-dbt.ps1'
    if ($script:SelfPath -and (Test-PathUnder $script:SelfPath $script:Root)) {
        $relative = $script:SelfPath.Substring($script:Root.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $script:SelfRelative = $relative.Replace('\', '/')
        $display = '.\' + $relative.Replace('/', '\')
    }
    elseif ($script:SelfPath) {
        $script:SelfRelative = Split-Path -Leaf $script:SelfPath
        $display = $script:SelfPath
    }
    if ($display.Contains(' ')) { $display = '"' + $display + '"' }
    $script:SelfCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $display
    $here = (Get-Location).ProviderPath
    if ($here -and -not [string]::Equals($here.TrimEnd('\'), $script:Root, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Info ('Current folder is {0}; working on the project root above.' -f $here)
    }

    foreach ($oneDrive in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($oneDrive -and (Test-PathUnder $script:Root $oneDrive)) {
            Write-Warn ('The project is inside OneDrive ({0}). It works, but OneDrive syncs thousands of .venv files and can lock them; a folder such as %USERPROFILE%\src is better.' -f $oneDrive)
            break
        }
    }

    $longest = $script:Root.Length + 1 + $VenvLongestRelativePath
    if ($longest -ge 260 -and -not (Test-LongPathsEnabled)) {
        $help = @(
            ('The project path is {0} characters; files inside .venv will reach about {1}, over the 260-character' -f $script:Root.Length, $longest),
            'Windows limit (LongPathsEnabled is off on this machine). Fix without admin: clone the repo to a shorter',
            'path, e.g. %USERPROFILE%\src\<repo> or C:\src\<repo>. With admin, IT can enable LongPathsEnabled.')
        if ($CheckOnly) { Write-Warn 'Project path too long for .venv'; Write-Detail $help }
        else { Stop-Setup 'The project path is too long for a .venv on this machine.' $help }
    }

    foreach ($name in @('PYTHONHOME', 'PYTHONPATH')) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process')) {
            Write-Warn ('{0} is set; it can break virtual environments. Unset it unless you know you need it.' -f $name)
        }
    }
    Write-NetworkConfig

    # Process-scoped settings for this run only (restored on exit).
    Set-ProcessEnv 'PYTHONIOENCODING' 'utf-8'
    Set-ProcessEnv 'PYTHONUNBUFFERED' '1'
    Set-ProcessEnv 'PYTHON_MANAGER_AUTOMATIC_INSTALL' 'false'
    Set-ProcessEnv 'VIRTUAL_ENV' $null
    Set-ProcessEnv 'DBT_USE_COLORS' 'false'
    if (-not $env:UV_PYTHON_INSTALL_DIR) {
        # uv's default is %APPDATA% (Roaming); keep interpreters out of roaming profiles.
        Set-ProcessEnv 'UV_PYTHON_INSTALL_DIR' (Join-Path $env:LOCALAPPDATA 'uv\python')
    }
    try {
        $script:SavedOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = $script:Utf8NoBom
    }
    catch { $script:SavedOutputEncoding = $null }
    try {
        # Windows PowerShell 5.1 on older .NET defaults may not offer TLS 1.2 (python.org/GitHub need it).
        # SystemDefault (0) already lets the OS choose, so it is left alone.
        $script:SavedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$script:SavedSecurityProtocol -ne 0) {
            [Net.ServicePointManager]::SecurityProtocol = $script:SavedSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
    }
    catch { $script:SavedSecurityProtocol = $null }
}

# =====================================================================================
# Main
# =====================================================================================
function Invoke-Main {
    Write-Host ''
    Write-Host ('dbt Core {0} + dbt-fabric {1} -- project-local setup' -f $DbtCoreVersion, $DbtFabricVersion) -ForegroundColor White
    if ($CheckOnly) { Write-Host 'Mode: -CheckOnly (nothing will be installed or written)' -ForegroundColor Yellow }

    Write-Step 'Preflight: shell, project root, paths, network settings'
    Invoke-Preflight

    Write-Step 'requirements.txt (team version pins)'
    Sync-RequirementsFile

    Write-Step 'Existing virtual environment (.venv)'
    $status = Get-VenvStatus
    $script:VenvStatus = $status
    $needCreate = $false
    $reason = $null
    if (-not $status.Exists) {
        Write-Info '.venv does not exist yet'
        $needCreate = $true
        $reason = 'it does not exist'
    }
    elseif (-not $status.IsVenv) {
        Stop-Setup ('{0} exists but is not a Python virtual environment.' -f $script:VenvDir) @(
            'Rename or move it, then re-run. The script never deletes a folder it cannot identify as a venv.')
    }
    else {
        if ($status.Healthy) {
            $script:VenvInfo = $status.Info
            Write-Ok ('.venv runs Python {0} ({1}), built from {2}' -f $status.Info.version, $status.Info.machine, $status.Info.base)
        }
        else { Write-Warn ('.venv is not usable: ' + $status.Reason) }

        if ($Recreate) { $reason = '-Recreate was requested' }
        elseif ($UpdateLock) { $reason = '-UpdateLock re-resolves the lock in a fresh .venv' }
        elseif (-not $status.Healthy) { $reason = $status.Reason }
        elseif ($status.Freeze.Map.ContainsKey('dbt-fabric-samdebruyn')) { $reason = 'it contains the community fork dbt-fabric-samdebruyn' }
        elseif (-not (Test-Path -LiteralPath $script:LockPath) -and $status.Freeze.Map.Count -gt 0) {
            $reason = 'there is no requirements-lock.txt yet, and the lock must be resolved in a clean .venv'
        }
        if ($reason) {
            $needCreate = $true
            Write-Info ('.venv will be rebuilt: ' + $reason)
        }
    }

    Write-Step 'Base Python interpreter'
    if ($needCreate) {
        $script:BasePython = Find-BasePython
        if (-not $script:BasePython) {
            Write-Info ('No 64-bit Python {0} found.' -f ($PythonAcceptedMinors -join ' or '))
            if ($CheckOnly) { Write-Plan ('install Python {0} per-user ({1})' -f $PythonInstallMinor, $PythonInstallMethod) }
            else { $script:BasePython = Install-BasePython }
        }
    }
    else { Write-Ok 'Not needed: the existing .venv is healthy' }

    Write-Step 'Create or rebuild .venv'
    if ($needCreate) {
        if ($CheckOnly) { Write-Plan ('build .venv (' + $reason + ')') }
        else {
            if ($status.Exists) { Remove-Venv $reason }
            $script:VenvInfo = New-Venv $script:BasePython
            $script:VenvStatus = New-Object psobject -Property @{ Healthy = $true; Freeze = $null }
        }
    }
    else { Write-Ok ('Keeping ' + $script:VenvDir) }

    Write-Step 'Python packages: pip, pinned dbt, lock file'
    if ($script:VenvInfo) { Sync-Packages } else { Write-Info 'Skipped: no usable .venv' }

    Write-Step 'Verify packages and the database driver'
    if ($script:Installed) { Test-Packages } else { Write-Info 'Skipped: packages not installed' }

    Write-Step 'VS Code workspace settings'
    Update-VsCodeSettings
    Update-VsCodeExtensions

    Write-Step '.gitignore'
    Update-GitIgnore

    Write-Step 'dbt profile and sign-in prerequisites'
    Initialize-DbtProfile
    Test-AzureCli

    Write-Step 'Verify dbt'
    if ($script:BlockedFailure) { Write-Info 'Skipped: App Control blocks the native modules dbt needs (see step 7).' }
    elseif ($script:Installed -and (Test-Path -LiteralPath $script:VenvPython)) { Test-Dbt }
    else { Write-Info 'Skipped: dbt is not installed' }

    $script:Succeeded = $true
}

function Write-Summary {
    Write-Host ''
    Write-Host '==================================== Summary ====================================' -ForegroundColor Cyan
    if (-not $script:Succeeded) { Write-Host 'Result      : FAILED - fix the [FAIL] above and re-run (re-running is safe).' -ForegroundColor Red }
    elseif ($script:BlockedFailure) { Write-Host ('Result      : BLOCKED - ' + $script:BlockedFailure) -ForegroundColor Red }
    elseif ($CheckOnly -and $script:Drift) { Write-Host 'Result      : CHANGES NEEDED - re-run without -CheckOnly to apply the [TODO] items.' -ForegroundColor Yellow }
    elseif ($script:Warnings.Count -gt 0) { Write-Host ('Result      : OK with {0} warning(s)' -f $script:Warnings.Count) -ForegroundColor Yellow }
    else { Write-Host 'Result      : OK' -ForegroundColor Green }

    if ($script:Root) { Write-Host ('Project root: ' + $script:Root) }
    if ($script:VenvInfo) {
        Write-Host ('Python      : {0} (Python {1}, {2})' -f $script:VenvInfo.base, $script:VenvInfo.version, $script:VenvInfo.machine)
        Write-Host ('venv        : {0}' -f $script:VenvDir)
        Write-Host ('venv python : {0}' -f $script:VenvPython)
    }
    elseif ($script:BasePython) { Write-Host ('Python      : {0} (Python {1})' -f $script:BasePython.exe, $script:BasePython.version) }
    if ($script:Installed) {
        $parts = foreach ($name in @('dbt-core', 'dbt-fabric', 'dbt-adapters', 'dbt-common', 'mssql-python')) {
            $version = $script:Installed[$name]
            if (-not $version) { $version = '-' }
            '{0} {1}' -f $name, $version
        }
        Write-Host ('Installed   : ' + ($parts -join ', '))
    }
    if ($script:ProfileNameUsed -and $script:ProfilePath) {
        Write-Host ('dbt profile : "{0}" in {1} ({2})' -f $script:ProfileNameUsed, $script:ProfilePath, $script:ProfileState)
    }
    Write-Host 'Changes     :'
    if ($script:Changes.Count -eq 0) { Write-Host '  (none)' }
    foreach ($change in $script:Changes) { Write-Host ('  - ' + $change) }
    if ($script:Warnings.Count -gt 0) {
        Write-Host 'Warnings    :' -ForegroundColor Yellow
        foreach ($warning in $script:Warnings) { Write-Host ('  - ' + $warning) -ForegroundColor Yellow }
    }
    if (-not $script:Succeeded -or ($CheckOnly -and $script:Drift)) { Write-Host ''; return }
    if ($script:BlockedFailure) {
        Write-Host 'To unblock  :' -ForegroundColor Cyan
        $number = 0
        foreach ($step in $script:BlockedSteps) { $number++; Write-Host ('  {0}. {1}' -f $number, $step) }
        Write-Host ''
        return
    }

    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('VS Code: Ctrl+Shift+P > "Developer: Reload Window" (or "Python: Select Interpreter" > .venv\Scripts\python.exe).')
    $steps.Add('Open a NEW terminal (Terminal > New Terminal) so .venv is active; check with:  Get-Command dbt')
    if ($script:ProfileCreated -or ($script:ProfileEnv | Where-Object { $ProfileEnvVars -contains $_ })) {
        $steps.Add('Set the connection variables (this terminal only; or persist them with [Environment]::SetEnvironmentVariable(<name>, <value>, ''User'')):')
        $steps.Add('    $env:DBT_FABRIC_SERVER   = "<id>.datawarehouse.fabric.microsoft.com"   # warehouse > SQL connection string')
        $steps.Add('    $env:DBT_FABRIC_DATABASE = "<warehouse name>"')
        $steps.Add('    $env:DBT_FABRIC_SCHEMA   = "dbt_<yourname>"')
    }
    foreach ($step in $script:NextSteps) { $steps.Add($step) }
    if (-not ($script:NextSteps | Where-Object { $_ -like '*dbt debug*' })) {
        $steps.Add('Run:  dbt debug   (from the folder that contains dbt_project.yml)')
    }
    Write-Host 'Next steps  :' -ForegroundColor Cyan
    $number = 0
    foreach ($step in $steps) {
        if ($step.StartsWith('    ')) { Write-Host ('     ' + $step.TrimStart()) }
        else { $number++; Write-Host ('  {0}. {1}' -f $number, $step) }
    }
    Write-Host ''
}

$script:ExitCode = 0
try {
    Invoke-Main
    if ($script:BlockedFailure) { $script:ExitCode = 1 }
    elseif ($CheckOnly -and $script:Drift) { $script:ExitCode = 2 }
}
catch {
    $script:ExitCode = 1
    if (-not $script:FatalShown) {
        Write-Fail $_.Exception.Message
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { Write-Detail ($_.InvocationInfo.PositionMessage -split "`r?`n") }
    }
}
finally {
    Restore-ProcessState
    Write-Summary
}
exit $script:ExitCode
