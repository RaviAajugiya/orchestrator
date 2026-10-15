// rc-orch-guard.js - PreToolUse guard for the Orchestrator session. Fails closed.
// Allows only a single `rc-spawn ...` command (Bash / PowerShell) and a few harmless internal tools.
'use strict';
function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason }
  }));
  process.stderr.write(reason);
  process.exit(2);
}
let buf = '';
const timer = setTimeout(() => deny('guard timeout'), 4000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => { buf += d; });
process.stdin.on('end', () => {
  clearTimeout(timer);
  try {
    const ev = JSON.parse(buf.replace(/^﻿/, '').trim() || '{}');
    const tool = String(ev.tool_name || '');
    const SAFE = ['TodoWrite', 'ToolSearch'];
    if (SAFE.includes(tool)) process.exit(0);
    if (tool !== 'Bash' && tool !== 'PowerShell') deny('Orchestrator may only run rc-spawn (tool ' + tool + ' blocked)');
    const cmd = String((ev.tool_input && ev.tool_input.command) || '').trim();
    // one rc-spawn invocation, no shell metacharacters / expansions
    // backslashes are allowed inside Windows paths, but not right before a quote or at the end
    const ok = /^rc-spawn(\s.*)?$/.test(cmd) && !/[;&|<>`$(){}%^!\r\n]/.test(cmd) && !/\\["']/.test(cmd) && !/\\$/.test(cmd);
    if (!ok) deny('Orchestrator may only run a single plain `rc-spawn ...` command (no ; & | < > ` $ ( ) { } % ^ ! and no trailing backslash)');
    process.exit(0);
  } catch (e) {
    deny('guard error: ' + (e && e.message));
  }
});
