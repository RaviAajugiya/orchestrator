# install.ps1 - install / upgrade rc-spawn into one Claude profile (a separate CLAUDE_CONFIG_DIR, e.g. ~/.claude-work). Idempotent.
param(
    [Parameter(Mandatory = $true)][string]$HomeProfileDir,
    [string]$HomeProfileName,
    [string]$RcRoot,
    [string]$ClaudePath,
    [string[]]$ClaudePrefixArgs = @(),
    [switch]$NoTasks, [switch]$NoPath, [switch]$NoStart, [switch]$NoSkill
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
$utf8 = New-Object Text.UTF8Encoding $false
function Say([string]$m) { Write-Host "[install] $m" }

# ---- preflight
$HomeProfileDir = [IO.Path]::GetFullPath($HomeProfileDir).TrimEnd('\')
if ($HomeProfileDir -ieq (Join-Path $env:USERPROFILE '.claude')) { throw 'refusing to install into the default ~/.claude profile' }
if (-not (Test-Path -LiteralPath (Join-Path $HomeProfileDir 'settings.json'))) { throw "$HomeProfileDir does not look like a Claude profile (no settings.json)" }
if (-not $RcRoot) { $RcRoot = Join-Path $HomeProfileDir 'rc' }
if (-not $HomeProfileName) { $HomeProfileName = (Split-Path -Leaf $HomeProfileDir) -replace '^\.?claude-?', '' }
if ($HomeProfileName -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') { throw "bad profile name '$HomeProfileName'; pass -HomeProfileName (lowercase letters, digits, - or _)" }
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { throw 'node.exe not found on PATH' }
if (-not $ClaudePath) {
    $cands = @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'))
    $ClaudePath = $cands | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $ClaudePath) { throw 'claude.exe not found' }
}
Say "profile:  $HomeProfileDir"
Say "rc root:  $RcRoot"
Say "claude:   $ClaudePath"
Say "node:     $node"

# ---- copy code (config/state/logs are kept)
foreach ($d in @('bin', 'lib', 'hooks', 'orchestrator', 'config', 'state', 'state\run', 'state\pending', 'logs', 'audit')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $RcRoot $d) | Out-Null
}
foreach ($d in @('bin', 'lib', 'hooks', 'orchestrator')) {
    Copy-Item -Path (Join-Path $src "$d\*") -Destination (Join-Path $RcRoot $d) -Recurse -Force
}
# Git Bash shim (LF only)
$sh = "#!/bin/sh`nexec powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"`$(cygpath -w `"`$(dirname `"`$0`")/../lib/rc-spawn.ps1`")`" `"`$@`"`n"
[IO.File]::WriteAllText((Join-Path $RcRoot 'bin\rc-spawn'), $sh, $utf8)
$fwd = $RcRoot.Replace('\', '/')
$os = Join-Path $RcRoot 'orchestrator\.claude\settings.json'
[IO.File]::WriteAllText($os, ([IO.File]::ReadAllText($os).Replace('__RC_ROOT_FWD__', $fwd)), $utf8)
Say 'code copied'

# ---- config (only created when missing)
$cfgF = Join-Path $RcRoot 'config\rc.config.json'
$t = [IO.File]::ReadAllText((Join-Path $src 'defaults\rc.config.json'))
$t = $t.Replace('"__CLAUDE__"', (ConvertTo-Json $ClaudePath)).Replace('"__NODE__"', (ConvertTo-Json $node)).Replace('"__SOURCE__"', (ConvertTo-Json $PSScriptRoot.TrimEnd('\')))
$newCfg = ConvertFrom-Json $t
$newCfg.claudePrefixArgs = @($ClaudePrefixArgs)
if (Test-Path -LiteralPath $cfgF) {
    $old = ConvertFrom-Json ([IO.File]::ReadAllText($cfgF))
    $old.claudePath = $ClaudePath; $old.nodePath = $node; $old.sourceDir = $PSScriptRoot.TrimEnd('\'); $old.claudePrefixArgs = @($ClaudePrefixArgs)
    foreach ($p in $newCfg.PSObject.Properties) { if (-not $old.PSObject.Properties[$p.Name]) { $old | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value } }
    $newCfg = $old
}
[IO.File]::WriteAllText($cfgF, (ConvertTo-Json $newCfg -Depth 10), $utf8)

$profF = Join-Path $RcRoot 'config\profiles.json'
if (-not (Test-Path -LiteralPath $profF)) {
    $p = [ordered]@{ schemaVersion = 1; default = $HomeProfileName; profiles = [ordered]@{} }
    $p.profiles[$HomeProfileName] = [ordered]@{ configDir = $HomeProfileDir; envMode = 'set'; globalConfigFile = (Join-Path $HomeProfileDir '.claude.json'); allowFromPhone = $true; registeredAt = (Get-Date).ToUniversalTime().ToString('o'); home = $true }
    [IO.File]::WriteAllText($profF, (ConvertTo-Json $p -Depth 6), $utf8)
}
$notF = Join-Path $RcRoot 'config\notify.json'
if (-not (Test-Path -LiteralPath $notF)) {
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider; $b = New-Object byte[] 16; $rng.GetBytes($b)
    $alpha = 'abcdefghijklmnopqrstuvwxyz234567'; $topic = 'rc-' + (-join ($b | ForEach-Object { $alpha[$_ % 32] }))
    $n = [ordered]@{ schemaVersion = 1; enabled = $false; server = 'https://ntfy.sh'; topic = $topic; token = $null }
    [IO.File]::WriteAllText($notF, (ConvertTo-Json $n), $utf8)
}
foreach ($pair in @(@('config\denylist.user.json', '{"schemaVersion":1,"entries":[]}'), @('config\aliases.json', '{"schemaVersion":1,"aliases":{}}'),
        @('config\approved-project-configs.json', '{"schemaVersion":1,"approvals":{}}'), @('state\servers.json', '{"schemaVersion":1,"servers":{}}'))) {
    $f = Join-Path $RcRoot $pair[0]
    if (-not (Test-Path -LiteralPath $f)) { [IO.File]::WriteAllText($f, $pair[1], $utf8) }
}
Say 'config ready'

# ---- orchestrator entry + trust
Import-Module (Join-Path $RcRoot 'lib\RcCore.psm1') -Force -DisableNameChecking
$orchId = "$HomeProfileName/Orchestrator"
Invoke-RcLocked 'state' {
    $s = Get-RcServers
    $s.servers[$orchId] = [ordered]@{ profile = $HomeProfileName; name = 'Orchestrator'; displayName = 'Orchestrator'; path = (Join-Path $RcRoot 'orchestrator')
        spawn = 'same-dir'; capacity = 2; permissionMode = 'default'; enabled = $true; orchestrator = $true; createdAt = (Get-RcTimestamp); createdBy = 'install' }
    Save-RcServers $s
}
Set-RcTrust (Get-RcProfile $HomeProfileName) (Join-Path $RcRoot 'orchestrator')
Say 'orchestrator registered and trusted'

# ---- skill
if (-not $NoSkill) {
    $sd = Join-Path $HomeProfileDir 'skills\rc-spawn'
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    Copy-Item (Join-Path $src 'skills\rc-spawn\SKILL.md') $sd -Force
    Say "skill installed: $sd"
}

# ---- PATH (HKCU, keep REG_EXPAND_SZ)
$bin = Join-Path $RcRoot 'bin'
if (-not $NoPath) {
    $k = Get-Item 'HKCU:\Environment'
    $cur = $k.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    if (-not (($cur -split ';') -contains $bin)) {
        $new = $(if ($cur) { $cur.TrimEnd(';') + ';' + $bin } else { $bin })
        Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $new -Type ExpandString
        Add-Type -Namespace RcWin -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);' -ErrorAction SilentlyContinue
        $r = [UIntPtr]::Zero; [void][RcWin.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$r)
        Say "added to user PATH: $bin (open a new terminal)"
    } else { Say 'PATH already contains rc\bin' }
}

# ---- start at logon
$startAll = Join-Path $RcRoot 'bin\start-all.ps1'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startAll`" -Watch"
$mode = 'none'
if (-not $NoTasks) {
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs -WorkingDirectory $RcRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $trigger.Delay = 'PT30S'
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskPath '\rc-spawn\' -TaskName 'StartAll' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        $mode = 'task'
        Say 'logon task \rc-spawn\StartAll registered'
    } catch {
        Say "task registration failed ($($_.Exception.Message)); using Startup folder shortcut"
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'rc-spawn-start-all.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk); $sc.TargetPath = 'powershell.exe'; $sc.Arguments = $psArgs; $sc.WorkingDirectory = $RcRoot; $sc.WindowStyle = 7; $sc.Save()
        $mode = 'startup-lnk'
    }
}

# ---- manifest
$mf = [ordered]@{ version = '1.0.0'; installedAt = (Get-RcTimestamp); rcRoot = $RcRoot; homeProfileDir = $HomeProfileDir; pathAdded = (-not $NoPath); startMode = $mode; skill = (-not $NoSkill) }
Write-RcJson (Join-Path $RcRoot 'config\install-manifest.json') $mf

# ---- start now
if (-not $NoStart) {
    $w = Read-RcJson (Join-Path $RcRoot 'state\run\watchdog.json') $null
    if ($w -and (Test-RcProcAlive $w.pid $w.start)) {
        Say 'watchdog already running; restarting the Orchestrator to load new files'
        [void](Stop-RcServerProcess $orchId 10)
        [void](Start-RcSupervisor $orchId)
    } else {
        [void](Start-RcDetached ("powershell.exe $psArgs") $RcRoot)
        Say 'watchdog started (hidden); the Orchestrator comes up in ~10-30 s'
    }
}
$topic = (Read-RcJson $notF $null).topic
Say ''
Say 'NEXT STEPS'
Say '  1. Phone: Claude app > Code tab > DESKTOP > Orchestrator > say "list"'
Say '  2. New terminal: rc-spawn doctor'
Say '  3. Other profiles (optional, at the PC): rc-spawn profiles add <name> <path to .claude-xxx folder> --allow-from-phone'
