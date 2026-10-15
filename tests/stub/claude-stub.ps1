# claude-stub.ps1 - fake `claude` for tests. Records argv/cwd/env to $STUB_LOG (or next to this file).
$log = $(if ($env:STUB_LOG) { $env:STUB_LOG } else { Join-Path $PSScriptRoot 'stub-calls.jsonl' })
$rec = @{ argv = @($args); cwd = (Get-Location).Path; cfg = $env:CLAUDE_CONFIG_DIR; rcid = $env:RC_SPAWN_ID; claudecode = $env:CLAUDECODE; at = (Get-Date).ToString('o') }
[IO.File]::AppendAllText($log, (ConvertTo-Json $rec -Compress) + "`r`n")
$mode = $(if ($env:STUB_MODE) { $env:STUB_MODE } else { 'run' })
if ($args.Count -ge 1 -and $args[0] -eq '--version') { '9.9.9 (Claude Code stub)'; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'auth' -and $args[1] -eq 'status') {
    $email = 'tester@example.com'
    $f = Join-Path ([string]$env:CLAUDE_CONFIG_DIR) 'stub-email.txt'
    if ($env:CLAUDE_CONFIG_DIR -and (Test-Path $f)) { $email = (Get-Content $f -Raw).Trim() }
    @{ loggedIn = $true; authMethod = 'claude.ai'; apiProvider = 'firstParty'; email = $email; orgName = 'StubOrg'; subscriptionType = 'team'; configDirectory = $env:CLAUDE_CONFIG_DIR } | ConvertTo-Json
    exit 0
}
if ($args.Count -ge 1 -and $args[0] -eq 'remote-control') {
    $dbg = $null
    for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq '--debug-file') { $dbg = $args[$i + 1] } }
    $flag = Join-Path (Get-Location).Path '.stub-mode'
    if (Test-Path $flag) { $mode = (Get-Content $flag -Raw).Trim() }
    switch ($mode) {
        'exit-fast' { Start-Sleep 1; exit 1 }
        'auth-fail' { if ($dbg) { Add-Content $dbg 'Error: You must be logged in' }; exit 1 }
        'not-trusted' { if ($dbg) { Add-Content $dbg 'Error: Workspace not trusted' }; exit 1 }
        default { Write-Host "stub remote-control running in $((Get-Location).Path)"; while ($true) { Start-Sleep 5 } }
    }
}
exit 0
