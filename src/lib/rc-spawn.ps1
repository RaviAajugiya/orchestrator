# rc-spawn.ps1 - control Claude Code Remote Control servers (phone-friendly). Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
Import-Module (Join-Path $PSScriptRoot 'RcCore.psm1') -Force -DisableNameChecking
$RawArgs = @($args)

$script:ExitCode = 0
$script:Result = 'ok'
$script:Cmd = ''
function Out([string]$s) { [Console]::Out.WriteLine((Protect-RcText $s)) }
function Finish([string]$Kind, [string]$Summary, [int]$Code) {
    Out ("RESULT: $Kind $Summary")
    Write-RcAudit 'cli' $script:Cmd $RawArgs $Kind $Code $Summary
    exit $Code
}
function Refuse([string]$m) { Finish 'refused' $m 2 }
function Fail([string]$m, [int]$c = 5) { Finish 'error' $m $c }

# ---------------------------------------------------------------- argument parsing
$Spec = @{
    'start'    = @{ values = @('--profile', '--name', '--spawn', '--capacity', '--permission-mode'); flags = @('--create', '--yes') }
    'stop'     = @{ values = @('--profile'); flags = @('--all', '--yes') }
    'restart'  = @{ values = @('--profile'); flags = @() }
    'remove'   = @{ values = @('--profile'); flags = @() }
    'mode'     = @{ values = @('--profile'); flags = @() }
    'status'   = @{ values = @('--profile'); flags = @('--json') }
    'logs'     = @{ values = @('--profile', '-n'); flags = @('--debug') }
    'list'     = @{ values = @('--profile'); flags = @('--all', '--json') }
    'recent'   = @{ values = @('-n'); flags = @() }
    'find'     = @{ values = @('--depth', '--limit', '--drive'); flags = @() }
    'alias'    = @{ values = @(); flags = @() }
    'denylist' = @{ values = @(); flags = @('--yes') }
    'approve'  = @{ values = @(); flags = @('--yes') }
    'profiles' = @{ values = @('--global-config', '--env-mode'); flags = @('--allow-from-phone', '--i-understand-default-profile', '--json') }
    'trust'    = @{ values = @('--profile'); flags = @() }
    'health'   = @{ values = @(); flags = @() }
    'doctor'   = @{ values = @(); flags = @('--send-test') }
    'notify'   = @{ values = @(); flags = @() }
    'lockdown' = @{ values = @(); flags = @('--yes') }
    'unlock'   = @{ values = @(); flags = @() }
    'reboot'   = @{ values = @('--in'); flags = @('--cancel', '--yes') }
    'update'   = @{ values = @(); flags = @() }
    'help'     = @{ values = @(); flags = @() }
    'audit'    = @{ values = @('-n'); flags = @() }
    'history'  = @{ values = @('--profile', '-n', '--folder', '--search'); flags = @() }
    'resume'   = @{ values = @('--profile', '--name'); flags = @('--yes') }
    'sessions' = @{ values = @('--profile'); flags = @() }
    'end'      = @{ values = @('--profile'); flags = @() }
}

if ($RawArgs.Count -eq 0) { $RawArgs = @('help') }
$script:Cmd = ([string]$RawArgs[0]).ToLowerInvariant()
if (-not $Spec.ContainsKey($script:Cmd)) { Finish 'error' "unknown command '$($RawArgs[0])'. Try: rc-spawn help" 1 }
$Pos = New-Object System.Collections.ArrayList
$Opt = @{}
$sp = $Spec[$script:Cmd]
foreach ($a0 in $RawArgs) {
    if ([string]$a0 -match '(?i)dangerously|bypassPermissions') { Refuse 'bypass / dangerous modes are never allowed' }
    if ([string]$a0 -match '[\x00-\x1f]') { Finish 'error' 'control characters in arguments' 1 }
}
for ($i = 1; $i -lt $RawArgs.Count; $i++) {
    $a = [string]$RawArgs[$i]
    if ($a.StartsWith('-') -and $a.Length -gt 1 -and -not ($a -match '^-\d+$')) {
        $k = $a.ToLowerInvariant()
        if ($Opt.ContainsKey($k)) { Finish 'error' "duplicate option $a" 1 }
        if ($sp.values -contains $k) {
            if ($i + 1 -ge $RawArgs.Count) { Finish 'error' "option $a needs a value" 1 }
            $i++; $Opt[$k] = [string]$RawArgs[$i]
        } elseif ($sp.flags -contains $k) { $Opt[$k] = $true }
        else { Finish 'error' "unknown option $a for $script:Cmd" 1 }
    } else { [void]$Pos.Add($a) }
}
function O([string]$k) { if ($Opt.ContainsKey($k)) { return $Opt[$k] }; return $null }
$Caller = Get-RcCaller
$cfg = Get-RcConfig
$Profiles = Get-RcProfiles
$HomeName = $Profiles.default

if ((O '--profile') -and -not ((O '--profile') -match '^[a-z][a-z0-9-]{0,19}$')) { Finish 'error' 'bad profile name' 1 }
if ((O '--name') -and -not ((O '--name') -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$')) { Finish 'error' 'bad name (letters, digits, . _ - ; max 40)' 1 }

function Require-Local([string]$what) {
    if ($Caller.phoneDriven) { Refuse "$what is local only: run it in a normal PowerShell window at the PC" }
    $ans = Read-Host "Type YES to confirm $what"
    if ($ans -cne 'YES') { Refuse 'not confirmed' }
}

function Need-Code([string]$Action, [string]$ArgsText) {
    # Risky actions: local console runs them directly. From the phone, the Orchestrator must first ask the
    # user in the chat and only then re-run the identical command with --yes. Other sessions are refused.
    if (-not $Caller.phoneDriven) { return }
    $orchId = "$HomeName/Orchestrator"
    if ($Caller.rcSpawnId -ne $orchId) { Refuse "$Action from a session is only allowed via the Orchestrator (or at the PC)" }
    if (-not (O '--yes')) { Finish 'need-confirm' "ask the user to confirm '$Action $ArgsText' in the chat; if they say yes, re-run the same command with --yes" 7 }
}

# ---------------------------------------------------------------- server lookup
function Find-RcIds([string]$Target) {
    $s = Get-RcServers
    $t = $Target.ToLowerInvariant()
    $p = O '--profile'
    if ($t -eq 'orchestrator') { return @("$HomeName/Orchestrator") }
    if ($Target.Contains('/')) { if ($s.servers.Contains($Target)) { return @($Target) }; return @() }
    $hits = @($s.servers.Keys | Where-Object {
            $e = $s.servers[$_]
            ($e.name.ToLowerInvariant() -eq $t) -and ((-not $p) -or $e.profile -eq $p) -and -not ($e.Contains('orchestrator') -and $e.orchestrator)
        })
    if ($hits.Count -eq 0) {
        # maybe a path
        try {
            $n = ConvertTo-RcInputPath $Target
            if ($n) {
                $real = $n; try { $real = Get-RcRealCase $n } catch {}
                $hits = @($s.servers.Keys | Where-Object { $s.servers[$_].path -ieq $real -and ((-not $p) -or $s.servers[$_].profile -eq $p) })
            }
        } catch {}
    }
    return $hits
}
function Get-OneId([string]$Target) {
    if (-not $Target) { Finish 'error' 'which server? give a name, id (profile/name) or path' 1 }
    $ids = @(Find-RcIds $Target)
    if ($ids.Count -eq 0) { Finish 'error' "no server '$Target'. See: rc-spawn list --all" 3 }
    if ($ids.Count -gt 1) { Finish 'error' ("'$Target' is ambiguous: " + ($ids -join ', ') + '. Add --profile.') 4 }
    return $ids[0]
}
function Test-IsOrch([string]$Id) { $s = Get-RcServers; return ($s.servers.Contains($Id) -and $s.servers[$Id].Contains('orchestrator') -and $s.servers[$Id].orchestrator) }

function Format-Age([string]$iso) {
    if (-not $iso) { return '-' }
    try { $d = (Get-Date) - [datetime]::Parse($iso) } catch { return '-' }
    if ($d.TotalHours -ge 24) { return ('{0}d{1}h' -f [int][Math]::Floor($d.TotalDays), $d.Hours) }
    if ($d.TotalMinutes -ge 60) { return ('{0}h{1}m' -f [int][Math]::Floor($d.TotalHours), $d.Minutes) }
    return ('{0}m' -f [int][Math]::Floor($d.TotalMinutes))
}

function Wait-Running([string]$Id) {
    $deadline = (Get-Date).AddSeconds([int]$cfg.startWaitSec)
    $seenAt = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $r = Get-RcRun $Id
        if ($r -and $r.state -eq 'RUNNING' -and (Test-RcProcAlive $r.claudePid $r.claudeStart)) {
            if (-not $seenAt) { $seenAt = Get-Date }
            if (((Get-Date) - $seenAt).TotalSeconds -ge [int]$cfg.runningAfterSec) { return 'RUNNING' }
        } elseif ($r -and $r.state -in @('REFUSED', 'GAVE_UP', 'AUTH_FAIL', 'BACKOFF')) { if ($seenAt -or $r.state -ne 'BACKOFF') { return $r.state } }
    }
    $r = Get-RcRun $Id
    if ($r) { return $r.state }
    return 'STARTING'
}

function Add-Recent([string]$Path, [string]$Prof) {
    Invoke-RcLocked 'state' {
        $f = Get-RcFile 'state\recent.json'
        $r = Read-RcJson $f ([ordered]@{ items = @() })
        $list = New-Object System.Collections.ArrayList
        [void]$list.Add([ordered]@{ path = $Path; profile = $Prof; at = Get-RcTimestamp })
        foreach ($it in $r.items) { if (-not ($it.path -ieq $Path -and $it.profile -eq $Prof) -and $list.Count -lt 50) { [void]$list.Add($it) } }
        $r.items = $list
        Write-RcJson $f $r
    }
}


function Remove-RcEntry([string]$Id) {
    # After a clean stop the folder stays listed on the phone as "offline". Unregister it for good
    # (reattach with a read-only resume pointer, then clean stop => Claude archives + deletes the entry).
    $e = (Get-RcServers).servers[$Id]
    $prof = Get-RcProfile $e.profile
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Get-RcFile 'bin\rc-cleanup.ps1') + '" -Folders "' + $e.path + '" -ConfigDir "' + $prof.configDir + '" -Log "' + (Get-RcFile 'logs\cleanup.log') + '"'
    [void](Start-RcDetached $cmd (Get-RcRoot) 0)
}

# ---------------------------------------------------------------- past chats (history / resume)
function Get-HistProfileNames {
    $want = O '--profile'
    $names = @($Profiles.profiles.Keys | Where-Object { (-not $want) -or $_ -eq $want })
    if ($want -and -not $names.Count) { Refuse "profile '$want' is not registered" }
    if ($Caller.phoneDriven) { $names = @($names | Where-Object { $_ -eq $HomeName -or (Get-RcProfile $_).allowFromPhone }) }
    return $names
}

function Get-BgSessions([string[]]$Names) {
    # `claude agents --json` per profile; each item tagged with its profile
    $saved = @{}; Get-ChildItem Env: | ForEach-Object { $saved[$_.Name] = $_.Value }
    $out = New-Object System.Collections.ArrayList
    foreach ($pn in $Names) {
        try {
            Set-RcProfileEnv (Get-RcProfile $pn)
            $j = (Invoke-RcClaude @('agents', '--json') 2>$null | Out-String)
            $arr = ConvertFrom-Json $j   # PS 5.1 emits a JSON array as ONE object; foreach unrolls it
            foreach ($a in $arr) { $a | Add-Member -NotePropertyName profile -NotePropertyValue $pn -Force; [void]$out.Add($a) }
        } catch {}
    }
    Get-ChildItem Env: | Where-Object { -not $saved.ContainsKey($_.Name) } | ForEach-Object { Remove-Item ("Env:" + $_.Name) }
    foreach ($k in $saved.Keys) { Set-Item ("Env:" + $k) $saved[$k] }
    return @($out)
}

function Get-HistMeta([string]$File) {
    # title: custom-title > agent-name > ai-title > last prompt > first prompt; cwd: first line that has one.
    # No prompt at all (scripted/empty runs) => hasPrompt = $false and history skips it.
    $m = @{ cwd = $null; custom = $null; agent = $null; ai = $null; lastPrompt = $null; first = $null }
    foreach ($line in [IO.File]::ReadLines($File)) {
        if (-not $m.cwd -and $line -match '"cwd":"((?:[^"\\]|\\.)*)"') { $m.cwd = ConvertFrom-Json ('"' + $Matches[1] + '"') }
        if (-not $m.first -and $line.StartsWith('{"type":"user"') -and $line -notmatch '"isMeta":true' -and $line -match '"content":"((?:[^"\\]|\\.){1,300})') {
            $c = $Matches[1]; if ($c.Length -gt 0 -and -not $c.StartsWith('<')) { try { $m.first = ConvertFrom-Json ('"' + ($c -replace '\\$', '') + '"') } catch {} }
        }
        if ($line.StartsWith('{"type":"custom-title"')) { $m.custom = (ConvertFrom-Json $line).customTitle }
        elseif ($line.StartsWith('{"type":"agent-name"')) { $m.agent = (ConvertFrom-Json $line).agentName }
        elseif ($line.StartsWith('{"type":"ai-title"')) { $m.ai = (ConvertFrom-Json $line).aiTitle }
        elseif ($line.StartsWith('{"type":"last-prompt"')) { $m.lastPrompt = (ConvertFrom-Json $line).lastPrompt }
    }
    $t = @($m.custom, $m.agent, $m.ai, $m.lastPrompt, $m.first) | Where-Object { $_ } | Select-Object -First 1
    $hasPrompt = [bool]($m.lastPrompt -or $m.first)
    if (-not $t) { $t = '(untitled)' }
    $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt 70) { $t = $t.Substring(0, 70) + '...' }
    return @{ cwd = $m.cwd; title = $t; lastPrompt = [string]$m.lastPrompt; hasPrompt = $hasPrompt }
}

function Find-HistEntry([string]$T) {
    if ($T -match '^\d{1,2}$') {
        $last = Read-RcJson (Get-RcFile 'state\history-last.json') $null
        if (-not $last) { return $null }
        return (@($last.items) | Where-Object { [int]$_.n -eq [int]$T } | Select-Object -First 1)
    }
    if ($T -notmatch '^[0-9a-fA-F-]{8,36}$') { return $null }
    foreach ($pn in @(Get-HistProfileNames)) {
        $proj = Join-Path (Get-RcProfile $pn).configDir 'projects'
        $f = Get-ChildItem -LiteralPath $proj -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter "$T*.jsonl" } | Select-Object -First 1
        if ($f) { $m = Get-HistMeta $f.FullName; return @{ profile = $pn; sessionId = $f.BaseName; cwd = $m.cwd; title = $m.title } }
    }
    return $null
}

# ---------------------------------------------------------------- commands
switch ($script:Cmd) {

'help' {
    Out @'
rc-spawn - phone control of Claude Code Remote Control servers
  start <folder|name|alias> [--profile P] [--name N] [--spawn same-dir|worktree] [--capacity C]
        [--permission-mode default|plan|acceptEdits|auto] [--create]
  stop <name> | stop --all           restart <name|orchestrator>      remove <name>
  list [--all] [--profile P]         status <name>                     logs <name> [-n 40] [--debug]
  mode <name> <mode>                 recent [-n 10]                    find <query> [--depth 3]
  history [--profile P] [-n 15] [--folder F] [--search X]     resume <n|session-id> [--name N]
  sessions [--profile P]             end <n|id>   (past chats: continue on the phone / stop; history kept)
  alias list|add <name> <path>|remove <name>
  denylist list|add <path>|remove <path>          approve <folder>  (project hooks/MCP)
  profiles list | add <name> <dir> (local) | remove <name> (local)
  trust list                         health        doctor             audit [-n 30]
  lockdown      unlock (local)     reboot [--in 60] | reboot --cancel
  update                             help
'@
    Finish 'ok' 'help' 0
}

'list' {
    $s = Get-RcServers
    $rows = @()
    foreach ($id in $s.servers.Keys) {
        $e = $s.servers[$id]
        if ((O '--profile') -and $e.profile -ne (O '--profile')) { continue }
        $st = Get-RcState $id
        if (-not (O '--all') -and $st -eq 'STOPPED' -and -not ($e.Contains('orchestrator') -and $e.orchestrator)) { continue }
        $r = Get-RcRun $id
        $up = '-'; $rs = 0
        if ($r) { if ($st -eq 'RUNNING') { $up = Format-Age $r.startedAt }; $rs = $r.restarts }
        $rows += [pscustomobject]@{ ID = $id; STATE = $st; UP = $up; RESTARTS = $rs; MODE = $e.permissionMode; CAP = $e.capacity; PATH = $e.path }
    }
    if (O '--json') { Out (ConvertTo-Json -InputObject @($rows) -Depth 4) }
    elseif ($rows.Count -eq 0) { Out 'no servers running (use --all to include stopped ones)' }
    else { Out (($rows | Format-Table -AutoSize | Out-String -Width 250).TrimEnd()) }
    Finish 'ok' "$($rows.Count) server(s)" 0
}

'status' {
    $id = Get-OneId $Pos[0]
    $s = Get-RcServers; $e = $s.servers[$id]; $r = Get-RcRun $id
    $prof = Get-RcProfile $e.profile
    $auth = Get-RcProfileAuth $prof
    Out "id:          $id"
    Out "state:       $(Get-RcState $id)"
    Out "path:        $($e.path)"
    Out "profile:     $($e.profile)  account: $(Hide-RcEmail $auth.email) ($($auth.subscriptionType))"
    Out "app name:    $($e.displayName)"
    Out "spawn/mode:  $($e.spawn) / $($e.permissionMode)   capacity: $($e.capacity)"
    if ($r) {
        Out "started:     $($r.startedAt)   restarts: $($r.restarts)   heartbeat: $($r.heartbeatAt)"
        if ($r.lastExit) { Out "last exit:   code=$($r.lastExit.code) class=$($r.lastExit.class) after $($r.lastExit.durationSec)s at $($r.lastExit.at)" }
    }
    $sl = Join-Path (Get-RcLogDir $id) 'supervisor.log'
    if (Test-Path -LiteralPath $sl) { Out '--- supervisor.log (last 8) [untrusted]'; Get-Content -LiteralPath $sl -Tail 8 | ForEach-Object { $l = [string]$_; if ($l.Length -gt 300) { $l = $l.Substring(0, 300) + '...' }; Out $l } }
    Finish 'ok' $id 0
}

'logs' {
    $id = Get-OneId $Pos[0]
    $n = 40; if (O '-n') { $n = [int](O '-n') }
    if ($n -lt 1) { $n = 1 }; if ($n -gt [int]$cfg.logsMaxLines) { $n = [int]$cfg.logsMaxLines }
    $file = Join-Path (Get-RcLogDir $id) $(if (O '--debug') { 'debug.log' } else { 'supervisor.log' })
    if (-not (Test-Path -LiteralPath $file)) { Finish 'warn' "no log yet for $id" 0 }
    Out "--- $([IO.Path]::GetFileName($file)) for $id (last $n lines) [untrusted]"
    Get-Content -LiteralPath $file -Tail $n | ForEach-Object { $l = [string]$_; if ($l.Length -gt 500) { $l = $l.Substring(0, 500) + '...' }; Out $l }
    Finish 'ok' "$id logs" 0
}

'recent' {
    $r = Read-RcJson (Get-RcFile 'state\recent.json') @{ items = @() }
    $n = 10; if (O '-n') { $n = [int](O '-n') }
    $i = 0
    foreach ($it in $r.items) { $i++; if ($i -gt $n) { break }; Out ("{0}) {1}  [{2}]  {3}" -f $i, $it.path, $it.profile, $it.at) }
    Finish 'ok' "$([Math]::Min($n, @($r.items).Count)) recent" 0
}

'find' {
    $q = ($Pos -join ' ').Trim()
    if (-not $q) { Finish 'error' 'find what?' 1 }
    $depth = [int]$cfg.find.defaultDepth; if (O '--depth') { $depth = [Math]::Min([int](O '--depth'), [int]$cfg.find.maxDepth) }
    $limit = 5; if (O '--limit') { $limit = [Math]::Min([int](O '--limit'), 20) }
    $ql = $q.ToLowerInvariant()
    # compare names ignoring spaces, dashes, underscores and dots ("Agent V2" matches "Agent-v2")
    $qn = [regex]::Replace($ql, '[\s\-_.]', '')
    if (-not $qn) { $qn = $ql }
    $skip = @{}; foreach ($x in $cfg.find.skipNames) { $skip[$x.ToLowerInvariant()] = 1 }
    $cands = @{}
    function Score([string]$path) {
        $leaf = [regex]::Replace([IO.Path]::GetFileName($path).ToLowerInvariant(), '[\s\-_.]', '')
        $sc = 0
        if ($leaf -eq $qn) { $sc = 100 } elseif ($leaf.StartsWith($qn)) { $sc = 80 } elseif ($leaf.Contains($qn)) { $sc = 60 } else { return 0 }
        if (Test-Path -LiteralPath (Join-Path $path '.git')) { $sc += 15 }
        return $sc
    }
    # known servers, aliases, recent
    $s = Get-RcServers
    foreach ($id in $s.servers.Keys) { $e = $s.servers[$id]; if ($e.Contains('orchestrator') -and $e.orchestrator) { continue }; $sc = Score $e.path; if ($e.name.ToLowerInvariant() -eq $ql) { $sc = [Math]::Max($sc, 100) }; if ($sc -gt 0) { $cands[$e.path] = $sc + 10 } }
    $al = Read-RcJson (Get-RcFile 'config\aliases.json') @{ aliases = @{} }
    foreach ($k in $al.aliases.Keys) { if ([regex]::Replace($k.ToLowerInvariant(), '[\s\-_.]', '') -eq $qn) { $cands[$al.aliases[$k]] = 130 } }
    $rec = Read-RcJson (Get-RcFile 'state\recent.json') @{ items = @() }
    foreach ($it in $rec.items) { $sc = Score $it.path; if ($sc -gt 0) { $cands[$it.path] = [Math]::Max($sc + 10, $(if ($cands.ContainsKey($it.path)) { $cands[$it.path] } else { 0 })) } }
    # bounded BFS over fixed drives
    $sens = @(Get-RcSensitive | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() })
    $sw = [Diagnostics.Stopwatch]::StartNew(); $visited = 0; $partial = $false
    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
    if (O '--drive') { $drives = @($drives | Where-Object { $_.StartsWith((O '--drive').Substring(0, 1).ToUpper()) }) }
    $queue = New-Object System.Collections.Queue
    foreach ($d in $drives) { $queue.Enqueue(@($d, 0)) }
    $uroot = (Join-Path $env:SystemDrive 'Users').ToLowerInvariant()
    while ($queue.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt [int]$cfg.find.timeoutSec -or $visited -gt [int]$cfg.find.maxDirs) { $partial = $true; break }
        $item = $queue.Dequeue(); $dir = $item[0]; $lvl = $item[1]
        $subs = @()
        try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($sd in $subs) {
            $visited++
            $leaf = [IO.Path]::GetFileName($sd)
            $ll = $leaf.ToLowerInvariant()
            if ($skip.ContainsKey($ll) -or $ll.StartsWith('$') -or $ll -eq 'system volume information') { continue }
            $sl = $sd.ToLowerInvariant()
            if ($sens -contains $sl) { continue }
            if ($sl.StartsWith($uroot + '\') -and -not ($sl -eq $env:USERPROFILE.ToLowerInvariant() -or $sl.StartsWith($env:USERPROFILE.ToLowerInvariant() + '\'))) { continue }
            try { $attr = [IO.File]::GetAttributes($sd) } catch { continue }
            if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (($attr -band [IO.FileAttributes]::Hidden) -ne 0 -and ($attr -band [IO.FileAttributes]::System) -ne 0) { continue }
            if ([regex]::Replace($ll, '[\s\-_.]', '').Contains($qn)) { $sc = Score $sd; if ($sc -gt 0 -and -not (Get-RcPolicyReason $sd)) { $cands[$sd] = [Math]::Max($sc + (5 - [Math]::Min($lvl, 5)), $(if ($cands.ContainsKey($sd)) { $cands[$sd] } else { 0 })) } }
            if ($lvl + 1 -lt $depth) { $queue.Enqueue(@($sd, $lvl + 1)) }
        }
    }
    $top = @($cands.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Name' } | Select-Object -First $limit)
    if ($top.Count -eq 0) { Finish 'warn' ("no folder matching '$q'" + $(if ($partial) { ' (partial search: try --depth or a full path)' } else { '' })) 3 }
    $i = 0
    foreach ($t in $top) { $i++; $git = ''; if (Test-Path -LiteralPath (Join-Path $t.Name '.git')) { $git = ' [git]' }; Out ("{0}) {1}{2}  score {3}" -f $i, $t.Name, $git, $t.Value) }
    if ($partial) { Out '(partial search: time or folder budget reached)' }
    Finish 'ok' "$($top.Count) match(es)" 0
}

'alias' {
    $f = Get-RcFile 'config\aliases.json'
    $al = Read-RcJson $f ([ordered]@{ schemaVersion = 1; aliases = [ordered]@{} })
    $sub = $(if ($Pos.Count) { $Pos[0] } else { 'list' })
    if ($sub -eq 'list') { foreach ($k in $al.aliases.Keys) { Out "$k -> $($al.aliases[$k])" }; Finish 'ok' "$($al.aliases.Count) alias(es)" 0 }
    if ($sub -eq 'add') {
        if ($Pos.Count -lt 3) { Finish 'error' 'alias add <name> <path>' 1 }
        $nm = $Pos[1]
        if (-not ($nm -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$') -or $Reserved -contains $nm.ToLowerInvariant()) { Finish 'error' 'bad or reserved alias name' 1 }
        try { $r = Resolve-RcFolder $Pos[2] } catch { Refuse $_.Exception.Message }
        if ($null -eq $r) { Finish 'error' 'alias needs a full path' 1 }
        $al.aliases[$nm] = $r.path; Write-RcJson $f $al
        Finish 'ok' "alias $nm -> $($r.path)" 0
    }
    if ($sub -eq 'remove') { if ($Pos.Count -lt 2 -or -not $al.aliases.Contains($Pos[1])) { Finish 'error' 'no such alias' 3 }; $al.aliases.Remove($Pos[1]); Write-RcJson $f $al; Finish 'ok' "alias $($Pos[1]) removed" 0 }
    Finish 'error' 'alias list|add|remove' 1
}

'denylist' {
    $f = Get-RcFile 'config\denylist.user.json'
    $dl = Read-RcJson $f ([ordered]@{ schemaVersion = 1; entries = @() })
    $sub = $(if ($Pos.Count) { $Pos[0] } else { 'list' })
    if ($sub -eq 'list') {
        Out 'built-in (cannot be removed): drive roots, Windows, Program Files, ProgramData, C:\Users (except your own folder), your home folder itself, AppData, .ssh/.aws/.azure/.config/.local..., every .claude* profile, claude-hub*, PowerShell profile folders, the rc install and source folders'
        foreach ($e in $dl.entries) { Out "user: $($e.path)  (added $($e.addedAt) by $($e.by))" }
        Finish 'ok' "$(@($dl.entries).Count) user entr(ies)" 0
    }
    if ($Pos.Count -lt 2) { Finish 'error' "denylist $sub <path>" 1 }
    $n = ConvertTo-RcInputPath $Pos[1]
    if (-not $n) { Finish 'error' 'denylist needs a full path' 1 }
    if ($sub -eq 'add') {
        $list = New-Object System.Collections.ArrayList
        foreach ($e in $dl.entries) { if ($e.path -ieq $n) { Finish 'ok' 'already denied' 0 }; [void]$list.Add($e) }
        [void]$list.Add([ordered]@{ path = $n; addedAt = Get-RcTimestamp; by = $(if ($Caller.phoneDriven) { 'phone' } else { 'local' }) })
        $dl.entries = $list; Write-RcJson $f $dl
        $s = Get-RcServers
        $hit = @($s.servers.Keys | Where-Object { (Test-RcUnder $s.servers[$_].path $n) -or (Test-RcUnder $n $s.servers[$_].path) })
        if ($hit.Count) { Out ("WARN: affected servers (will be refused at their next restart): " + ($hit -join ', ')) }
        Finish 'ok' "denied $n" 0
    }
    if ($sub -eq 'remove') {
        Need-Code 'denylist-remove' $n
        $list = New-Object System.Collections.ArrayList
        $found = $false
        foreach ($e in $dl.entries) { if ($e.path -ieq $n) { $found = $true } else { [void]$list.Add($e) } }
        if (-not $found) { Finish 'error' 'not in the user denylist (built-in entries cannot be removed)' 3 }
        $dl.entries = $list; Write-RcJson $f $dl
        Finish 'ok' "removed $n from denylist" 0
    }
    Finish 'error' 'denylist list|add|remove' 1
}

'approve' {
    if ($Pos.Count -lt 1) { Finish 'error' 'approve <folder>' 1 }
    try { $r = Resolve-RcFolder $Pos[0] } catch { Refuse $_.Exception.Message }
    if ($null -eq $r) { Finish 'error' 'approve needs a full path' 1 }
    $g = Get-RcGateFindings $r.path
    if ($g.Count -eq 0) { Finish 'ok' 'nothing to approve: no hooks/MCP/env in project config' 0 }
    Out ('Will allow: ' + ($g -join '; '))
    Need-Code 'approve' $r.path
    Approve-RcGate $r.path $(if ($Caller.phoneDriven) { 'phone-confirmed' } else { 'local' })
    Finish 'ok' "approved project config of $($r.path) (any change to it needs approval again)" 0
}

'start' {
    if (Test-RcLocked) { Finish 'refused' 'LOCKED: run rc-spawn unlock at the PC' 6 }
    $target = ($Pos -join ' ').Trim()
    if (-not $target) { Finish 'error' 'start what? give a folder path, server name or alias' 1 }
    $s = Get-RcServers
    $profName = $(if (O '--profile') { O '--profile' } else { $null })
    # 1) known server name -> re-enable
    $ids = @(Find-RcIds $target)
    $path = $null
    if ($ids.Count -gt 1) { Finish 'error' ("'$target' is ambiguous: " + ($ids -join ', ') + '. Add --profile.') 4 }
    if ($ids.Count -eq 1 -and -not (Test-IsOrch $ids[0])) { $path = $s.servers[$ids[0]].path; if (-not $profName) { $profName = $s.servers[$ids[0]].profile } }
    if (-not $path) {
        $al = Read-RcJson (Get-RcFile 'config\aliases.json') @{ aliases = @{} }
        foreach ($k in $al.aliases.Keys) { if ($k -ieq $target) { $path = $al.aliases[$k] } }
    }
    if (-not $path) {
        try { $n = ConvertTo-RcInputPath $target } catch { Refuse $_.Exception.Message }
        if (-not $n) { Finish 'error' "'$target' is not a path, server or alias. Run: rc-spawn find $target" 3 }
        $path = $n
    }
    try { $r = Resolve-RcFolder $path -Create:([bool](O '--create')) } catch { Refuse $_.Exception.Message }
    $path = $r.path
    if (-not $profName) { $profName = $HomeName }
    $prof = Get-RcProfile $profName
    if ($null -eq $prof) { Refuse "profile '$profName' is not registered (register it at the PC: rc-spawn profiles add)" }

    # gate
    $gate = Get-RcGateFindings $path
    if ($gate.Count -gt 0 -and -not (Test-RcGateApproved $path)) {
        Out ('Project config would enable: ' + ($gate -join '; '))
        Refuse "approve it first: rc-spawn approve `"$path`""
    }
    # profile checks
    $auth = Get-RcProfileAuth $prof
    if (-not $auth.loggedIn -or $auth.authMethod -ne 'claude.ai' -or ($auth.Contains('apiProvider') -and $auth.apiProvider -ne 'firstParty')) {
        Refuse "profile $profName is not signed in with claude.ai. At the PC: `$env:CLAUDE_CONFIG_DIR='$($prof.configDir)'; claude auth login"
    }
    $homeAuth = Get-RcProfileAuth (Get-RcHomeProfile)
    $warns = @()
    $crossAccount = ($auth.email -ne $homeAuth.email)
    if ($profName -ne $HomeName) {
        if ($Caller.phoneDriven -and -not $prof.allowFromPhone) { Refuse "profile $profName is not allowed from the phone (allowFromPhone=false)" }
        if ($crossAccount) {
            $warns += "WARN: profile $profName is signed in as $(Hide-RcEmail $auth.email) ($($auth.subscriptionType)). Its sessions appear ONLY in that account's Claude app, not in yours ($(Hide-RcEmail $homeAuth.email)). The owner of that account can run commands on this PC in $path."
        }
    }
    # mode
    $mode = $(if (O '--permission-mode') { O '--permission-mode' } else { $cfg.defaults.permissionMode })
    if (-not (Test-RcModeAllowed $mode $false)) { Refuse "permission mode '$mode' not allowed (allowed: $(@($cfg.allowedModes) -join ', '))" }
    $spawn = $(if (O '--spawn') { O '--spawn' } else { $cfg.defaults.spawn })
    if ($spawn -notin @('same-dir', 'worktree')) { Finish 'error' 'spawn must be same-dir or worktree' 1 }
    if ($spawn -eq 'worktree' -and -not (Test-Path -LiteralPath (Join-Path $path '.git'))) { $warns += 'WARN: not a git repo; using same-dir'; $spawn = 'same-dir' }
    $cap = [int]$cfg.defaults.capacity; if (O '--capacity') { $cap = [int](O '--capacity') }
    if ($cap -lt 1 -or $cap -gt [int]$cfg.caps.maxCapacity) { Finish 'error' "capacity must be 1..$($cfg.caps.maxCapacity)" 1 }
    # name
    $name = O '--name'
    if (-not $name) {
        $name = ([regex]::Replace([IO.Path]::GetFileName($path), '[^A-Za-z0-9._-]', '-')).Trim('-', '.')
        if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
        if (-not $name) { $name = 'session' }
    }
    if ($Reserved -contains $name.ToLowerInvariant()) { Finish 'error' "name '$name' is reserved; use --name" 1 }
    $id = "$profName/$name"
    $existing = $null
    if ($s.servers.Contains($id)) {
        $existing = $s.servers[$id]
        if ($existing.path -ine $path) { Finish 'error' "name '$name' is already used for $($existing.path) under $profName. Use --name." 4 }
    }
    $samePathOther = @($s.servers.Keys | Where-Object { $_ -ne $id -and $s.servers[$_].path -ieq $path -and $s.servers[$_].profile -eq $profName })
    if ($samePathOther.Count) { Finish 'error' ("this folder is already served under $profName as " + ($samePathOther -join ', ')) 4 }
    $otherProf = @($s.servers.Keys | Where-Object { $s.servers[$_].path -ieq $path -and $s.servers[$_].profile -ne $profName -and $s.servers[$_].enabled })
    if ($otherProf.Count) { $warns += ("WARN: the same folder is also served by " + ($otherProf -join ', ')) }
    if ($existing -and $existing.enabled -and (Get-RcState $id) -in @('RUNNING', 'BACKOFF', 'STARTING') -and (Test-RcSupervisorAlive $id)) {
        if ((O '--permission-mode') -and $existing.permissionMode -ne $mode) { Finish 'warn' "already running with mode=$($existing.permissionMode); use: rc-spawn mode $name $mode" 0 }
        foreach ($w in $warns) { Out $w }
        Finish 'ok' "already running: open '$($existing.displayName)' in the Code tab" 0
    }
    # caps
    $enabledCount = @($s.servers.Keys | Where-Object { $s.servers[$_].enabled -and -not ($s.servers[$_].Contains('orchestrator') -and $s.servers[$_].orchestrator) -and $_ -ne $id }).Count
    if ($enabledCount -ge [int]$cfg.caps.maxServers) { Refuse "server cap reached ($($cfg.caps.maxServers)); stop one first" }
    $perProf = @($s.servers.Keys | Where-Object { $s.servers[$_].enabled -and $s.servers[$_].profile -eq $profName -and $_ -ne $id }).Count
    if ($perProf -ge [int]$cfg.caps.maxServersPerProfile) { Refuse "per-profile cap reached for $profName" }
    # cross-account from phone needs confirmation, unless the owner pre-approved this profile (confirmCrossAccount=false)
    $confirmCross = -not ($prof.Contains('confirmCrossAccount') -and -not $prof.confirmCrossAccount)
    if ($profName -ne $HomeName -and $crossAccount -and $confirmCross) { Need-Code 'start-cross' "$profName $path" }

    $display = $(if ($profName -eq $HomeName) { $name } else { "$name@$profName" })
    try { Set-RcTrust $prof $path } catch { Fail $_.Exception.Message }
    Invoke-RcLocked 'state' {
        $s2 = Get-RcServers
        $s2.servers[$id] = [ordered]@{
            profile = $profName; name = $name; displayName = $display; path = $path; spawn = $spawn; capacity = $cap
            permissionMode = $mode; enabled = $true
            createdAt = $(if ($existing) { $existing.createdAt } else { Get-RcTimestamp }); createdBy = $(if ($Caller.phoneDriven) { "session:$($Caller.rcSpawnId)" } else { 'local' })
        }
        Save-RcServers $s2
    }
    Add-Recent $path $profName
    [void](Start-RcSupervisor $id)
    $st = Wait-Running $id
    foreach ($w in $warns) { Out $w }
    [void](Send-RcNotify "rc: started $display" "$path ($profName, $mode)" 2 'rocket')
    if ($st -eq 'RUNNING') { Finish 'ok' "started $id - open '$display' in the Claude app Code tab$(if ($crossAccount -and $profName -ne $HomeName) { ' of the ' + $profName + ' account' })" 0 }
    Finish 'warn' "$id is $st - check: rc-spawn logs $name" 0
}

'stop' {
    if (O '--all') {
        Need-Code 'stop-all' 'all'
        $s = Get-RcServers; $n = 0
        foreach ($id in @($s.servers.Keys)) {
            if (Test-IsOrch $id) { continue }
            Invoke-RcLocked 'state' { $s2 = Get-RcServers; $s2.servers[$id].enabled = $false; Save-RcServers $s2 }
            [void](Stop-RcServerProcess $id); Remove-RcEntry $id; $n++
        }
        [void](Send-RcNotify 'rc: stopped all' "$n server(s) stopped" 3 'stop_sign')
        Finish 'ok' "stopped $n server(s)" 0
    }
    $id = Get-OneId $Pos[0]
    if (Test-IsOrch $id) { Refuse 'the Orchestrator cannot stop itself (use lockdown to stop everything)' }
    Invoke-RcLocked 'state' { $s2 = Get-RcServers; $s2.servers[$id].enabled = $false; Save-RcServers $s2 }
    [void](Stop-RcServerProcess $id)
    Remove-RcEntry $id
    [void](Send-RcNotify "rc: stopped $id" 'stopped' 2 'stop_sign')
    Finish 'ok' "stopped $id; it disappears from the phone's Directory list in ~15 s" 0
}

'history' {
    $n = 15; if (O '-n') { $n = [Math]::Min(50, [Math]::Max(1, [int](O '-n'))) }
    $folder = O '--folder'; $search = O '--search'
    $names = @(Get-HistProfileNames)
    $running = Get-BgSessions $names
    # newest first across all profiles; parse lazily until we have n matches
    $files = foreach ($pn in $names) {
        $proj = Join-Path (Get-RcProfile $pn).configDir 'projects'
        if (-not (Test-Path -LiteralPath $proj)) { continue }
        Get-ChildItem -LiteralPath $proj -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.jsonl' } |
            Where-Object { $_.Length -ge 1024 } | ForEach-Object { [pscustomobject]@{ profile = $pn; file = $_ } }
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($f in @($files | Sort-Object { $_.file.LastWriteTime } -Descending)) {
        if ($items.Count -ge $n) { break }
        $m = Get-HistMeta $f.file.FullName
        if (-not $m.cwd -or -not $m.hasPrompt) { continue }
        if (Get-RcPolicyReason $m.cwd) { continue }   # e.g. the Orchestrator's own folder: never resumable
        if ($folder -and $m.cwd.IndexOf($folder, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($search -and ($m.title + ' ' + $m.lastPrompt + ' ' + $m.cwd).IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $sid = $f.file.BaseName
        [void]$items.Add([ordered]@{ n = $items.Count + 1; profile = $f.profile; sessionId = $sid; cwd = $m.cwd; title = $m.title
                when = $f.file.LastWriteTime.ToString('dd MMM HH:mm'); running = [bool]($running | Where-Object { $_.sessionId -eq $sid -and $_.profile -eq $f.profile }) })
    }
    Write-RcJson (Get-RcFile 'state\history-last.json') ([ordered]@{ at = Get-RcTimestamp; items = @($items) })
    foreach ($it in $items) {
        Out ("{0}. [{1}] {2} | {3} | {4} | {5}{6}" -f $it.n, $it.profile, $it.when, $it.title, $it.cwd, $it.sessionId.Substring(0, 8), $(if ($it.running) { ' (running now)' } else { '' }))
    }
    Finish 'ok' "$($items.Count) past chat(s) from $($names -join ', '). Continue one with: rc-spawn resume <number>" 0
}

'resume' {
    if (Test-RcLocked) { Finish 'refused' 'LOCKED' 6 }
    if ($Pos.Count -lt 1) { Finish 'error' 'resume <number from history | session id>' 1 }
    $h = Find-HistEntry $Pos[0]
    if (-not $h) { Finish 'error' "no past chat '$($Pos[0])' (run rc-spawn history first, or give at least 8 characters of the id)" 3 }
    $prof = Get-RcProfile $h.profile
    if ($Caller.phoneDriven -and -not $prof.allowFromPhone) { Refuse "profile $($h.profile) is not allowed from the phone (allowFromPhone=false)" }
    try { $r = Resolve-RcFolder $h.cwd } catch { Refuse $_.Exception.Message }
    $path = $r.path
    $gate = Get-RcGateFindings $path
    if ($gate.Count -gt 0 -and -not (Test-RcGateApproved $path)) { Out ('Project config would enable: ' + ($gate -join '; ')); Refuse "approve it first: rc-spawn approve `"$path`"" }
    $auth = Get-RcProfileAuth $prof
    if (-not $auth.loggedIn) { Refuse "profile $($h.profile) is not signed in" }
    $homeAuth = Get-RcProfileAuth (Get-RcHomeProfile)
    $crossAccount = ($auth.email -ne $homeAuth.email)
    $confirmCross = -not ($prof.Contains('confirmCrossAccount') -and -not $prof.confirmCrossAccount)
    if ($h.profile -ne $HomeName -and $crossAccount -and $confirmCross) { Need-Code 'resume-cross' "$($h.profile) $($h.sessionId)" }
    $live = @(Get-BgSessions @($h.profile) | Where-Object { $_.sessionId -eq $h.sessionId })
    if ($live.Count) { Finish 'ok' "already running as '$($live[0].name)' - open it in the Code tab$(if ($crossAccount) { ' of the ' + $h.profile + ' account' })" 0 }
    try { Set-RcTrust $prof $path } catch { Fail $_.Exception.Message }
    $name = $(if (O '--name') { O '--name' } else { $h.title })
    $name = ([regex]::Replace([string]$name, '[^\w .,()-]', ' ')).Trim(); if ($name.Length -gt 40) { $name = $name.Substring(0, 40).Trim() }
    if (-not $name) { $name = [IO.Path]::GetFileName($path) }
    # No --permission-mode: it makes a PC-created RC session "elevated" (403 under Trusted Devices); the phone sets the mode.
    Set-RcProfileEnv $prof
    Push-Location -LiteralPath $path
    try { $o = (Invoke-RcClaude @('--bg', '--resume', $h.sessionId, '--remote-control', $name) 2>&1 | Out-String) } finally { Pop-Location }
    $o = $o -replace '\x1b\[[0-9;]*m', ''
    if ($o -notmatch 'backgrounded') { Fail ("claude did not start: " + ($o.Trim() -split "`n")[0]) }
    Finish 'ok' "resumed '$name' ($($h.profile), $path) - open it in the Code tab$(if ($crossAccount) { ' of the ' + $h.profile + ' account' }) in ~10 s. Stop it later with: rc-spawn end $($h.sessionId.Substring(0, 8))" 0
}

'sessions' {
    $names = @(Get-HistProfileNames)
    $all = @(Get-BgSessions $names | Where-Object { $_.kind -eq 'background' -and $_.pid })
    $i = 0
    foreach ($s in $all) { $i++; Out ("{0}. [{1}] {2} | {3} | {4} | {5}" -f $i, $s.profile, $s.name, $s.cwd, $s.status, $s.id) }
    Write-RcJson (Get-RcFile 'state\sessions-last.json') ([ordered]@{ at = Get-RcTimestamp; items = @($all | ForEach-Object { [ordered]@{ id = $_.id; profile = $_.profile; name = $_.name } }) })
    Finish 'ok' "$($all.Count) running background chat(s). Stop one with: rc-spawn end <number|id>" 0
}

'end' {
    if ($Pos.Count -lt 1) { Finish 'error' 'end <number from sessions | id>' 1 }
    $t = [string]$Pos[0]
    $names = @(Get-HistProfileNames)
    $all = @(Get-BgSessions $names | Where-Object { $_.kind -eq 'background' -and $_.pid })
    $hit = $null
    if ($t -match '^\d{1,2}$') {
        $last = Read-RcJson (Get-RcFile 'state\sessions-last.json') $null
        if ($last) { $want = @($last.items)[[int]$t - 1]; if ($want) { $hit = $all | Where-Object { $_.id -eq $want.id -and $_.profile -eq $want.profile } | Select-Object -First 1 } }
    } else {
        $hit = $all | Where-Object { $_.id -like "$t*" -or $_.sessionId -like "$t*" } | Select-Object -First 1
    }
    if (-not $hit) { Finish 'error' "no running background chat '$t' (run rc-spawn sessions)" 3 }
    Set-RcProfileEnv (Get-RcProfile $hit.profile)
    $o = (Invoke-RcClaude @('stop', $hit.id) 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
    if ($o -notmatch 'stopped') { Fail ("claude stop failed: " + $o.Trim()) }
    Finish 'ok' "stopped '$($hit.name)' ($($hit.profile)); its history is kept (rc-spawn resume $($hit.sessionId.Substring(0, 8)) brings it back)" 0
}

'restart' {
    if (Test-RcLocked) { Finish 'refused' 'LOCKED' 6 }
    $id = Get-OneId $Pos[0]
    $e = (Get-RcServers).servers[$id]
    $prob = Get-RcEntryProblem $e
    if ($prob) { Refuse $prob }
    if (Test-IsOrch $id) {
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Sleep 5; Import-Module ''' + (Get-RcFile 'lib\RcCore.psm1') + '''; [void](Stop-RcServerProcess ''' + $id + '''); [void](Start-RcSupervisor ''' + $id + ''')"'
        [void](Start-RcDetached $cmd (Get-RcRoot) 0)
        Finish 'ok' 'Orchestrator restarts in ~5 s; reopen it in the Code tab in ~30 s' 0
    }
    Invoke-RcLocked 'state' { $s2 = Get-RcServers; $s2.servers[$id].enabled = $true; Save-RcServers $s2 }
    [void](Stop-RcServerProcess $id)
    [void](Start-RcSupervisor $id)
    $st = Wait-Running $id
    Finish $(if ($st -eq 'RUNNING') { 'ok' } else { 'warn' }) "$id is $st" 0
}

'remove' {
    $id = Get-OneId $Pos[0]
    if (Test-IsOrch $id) { Refuse 'cannot remove the Orchestrator' }
    if (Test-RcSupervisorAlive $id) { Finish 'error' "stop it first: rc-spawn stop $($Pos[0])" 4 }
    Invoke-RcLocked 'state' { $s2 = Get-RcServers; $s2.servers.Remove($id); Save-RcServers $s2 }
    $rf = Get-RcRunFile $id; if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force }
    Finish 'ok' "removed $id" 0
}

'mode' {
    if ($Pos.Count -lt 2) { Finish 'error' 'mode <name> <default|plan|acceptEdits|auto>' 1 }
    $id = Get-OneId $Pos[0]
    if (Test-IsOrch $id) { Refuse 'the Orchestrator mode is fixed' }
    $m = $Pos[1]
    $canon = @($cfg.allowedModes | Where-Object { $_ -ieq $m })
    if ($canon.Count -eq 0) { Refuse "mode '$m' not allowed (allowed: $(@($cfg.allowedModes) -join ', '))" }
    Invoke-RcLocked 'state' { $s2 = Get-RcServers; $s2.servers[$id].permissionMode = $canon[0]; $s2.servers[$id].enabled = $true; Save-RcServers $s2 }
    [void](Stop-RcServerProcess $id); [void](Start-RcSupervisor $id)
    $st = Wait-Running $id
    Finish 'ok' "$id now uses $($canon[0]) for new sessions ($st)" 0
}

'profiles' {
    $sub = $(if ($Pos.Count) { $Pos[0] } else { 'list' })
    $pf = Get-RcFile 'config\profiles.json'
    if ($sub -eq 'list') {
        $hm = Get-RcProfileAuth (Get-RcHomeProfile) -NoCache
        foreach ($k in $Profiles.profiles.Keys) {
            $p = Get-RcProfile $k
            $a = Get-RcProfileAuth $p -NoCache
            $running = @((Get-RcServers).servers.Keys | Where-Object { $_.StartsWith("$k/") -and (Get-RcState $_) -eq 'RUNNING' }).Count
            $acct = $(if ($a.loggedIn) { "$(Hide-RcEmail $a.email) $($a.subscriptionType) org=$($a.orgName)" } else { 'NOT SIGNED IN' })
            $flags = @()
            if ($k -eq $HomeName) { $flags += 'home' }
            if ($p.allowFromPhone) { $flags += 'phone-ok' }
            if ($a.loggedIn -and $a.email -ne $hm.email) { $flags += 'OTHER-ACCOUNT' }
            Out ("{0,-10} {1}  [{2}]  running={3}  {4}" -f $k, $acct, ($flags -join ','), $running, $p.configDir)
        }
        Finish 'ok' "$($Profiles.profiles.Count) profile(s)" 0
    }
    if ($sub -eq 'add') {
        if ($Pos.Count -lt 3) { Finish 'error' 'profiles add <name> <configDir>' 1 }
        $nm = $Pos[1].ToLowerInvariant()
        if (-not ($nm -match '^[a-z][a-z0-9-]{0,19}$')) { Finish 'error' 'bad profile name' 1 }
        if ($Profiles.profiles.Contains($nm)) { Finish 'error' 'profile exists' 4 }
        $dir = [IO.Path]::GetFullPath($Pos[2].Trim('"'))
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Finish 'error' "no such folder $dir" 3 }
        if (-not (Test-RcUnder $dir $env:USERPROFILE)) { Refuse 'profile dirs must be inside your user folder' }
        if (Test-RcUnder $dir (Get-RcRoot)) { Refuse 'not a profile dir' }
        if (-not ((Test-Path (Join-Path $dir 'settings.json')) -or (Test-Path (Join-Path $dir '.credentials.json')))) { Refuse 'that folder does not look like a Claude profile (no settings.json/.credentials.json)' }
        $isDefault = ($dir.TrimEnd('\') -ieq (Join-Path $env:USERPROFILE '.claude'))
        if ($isDefault -and -not (O '--i-understand-default-profile')) { Refuse 'this is the default ~/.claude profile; add --i-understand-default-profile (only its trust entries will be written)' }
        Require-Local "registering profile $nm ($dir)"
        $envMode = $(if (O '--env-mode') { O '--env-mode' } elseif ($isDefault) { 'unset' } else { 'set' })
        $gcf = $(if (O '--global-config') { O '--global-config' } elseif ($envMode -eq 'unset') { Join-Path $env:USERPROFILE '.claude.json' } else { Join-Path $dir '.claude.json' })
        $entry = [ordered]@{ configDir = $dir; envMode = $envMode; globalConfigFile = $gcf; allowFromPhone = [bool](O '--allow-from-phone'); registeredAt = Get-RcTimestamp; home = $false }
        $Profiles.profiles[$nm] = $entry
        Write-RcJson $pf $Profiles
        $p = Get-RcProfile $nm
        $a = Get-RcProfileAuth $p -NoCache
        $Profiles.profiles[$nm]['expectedEmail'] = $a.email
        Write-RcJson $pf $Profiles
        Out "account: $(if ($a.loggedIn) { Hide-RcEmail $a.email } else { 'NOT SIGNED IN' })  configDirectory reported: $($a.configDirectory)"
        Finish 'ok' "profile $nm registered" 0
    }
    if ($sub -eq 'remove') {
        if ($Pos.Count -lt 2) { Finish 'error' 'profiles remove <name>' 1 }
        $nm = $Pos[1]
        if ($nm -eq $HomeName) { Refuse 'cannot remove the home profile' }
        if (-not $Profiles.profiles.Contains($nm)) { Finish 'error' 'no such profile' 3 }
        $mine = @((Get-RcServers).servers.Keys | Where-Object { $_.StartsWith("$nm/") })
        if ($mine.Count) { Finish 'error' ("stop and remove its servers first: " + ($mine -join ', ')) 4 }
        Require-Local "removing profile $nm"
        $Profiles.profiles.Remove($nm); Write-RcJson $pf $Profiles
        Finish 'ok' "profile $nm removed" 0
    }
    Finish 'error' 'profiles list|add|remove' 1
}

'trust' {
    $l = Read-RcJson (Get-RcFile 'state\trust-ledger.json') @{ entries = @() }
    foreach ($e in $l.entries) { if ((O '--profile') -and $e.profile -ne (O '--profile')) { continue }; Out "$($e.profile)  $($e.key)  preExisting=$($e.preExisting)  $($e.addedAt)" }
    Finish 'ok' "$(@($l.entries).Count) trust entr(ies)" 0
}

'audit' {
    $n = 30; if (O '-n') { $n = [Math]::Min([int](O '-n'), 200) }
    $files = @(Get-ChildItem -LiteralPath (Get-RcFile 'audit') -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 2)
    $lines = @(); foreach ($f in $files) { $lines = @(Get-Content -LiteralPath $f.FullName) + $lines }
    foreach ($ln in ($lines | Select-Object -Last $n)) {
        try { $r = ConvertFrom-Json $ln; Out ("{0} {1,-8} {2} {3} -> {4} {5}" -f $r.ts, $r.src, $r.cmd, (@($r.args) -join ' '), $r.result, $r.detail) } catch {}
    }
    Finish 'ok' 'audit' 0
}

'health' {
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $os = Get-CimInstance Win32_OperatingSystem
    $up = (Get-Date) - $os.LastBootUpTime
    Out ("CPU {0}%   RAM {1:N1}/{2:N1} GB used   uptime {3}d {4}h" -f [int]$cpu, (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB), ($os.TotalVisibleMemorySize / 1MB), $up.Days, $up.Hours)
    foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) { Out ("disk {0} {1:N0} GB free of {2:N0}" -f $d.Name, ($d.AvailableFreeSpace / 1GB), ($d.TotalSize / 1GB)) }
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) { Out ("battery {0}%  status={1} (2=AC)" -f $bat.EstimatedChargeRemaining, $bat.BatteryStatus) } else { Out 'battery: none (desktop/AC)' }
    $cl = @(Get-Process claude -ErrorAction SilentlyContinue)
    Out ("claude processes: {0}  memory {1:N0} MB" -f $cl.Count, (($cl | Measure-Object WorkingSet64 -Sum).Sum / 1MB))
    $s = Get-RcServers; $by = @{}
    foreach ($id in $s.servers.Keys) { $st = Get-RcState $id; if (-not $by.ContainsKey($st)) { $by[$st] = 0 }; $by[$st]++ }
    Out ('servers: ' + (($by.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect($cfg.supervisor.networkHost, 443); $c.Close(); Out "network: api.anthropic.com:443 $($sw.ElapsedMilliseconds) ms" } catch { Out 'network: api.anthropic.com UNREACHABLE' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { Out 'WARN: Windows Update reboot pending' }
    if (Test-RcLocked) { Out 'LOCKED: lockdown active' }
    Finish 'ok' 'health' 0
}

'doctor' {
    $fails = 0; $warnsN = 0
    function Chk([string]$lvl, [string]$name, [string]$detail) { Out ("{0,-4} {1}: {2}" -f $lvl, $name, $detail); if ($lvl -eq 'FAIL') { $script:fails++ } elseif ($lvl -eq 'WARN') { $script:warnsN++ } }
    $script:fails = 0; $script:warnsN = 0
    if (Test-Path -LiteralPath $cfg.claudePath) { $ver = (Invoke-RcClaude @('--version') 2>$null) -join ''; Chk 'OK' 'claude' "$ver ($($cfg.claudePath))" } else { Chk 'FAIL' 'claude' "not found at $($cfg.claudePath)" }
    if (Test-Path -LiteralPath $cfg.nodePath) { Chk 'OK' 'node' $cfg.nodePath } else { Chk 'FAIL' 'node' 'not found (guard hook fails closed: Orchestrator can do nothing)' }
    $hm = Get-RcProfileAuth (Get-RcHomeProfile) -NoCache
    foreach ($k in $Profiles.profiles.Keys) {
        $p = Get-RcProfile $k; $a = Get-RcProfileAuth $p -NoCache
        if (-not $a.loggedIn) { Chk $(if ($k -eq $HomeName) { 'FAIL' } else { 'WARN' }) "profile $k" 'not signed in'; continue }
        if ($a.authMethod -ne 'claude.ai') { Chk 'FAIL' "profile $k" "authMethod=$($a.authMethod) (Remote Control needs claude.ai login)"; continue }
        $lvl = 'OK'; $d = "$(Hide-RcEmail $a.email) $($a.subscriptionType) org=$($a.orgName)"
        if ($p.envMode -ne 'unset' -and $a.configDirectory -and $a.configDirectory.TrimEnd('\') -ine $p.configDir.TrimEnd('\')) { $lvl = 'FAIL'; $d += " configDirectory mismatch ($($a.configDirectory))" }
        if ($k -ne $HomeName -and $a.email -ne $hm.email) { if ($lvl -eq 'OK') { $lvl = 'WARN' }; $d += ' OTHER ACCOUNT: its sessions do not show in your app' }
        if ($p.Contains('expectedEmail') -and $p.expectedEmail -and $p.expectedEmail -ne $a.email) { $lvl = 'WARN'; $d += ' account changed since registration' }
        Chk $lvl "profile $k" $d
    }
    foreach ($v in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_OAUTH_TOKEN')) {
        foreach ($scope in @('User', 'Machine')) { if ([Environment]::GetEnvironmentVariable($v, $scope)) { Chk 'FAIL' 'env' "$v set at $scope scope (Remote Control will refuse)" } }
    }
    $s = Get-RcServers
    foreach ($id in $s.servers.Keys) {
        $e = $s.servers[$id]
        $isO = $e.Contains('orchestrator') -and $e.orchestrator
        if (-not $isO -and -not $e.enabled) { continue }
        $st = Get-RcState $id
        $prob = Get-RcEntryProblem $e
        $p = Get-RcProfile $e.profile
        $tr = ''
        if ($p) { $tr = (& $cfg.nodePath (Get-RcFile 'lib\rcjson.js') has-trust --file $p.globalConfigFile --path $e.path.Replace('\', '/')) -join '' }
        if ($prob) { Chk 'FAIL' "server $id" $prob }
        elseif ($st -eq 'RUNNING') { Chk 'OK' "server $id" "RUNNING trust=$tr" }
        else { Chk $(if ($isO) { 'FAIL' } else { 'WARN' }) "server $id" "$st trust=$tr" }
    }
    $w = Read-RcJson (Get-RcFile 'state\run\watchdog.json') $null
    if ($w -and (Test-RcProcAlive $w.pid $w.start)) { Chk 'OK' 'watchdog' "pid $($w.pid)" } else { Chk 'WARN' 'watchdog' 'not running (starts at logon; or run start-all.ps1 -Watch)' }
    $t = Get-ScheduledTask -TaskPath '\rc-spawn\' -TaskName 'StartAll' -ErrorAction SilentlyContinue
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'rc-spawn-start-all.lnk'
    if ($t) { Chk 'OK' 'logon start' "task \rc-spawn\StartAll ($($t.State))" } elseif (Test-Path $lnk) { Chk 'OK' 'logon start' 'Startup folder shortcut' } else { Chk 'FAIL' 'logon start' 'not installed' }
    $gc = @(Get-Command rc-spawn -All -ErrorAction SilentlyContinue)
    if ($gc.Count -and $gc[0].Source -like '*\rc\bin\rc-spawn.cmd') { Chk 'OK' 'PATH' $gc[0].Source } else { Chk 'WARN' 'PATH' 'rc-spawn.cmd not first on PATH in this shell (open a new terminal)' }
    $pq = (& powercfg.exe /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null) -join "`n"
    $m = [regex]::Match($pq, 'Current AC Power Setting Index:\s*0x([0-9a-f]+)')
    if ($m.Success -and [Convert]::ToInt32($m.Groups[1].Value, 16) -eq 0) { Chk 'OK' 'sleep (AC)' 'never' } else { Chk 'WARN' 'sleep (AC)' 'PC may sleep: powercfg /change standby-timeout-ac 0' }
    $al = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).AutoAdminLogon
    if ($al -eq '1') { Chk 'OK' 'autologon' 'on' } else { Chk 'WARN' 'autologon' 'off: after a reboot nothing starts until you sign in' }
    $n = Read-RcJson (Get-RcFile 'config\notify.json') $null
    if ($n -and $n.enabled) {
        if (O '--send-test') { if (Send-RcNotify 'rc-spawn doctor' 'test notification' 3 'white_check_mark') { Chk 'OK' 'ntfy' 'test sent' } else { Chk 'FAIL' 'ntfy' 'send failed' } }
        else { Chk 'OK' 'ntfy' "enabled ($($n.server))" }
    }
    if (Test-RcLocked) { Chk 'WARN' 'lockdown' 'LOCKED' }
    foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) { if ($d.AvailableFreeSpace -lt 5GB) { Chk 'WARN' 'disk' "$($d.Name) below 5 GB free" } }
    if ($script:fails) { Finish 'error' "$($script:fails) FAIL, $($script:warnsN) WARN" 2 }
    if ($script:warnsN) { Finish 'warn' "$($script:warnsN) WARN" 1 }
    Finish 'ok' 'all checks passed' 0
}

'notify' {
    $txt = ($Pos -join ' ').Trim()
    if (-not $txt -or $txt -eq 'test') { $txt = 'test notification from rc-spawn' }
    $txt = '[note] ' + ([regex]::Replace($txt, '\d{6,}', '######'))
    if ($txt.Length -gt 300) { $txt = $txt.Substring(0, 300) }
    if (Send-RcNotify 'rc-spawn note' $txt 3 'speech_balloon') { Finish 'ok' 'sent' 0 }
    Fail 'ntfy not configured or unreachable'
}

'lockdown' {
    Write-RcText (Get-RcFile 'state\LOCKED') (Get-RcTimestamp)
    [void](Send-RcNotify 'rc: LOCKDOWN' 'All Remote Control servers are stopping. Undo only at the PC: rc-spawn unlock' 5 'lock,rotating_light')
    $s = Get-RcServers
    foreach ($id in @($s.servers.Keys)) { if (-not (Test-IsOrch $id)) { [void](Stop-RcServerProcess $id 5) } }
    $orch = @($s.servers.Keys | Where-Object { Test-IsOrch $_ })
    if ($orch.Count) {
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Sleep 4; Import-Module ''' + (Get-RcFile 'lib\RcCore.psm1') + '''; [void](Stop-RcServerProcess ''' + $orch[0] + ''' 5)"'
        [void](Start-RcDetached $cmd (Get-RcRoot) 0)
    }
    Finish 'ok' 'LOCKED: everything stops now (Orchestrator in ~5 s). Undo only at the PC with: rc-spawn unlock' 0
}

'unlock' {
    if (-not (Test-RcLocked)) { Finish 'ok' 'not locked' 0 }
    Require-Local 'unlock'
    Remove-Item -LiteralPath (Get-RcFile 'state\LOCKED') -Force
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Get-RcFile 'bin\start-all.ps1') + '" -Watch'
    [void](Start-RcDetached $cmd (Get-RcRoot))
    [void](Send-RcNotify 'rc: unlocked' 'Servers are starting again.' 3 'unlock')
    Finish 'ok' 'unlocked; servers are starting' 0
}

'reboot' {
    if (O '--cancel') { & shutdown.exe /a 2>&1 | Out-Null; [void](Send-RcNotify 'rc: reboot cancelled' 'cancelled' 3 'x'); Finish 'ok' 'reboot cancelled (if one was pending)' 0 }
    $in = 60; if (O '--in') { $in = [int](O '--in') }
    if ($in -lt 60 -or $in -gt 3600) { Finish 'error' '--in must be 60..3600 seconds' 1 }
    Need-Code 'reboot' "$in"
    $al = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).AutoAdminLogon
    if ($al -ne '1') { Out 'WARN: autologon is off - after the reboot the PC waits at the sign-in screen and nothing starts.' }
    & shutdown.exe /r /t $in /c "rc-spawn reboot" 2>&1 | Out-Null
    [void](Send-RcNotify 'rc: reboot scheduled' "PC reboots in $in s. Cancel: rc-spawn reboot --cancel" 4 'repeat')
    Finish 'ok' "rebooting in $in s (cancel: reboot --cancel)" 0
}

'update' {
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Get-RcFile 'bin\rc-update.ps1') + '"'
    [void](Start-RcDetached $cmd (Get-RcRoot))
    Finish 'ok' 'update started in the background; all servers (and this Orchestrator) restart in ~1 min. Check later with: rc-spawn doctor' 0
}
}
