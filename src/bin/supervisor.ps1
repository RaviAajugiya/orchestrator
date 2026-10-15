# supervisor.ps1 - keeps one `claude remote-control` server alive. Launched detached by rc-spawn / start-all.
param([Parameter(Mandatory = $true)][string]$Id)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
Import-Module (Join-Path $PSScriptRoot '..\lib\RcCore.psm1') -Force -DisableNameChecking
try { $Host.UI.RawUI.WindowTitle = "rc: $Id" } catch {}

$cfg = Get-RcConfig
$sv = $cfg.supervisor
$logDir = Get-RcLogDir $Id
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$supLog = Join-Path $logDir 'supervisor.log'
$dbgLog = Join-Path $logDir 'debug.log'
$stopFlag = Join-Path (Get-RcFile 'state\pending') ('stop-' + (Get-RcIdFile $Id))
$me = Get-Process -Id $PID

function Log([string]$m) { Add-RcLine $supLog ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $m) }

$run = Get-RcRun $Id
if ($run -and (Test-RcProcAlive $run.supervisorPid $run.supervisorStart) -and [int]$run.supervisorPid -ne $PID) {
    Log "another supervisor (pid $($run.supervisorPid)) is alive; exiting"; exit 0
}
$restarts = 0; $fastFails = 0
if ($run -and $run.Contains('restarts')) { $restarts = [int]$run.restarts }

function Beat([string]$State, $ClaudeProc, $LastExit) {
    $r = [ordered]@{
        id = $Id; state = $State; supervisorPid = $PID; supervisorStart = [string]$me.StartTime.Ticks
        claudePid = $null; claudeStart = $null; startedAt = $script:startedAt; restarts = $script:restarts
        consecutiveFastFails = $script:fastFails; lastExit = $LastExit; heartbeatAt = (Get-RcTimestamp)
    }
    if ($ClaudeProc) { $r.claudePid = $ClaudeProc.Id; try { $r.claudeStart = [string]$ClaudeProc.StartTime.Ticks } catch {} }
    Write-RcJson (Get-RcRunFile $Id) $r
}

function Quote([string]$a) {
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Wait-Network {
    $t0 = Get-Date; $alerted = $false
    while ($true) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $iar = $c.BeginConnect($sv.networkHost, 443, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(5000) -and $c.Connected) { $c.Close(); return }
            $c.Close()
        } catch {}
        if (Test-Path -LiteralPath $stopFlag) { return }
        if (-not $alerted -and ((Get-Date) - $t0).TotalMinutes -ge 10) { [void](Send-RcNotify "rc: $Id offline" 'No network for 10 min; waiting.' 3 'warning'); $alerted = $true }
        Start-Sleep -Seconds 15
    }
}

function Classify([double]$Secs) {
    $tail = ''
    if (Test-Path -LiteralPath $dbgLog) {
        try {
            $fs = [IO.File]::Open($dbgLog, 'Open', 'Read', 'ReadWrite')
            $len = $fs.Length; $from = [Math]::Max([long]$script:dbgStart, $len - 8192); $n = [int]($len - $from); $fs.Seek($from, 'Begin') | Out-Null
            $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n); $fs.Close()
            $tail = [Text.Encoding]::UTF8.GetString($buf)
        } catch {}
    }
    foreach ($cls in @('NOT_TRUSTED', 'AUTH_FAIL', 'POLICY_UNKNOWN')) {
        foreach ($pat in $cfg.fatalPatterns[$cls]) { if ($tail.IndexOf($pat, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $cls } }
    }
    if ($Secs -ge [double]$sv.fastFailSec) { return 'NORMAL_OFFLINE' }
    return 'FAST_FAIL'
}

Add-Type -Name RcCon -Namespace RcNative -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint groupId);
'@ -ErrorAction SilentlyContinue
$script:startedAt = Get-RcTimestamp
$lastExit = $null
$notTrustedHits = 0
Log "supervisor start pid=$PID"

while ($true) {
    if (Test-Path -LiteralPath $stopFlag) { Beat 'STOPPED' $null $lastExit; Log 'stop flag; exiting'; exit 0 }
    if (Test-RcLocked) { Beat 'LOCKED' $null $lastExit; Log 'LOCKED; exiting'; exit 0 }
    $servers = Get-RcServers
    if (-not $servers.servers.Contains($Id)) { Beat 'STOPPED' $null $lastExit; Log 'entry removed; exiting'; exit 0 }
    $e = $servers.servers[$Id]
    $isOrch = [bool]($e.Contains('orchestrator') -and $e.orchestrator)
    if (-not $isOrch -and -not $e.enabled) { Beat 'STOPPED' $null $lastExit; Log 'disabled; exiting'; exit 0 }
    $problem = Get-RcEntryProblem $e
    if ($problem) {
        Beat 'REFUSED' $null $lastExit; Log "REFUSED: $problem"
        [void](Send-RcNotify "rc: $Id refused" $problem 4 'no_entry'); exit 2
    }
    $prof = Get-RcProfile $e.profile
    try { Set-RcTrust $prof $e.path } catch { Log "trust: $($_.Exception.Message)" }
    Wait-Network
    if (Test-Path -LiteralPath $stopFlag) { continue }

    Set-RcProfileEnv $prof
    $env:RC_SPAWN_ID = $Id
    $env:Path = (Get-RcFile 'bin') + ';' + ($env:Path -replace [regex]::Escape((Get-RcFile 'bin') + ';'), '')
    if (Test-Path -LiteralPath $dbgLog) {
        if ((Get-Item -LiteralPath $dbgLog).Length -gt ([int]$sv.debugLogMaxMB * 1MB)) {
            for ($i = [int]$sv.debugLogKeep - 1; $i -ge 1; $i--) { if (Test-Path "$dbgLog.$i") { Move-Item "$dbgLog.$i" "$dbgLog.$($i+1)" -Force } }
            Move-Item $dbgLog "$dbgLog.1" -Force
        }
    }
    $argv = @()
    if ($cfg.Contains('claudePrefixArgs') -and $cfg.claudePrefixArgs) { $argv += @($cfg.claudePrefixArgs) }
    # No --permission-mode: in 2.1.299 it makes the pre-created session "elevated" (403 under Trusted Devices,
    # anthropics/claude-code#99463), and the phone sets the mode per session anyway. The mode comes from the
    # folder/profile settings; the Orchestrator's safety is its deny rules + guard hook.
    # No --no-create-session-in-dir: that disables bridge-pointer reuse, so every restart registered a NEW
    # environment and the phone kept routing sessions to the dead old one.
    $argv += @('remote-control', '--name', $e.displayName, '--spawn', $e.spawn, '--capacity', [string]$e.capacity, '--debug-file', $dbgLog)
    $argString = ($argv | ForEach-Object { Quote ([string]$_) }) -join ' '
    Log "launch: $($cfg.claudePath) $argString  (cwd=$($e.path), profile=$($e.profile))"
    $script:dbgStart = 0
    if (Test-Path -LiteralPath $dbgLog) { $script:dbgStart = (Get-Item -LiteralPath $dbgLog).Length }
    $t0 = Get-Date
    try {
        $p = Start-Process -FilePath $cfg.claudePath -ArgumentList $argString -WorkingDirectory $e.path -NoNewWindow -PassThru
        $null = $p.Handle
    } catch {
        Log "launch failed: $($_.Exception.Message)"; $p = $null
    }
    if ($p) {
        Beat 'RUNNING' $p $lastExit
        $lastBeat = Get-Date
        while (-not $p.WaitForExit(1500)) {
            if ((Test-Path -LiteralPath $stopFlag) -or (Test-RcLocked)) {
                Log 'stop requested; sending Ctrl+C so the server unregisters'
                # graceful: Ctrl+C to the shared console (supervisor ignores it), then force after 15 s
                try {
                    [void][RcNative.RcCon]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
                    [void][RcNative.RcCon]::GenerateConsoleCtrlEvent(0, 0)
                } catch { Log "ctrl+c failed: $($_.Exception.Message)" }
                if (-not $p.WaitForExit(15000)) { Log 'no exit after Ctrl+C; killing'; Stop-RcTree $p.Id; $p.WaitForExit(10000) | Out-Null }
                try { [void][RcNative.RcCon]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) } catch {}
                break
            }
            if (((Get-Date) - $lastBeat).TotalSeconds -ge [int]$sv.heartbeatSec) { Beat 'RUNNING' $p $lastExit; $lastBeat = Get-Date }
        }
        $code = $null; try { $code = $p.ExitCode } catch {}
    } else { $code = -1 }
    $secs = ((Get-Date) - $t0).TotalSeconds
    if ((Test-Path -LiteralPath $stopFlag) -or (Test-RcLocked)) { continue }
    $cls = Classify $secs
    $lastExit = [ordered]@{ code = $code; class = $cls; at = (Get-RcTimestamp); durationSec = [int]$secs }
    $restarts++
    Log "exit code=$code after $([int]$secs)s class=$cls"
    switch ($cls) {
        'NORMAL_OFFLINE' { $fastFails = 0; $delay = [int]$sv.baseDelaySec }
        'POLICY_UNKNOWN' { $fastFails = 0; $delay = 30 }
        'NOT_TRUSTED' {
            $notTrustedHits++
            if ($notTrustedHits -ge 2) {
                Beat 'GAVE_UP' $null $lastExit
                [void](Send-RcNotify "rc: $Id gave up" 'Workspace not trusted even after re-trust. Run claude once in that folder at the PC.' 4 'x'); exit 3
            }
            $delay = 2
        }
        'AUTH_FAIL' {
            Beat 'AUTH_FAIL' $null $lastExit
            [void](Send-RcNotify "rc: $Id login problem" "Profile $($e.profile) needs 'claude auth login' at the PC (CLAUDE_CONFIG_DIR=$($prof.configDir)). Retrying every $($sv.authRetryMin) min." 5 'rotating_light')
            $delay = [int]$sv.authRetryMin * 60
        }
        default {
            $fastFails++
            if ($fastFails -ge [int]$sv.giveUpAfter) {
                Beat 'GAVE_UP' $null $lastExit
                [void](Send-RcNotify "rc: $Id gave up" "$fastFails fast failures in a row. Check: rc-spawn logs $Id --debug" 4 'x'); exit 3
            }
            if ($fastFails -le 3) { $delay = [int]$sv.baseDelaySec } else { $delay = [int]@($sv.backoffSec)[[Math]::Min($fastFails - 4, @($sv.backoffSec).Count - 1)] }
            if ($fastFails -eq 4) { [void](Send-RcNotify "rc: $Id failing" "Fast failures; backing off ($delay s)." 3 'warning') }
        }
    }
    if ($cls -ne 'AUTH_FAIL') { Beat 'BACKOFF' $null $lastExit }
    $until = (Get-Date).AddSeconds($delay)
    while ((Get-Date) -lt $until) {
        if ((Test-Path -LiteralPath $stopFlag) -or (Test-RcLocked)) { break }
        Start-Sleep -Seconds 2
    }
}
