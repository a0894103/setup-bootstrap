# bootstrap.ps1 - first thing to run on a fresh Windows machine (new-machine SOP, chapter 0).
# Owner runs ONE line in an administrator PowerShell (one UAC):
#   irm https://raw.githubusercontent.com/a0894103/setup-bootstrap/main/bootstrap.ps1 | iex
# Optional before the line: $Roles = 'user,dev,build'   (default 'user,dev')
#                           $Site = 'company' | 'home'  (default auto: office gateway or blocked UDP DNS -> DNS over HTTPS)
# What it does:
#   A. everything that needs administrator rights, once: OpenSSH for tezhu, Developer Mode, Chrome,
#      Chrome Remote Desktop host, Google Drive for desktop, Codex App license provisioning, and VS Build Tools for the build role.
#   B. downloads this public package to C:\WORK\setup and starts setup-machine.ps1 as the normal user
#      (user-level installs, then the setup console opens in Chrome).
# ASCII only. No secrets in this package (tezhu's SSH key below is a PUBLIC key).
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Roles) { $Roles = 'user,dev' }
if ($Site -notin 'company', 'home') { $Site = 'auto' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Output 'Please run this in an ADMINISTRATOR PowerShell (right-click > Run as administrator).'; return }
$root = 'C:\WORK\setup'; $state = "$root\state"; $tmp = "$env:TEMP\bootstrap"
New-Item -ItemType Directory -Force $root, $state, $tmp, 'C:\WORK\TOOLS', 'C:\WORK\AI' | Out-Null
$log = "$state\bootstrap.log"
function L($m) { $l = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Output $l; try { [IO.File]::AppendAllText($log, $l + "`r`n") } catch { } }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
L "bootstrap roles=$Roles arch=$arch user=$env:USERNAME"

# ---------- A. administrator part (one UAC) ----------
L '[A0] Tailscale (install only; owner signs in from the tray icon)'
if (-not (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) {
  try {
    $ta = if ($arch -eq 'arm64') { 'arm64' } else { 'amd64' }
    Invoke-WebRequest -UseBasicParsing "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$ta.msi" -OutFile "$tmp\tailscale.msi"
    Start-Process msiexec.exe -ArgumentList '/i', "`"$tmp\tailscale.msi`"", '/qn', '/norestart' -Wait
    L '[A0] ok'
  } catch { L "[A0] ERR $($_.Exception.Message)" }
} else { L '[A0] present' }
L '[A1] OpenSSH server for tezhu (Tailscale range only)'
try {
  if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null }
  Set-Service sshd -StartupType Automatic; Start-Service sshd
  $k = 'C:\ProgramData\ssh\administrators_authorized_keys'
  Set-Content -Path $k -Value @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIaj52dCYwhuTRN7TOY2FwkkS1yPQhl5KzsRlhXPqhGX tezhu@TCCC21', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM6AzJ8aDvYElXj8cWnnERsMQH/kiYd8kBgbrDD6ra+B tezhu@TCCC11') -Encoding ascii
  icacls $k /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
  Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
  if (-not (Get-NetFirewallRule -Name 'sshd-tailscale' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'sshd-tailscale' -DisplayName 'OpenSSH (Tailscale only)' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null }
  powercfg /change standby-timeout-ac 0
  L '[A1] ok'
} catch { L "[A1] ERR $($_.Exception.Message)" }

L '[A2] Developer Mode'
try { New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force | Out-Null; L '[A2] ok' } catch { L "[A2] ERR $($_.Exception.Message)" }

L '[A2b] Microsoft Defender exclusions for build/test folders'
# Owner 10/28: TCCC11 lagged with MsMpEng at ~2 cores scanning every file our builds/tests write (no exclusions set).
# Real-time protection stays on; only these work folders are skipped. Owner runs this script as administrator himself.
try {
  $ex = @('C:\WORK', "$env:LOCALAPPDATA\go-build", "$env:USERPROFILE\go\pkg\mod", "$env:USERPROFILE\.nuget\packages")
  $have = @((Get-MpPreference).ExclusionPath)
  foreach ($p in $ex) { if ($have -notcontains $p) { Add-MpPreference -ExclusionPath $p } }
  L ('[A2b] ok: ' + ((Get-MpPreference).ExclusionPath -join '; '))
} catch { L "[A2b] ERR $($_.Exception.Message)" }

L '[A2c] always-on machine settings (power, long paths, no surprise reboot)'
# These machines run PMs, cores and Chrome workers around the clock; most are laptops left at home or the office.
try {
  powercfg /change hibernate-timeout-ac 0
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0   # closing the lid on AC power does nothing
  powercfg /setactive SCHEME_CURRENT
  # Fast startup off: "shut down" becomes a real shutdown, so services and Tailscale come up clean after a restart.
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -PropertyType DWord -Force | Out-Null
  # Deep .worktrees / node_modules / dotnet obj paths exceed 260 characters.
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force | Out-Null
  # Updates still install; Windows just does not restart by itself while the owner is signed in (that killed PMs and cores).
  $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  New-Item -Path $au -Force | Out-Null
  New-ItemProperty -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value 1 -PropertyType DWord -Force | Out-Null
  L '[A2c] ok'
} catch { L "[A2c] ERR $($_.Exception.Message)" }

L "[A2d] DNS over HTTPS (Site=$Site)"
# The office network (gateway 192.168.50.x) blocks plain UDP DNS: TCCC12 lost all name lookups on 10/27 until DNS went
# over HTTPS. Site 'company' always applies it, 'home' never does, 'auto' applies it on the office gateway or whenever
# UDP DNS fails while TCP DNS works. It keeps working on any other network, so a laptop moved home later is fine.
try {
  $ifc = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Where-Object { $_.InterfaceAlias -notmatch 'Tailscale' } | Sort-Object RouteMetric | Select-Object -First 1)
  $gw = "$($ifc.NextHop)"
  $udpOk = $true; try { Resolve-DnsName github.com -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null } catch { $udpOk = $false }
  $tcpOk = $true; try { Resolve-DnsName github.com -DnsOnly -TcpOnly -QuickTimeout -ErrorAction Stop | Out-Null } catch { $tcpOk = $false }
  $apply = ($Site -eq 'company') -or ($Site -eq 'auto' -and ($gw -like '192.168.50.*' -or (-not $udpOk -and $tcpOk)))
  L "[A2d] adapter=$($ifc.InterfaceAlias) gateway=$gw udpDns=$udpOk tcpDns=$tcpOk apply=$apply"
  if ($apply) {
    $before = (Get-DnsClientServerAddress -InterfaceAlias $ifc.InterfaceAlias -AddressFamily IPv4).ServerAddresses -join ','
    # Keep the first record only (a re-run would otherwise save our own 1.1.1.1/8.8.8.8 as "before").
    if (-not (Test-Path "$state\dns_before.txt")) {
      $dhcp = (Get-NetIPInterface -InterfaceAlias $ifc.InterfaceAlias -AddressFamily IPv4).Dhcp
      $undo = if ("$dhcp" -eq 'Enabled' -or -not $before) { "Set-DnsClientServerAddress -InterfaceAlias '$($ifc.InterfaceAlias)' -ResetServerAddresses" } else { "Set-DnsClientServerAddress -InterfaceAlias '$($ifc.InterfaceAlias)' -ServerAddresses $before" }
      Set-Content -Path "$state\dns_before.txt" -Value "$($ifc.InterfaceAlias) dns=$before dhcp=$dhcp (rollback: $undo)" -Encoding ascii
    }
    foreach ($p in @(@('1.1.1.1', 'https://cloudflare-dns.com/dns-query'), @('8.8.8.8', 'https://dns.google/dns-query'))) {
      if (Get-DnsClientDohServerAddress -ServerAddress $p[0] -ErrorAction SilentlyContinue) { Set-DnsClientDohServerAddress -ServerAddress $p[0] -DohTemplate $p[1] -AllowFallbackToUdp $false -AutoUpgrade $true | Out-Null }
      else { Add-DnsClientDohServerAddress -ServerAddress $p[0] -DohTemplate $p[1] -AllowFallbackToUdp $false -AutoUpgrade $true | Out-Null }
    }
    Set-DnsClientServerAddress -InterfaceAlias $ifc.InterfaceAlias -ServerAddresses @('1.1.1.1', '8.8.8.8')
    netsh dns set global doh=yes | Out-Null
    ipconfig /flushdns | Out-Null
    Start-Sleep 2
    try { Resolve-DnsName github.com -ErrorAction Stop | Out-Null; L "[A2d] ok (was $before)" } catch { L "[A2d] ERR lookup still failing: $($_.Exception.Message)" }
  } else { L '[A2d] skipped' }
} catch { L "[A2d] ERR $($_.Exception.Message)" }

L '[A3] Chrome'
if (-not (Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe')) {
  try { Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/chrome/install/latest/chrome_installer.exe' -OutFile "$tmp\chrome.exe"; Start-Process "$tmp\chrome.exe" -ArgumentList '/silent', '/install', '--do-not-launch-chrome' -Wait; L '[A3] ok' } catch { L "[A3] ERR $($_.Exception.Message)" }
} else { L '[A3] present' }

L '[A3b] Git (into the user folder, but the installer needs admin rights)'
# 10/28 TCCC31: Git 2.56 writes HKLM keys even with /CURRENTUSER; run unelevated in setup-machine it waited ~160 s
# for an elevation that never came and installed nothing. Elevated here it takes ~35 s. Same path as before.
if (-not (Test-Path "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
  try {
    $rel = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'bootstrap' }
    $pat = if ($arch -eq 'arm64') { '^Git-.*-arm64\.exe$' } else { '^Git-.*-64-bit\.exe$' }
    $u = ($rel.assets | Where-Object { $_.name -match $pat } | Select-Object -First 1).browser_download_url
    Invoke-WebRequest -UseBasicParsing $u -OutFile "$tmp\git.exe"
    $p = Start-Process "$tmp\git.exe" -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NOCANCEL', "/DIR=$env:LOCALAPPDATA\Programs\Git", "/LOG=$state\git-install.log" -Wait -PassThru
    L "[A3b] exit=$($p.ExitCode) git=$(Test-Path "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")"
  } catch { L "[A3b] ERR $($_.Exception.Message)" }
} else { L '[A3b] present' }

# ---------- B. download this package and start setup-machine as the normal user ----------
L '[B1] download setup package'
try {
  Invoke-WebRequest -UseBasicParsing 'https://github.com/a0894103/setup-bootstrap/archive/refs/heads/main.zip' -OutFile "$tmp\pkg.zip"
  New-Item -ItemType Directory -Force "$tmp\pkg" | Out-Null; & "$env:SystemRoot\System32\tar.exe" -xf "$tmp\pkg.zip" -C "$tmp\pkg"
  Copy-Item "$tmp\pkg\setup-bootstrap-main\*" $root -Recurse -Force
  L '[B1] ok'
  $pkgOk = $true
} catch { L "[B1] ERR $($_.Exception.Message)"; $pkgOk = $false }

if ($pkgOk) {
L '[B2] start setup-machine.ps1 as the signed-in user (not elevated)'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File $root\setup-machine.ps1 -Roles $Roles -LogDir $state"
$tn = 'SetupMachineOnce'
# Register-ScheduledTask so it also runs on battery (laptops); interactive, not elevated
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File $root\setup-machine.ps1 -Roles $Roles -LogDir $state"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
$pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $tn -Action $act -Settings $set -Principal $pri -Force | Out-Null
Start-ScheduledTask -TaskName $tn
Start-Sleep 5
Disable-ScheduledTask -TaskName $tn | Out-Null
L '[B2] started; the setup console opens in Chrome as soon as Node is installed. Admin steps continue below.'
}

# ---------- A (continued). slower admin steps; setup-machine waits for the marker at the end ----------
L '[A4] Chrome Remote Desktop host'
if (-not (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop\CurrentVersion\remoting_host.exe")) {
  try { Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi' -OutFile "$tmp\crd.msi"; Start-Process msiexec.exe -ArgumentList '/i', "`"$tmp\crd.msi`"", '/qn', '/norestart' -Wait; L '[A4] ok' } catch { L "[A4] ERR $($_.Exception.Message)" }
} else { L '[A4] present' }

L '[A4b] Google Drive for desktop (owner signs in from the tray icon; media lives on G:)'
if (-not (Get-ChildItem "$env:ProgramFiles\Google\Drive File Stream\*\GoogleDriveFS.exe" -ErrorAction SilentlyContinue)) {
  # 10/28 TCCC31: the office network cut the 44 MB download midway, so use curl.exe with retries and check the signature.
  # Wait only for the installer process: -Wait would also wait for GoogleDriveFS.exe, which it starts and never exits.
  try {
    $f = "$tmp\gdrive.exe"; Remove-Item $f -ErrorAction SilentlyContinue
    & curl.exe -sSL --retry 5 --retry-all-errors -o $f 'https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe'
    $sig = Get-AuthenticodeSignature $f
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Google') { throw "download not a valid Google-signed installer ($($sig.Status))" }
    $p = Start-Process $f -ArgumentList '--silent', '--desktop_shortcut', '--gsuite_shortcuts=false' -PassThru
    [void]$p.WaitForExit(900000)
    L "[A4b] exit=$($p.ExitCode) installed=$([bool](Get-ChildItem "$env:ProgramFiles\Google\Drive File Stream\*\GoogleDriveFS.exe" -ErrorAction SilentlyContinue))"
  } catch { L "[A4b] ERR $($_.Exception.Message)" }
} else { L '[A4b] present' }

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
