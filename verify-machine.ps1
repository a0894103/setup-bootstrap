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
Cmd 'base' 'Git' 'git' @('--version') "$env:LOCALAPPDATA\Programs\Git\*" 'git version*'
Cmd 'base' 'Node 24.19.0' 'node' @('--version') 'C:\WORK\TOOLS\nodejs\*' 'v24.19.0'
Cmd 'base' 'gh' 'gh' @('--version') 'C:\WORK\TOOLS\gh\*' 'gh version*'
$chrome = @('C:\Program Files\Google\Chrome\Application\chrome.exe', "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($chrome) { Row 'base' 'Chrome' 'PASS' $chrome } else { Row 'base' 'Chrome' 'FAIL' 'chrome.exe not found' }
$ag = [bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^Antigravity' })
if ($ag) { Row 'base' 'Antigravity App' 'PASS' 'installed' } else { Row 'base' 'Antigravity App' 'FAIL' 'not installed (setup console: install)' }
if (Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue) { Row 'base' 'Codex App' 'PASS' 'installed' } else { Row 'base' 'Codex App' 'FAIL' 'not installed (Microsoft Store: winget install Codex -s msstore)' }$dm = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($dm -eq 1) { Row 'base' 'Developer Mode' 'PASS' 'on' } else { Row 'base' 'Developer Mode' 'FAIL' 'off: Settings > System > For developers (UAC), or setup console button' }$pid1 = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue).ProgId
if ($pid1 -like 'ChromeHTML*') { Row 'base' 'Chrome is default browser' 'PASS' $pid1 } else { Row 'base' 'Chrome is default browser' 'FAIL' "current: $pid1 (Settings > Apps > Default apps > Chrome)" }$crd = "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop\CurrentVersion\remoting_host.exe"
if (Test-Path $crd) { Row 'base' 'Chrome Remote Desktop host' 'PASS' $crd } else { Row 'base' 'Chrome Remote Desktop host' 'FAIL' 'remoting_host.exe not found' }
Row 'base' 'Remote access enabled (PIN)' 'MANUAL' 'owner enables at remotedesktop.google.com/access'$ghOk = $false; try { & 'C:\WORK\TOOLS\gh\bin\gh.exe' auth status *> $null; $ghOk = ($LASTEXITCODE -eq 0) } catch { }
if (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git') { Row 'base' 'AI_AGENT_ULTRA clone' 'PASS' ((git -C 'C:\WORK\AI\AI_AGENT_ULTRA' log -1 --format='%h %cd' --date=short 2>$null) -join '') }
elseif (-not $ghOk) { Row 'base' 'AI_AGENT_ULTRA clone' 'WAIT' 'gh not logged in: setup console > GitHub login > pull AI_AGENT_ULTRA' }
else { Row 'base' 'AI_AGENT_ULTRA clone' 'FAIL' 'C:\WORK\AI\AI_AGENT_ULTRA\.git missing' }
$t = Get-ScheduledTask -TaskName 'AI_AGENT_ULTRA_AutoPull' -ErrorAction SilentlyContinue
if ($t) { Row 'base' 'AutoPull task' 'PASS' $t.State } elseif (-not (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git')) { Row 'base' 'AutoPull task' 'WAIT' 'created after the repo is pulled' } else { Row 'base' 'AutoPull task' 'FAIL' 'task missing' }if (Test-Path 'C:\WORK\AI\AI_AGENT_ULTRA\.git') {
  Push-Location 'C:\WORK\AI\AI_AGENT_ULTRA'; $pw = & node -e "import('playwright').then(()=>console.log('ok')).catch(e=>console.log('fail '+e.message))" 2>&1 | Out-String; Pop-Location
  if ($pw -match '^ok') { Row 'base' 'npm playwright' 'PASS' 'loads from AI_AGENT_ULTRA' } else { Row 'base' 'npm playwright' 'FAIL' ($pw.Trim()) }
}$ghAcc = ''; try { $ghOut = & 'C:\WORK\TOOLS\gh\bin\gh.exe' auth status 2>&1 | Out-String; if ($LASTEXITCODE -eq 0) { $ghAcc = ([regex]::Matches($ghOut, 'account (\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ',' } } catch { }
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
}
if ($Roles -contains 'dev') {
  Cmd 'dev' 'Python 3.12' 'python' @('--version') "$env:LOCALAPPDATA\Programs\Python\Python312*" 'Python 3.12*'
  Cmd 'dev' 'Go 1.27' 'go' @('version') 'C:\WORK\TOOLS\go\*' 'go version go1.27*'
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$rows | ConvertTo-Json | Set-Content -Path (Join-Path $OutDir 'verify-results.json') -Encoding ASCII
$fail = @($rows | Where-Object Status -eq 'FAIL').Count
"PASS=$(@($rows | Where-Object Status -eq 'PASS').Count) FAIL=$fail WAIT=$(@($rows | Where-Object Status -eq 'WAIT').Count) MANUAL=$(@($rows | Where-Object Status -eq 'MANUAL').Count)"
exit $fail
