# setup-machine.ps1 - install tools for a machine role, following the new-machine SOP in docs\.
# User-level installs from official sources only. Safe to re-run (skips what is already installed).
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup-machine.ps1 -Roles user,dev [-RepoSource <git url or path>] [-LogDir <dir>]
# Roles: base (always), user (SOP 1), dev (SOP 2). Others (autoconverter, core, build, drama) are added later.
# ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
param(
  [string[]]$Roles = @('user', 'dev'),  # accepts 'user,dev' too
  [string]$RepoSource = 'https://github.com/a0894103/AI_AGENT_ULTRA.git',
  [string]$LogDir = "C:\WORK\setup\state",
  [switch]$SkipChrome,
  [switch]$NoConsole
)
$ErrorActionPreference = 'Stop'
$Roles = @($Roles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force $LogDir, 'C:\WORK\TOOLS', 'C:\WORK\AI' | Out-Null
$log = Join-Path $LogDir 'setup.log'
$results = New-Object System.Collections.ArrayList
function Log($m) { $l = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Output $l; try { [IO.File]::AppendAllText($log, $l + "`r`n") } catch { } }
function Add-UserPath($p) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User'); $parts = @($cur -split ';' | Where-Object { $_ })
  if ($parts -notcontains $p) { [Environment]::SetEnvironmentVariable('Path', (($parts + $p) -join ';'), 'User') }
  if (($env:Path -split ';') -notcontains $p) { $env:Path = "$env:Path;$p" }
}
function Get-File($url, $out) { Log "download $url"; Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out }
function Save-Results { try { [IO.File]::WriteAllText((Join-Path $LogDir 'setup-results.json'), ($results | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { } }
function Step($name, [scriptblock]$check, [scriptblock]$install) {
  $t0 = Get-Date
  try {
    if (& $check) { Log "[skip] $name already present"; [void]$results.Add([pscustomobject]@{ Step = $name; Result = 'present'; Seconds = 0 }); Save-Results; return }
    Log "[run ] $name"; $ErrorActionPreference = 'Continue'; & $install; $ErrorActionPreference = 'Stop'
    $ok = & $check
    [void]$results.Add([pscustomobject]@{ Step = $name; Result = $(if ($ok) { 'installed' } else { 'FAILED-check' }); Seconds = [int]((Get-Date) - $t0).TotalSeconds })
    Log "[$(if ($ok) {'ok  '} else {'FAIL'})] $name"; Save-Results
  } catch {
    [void]$results.Add([pscustomobject]@{ Step = $name; Result = "ERROR: $($_.Exception.Message)"; Seconds = [int]((Get-Date) - $t0).TotalSeconds })
    Log "[ERR ] $name : $($_.Exception.Message)"
  }
}
function Latest-GitHubAsset($repo, $pattern) {
  $rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'setup-machine' }
  ($rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1).browser_download_url
}
$tmp = Join-Path $env:TEMP 'setup-machine'; New-Item -ItemType Directory -Force $tmp | Out-Null
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Log "roles=$($Roles -join ',') arch=$arch user=$env:USERNAME"

# ---------- base (chapter 0-3) ----------
Step 'Git (per-user)' { Test-Path "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe" } {
  $pat = if ($arch -eq 'arm64') { '^Git-.*-arm64\.exe$' } else { '^Git-.*-64-bit\.exe$' }
  $u = Latest-GitHubAsset 'git-for-windows/git' $pat; Get-File $u "$tmp\git.exe"
  Start-Process "$tmp\git.exe" -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NOCANCEL', "/DIR=$env:LOCALAPPDATA\Programs\Git" -Wait
  Add-UserPath "$env:LOCALAPPDATA\Programs\Git\cmd"
}
Step 'Node 24.19.0' { Test-Path 'C:\WORK\TOOLS\nodejs\node.exe' } {
  $u = "https://nodejs.org/dist/v24.19.0/node-v24.19.0-win-$arch.zip"; Get-File $u "$tmp\node.zip"
  Expand-Archive "$tmp\node.zip" $tmp -Force; Move-Item "$tmp\node-v24.19.0-win-$arch" 'C:\WORK\TOOLS\nodejs'
  Add-UserPath 'C:\WORK\TOOLS\nodejs'; Add-UserPath "$env:APPDATA\npm"
}
Step 'gh' { Test-Path 'C:\WORK\TOOLS\gh\bin\gh.exe' } {
  $pat = if ($arch -eq 'arm64') { '^gh_.*_windows_arm64\.zip$' } else { '^gh_.*_windows_amd64\.zip$' }
  $u = Latest-GitHubAsset 'cli/cli' $pat; Get-File $u "$tmp\gh.zip"
  Expand-Archive "$tmp\gh.zip" 'C:\WORK\TOOLS\gh' -Force; Add-UserPath 'C:\WORK\TOOLS\gh\bin'
}
if (-not $SkipChrome) {
  Step 'Chrome' { (Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe') -or (Test-Path "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") } {
    Get-File 'https://dl.google.com/chrome/install/latest/chrome_installer.exe' "$tmp\chrome.exe"
    Start-Process "$tmp\chrome.exe" -ArgumentList '/silent', '/install', '--do-not-launch-chrome' -Wait
  }
}
# ---------- setup console (local web UI) ----------
function Start-SetupConsole {
  $dir = Join-Path $PSScriptRoot 'console'
  $node = 'C:\WORK\TOOLS\nodejs\node.exe'
  if (-not (Test-Path "$dir\server.mjs") -or -not (Test-Path $node)) { Log '[skip] setup console: server.mjs or node missing'; return }
  if (Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue) { Log '[skip] setup console already listening on 8765'; return }
  $cfg = Get-Content "$dir\console.json" -Raw -Encoding UTF8 | ConvertFrom-Json
  $cfg.roles = ($Roles -join ','); $cfg.stateDir = $LogDir
  $cfg.setupScript = $PSCommandPath; $cfg.verifyScript = (Join-Path $PSScriptRoot 'verify-machine.ps1')
  $cfgPath = Join-Path $LogDir 'console.json'
  [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
  Start-Process -FilePath $node -ArgumentList "`"$dir\server.mjs`"", '--config', "`"$cfgPath`"" -WindowStyle Hidden
  Start-Sleep 2
  $chrome = @('C:\Program Files\Google\Chrome\Application\chrome.exe', "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($chrome) { Start-Process -FilePath $chrome -ArgumentList 'http://127.0.0.1:8765' }
  Log '[ok  ] setup console http://127.0.0.1:8765'
}
if (-not $NoConsole) { try { Start-SetupConsole } catch { Log "[ERR ] setup console: $($_.Exception.Message)" } }
function Test-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }
function App-Step($name, [scriptblock]$check, [string[]]$wingetArgs) {
  if (& $check) { Log "[skip] $name already present"; [void]$results.Add([pscustomobject]@{ Step = $name; Result = 'present'; Seconds = 0 }); Save-Results; return }
  if (-not (Test-Winget)) { Log "[wait] $name : no winget here, install from the setup console (opens official download page)"; [void]$results.Add([pscustomobject]@{ Step = $name; Result = 'WAIT-manual'; Seconds = 0 }); Save-Results; return }
  Step $name $check { & winget @wingetArgs 2>&1 | ForEach-Object { Log "  $_" } }
}
Step 'Antigravity App' { [bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^Antigravity' }) } {
  $page = (Invoke-WebRequest -UseBasicParsing -Uri 'https://antigravity.google/download').Content
  $want = if ($arch -eq 'arm64') { 'windows-arm/Antigravity-arm64\.exe' } else { 'windows-x64/Antigravity-x64\.exe' }
  $u = ([regex]::Matches($page, "https://storage\.googleapis\.com/antigravity-public/[^`"'\s]+$want") | Select-Object -First 1).Value
  if (-not $u) { throw 'Antigravity installer link not found on antigravity.google/download' }
  Get-File $u "$tmp\antigravity.exe"
  Start-Process "$tmp\antigravity.exe" -ArgumentList '/S', '/currentuser' -Wait
}
function Install-WingetIfMissing {
  if (Test-Winget) { return $true }
  Log '[run ] winget bootstrap (microsoft/winget-cli release)'
  try {
    $rel = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'setup-machine' }
    $bundle = ($rel.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1).browser_download_url
    $deps = ($rel.assets | Where-Object { $_.name -like '*Dependencies*.zip' } | Select-Object -First 1).browser_download_url
    Get-File $deps "$tmp\winget-deps.zip"; Expand-Archive "$tmp\winget-deps.zip" "$tmp\winget-deps" -Force
    $depArch = if ($arch -eq 'arm64') { 'arm64' } else { 'x64' }
    Get-ChildItem "$tmp\winget-deps" -Recurse -Filter *.appx | Where-Object { $_.FullName -match "\\$depArch\\" } | ForEach-Object { try { Add-AppxPackage -Path $_.FullName -ErrorAction Stop } catch { Log "  dep $($_.Exception.Message)" } }
    Get-File $bundle "$tmp\winget.msixbundle"; Add-AppxPackage -Path "$tmp\winget.msixbundle" -ErrorAction Stop
    $env:Path = "$env:Path;$env:LOCALAPPDATA\Microsoft\WindowsApps"
  } catch { Log "[ERR ] winget bootstrap: $($_.Exception.Message)" }
  return (Test-Winget)
}
# Admin-only items (Chrome Remote Desktop host, Codex App license) are done by bootstrap.ps1 in parallel.
# Wait for its marker before checking them, so this non-elevated script never asks for UAC.
function Wait-BootstrapAdmin {
  $mk = Join-Path $LogDir 'bootstrap_admin_done.txt'
  if (-not (Test-Path (Join-Path $LogDir 'bootstrap.log'))) { return }
  for ($i = 0; $i -lt 160 -and -not (Test-Path $mk); $i++) { if ($i -eq 0) { Log '[wait] bootstrap admin steps still running (CRD host, Codex license)...' }; Start-Sleep 15 }
}
Wait-BootstrapAdmin
Step 'Codex App' { [bool](Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue) } {
  # Store-signed MSIX: needs the official license, provisioned as admin (UAC once), then registered for this user.
  $ma = if ($arch -eq 'arm64') { 'arm64' } else { 'x64' }
  if (Test-Path 'C:\WORK\setup\codex.msix') { Copy-Item 'C:\WORK\setup\codex.msix' "$tmp\codex.msix" -Force } else { Get-File "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$ma.msix" "$tmp\codex.msix" }
  Get-File 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml' "$tmp\codex-license.xml"
  $prov = "Add-AppxProvisionedPackage -Online -PackagePath '$tmp\codex.msix' -LicensePath '$tmp\codex-license.xml' -Regions all | Out-Null"
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) { Invoke-Expression $prov } elseif (-not (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'OpenAI.Codex' })) { Log '  Codex App: not provisioned and not admin - run the bootstrap (admin, one UAC); no separate UAC here' }
  Add-AppxPackage -Path "$tmp\codex.msix"
}
Step 'Chrome Remote Desktop host' { Test-Path "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop\CurrentVersion\remoting_host.exe" } {
  Get-File 'https://dl.google.com/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi' "$tmp\crd.msi"
  Start-Process msiexec.exe -ArgumentList '/i', "`"$tmp\crd.msi`"", '/qn', '/norestart' -Wait
}
$needLogin = ($RepoSource -like 'https://*') -and -not (& { try { & 'C:\WORK\TOOLS\gh\bin\gh.exe' auth status *> $null; $LASTEXITCODE -eq 0 } catch { $false } })
if ($needLogin) {
  Log '[wait] AI_AGENT_ULTRA clone + AutoPull: gh not logged in yet. Owner runs gh auth login, then re-run this script.'
  [void]$results.Add([pscustomobject]@{ Step = 'AI_AGENT_ULTRA clone'; Result = 'WAIT-gh-login'; Seconds = 0 })
} else {
if ($RepoSource -like 'https://*') { & 'C:\WORK\TOOLS\gh\bin\gh.exe' auth setup-git 2>&1 | ForEach-Object { Log "  $_" } }
Step 'AI_AGENT_ULTRA clone' { Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git' } {
  & "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe" -c safe.directory=* clone $RepoSource 'C:\WORK\AI\AI_AGENT_ULTRA' 2>&1 | ForEach-Object { Log "  $_" }
}
Step 'AutoPull task' { [bool](Get-ScheduledTask -TaskName 'AI_AGENT_ULTRA_AutoPull' -ErrorAction SilentlyContinue) } {
  & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\WORK\AI\AI_AGENT_ULTRA\tools\install-auto-pull-task.ps1' 2>&1 | ForEach-Object { Log "  $_" }
}
}

Step 'npm packages (playwright)' { Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\node_modules\playwright\package.json' } {
  if (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\package-lock.json') { Push-Location 'C:\WORK\AI\AI_AGENT_ULTRA'; & 'C:\WORK\TOOLS\nodejs\npm.cmd' ci --no-audit --no-fund 2>&1 | ForEach-Object { Log "  $_" }; Pop-Location }
  else { Log '  repo not cloned yet (needs gh login); re-run after pulling' }
}
# ---------- SOP 1: user ----------
if ($Roles -contains 'user' -or $Roles -contains 'dev') {
  Step 'Claude CLI' { Test-Path "$env:USERPROFILE\.local\bin\claude.exe" } {
    & powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://claude.ai/install.ps1 | iex' 2>&1 | ForEach-Object { Log "  $_" }
    Add-UserPath "$env:USERPROFILE\.local\bin"
  }
  Step 'Codex CLI' { Test-Path "$env:APPDATA\npm\codex.cmd" } {
    & 'C:\WORK\TOOLS\nodejs\npm.cmd' install -g --prefix "$env:APPDATA\npm" '@openai/codex' 2>&1 | ForEach-Object { Log "  $_" }
  }
  Step 'AGY CLI' { Test-Path "$env:LOCALAPPDATA\agy\bin\agy.exe" } {
    & powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://antigravity.google/cli/install.ps1 | iex' 2>&1 | ForEach-Object { Log "  $_" }
  }
}

# ---------- SOP 2: dev ----------
if ($Roles -contains 'dev') {
  Step 'Python 3.12.10 (per-user)' { Test-Path "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" } {
    $u = if ($arch -eq 'arm64') { 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-arm64.exe' } else { 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' }
    Get-File $u "$tmp\python.exe"
    $p = Start-Process "$tmp\python.exe" -ArgumentList '/quiet', 'InstallAllUsers=0', 'InstallLauncherAllUsers=0', 'Include_launcher=0', 'PrependPath=1', 'Include_test=0', 'Include_doc=0', 'Include_tcltk=0', '/log', "$LogDir\python-install.log" -PassThru
    if (-not $p.WaitForExit(1500000)) { Log '  python installer still running after 25 min'; try { $p.Kill() } catch { } }
  }
  Step 'Go 1.27.0' { Test-Path 'C:\WORK\TOOLS\go\bin\go.exe' } {
    $ga = if ($arch -eq 'arm64') { 'arm64' } else { 'amd64' }
    Get-File "https://go.dev/dl/go1.27.0.windows-$ga.zip" "$tmp\go.zip"
    Expand-Archive "$tmp\go.zip" 'C:\WORK\TOOLS' -Force; Add-UserPath 'C:\WORK\TOOLS\go\bin'
  }
}

$results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Log $_ }
$results | ConvertTo-Json | Set-Content -Path (Join-Path $LogDir 'setup-results.json') -Encoding ASCII
Log 'setup done'
