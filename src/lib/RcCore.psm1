# RcCore.psm1 - shared library for rc-spawn (Windows PowerShell 5.1)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:RcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Reserved = @('orchestrator', 'all', 'orchestrator-tg', 'help')

# ---------------------------------------------------------------- JSON / files

function ConvertTo-RcHash($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-RcHash $p.Value }
        return $h
    }
    if ($o -is [System.Collections.IList] -and -not ($o -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $o) { [void]$list.Add((ConvertTo-RcHash $i)) }
        return , $list
    }
    return $o
}

function Read-RcJson([string]$Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $txt = [IO.File]::ReadAllText($Path, $script:Utf8NoBom)
    if ($txt.Length -gt 0 -and $txt[0] -eq [char]0xFEFF) { $txt = $txt.Substring(1) }
    # a hard power-off can leave a file of NUL bytes or half-written JSON. Runtime files (state\run, authcache,
    # pending) are rebuilt by the supervisor, so quarantine them and use the default; anything else still throws.
    $volatile = $Path -match '\\state\\(run|authcache|pending)\\'
    if ($txt.Trim([char]0, ' ', "`t", "`r", "`n").Length -eq 0) {
        if ($txt.Length -gt 0 -and -not $volatile) { throw "corrupt (NUL-filled) JSON file: $Path" }
        if ($txt.Length -gt 0) { Move-Item -LiteralPath $Path -Destination "$Path.corrupt-$((Get-Date).ToString('yyyyMMddHHmmss'))" -Force -ErrorAction SilentlyContinue }
        return $Default
    }
    try { return ConvertTo-RcHash (ConvertFrom-Json -InputObject $txt) }
    catch {
        if (-not $volatile) { throw "corrupt JSON file: $Path ($($_.Exception.Message))" }
        Move-Item -LiteralPath $Path -Destination "$Path.corrupt-$((Get-Date).ToString('yyyyMMddHHmmss'))" -Force -ErrorAction SilentlyContinue
        return $Default
    }
}

function Write-RcJson([string]$Path, $Obj) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ConvertTo-Json -InputObject $Obj -Depth 12
    $tmp = "$Path.rc-tmp"
    # flush to disk before the rename so a power cut can't leave a NUL-filled file behind
    $bytes = $script:Utf8NoBom.GetBytes($json)
    $fs = New-Object IO.FileStream($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-RcText([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Add-RcLine([string]$Path, [string]$Line) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::AppendAllText($Path, $Line + "`r`n", $script:Utf8NoBom)
}

function Get-RcRoot { return $script:RcRoot }
function Get-RcFile([string]$Rel) { return (Join-Path $script:RcRoot $Rel) }

function Get-RcConfig {
    $c = Read-RcJson (Get-RcFile 'config\rc.config.json') $null
    if ($null -eq $c) { throw "rc.config.json missing under $script:RcRoot\config" }
    return $c
}

function Invoke-RcLocked([string]$Name, [scriptblock]$Block) {
    $m = New-Object System.Threading.Mutex($false, "Local\rc-spawn-$Name")
    $got = $false
    try {
        try { $got = $m.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { throw "timeout waiting for lock $Name" }
        & $Block
    } finally {
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function Invoke-RcClaude([string[]]$A) {
    $cfg = Get-RcConfig
    $pre = @()
    if ($cfg.Contains('claudePrefixArgs') -and $cfg.claudePrefixArgs) { $pre = @($cfg.claudePrefixArgs) }
    & $cfg.claudePath @pre @A
}

function Get-RcTimestamp { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }

# ---------------------------------------------------------------- redaction / audit / notify

function Protect-RcText([string]$s) {
    if ($null -eq $s) { return '' }
    $pats = @(
        'sk-ant-[A-Za-z0-9_\-]+',
        'eyJ[\w\-]+\.[\w\-]+\.[\w\-]+',
        '(?i)bearer\s+\S+',
        '(?i)"(access|refresh)Token"\s*:\s*"[^"]+"',
        '(?i)(password|pwd|passwd|secret|api[_\-]?key|client_secret)\s*[=:]\s*[^;\s"'']+',
        'AKIA[0-9A-Z]{16}',
        'gh[pousr]_[A-Za-z0-9]{30,}',
        'xox[abposr]-[\w\-]+',
        '(?i)https://\S*[?&](code|token|key)=[^&\s]+'
    )
    foreach ($p in $pats) { $s = [regex]::Replace($s, $p, '[REDACTED]') }
    $topic = $null
    try { $n = Read-RcJson (Get-RcFile 'config\notify.json') $null; if ($n) { $topic = $n.topic } } catch {}
    if ($topic) { $s = $s.Replace($topic, '[topic]') }
    # strip control chars / ANSI escapes
    $s = [regex]::Replace($s, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
    $s = [regex]::Replace($s, '\x1b\][^\x07]*\x07', '')
    $s = [regex]::Replace($s, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
    return $s
}

function Hide-RcEmail([string]$e) {
    if (-not $e) { return '' }
    $i = $e.IndexOf('@')
    if ($i -lt 1) { return '***' }
    return $e.Substring(0, 1) + '***' + $e.Substring($i)
}

function Get-RcCaller {
    $phone = $false
    if ($env:CLAUDECODE) { $phone = $true }
    try { if ([Console]::IsInputRedirected) { $phone = $true } } catch { $phone = $true }
    if (-not [Environment]::UserInteractive) { $phone = $true }
    return @{ phoneDriven = $phone; rcSpawnId = $env:RC_SPAWN_ID; claudecode = [bool]$env:CLAUDECODE }
}

function Write-RcAudit([string]$Src, [string]$Cmd, $ArgList, [string]$Result, [int]$Exit, [string]$Detail) {
    try {
        $c = Get-RcCaller
        $rec = [ordered]@{
            ts = Get-RcTimestamp; src = $Src
            caller = [ordered]@{ rcSpawnId = $c.rcSpawnId; claudecode = $c.claudecode; phoneDriven = $c.phoneDriven }
            cmd = $Cmd; args = @($ArgList | ForEach-Object { Protect-RcText ([string]$_) })
            result = $Result; exit = $Exit; detail = (Protect-RcText $Detail)
        }
        $line = ConvertTo-Json -InputObject $rec -Depth 5 -Compress
        Add-RcLine (Get-RcFile ("audit\" + (Get-Date).ToString('yyyy-MM-dd') + '.jsonl')) $line
    } catch {}
}

function Send-RcNotify([string]$Title, [string]$Message, [int]$Priority = 3, [string]$Tags = '', [switch]$NoCache) {
    $n = Read-RcJson (Get-RcFile 'config\notify.json') $null
    if ($null -eq $n -or -not $n.enabled -or -not $n.topic) { return $false }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $q = 'title=' + [Uri]::EscapeDataString($Title) + '&priority=' + $Priority
        if ($Tags) { $q += '&tags=' + [Uri]::EscapeDataString($Tags) }
        $uri = ($n.server.TrimEnd('/')) + '/' + $n.topic + '?' + $q
        $h = @{}
        if ($n.token) { $h['Authorization'] = 'Bearer ' + $n.token }
        if ($NoCache) { $h['Cache'] = 'no' }
        $body = [Text.Encoding]::UTF8.GetBytes($Message)
        Invoke-RestMethod -Method Post -Uri $uri -Headers $h -Body $body -ContentType 'text/plain; charset=utf-8' -TimeoutSec 10 | Out-Null
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- profiles

function Get-RcProfiles { return (Read-RcJson (Get-RcFile 'config\profiles.json') $null) }

function Get-RcProfile([string]$Name) {
    $p = Get-RcProfiles
    if (-not $Name) { $Name = $p.default }
    if (-not $p.profiles.Contains($Name)) { return $null }
    $e = $p.profiles[$Name]
    $e['name'] = $Name
    return $e
}

function Get-RcHomeProfile { $p = Get-RcProfiles; return (Get-RcProfile $p.default) }

function Set-RcProfileEnv($Profile) {
    # Applies the profile env to the CURRENT process (callers run claude as a child afterwards).
    if ($Profile.envMode -eq 'unset') { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_CONFIG_DIR = $Profile.configDir }
    foreach ($v in @(Get-ChildItem Env: | Where-Object {
                ($_.Name -like 'CLAUDE_CODE_*' -and $_.Name -ne 'CLAUDE_CODE_GIT_BASH_PATH') -or
                $_.Name -in @('CLAUDECODE', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
                    'CLAUDE_CODE_OAUTH_TOKEN', 'NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE', 'BASH_ENV', 'ENV') })) {
        Remove-Item ("Env:" + $v.Name) -ErrorAction SilentlyContinue
    }
    # fail closed: verify
    if ($Profile.envMode -ne 'unset' -and $env:CLAUDE_CONFIG_DIR -ne $Profile.configDir) { throw 'profile env mismatch' }
}

function Get-RcProfileAuth($Profile, [switch]$NoCache) {
    $cfg = Get-RcConfig
    $cacheFile = Get-RcFile ("state\authcache\" + $Profile.name + '.json')
    if (-not $NoCache -and (Test-Path -LiteralPath $cacheFile)) {
        $age = ((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalMinutes
        if ($age -lt 10) { return (Read-RcJson $cacheFile $null) }
    }
    $saved = @{}
    Get-ChildItem Env: | ForEach-Object { $saved[$_.Name] = $_.Value }
    try {
        Set-RcProfileEnv $Profile
        $out = Invoke-RcClaude @('auth', 'status', '--json') 2>$null
        $res = ConvertTo-RcHash (ConvertFrom-Json -InputObject ($out -join "`n"))
    } catch {
        $res = [ordered]@{ loggedIn = $false; error = $_.Exception.Message }
    } finally {
        Get-ChildItem Env: | Where-Object { -not $saved.ContainsKey($_.Name) } | ForEach-Object { Remove-Item ("Env:" + $_.Name) }
        foreach ($k in $saved.Keys) { Set-Item -LiteralPath ("Env:" + $k) -Value $saved[$k] }
    }
    Write-RcJson $cacheFile $res
    return $res
}

# ---------------------------------------------------------------- paths & policy

function Get-RcRealCase([string]$Path) {
    # returns on-disk casing; follows reparse points (junction/symlink) segment by segment
    $hops = 0
    $p = $Path
    while ($true) {
        $root = [IO.Path]::GetPathRoot($p)
        $rest = $p.Substring($root.Length).Trim('\')
        $cur = $root.ToUpper()
        $segs = @()
        if ($rest) { $segs = $rest.Split('\') }
        $restarted = $false
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $seg = $segs[$i]
            $found = $null
            try { $found = [IO.Directory]::GetDirectories($cur, $seg) | Select-Object -First 1 } catch { throw "cannot read $cur" }
            if (-not $found) { throw "folder not found: $(Join-Path $cur $seg)" }
            $di = New-Object IO.DirectoryInfo $found
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $hops++
                if ($hops -gt 16) { throw 'too many reparse points' }
                $item = Get-Item -LiteralPath $found -Force
                $t = @($item.Target)[0]
                if (-not $t) { throw "unresolvable reparse point: $found" }
                if ($t.StartsWith('\\?\')) { $t = $t.Substring(4) }
                if ($t -match '^(UNC\\|\\\\|Volume\{)') { throw "reparse target not allowed: $t" }
                if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $found) $t }
                $remaining = ($segs[($i + 1)..($segs.Count)] | Where-Object { $_ }) -join '\'
                if ($remaining) { $p = [IO.Path]::GetFullPath((Join-Path $t $remaining)) } else { $p = [IO.Path]::GetFullPath($t) }
                $restarted = $true
                break
            }
            $cur = $di.FullName
        }
        if (-not $restarted) { return $cur.TrimEnd('\') + $(if ($cur.Length -eq 3) { '\' } else { '' }) }
    }
}

function ConvertTo-RcInputPath([string]$Raw) {
    $s = $Raw.Trim()
    if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) { $s = $s.Substring(1, $s.Length - 2) }
    if ($s.Length -gt 1024) { throw 'path too long' }
    if ($s -match '[\x00-\x1f"<>|*?%^!]' -or $s -match '\$\(' -or $s -match '\$env:') { throw 'path contains forbidden characters' }
    if ($s -match '^/([a-zA-Z])(/.*)?$') { $s = $Matches[1].ToUpper() + ':' + $(if ($Matches[2]) { $Matches[2] } else { '\' }) }
    if ($s -eq '~') { $s = $env:USERPROFILE }
    elseif ($s -match '^~[\\/](.*)$') { $s = Join-Path $env:USERPROFILE $Matches[1] }
    $s = $s.Replace('/', '\')
    if ($s.StartsWith('\\')) { throw 'UNC and device paths are not allowed' }
    if ($s -match '^[a-zA-Z]:$' -or $s -match '^[a-zA-Z]:[^\\]') { throw 'drive-relative paths are not allowed' }
    if (-not ($s -match '^[a-zA-Z]:\\')) { return $null }  # not a path -> caller treats as name
    if ($s.Substring(2).Contains(':')) { throw 'alternate data streams are not allowed' }
    foreach ($seg in $s.Substring(3).Split('\')) {
        if ($seg -eq '') { continue }
        if ($seg -match '[ .]$') { throw "segment ends in dot or space: '$seg'" }
        if ($seg -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { throw "reserved device name: $seg" }
    }
    $s = [IO.Path]::GetFullPath($s.TrimEnd('\') + $(if ($s.TrimEnd('\').Length -eq 2) { '\' } else { '' }))
    $drv = New-Object IO.DriveInfo ($s.Substring(0, 1))
    $cfg = Get-RcConfig
    if ($drv.DriveType -ne 'Fixed') {
        if (-not (($drv.DriveType -eq 'Removable' -and $cfg.drives.allowRemovable) -or ($drv.DriveType -eq 'Network' -and $cfg.drives.allowNetwork))) {
            throw "drive $($s.Substring(0,2)) is $($drv.DriveType); only fixed drives are allowed"
        }
    }
    return $s
}

function Test-RcUnder([string]$Path, [string]$Base) {
    $p = $Path.TrimEnd('\').ToLowerInvariant(); $b = $Base.TrimEnd('\').ToLowerInvariant()
    return ($p -eq $b -or $p.StartsWith($b + '\'))
}

function Get-RcSensitive {
    # paths that must never be opened, nor any folder containing them
    $u = $env:USERPROFILE
    $list = New-Object System.Collections.ArrayList
    foreach ($x in @($env:SystemRoot, 'C:\Windows.old', $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            'C:\Recovery', 'C:\PerfLogs', 'C:\Boot', 'C:\Config.Msi',
            (Join-Path $u 'AppData'), (Join-Path $u '.ssh'), (Join-Path $u '.aws'), (Join-Path $u '.azure'),
            (Join-Path $u '.gnupg'), (Join-Path $u '.kube'), (Join-Path $u '.docker'), (Join-Path $u '.config'),
            (Join-Path $u '.local'), (Join-Path $u '.nuget'), (Join-Path $u '.m2'),
            (Join-Path $u 'Documents\WindowsPowerShell'), (Join-Path $u 'Documents\PowerShell'), $script:RcRoot)) {
        if ($x) { [void]$list.Add($x) }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $u -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.claude*' -or $_.Name -like 'claude-hub*' })) { [void]$list.Add($d.FullName) }
    $pr = Get-RcProfiles
    foreach ($k in $pr.profiles.Keys) { [void]$list.Add($pr.profiles[$k].configDir) }
    $cfg = Get-RcConfig
    if ($cfg.Contains('sourceDir') -and $cfg.sourceDir) { [void]$list.Add($cfg.sourceDir) }
    foreach ($drv in [IO.DriveInfo]::GetDrives()) {
        [void]$list.Add((Join-Path $drv.Name '$Recycle.Bin'))
        [void]$list.Add((Join-Path $drv.Name 'System Volume Information'))
    }
    $ud = Read-RcJson (Get-RcFile 'config\denylist.user.json') @{ entries = @() }
    foreach ($e in $ud.entries) { [void]$list.Add($e.path) }
    return $list
}

function Get-RcPolicyReason([string]$Path) {
    # returns $null when allowed, otherwise a refusal reason
    $u = $env:USERPROFILE.TrimEnd('\')
    if ($Path.TrimEnd('\').Length -le 3) { return 'drive roots are not allowed' }
    if ($Path.TrimEnd('\') -ieq $u) { return 'your home folder itself is not allowed (trust is never saved there)' }
    $users = Join-Path $env:SystemDrive 'Users'
    if (Test-RcUnder $Path $users) {
        if (-not (Test-RcUnder $Path $u)) { return 'other users'' folders and C:\Users are not allowed' }
    }
    foreach ($s in Get-RcSensitive) {
        if (Test-RcUnder $Path $s) { return "inside protected folder $s" }
        if (Test-RcUnder $s $Path) { return "contains protected folder $s" }
    }
    return $null
}

function Resolve-RcFolder([string]$Raw, [switch]$Create) {
    # returns @{ path = canonical; requested = normalized } or throws
    $n = ConvertTo-RcInputPath $Raw
    if ($null -eq $n) { return $null }
    $r1 = Get-RcPolicyReason $n
    if ($r1) { throw "refused: $r1" }
    if (-not (Test-Path -LiteralPath $n -PathType Container)) {
        if ($Create) {
            $parent = Split-Path -Parent $n
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "parent folder does not exist: $parent" }
            New-Item -ItemType Directory -Path $n | Out-Null
        } else { throw "folder not found: $n (use --create to make it)" }
    }
    $real = Get-RcRealCase $n
    $r2 = Get-RcPolicyReason $real
    if ($r2) { throw "refused (resolved to $real): $r2" }
    return @{ path = $real; requested = $n }
}

# ---------------------------------------------------------------- project-config gate

function Get-RcGateFiles([string]$Folder) {
    $files = @()
    foreach ($rel in @('.claude\settings.json', '.claude\settings.local.json', '.mcp.json')) {
        $f = Join-Path $Folder $rel
        if (Test-Path -LiteralPath $f -PathType Leaf) { $files += $f }
    }
    return $files
}

function Get-RcGateFindings([string]$Folder) {
    $risky = @('hooks', 'mcpServers', 'apiKeyHelper', 'env', 'disableAllHooks', 'enabledPlugins', 'extraKnownMarketplaces',
        'statusLine', 'otelHeadersHelper', 'awsAuthRefresh', 'awsCredentialExport', 'enableAllProjectMcpServers', 'enabledMcpjsonServers')
    $found = New-Object System.Collections.ArrayList
    foreach ($f in Get-RcGateFiles $Folder) {
        $rel = $f.Substring($Folder.Length).TrimStart('\')
        if ($rel -eq '.mcp.json') { [void]$found.Add('.mcp.json (project MCP servers)'); continue }
        try { $j = Read-RcJson $f $null } catch { [void]$found.Add("$rel (unparseable)"); continue }
        if ($null -eq $j) { continue }
        foreach ($k in $risky) { if ($j.Contains($k)) { [void]$found.Add("$rel -> $k") } }
        if ($j.Contains('permissions') -and $j.permissions) {
            if ($j.permissions.Contains('defaultMode') -and $j.permissions.defaultMode -eq 'bypassPermissions') { [void]$found.Add("$rel -> permissions.defaultMode=bypassPermissions") }
            if ($j.permissions.Contains('additionalDirectories')) { [void]$found.Add("$rel -> permissions.additionalDirectories") }
        }
    }
    return , $found
}

function Get-RcGateHash([string]$Folder) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in Get-RcGateFiles $Folder) {
        $b = [IO.File]::ReadAllBytes($f)
        [void]$sb.Append($f.ToLowerInvariant() + ':' + [BitConverter]::ToString($sha.ComputeHash($b)) + ';')
    }
    return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace('-', '')
}

function Test-RcGateApproved([string]$Folder) {
    $a = Read-RcJson (Get-RcFile 'config\approved-project-configs.json') @{ approvals = @{} }
    $k = $Folder.ToLowerInvariant()
    if (-not $a.approvals.Contains($k)) { return $false }
    return ($a.approvals[$k].hash -eq (Get-RcGateHash $Folder))
}

function Approve-RcGate([string]$Folder, [string]$By) {
    $f = Get-RcFile 'config\approved-project-configs.json'
    $a = Read-RcJson $f ([ordered]@{ schemaVersion = 1; approvals = [ordered]@{} })
    $a.approvals[$Folder.ToLowerInvariant()] = [ordered]@{ path = $Folder; hash = (Get-RcGateHash $Folder); at = Get-RcTimestamp; by = $By }
    Write-RcJson $f $a
}

# ---------------------------------------------------------------- trust

function Set-RcTrust($Profile, [string]$Folder) {
    $cfg = Get-RcConfig
    $file = $Profile.globalConfigFile
    $key = $Folder.Replace('\', '/')
    $node = $cfg.nodePath
    $out = & $node (Get-RcFile 'lib\rcjson.js') trust --file $file --path $key 2>&1
    if ($LASTEXITCODE -ne 0) { throw "trust write failed: $out" }
    $pre = ($out -join '') -match 'preExisting=true'
    Invoke-RcLocked 'state' {
        $lf = Get-RcFile 'state\trust-ledger.json'
        $l = Read-RcJson $lf ([ordered]@{ entries = @() })
        $exists = @($l.entries | Where-Object { $_.profile -eq $Profile.name -and $_.key -ieq $key }).Count -gt 0
        if (-not $exists) {
            $list = New-Object System.Collections.ArrayList
            foreach ($e in $l.entries) { [void]$list.Add($e) }
            [void]$list.Add([ordered]@{ profile = $Profile.name; file = $file; key = $key; preExisting = $pre; addedAt = Get-RcTimestamp })
            $l.entries = $list
            Write-RcJson $lf $l
        }
    }
}

# ---------------------------------------------------------------- servers state

function Get-RcServers { return (Read-RcJson (Get-RcFile 'state\servers.json') ([ordered]@{ schemaVersion = 1; servers = [ordered]@{} })) }
function Save-RcServers($s) { Write-RcJson (Get-RcFile 'state\servers.json') $s }
function Get-RcIdFile([string]$Id) { return ($Id.Replace('/', '__')) }
function Get-RcRunFile([string]$Id) { return (Get-RcFile ("state\run\" + (Get-RcIdFile $Id) + '.json')) }
function Get-RcRun([string]$Id) { return (Read-RcJson (Get-RcRunFile $Id) $null) }
function Get-RcLogDir([string]$Id) { $p = $Id.Split('/'); return (Get-RcFile ("logs\" + $p[0] + '\' + $p[1])) }
function Test-RcLocked { return (Test-Path -LiteralPath (Get-RcFile 'state\LOCKED')) }

function Test-RcProcAlive($ProcId, [string]$StartTicks) {
    if (-not $ProcId) { return $false }
    $p = Get-Process -Id ([int]$ProcId) -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    if ($StartTicks) { try { if ([string]$p.StartTime.Ticks -ne [string]$StartTicks) { return $false } } catch { return $false } }
    return $true
}

function Test-RcSupervisorAlive([string]$Id) {
    $r = Get-RcRun $Id
    if ($null -eq $r) { return $false }
    return (Test-RcProcAlive $r.supervisorPid $r.supervisorStart)
}

function Get-RcState([string]$Id) {
    $r = Get-RcRun $Id
    if ($null -eq $r) { return 'STOPPED' }
    $alive = Test-RcProcAlive $r.supervisorPid $r.supervisorStart
    if (-not $alive) {
        if ($r.state -in @('STOPPED', 'GAVE_UP', 'REFUSED', 'LOCKED')) { return $r.state }
        return 'DEAD'
    }
    return $r.state
}

function Test-RcModeAllowed([string]$Mode, [bool]$Orchestrator) {
    if ($Orchestrator) { return ($Mode -eq 'default') }
    $cfg = Get-RcConfig
    return (@($cfg.allowedModes) -contains $Mode)
}

function Get-RcEntryProblem($Entry) {
    # treat desired state as untrusted input: re-validate everything before launch
    $cfg = Get-RcConfig
    $orch = [bool]($Entry.Contains('orchestrator') -and $Entry.orchestrator)
    $prof = Get-RcProfile $Entry.profile
    if ($null -eq $prof) { return "profile '$($Entry.profile)' is not registered" }
    if (-not (Test-RcModeAllowed $Entry.permissionMode $orch)) { return "permission mode '$($Entry.permissionMode)' not allowed" }
    if ($Entry.spawn -notin @('same-dir', 'worktree', 'session')) { return "spawn '$($Entry.spawn)' not allowed" }
    if ([int]$Entry.capacity -lt 1 -or [int]$Entry.capacity -gt [int]$cfg.caps.maxCapacity) { return 'capacity out of range' }
    if ($orch) {
        if ($Entry.path -ne (Get-RcFile 'orchestrator')) { return 'orchestrator path mismatch' }
        if ($Entry.profile -ne (Get-RcProfiles).default) { return 'orchestrator must run under the home profile' }
        return $null
    }
    try { $r = Resolve-RcFolder $Entry.path } catch { return $_.Exception.Message }
    if ($r.path -ne $Entry.path) { return "path now resolves elsewhere ($($r.path))" }
    $gate = Get-RcGateFindings $Entry.path
    if ($gate.Count -gt 0 -and -not (Test-RcGateApproved $Entry.path)) { return ('project config not approved: ' + ($gate -join ', ')) }
    return $null
}

function Start-RcDetached([string]$CommandLine, [string]$Cwd, [int]$Show = 0) {
    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]$Show }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CommandLine; CurrentDirectory = $Cwd; ProcessStartupInformation = $si }
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed ($($r.ReturnValue))" }
    return $r.ProcessId
}

function Start-RcSupervisor([string]$Id) {
    $sup = Get-RcFile 'bin\supervisor.ps1'
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $sup + '" -Id "' + $Id + '"'
    $pf = Join-Path (Get-RcFile 'state\pending') ('stop-' + (Get-RcIdFile $Id))
    if (Test-Path -LiteralPath $pf) { Remove-Item -LiteralPath $pf -Force }
    return (Start-RcDetached $cmd (Get-RcRoot))
}

function Stop-RcTree([int]$RootPid) {
    # kill a process and all descendants (children first)
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    $kids = @{}
    foreach ($p in $all) { $pp = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }; [void]$kids[$pp].Add([int]$p.ProcessId) }
    $order = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack; $stack.Push($RootPid)
    $seen = @{}
    while ($stack.Count) { $x = $stack.Pop(); if ($seen.ContainsKey($x)) { continue }; $seen[$x] = 1; [void]$order.Insert(0, $x); if ($kids.ContainsKey($x)) { foreach ($c in $kids[$x]) { if ($c -ne $x) { $stack.Push($c) } } } }
    foreach ($x in $order) { try { Stop-Process -Id $x -Force -ErrorAction Stop } catch {} }
}

function Stop-RcServerProcess([string]$Id, [int]$WaitSec = 25) {
    $pdir = Get-RcFile 'state\pending'
    if (-not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force -Path $pdir | Out-Null }
    Write-RcText (Join-Path $pdir ('stop-' + (Get-RcIdFile $Id))) (Get-RcTimestamp)
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-RcSupervisorAlive $Id)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $r = Get-RcRun $Id
    if ($r) {
        if (Test-RcProcAlive $r.claudePid $r.claudeStart) { Stop-RcTree ([int]$r.claudePid) }
        if (Test-RcProcAlive $r.supervisorPid $r.supervisorStart) { Stop-RcTree ([int]$r.supervisorPid) }
        $r.state = 'STOPPED'
        Write-RcJson (Get-RcRunFile $Id) $r
    }
    return $true
}

# ---------------------------------------------------------------- confirm codes

function Get-RcSha([string]$s) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '')
}

function New-RcCode([string]$Action, [string]$ArgsText) {
    $n = Read-RcJson (Get-RcFile 'config\notify.json') $null
    if ($null -eq $n -or -not $n.enabled) { return 'no-ntfy' }
    $f = Get-RcFile ("state\pending\code-" + $Action + '.json')
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $b = New-Object byte[] 8; $rng.GetBytes($b)
    $code = ([BitConverter]::ToUInt64($b, 0) % 1000000).ToString('000000')
    $salt = [Convert]::ToBase64String($b)
    $rec = [ordered]@{ action = $Action; argsHash = (Get-RcSha $ArgsText); salt = $salt; hash = (Get-RcSha ($code + $salt)); expires = (Get-Date).AddMinutes(5).ToString('o'); attempts = 0 }
    Write-RcJson $f $rec
    $ok = Send-RcNotify 'rc-spawn confirm code' ("Code $code for: $Action $ArgsText  (expires in 5 min; only type it into the Orchestrator if YOU asked for this)") 4 'key' -NoCache
    if (-not $ok) { Remove-Item -LiteralPath $f -Force; return 'send-failed' }
    return 'sent'
}

function Confirm-RcCode([string]$Action, [string]$ArgsText, [string]$Code) {
    $f = Get-RcFile ("state\pending\code-" + $Action + '.json')
    $rec = Read-RcJson $f $null
    if ($null -eq $rec) { return 'no pending code; ask again without --code' }
    if ([datetime]::Parse($rec.expires) -lt (Get-Date)) { Remove-Item -LiteralPath $f -Force; return 'code expired' }
    if ($rec.argsHash -ne (Get-RcSha $ArgsText)) { return 'arguments differ from the request the code was issued for' }
    if ((Get-RcSha ($Code + $rec.salt)) -eq $rec.hash) { Remove-Item -LiteralPath $f -Force; return $null }
    $rec.attempts = [int]$rec.attempts + 1
    if ($rec.attempts -ge 3) {
        Remove-Item -LiteralPath $f -Force
        [void](Send-RcNotify 'rc-spawn: code attempts exceeded' "3 wrong codes for $Action. Request cancelled." 4 'warning')
        return 'too many wrong attempts; request cancelled'
    }
    Write-RcJson $f $rec
    return 'wrong code'
}

Export-ModuleMember -Function * -Variable Reserved
