# rc-update.ps1 - update Claude Code safely: stop rc servers, update (exe must not be in use), restart.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RcCore.psm1') -Force -DisableNameChecking
$cfg = Get-RcConfig
$log = Get-RcFile 'logs\update.log'
function Log([string]$m) { Add-RcLine $log ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $m) }
Start-Sleep -Seconds 5
$old = (Invoke-RcClaude @('--version') 2>$null) -join ''
Log "update start; current $old"
$s = Get-RcServers
$ids = @($s.servers.Keys | Where-Object { ($s.servers[$_].Contains('orchestrator') -and $s.servers[$_].orchestrator) -or $s.servers[$_].enabled })
foreach ($id in $ids) { [void](Stop-RcServerProcess $id 10) }
Start-Sleep -Seconds 3
$others = @(Get-Process claude -ErrorAction SilentlyContinue)
$ok = $true; $msg = ''
if ($others.Count -gt 0) {
    $ok = $false
    $msg = "$($others.Count) other claude process(es) still running (interactive sessions?). Close them and run update again."
} else {
    try {
        $out = Invoke-RcClaude @('update') 2>&1
        Log ($out -join "`n")
        if ($LASTEXITCODE -ne 0) {
            Log 'claude update failed; trying npm'
            $out = & npm.cmd i -g '@anthropic-ai/claude-code@latest' 2>&1
            Log ($out -join "`n")
        }
    } catch { $ok = $false; $msg = $_.Exception.Message }
}
$new = (Invoke-RcClaude @('--version') 2>$null) -join ''
foreach ($id in $ids) { [void](Start-RcSupervisor $id); Start-Sleep -Seconds ([int]$cfg.startStaggerSec) }
if ($ok) { $msg = "$old -> $new; $($ids.Count) server(s) restarted" }
Log $msg
[void](Send-RcNotify 'rc: update' $msg 3 'package')
