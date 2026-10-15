# start-all.ps1 - start the Orchestrator and every enabled server. With -Watch, stay running as the watchdog.
param([switch]$Watch, [string]$Only)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
Import-Module (Join-Path $PSScriptRoot '..\lib\RcCore.psm1') -Force -DisableNameChecking
try { $Host.UI.RawUI.WindowTitle = 'rc: watchdog' } catch {}
$cfg = Get-RcConfig
$log = Get-RcFile 'logs\start-all.log'
function Log([string]$m) { Add-RcLine $log ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $m) }

function Invoke-Revive([bool]$First) {
    if (Test-RcLocked) { if ($First) { Log 'LOCKED: nothing started'; [void](Send-RcNotify 'rc: PC up (LOCKED)' 'Lockdown active; nothing started. Run rc-spawn unlock at the PC.' 4 'lock') }; return }
    $s = Get-RcServers
    $ids = @($s.servers.Keys)
    $orch = @($ids | Where-Object { $s.servers[$_].Contains('orchestrator') -and $s.servers[$_].orchestrator })
    $rest = @($ids | Where-Object { -not ($s.servers[$_].Contains('orchestrator') -and $s.servers[$_].orchestrator) -and $s.servers[$_].enabled })
    $started = 0
    foreach ($id in @($orch + $rest)) {
        if ($Only -and $id -ne $Only) { continue }
        $st = Get-RcState $id
        if ($st -in @('RUNNING', 'BACKOFF', 'AUTH_FAIL', 'STARTING') -and (Test-RcSupervisorAlive $id)) { continue }
        if (-not $First -and $st -in @('GAVE_UP', 'REFUSED')) { continue }
        $prob = Get-RcEntryProblem $s.servers[$id]
        if ($prob) { Log "skip $id : $prob"; continue }
        Log "starting $id (state was $st)"
        [void](Start-RcSupervisor $id)
        $started++
        Start-Sleep -Seconds ([int]$cfg.startStaggerSec)
        if (-not $First) { [void](Send-RcNotify "rc: revived $id" "Supervisor was $st; restarted." 3 'arrows_counterclockwise') }
    }
    if ($First) { [void](Send-RcNotify 'rc: PC up' "$started server(s) started." 3 'computer') }
}

# wait for network (max 120 s)
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt [int]$cfg.networkWaitStartAllSec) {
    try { $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect($cfg.supervisor.networkHost, 443, $null, $null); if ($iar.AsyncWaitHandle.WaitOne(5000) -and $c.Connected) { $c.Close(); break }; $c.Close() } catch {}
    Start-Sleep -Seconds 5
}

if ($Watch) {
    $wf = Get-RcFile 'state\run\watchdog.json'
    $w = Read-RcJson $wf $null
    if ($w -and (Test-RcProcAlive $w.pid $w.start) -and [int]$w.pid -ne $PID) { Log 'watchdog already running'; exit 0 }
    Write-RcJson $wf ([ordered]@{ pid = $PID; start = [string](Get-Process -Id $PID).StartTime.Ticks; at = Get-RcTimestamp })
}

if (-not $Watch) { Invoke-RcLocked 'startall' { Invoke-Revive $true }; exit 0 }
# as the watchdog, never die on the first pass: log it and let the loop retry
try { Invoke-RcLocked 'startall' { Invoke-Revive $true } } catch { Log "first start error: $($_.Exception.Message)" }
Log "watchdog loop pid=$PID"
while ($true) {
    Start-Sleep -Seconds ([int]$cfg.watchdogSec)
    try { Invoke-RcLocked 'startall' { Invoke-Revive $false } } catch { Log "watchdog error: $($_.Exception.Message)" }
}
