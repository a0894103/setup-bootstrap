# bootstrap.ps1 - first thing to run on a fresh Windows machine (new-machine SOP, chapter 0).
# Owner runs ONE line in an administrator PowerShell (one UAC):
#   irm https://raw.githubusercontent.com/a0894103/setup-bootstrap/main/bootstrap.ps1 | iex
# Optional before the line: $Roles = 'user,dev,build'   (default 'user,dev')
# What it does:
#   A. everything that needs administrator rights, once: OpenSSH for tezhu, Developer Mode, Chrome,
#      Chrome Remote Desktop host, Codex App license provisioning, and VS Build Tools for the build role.
#   B. downloads this public package to C:\WORK\setup and starts setup-machine.ps1 as the normal user
#      (user-level installs, then the setup console opens in Chrome).
# ASCII only. No secrets in this package (tezhu's SSH key below is a PUBLIC key).
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Roles) { $Roles = 'user,dev' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Output 'Please run this in an ADMINISTRATOR PowerShell (right-click > Run as administrator).'; return }
$root = 'C:\WORK\setup'; $state = "$root\state"; $tmp = "$env:TEMP\bootstrap"
New-Item -ItemType Directory -Force $root, $state, $tmp, 'C:\WORK\TOOLS', 'C:\WORK\AI' | Out-Null
$log = "$state\bootstrap.log"
function L($m) { $l = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Output $l; try { [IO.File]::AppendAllText($log, $l + "`r`n") } catch { } }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
L "bootstrap roles=$Roles arch=$arch user=$env:USERNAME"

# ---------- A. administrator part (one UAC) ----------
L '[A1] OpenSSH server for tezhu (Tailscale range only)'
try {
  if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null }
  Set-Service sshd -StartupType Automatic; Start-Service sshd
  $k = 'C:\ProgramData\ssh\administrators_authorized_keys'
  Set-Content -Path $k -Value 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM6AzJ8aDvYElXj8cWnnERsMQH/kiYd8kBgbrDD6ra+B tezhu@TCCC11' -Encoding ascii
  icacls $k /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
  Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
  if (-not (Get-NetFirewallRule -Name 'sshd-tailscale' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'sshd-tailscale' -DisplayName 'OpenSSH (Tailscale only)' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null }
  powercfg /change standby-timeout-ac 0
  L '[A1] ok'
} catch { L "[A1] ERR $($_.Exception.Message)" }

L '[A2] Developer Mode'
try { New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force | Out-Null; L '[A2] ok' } catch { L "[A2] ERR $($_.Exception.Message)" }

L '[A3] Chrome'
if (-not (Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe')) {
  try { Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/chrome/install/latest/chrome_installer.exe' -OutFile "$tmp\chrome.exe"; Start-Process "$tmp\chrome.exe" -ArgumentList '/silent', '/install', '--do-not-launch-chrome' -Wait; L '[A3] ok' } catch { L "[A3] ERR $($_.Exception.Message)" }
} else { L '[A3] present' }

# ---------- B. download this package and start setup-machine as the normal user ----------
L '[B1] download setup package'
try {
  Invoke-WebRequest -UseBasicParsing 'https://github.com/a0894103/setup-bootstrap/archive/refs/heads/main.zip' -OutFile "$tmp\pkg.zip"
  Expand-Archive "$tmp\pkg.zip" "$tmp\pkg" -Force
  Copy-Item "$tmp\pkg\setup-bootstrap-main\*" $root -Recurse -Force
  L '[B1] ok'
  $pkgOk = $true
} catch { L "[B1] ERR $($_.Exception.Message)"; $pkgOk = $false }

if ($pkgOk) {
L '[B2] start setup-machine.ps1 as the signed-in user (not elevated)'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File $root\setup-machine.ps1 -Roles $Roles -LogDir $state"
$tn = 'SetupMachineOnce'
schtasks /create /tn $tn /tr $cmd /sc once /st 23:59 /it /rl LIMITED /ru "$env:USERDOMAIN\$env:USERNAME" /f | Out-Null
schtasks /run /tn $tn | Out-Null
Start-Sleep 5
schtasks /change /tn $tn /disable | Out-Null
L '[B2] started; the setup console opens in Chrome as soon as Node is installed. Admin steps continue below.'
}

# ---------- A (continued). slower admin steps; setup-machine waits for the marker at the end ----------
L '[A4] Chrome Remote Desktop host'
if (-not (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop\CurrentVersion\remoting_host.exe")) {
  try { Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi' -OutFile "$tmp\crd.msi"; Start-Process msiexec.exe -ArgumentList '/i', "`"$tmp\crd.msi`"", '/qn', '/norestart' -Wait; L '[A4] ok' } catch { L "[A4] ERR $($_.Exception.Message)" }
} else { L '[A4] present' }

L '[A5] Codex App (official MSIX + license, provisioned)'
if (-not (Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'OpenAI.Codex' })) {
  try {
    Invoke-WebRequest -UseBasicParsing "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$arch.msix" -OutFile "$tmp\codex.msix"
    Invoke-WebRequest -UseBasicParsing 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml' -OutFile "$tmp\codex-license.xml"
    Add-AppxProvisionedPackage -Online -PackagePath "$tmp\codex.msix" -LicensePath "$tmp\codex-license.xml" -Regions all | Out-Null
    Copy-Item "$tmp\codex.msix" "$root\codex.msix" -Force
    L '[A5] ok'
  } catch { L "[A5] ERR $($_.Exception.Message)" }
} else { L '[A5] present' }

if ($Roles -match 'build') {
  L '[A6] VS 2022 Build Tools (C++ + ATL) for the build role'
  $vw = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
  $has = (Test-Path $vw) -and (& $vw -products * -requires Microsoft.VisualStudio.Component.VC.ATL -property installationPath)
  if (-not $has) {
    try {
      Invoke-WebRequest -UseBasicParsing 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile "$tmp\vs_buildtools.exe"
      Start-Process "$tmp\vs_buildtools.exe" -ArgumentList '--quiet', '--wait', '--norestart', '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--add', 'Microsoft.VisualStudio.Component.VC.ATL', '--includeRecommended' -Wait
      L '[A6] ok'
    } catch { L "[A6] ERR $($_.Exception.Message)" }
  } else { L '[A6] present' }
}

Set-Content -Path "$state\bootstrap_admin_done.txt" -Value (Get-Date -Format s) -Encoding ascii
L 'admin phase done (marker written)'
