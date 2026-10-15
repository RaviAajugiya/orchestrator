# uninstall.ps1 - stop everything and remove what install.ps1 added. Profile settings.json is never touched.
param(
    [Parameter(Mandatory = $true)][string]$HomeProfileDir,
    [string]$RcRoot,
    [switch]$RemoveTrust,
    [switch]$KeepLogs
)
$ErrorActionPreference = 'Stop'
if (-not $RcRoot) { $RcRoot = Join-Path $HomeProfileDir 'rc' }
if (-not (Test-Path -LiteralPath (Join-Path $RcRoot 'lib\RcCore.psm1'))) { throw "no rc install at $RcRoot" }
Import-Module (Join-Path $RcRoot 'lib\RcCore.psm1') -Force -DisableNameChecking
function Say([string]$m) { Write-Host "[uninstall] $m" }

# watchdog first, so nothing is revived
$w = Read-RcJson (Join-Path $RcRoot 'state\run\watchdog.json') $null
if ($w -and (Test-RcProcAlive $w.pid $w.start)) { Stop-RcTree ([int]$w.pid); Say 'watchdog stopped' }
$s = Get-RcServers
foreach ($id in @($s.servers.Keys)) { [void](Stop-RcServerProcess $id 10); Say "stopped $id" }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($RcRoot) } | ForEach-Object { Stop-RcTree ([int]$_.ProcessId) }

Unregister-ScheduledTask -TaskPath '\rc-spawn\' -TaskName 'StartAll' -Confirm:$false -ErrorAction SilentlyContinue
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'rc-spawn-start-all.lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
Say 'logon start removed'

$bin = Join-Path $RcRoot 'bin'
$k = Get-Item 'HKCU:\Environment'
$cur = $k.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
$parts = @($cur -split ';' | Where-Object { $_ -and $_ -ne $bin })
if ($parts.Count -ne @($cur -split ';' | Where-Object { $_ }).Count) { Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value ($parts -join ';') -Type ExpandString; Say 'PATH entry removed' }

$sd = Join-Path $HomeProfileDir 'skills\rc-spawn'
if (Test-Path -LiteralPath $sd) { Remove-Item -LiteralPath $sd -Recurse -Force; Say 'skill removed' }

if ($RemoveTrust) {
    $l = Read-RcJson (Join-Path $RcRoot 'state\trust-ledger.json') @{ entries = @() }
    $cfg = Get-RcConfig
    foreach ($e in $l.entries) {
        if ($e.preExisting) { continue }
        & $cfg.nodePath (Join-Path $RcRoot 'lib\rcjson.js') untrust --file $e.file --path $e.key | Out-Null
        Say "untrusted $($e.profile) $($e.key)"
    }
}
if ($KeepLogs) {
    $arch = Join-Path $PSScriptRoot ('uninstall-archive\' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $arch | Out-Null
    foreach ($d in @('logs', 'audit', 'config', 'state')) { Copy-Item -Path (Join-Path $RcRoot $d) -Destination $arch -Recurse -Force }
    Say "logs archived to $arch"
}
Remove-Module RcCore -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item -LiteralPath $RcRoot -Recurse -Force
Say "removed $RcRoot. Done."
