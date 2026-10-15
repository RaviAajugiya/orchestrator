# rc-cleanup.ps1 - permanently remove stale Remote Control directory entries (as shown on the phone).
# How: Claude deletes its environment on a clean stop when it could NOT save its resume pointer.
# For each folder: mark projects\<folder>\bridge-pointer.json read-only, start `claude remote-control`
# there (it reattaches to the old environment from the pointer), wait for the poll loop, send Ctrl+C
# (archives its sessions + DELETE environment), then remove the pointer.
# Must run in its own console (launch detached, e.g. via Win32_Process.Create).
param(
    [Parameter(Mandatory = $true)][string[]]$Folders,
    [Parameter(Mandatory = $true)][string]$ConfigDir,
    [string]$Log
)
if (-not $Log) { $Log = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'rc-cleanup.log' }
$ErrorActionPreference = 'Stop'
Add-Type -Name Con -Namespace RcClean2 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);
'@
function Say([string]$m) { Add-Content -LiteralPath $Log -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $m) }
function Get-ProjKey([string]$dir) { return ($dir -replace '[^A-Za-z0-9]', '-') }

$env:CLAUDE_CONFIG_DIR = $ConfigDir
foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -eq 'CLAUDECODE' -or $_.Name -like 'CLAUDE_CODE_*' })) { Remove-Item ("Env:" + $v.Name) }
$exe = (Get-Command claude.exe -ErrorAction Stop).Source

foreach ($f in $Folders) {
    $ptr = Join-Path $ConfigDir ('projects\' + (Get-ProjKey $f) + '\bridge-pointer.json')
    if (-not (Test-Path -LiteralPath $ptr)) { Say "skip $f (no pointer: nothing to reattach to)"; continue }
    $want = (Get-Content -LiteralPath $ptr -Raw | ConvertFrom-Json).environmentId
    Set-ItemProperty -LiteralPath $ptr -Name IsReadOnly -Value $true
    $dbg = Join-Path $env:TEMP ('rc-cleanup-' + [guid]::NewGuid().ToString('N') + '.log')
    $p = Start-Process -FilePath $exe -ArgumentList "remote-control --name cleanup --capacity 1 --debug-file `"$dbg`"" -WorkingDirectory $f -NoNewWindow -PassThru
    $null = $p.Handle
    $got = ''; $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 750
        if ($p.HasExited) { break }
        if (Test-Path $dbg) {
            $t = Get-Content $dbg -Raw
            if ($t -match 'environment_id=(env_\w+)') { $got = $Matches[1] }
            if ($t -match 'Starting poll loop') { $ready = $true; break }
        }
    }
    if ($ready) {
        [void][RcClean2.Con]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)   # we ignore it; claude gets it
        [void][RcClean2.Con]::GenerateConsoleCtrlEvent(0, 0)
        $exited = $p.WaitForExit(25000)
        [void][RcClean2.Con]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
        if (-not $exited) { Stop-Process -Id $p.Id -Force }
        $t = Get-Content $dbg -Raw
        $del = $t -match 'Environment deregistered'
        Say ("{0} {1}: wanted {2}, got {3}, deleted={4}, cleanExit={5}" -f $(if ($del -and $got -eq $want) { 'REMOVED' } else { 'CHECK' }), $f, $want, $got, $del, $exited)
    } else {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        $why = ''; if (Test-Path $dbg) { $why = ((Get-Content $dbg -Tail 2) -join ' | ') }
        Say "FAILED $f (never polled) $why"
    }
    Set-ItemProperty -LiteralPath $ptr -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ptr -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
Say 'DONE'
