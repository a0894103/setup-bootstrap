# verify-machine.ps1 - check a machine against the new-machine SOP for the given roles.
# Prints a PASS/FAIL/MANUAL table, writes verify-results.json, exit code = number of FAIL.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File verify-machine.ps1 -Roles user,dev [-OutDir <dir>]
# ASCII only.
param(
  [string[]]$Roles = @('user', 'dev'),  # accepts 'user,dev' too
  [string]$OutDir = "$env:USERPROFILE\setup-logs"
)
$ErrorActionPreference = 'Continue'
$Roles = @($Roles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
New-Item -ItemType Directory -Force $OutDir | Out-Null
# fresh PATH from registry (setup may have changed it in another process)
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$rows = New-Object System.Collections.ArrayList
function Row($role, $item, $status, $detail) { [void]$rows.Add([pscustomobject]@{ Role = $role; Item = $item; Status = $status; Detail = $detail }) }
function Cmd($role, $item, $exe, $verArgs, $expectPathLike, $expectVerLike) {
  $c = Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $c) { Row $role $item 'FAIL' "not on PATH: $exe"; return }
  $v = ''
  try { $v = (& $c.Source @verArgs 2>&1 | Select-Object -First 1 | Out-String).Trim() } catch { $v = "version call failed: $($_.Exception.Message)" }
  $problems = @()
  if ($expectPathLike -and $c.Source -notlike $expectPathLike) { $problems += "path $($c.Source) not like $expectPathLike" }
  if ($expectVerLike -and $v -notlike $expectVerLike) { $problems += "version '$v' not like $expectVerLike" }
  if ($problems) { Row $role $item 'FAIL' ($problems -join '; ') } else { Row $role $item 'PASS' "$v @ $($c.Source)" }
}

# base
Cmd 'base' 'Git' 'git' @('--version') $null 'git version*'
Cmd 'base' 'Node 24' 'node' @('--version') 'C:\WORK\TOOLS\nodejs\*' 'v24.*'
Cmd 'base' 'gh' 'gh' @('--version') 'C:\WORK\TOOLS\gh\*' 'gh version*'
$chrome = @('C:\Program Files\Google\Chrome\Application\chrome.exe', "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($chrome) { Row 'base' 'Chrome' 'PASS' $chrome } else { Row 'base' 'Chrome' 'FAIL' 'chrome.exe not found' }
$ag = [bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^Antigravity' })
if ($ag) { Row 'base' 'Antigravity App' 'PASS' 'installed' } else { Row 'base' 'Antigravity App' 'FAIL' 'not installed (setup console: install)' }
if (Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue) { Row 'base' 'Codex App' 'PASS' 'installed' } else { Row 'base' 'Codex App' 'FAIL' 'not installed (Microsoft Store: winget install Codex -s msstore)' }
$dm =(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($dm -eq 1) { Row 'base' 'Developer Mode' 'PASS' 'on' } else { Row 'base' 'Developer Mode' 'FAIL' 'off: Settings > System > For developers (UAC), or setup console button' }
# Newer Windows 11 builds store the choice under UserChoiceLatest\ProgId; the old UserChoice key can keep a stale MSEdgeHTM (TCCC03 2026-10-08).
$https = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https'
$pid1 = (Get-ItemProperty "$https\UserChoiceLatest\ProgId" -ErrorAction SilentlyContinue).ProgId
if (-not $pid1) { $pid1 = (Get-ItemProperty "$https\UserChoice" -ErrorAction SilentlyContinue).ProgId }
if ($pid1 -like 'ChromeHTML*') { Row 'base' 'Chrome is default browser' 'PASS' $pid1 } else { Row 'base' 'Chrome is default browser' 'FAIL' "current: $pid1 (Settings > Apps > Default apps > Chrome)" }
$crd ="${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop\CurrentVersion\remoting_host.exe"
if (Test-Path $crd) { Row 'base' 'Chrome Remote Desktop host' 'PASS' $crd } else { Row 'base' 'Chrome Remote Desktop host' 'FAIL' 'remoting_host.exe not found' }
$gd = Get-ChildItem "$env:ProgramFiles\Google\Drive File Stream\*\GoogleDriveFS.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gd) { Row 'base' 'Google Drive for desktop' 'PASS' $gd.FullName } else { Row 'base' 'Google Drive for desktop' 'FAIL' 'GoogleDriveFS.exe not found (bootstrap A4b)' }
$crdSvc = Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue
if ($crdSvc -and $crdSvc.Status -eq 'Running') { Row 'base' 'Remote access enabled (PIN)' 'PASS' 'chromoting service running' } else { Row 'base' 'Remote access enabled (PIN)' 'MANUAL' 'owner enables at remotedesktop.google.com/access' }
# tezhu can only reach a machine when Tailscale is signed in and sshd runs (bootstrap A0/A1).
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) { Row 'base' 'Tailscale signed in' 'FAIL' 'tailscale.exe not found (bootstrap A0)' }
else {
  $tsState = ''; try { $tsState = ((& $ts status --json 2>$null | Out-String) | ConvertFrom-Json).BackendState } catch { }
  if ($tsState -eq 'Running') { Row 'base' 'Tailscale signed in' 'PASS' 'BackendState=Running' } else { Row 'base' 'Tailscale signed in' 'MANUAL' "state=${tsState}; owner signs in from the tray icon" }
}
$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($sshd -and $sshd.Status -eq 'Running' -and $sshd.StartType -eq 'Automatic') { Row 'base' 'OpenSSH server (tezhu)' 'PASS' 'sshd running, automatic' }
elseif ($sshd) { Row 'base' 'OpenSSH server (tezhu)' 'FAIL' "sshd $($sshd.Status)/$($sshd.StartType): re-run bootstrap (admin)" }
else { Row 'base' 'OpenSSH server (tezhu)' 'FAIL' 'sshd not installed: re-run bootstrap (admin)' }
$sshOpt = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue).DefaultShellCommandOption
if ($sshOpt -match 'UTF8Encoding') { Row 'base' 'SSH UTF-8 output' 'PASS' 'DefaultShellCommandOption sets UTF-8' } else { Row 'base' 'SSH UTF-8 output' 'FAIL' 'Chinese output over SSH will be mojibake: re-run bootstrap (admin)' }
$ghOk = $false; try { & 'C:\WORK\TOOLS\gh\bin\gh.exe' auth status *> $null; $ghOk = ($LASTEXITCODE -eq 0) } catch { }
if (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git') { Row 'base' 'AI_AGENT_ULTRA clone' 'PASS' ((git -C 'C:\WORK\AI\AI_AGENT_ULTRA' log -1 --format='%h %cd' --date=short 2>$null) -join '') }
elseif (-not $ghOk) { Row 'base' 'AI_AGENT_ULTRA clone' 'WAIT' 'gh not logged in: setup console > GitHub login > pull AI_AGENT_ULTRA' }
else { Row 'base' 'AI_AGENT_ULTRA clone' 'FAIL' 'C:\WORK\AI\AI_AGENT_ULTRA\.git missing' }
$t = Get-ScheduledTask -TaskName 'AI_AGENT_ULTRA_AutoPull' -ErrorAction SilentlyContinue
if ($t) { Row 'base' 'AutoPull task' 'PASS' $t.State } elseif (-not (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git')) { Row 'base' 'AutoPull task' 'WAIT' 'created after the repo is pulled' } else { Row 'base' 'AutoPull task' 'FAIL' 'task missing' }
if (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git') {
  Push-Location 'C:\WORK\AI\AI_AGENT_ULTRA'; $pw = & node -e "import('playwright').then(()=>console.log('ok')).catch(e=>console.log('fail '+e.message))" 2>&1 | Out-String; Pop-Location
  if ($pw -match '^ok') { Row 'base' 'npm playwright' 'PASS' 'loads from AI_AGENT_ULTRA' } else { Row 'base' 'npm playwright' 'FAIL' ($pw.Trim()) }
}
$ghAcc = ''; try { $ghOut = & 'C:\WORK\TOOLS\gh\bin\gh.exe' auth status 2>&1 | Out-String; if ($LASTEXITCODE -eq 0) { $ghAcc = ([regex]::Matches($ghOut, 'account (\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ',' } } catch { }
if ($ghAcc) { Row 'base' 'gh auth login' 'PASS' "logged in: $ghAcc" } else { Row 'base' 'gh auth login' 'WAIT' 'owner logs in (setup console > GitHub login)' }

if ($Roles -contains 'user' -or $Roles -contains 'dev') {
  Cmd 'user' 'Claude CLI' 'claude' @('--version') "$env:USERPROFILE\.local\bin\*" ''
  Cmd 'user' 'Codex CLI' 'codex' @('--version') "$env:APPDATA\npm\*" ''
  if (Test-Path "$env:LOCALAPPDATA\agy\bin\agy.exe") { Row 'user' 'AGY CLI' 'PASS' "$env:LOCALAPPDATA\agy\bin\agy.exe" } else { Row 'user' 'AGY CLI' 'FAIL' 'agy.exe missing' }
  $svc = Get-CimInstance Win32_Service -Filter "Name='CoworkVMService'" -ErrorAction SilentlyContinue
  if (-not $svc) { Row 'user' 'Claude desktop app' 'MANUAL' 'not installed: official installer + owner login, then tools\setup\disable-claude-cowork-service.cmd' }
  elseif ($svc.StartMode -eq 'Disabled') { Row 'user' 'CoworkVMService disabled' 'PASS' "StartMode=Disabled State=$($svc.State)" }
  else { Row 'user' 'CoworkVMService disabled' 'FAIL' "StartMode=$($svc.StartMode) State=$($svc.State): run tools\setup\disable-claude-cowork-service.cmd (UAC)" }
  if (Test-Path "$env:USERPROFILE\.claude\.credentials.json") { Row 'user' 'Claude seat1 login' 'PASS' 'credentials present (not read)' } else { Row 'user' 'Claude seat1 login' 'WAIT' 'setup console > seat 1 login' }
  if (Test-Path "$env:USERPROFILE\.codex\auth.json") { Row 'user' 'Codex login' 'PASS' 'auth present (not read)' } else { Row 'user' 'Codex login' 'WAIT' 'setup console > Codex login' }
  Row 'user' 'AGY / Antigravity App login' 'MANUAL' 'owner signs in to the Antigravity App'
  # Claude only loads AGENTS.md/CLAUDE.md rules through this one-line import (setup-machine step 'Claude global rules').
  $cm = "$env:USERPROFILE\.claude\CLAUDE.md"
  if ((Test-Path $cm) -and ((Get-Content $cm -Raw) -match '@C:/WORK/AI/AI_AGENT_ULTRA/CLAUDE\.md')) { Row 'user' 'Claude global rules import' 'PASS' $cm } else { Row 'user' 'Claude global rules import' 'FAIL' "$cm lacks @C:/WORK/AI/AI_AGENT_ULTRA/CLAUDE.md (re-run setup-machine)" }
  $cx = "$env:USERPROFILE\.codex\config.toml"
  if ((Test-Path $cx) -and ((Get-Content $cx -Raw) -match '(?m)^\s*model\s*=\s*"gpt-6\.2-sol"')) { Row 'user' 'Codex default model gpt-6.2-sol' 'PASS' $cx } else { Row 'user' 'Codex default model gpt-6.2-sol' 'FAIL' "$cx has no model = `"gpt-6.2-sol`" (re-run setup-machine)" }
}
if ($Roles -contains 'dev') {
  # AutoConverter machines: its installer puts an embedded Python at C:\WORK\TOOLS\python first on PATH on purpose.
  # Accept that when the regular Python 3.12 install is also present (dev tools use it via its full path / py launcher).
  $pyFirst = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  $pyUser = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python312*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pyFirst -and $pyFirst.Source -like 'C:\WORK\TOOLS\python\*' -and $pyUser) {
    $pv = (& $pyUser.FullName --version 2>&1 | Out-String).Trim()
    if ($pv -like 'Python 3.12*') { Row 'dev' 'Python 3.12' 'PASS' "$pv @ $($pyUser.FullName) (AutoConverter embedded Python first on PATH)" }
    else { Row 'dev' 'Python 3.12' 'FAIL' "version '$pv' not like Python 3.12*" }
  } else {
    Cmd 'dev' 'Python 3.12' 'python' @('--version') "$env:LOCALAPPDATA\Programs\Python\Python312*" 'Python 3.12*'
  }
  Cmd 'dev' 'Go 1.27' 'go' @('version') 'C:\WORK\TOOLS\go\*' 'go version go1.27*'
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$rows | ConvertTo-Json | Set-Content -Path (Join-Path $OutDir 'verify-results.json') -Encoding ASCII
$fail = @($rows | Where-Object Status -eq 'FAIL').Count
"PASS=$(@($rows | Where-Object Status -eq 'PASS').Count) FAIL=$fail WAIT=$(@($rows | Where-Object Status -eq 'WAIT').Count) MANUAL=$(@($rows | Where-Object Status -eq 'MANUAL').Count)"
exit $fail
