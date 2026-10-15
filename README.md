# rc-spawn: control Claude Code from your phone

An always-on **Orchestrator** Remote Control session runs on your Windows PC. From the Claude app you tell it
"start a session in D:\Projects\foo", and it starts a Remote Control server in that folder, under any registered
profile, and keeps it alive.

**First time? Read [SETUP.md](SETUP.md).**

## Layout
| Where | What |
|---|---|
| `src\` (this folder) | source (edit here, then re-run `install.ps1`) |
| `<profile>\rc\` | installed: `bin\` shims + supervisor, `lib\` CLI, `hooks\` guard, `orchestrator\` (cwd + CLAUDE.md), `config\`, `state\`, `logs\`, `audit\` |
| Task Scheduler `\rc-spawn\StartAll` | at logon: starts the watchdog, which starts the Orchestrator and all enabled servers, then revives dead ones every 2 min |
| `<profile>\skills\rc-spawn` | skill so normal sessions in that profile know the command |

`<profile>` is the Claude profile folder you install into, for example `%USERPROFILE%\.claude-work`.
Its `settings.json` is never changed.

## Phone
Claude app → Code tab → **Orchestrator** → for example: `list` · `start a session in D:\Projects\foo` ·
`start foo with profile personal` · `open D:\x in plan mode` · `logs foo` · `stop foo` · `how's the PC` · `run doctor` ·
`reboot the PC` (code via ntfy) · `lock everything down`.
Alerts and confirm codes go to the **ntfy** app (the topic is in `<profile>\rc\config\notify.json`).

## At the PC
```
rc-spawn help | list --all | doctor --send-test
rc-spawn profiles add personal "$env:USERPROFILE\.claude-personal" --allow-from-phone   # local only (types YES)
rc-spawn approve "D:\path"      # allow a project whose .claude config has hooks/MCP/env
rc-spawn unlock                 # after lockdown (local only)
.\install.ps1 -HomeProfileDir "$env:USERPROFILE\.claude-work"     # upgrade after editing src (keeps config/state)
.\uninstall.ps1 -HomeProfileDir "$env:USERPROFILE\.claude-work" [-RemoveTrust] [-KeepLogs]
```

## Rules enforced in code
- **Folders:** any folder on a fixed drive, except drive roots, Windows/Program Files/ProgramData, other users,
  your home folder itself, AppData, .ssh/.aws/.config/.local…, every `.claude*` profile, claude-hub*, this source
  folder, the rc install, your denylist, and any folder that **contains** one of these. Junctions are resolved, and
  the real target is checked.
- **Project config:** folders whose `.claude/settings*.json` or `.mcp.json` turn on hooks/MCP/env/plugins must be
  approved first (with a code from the phone).
- **Permission modes:** never `bypassPermissions` or `dontAsk`. The default is `default`.
- **Orchestrator:** runs in `default` mode, with only `rc-spawn` allowed plus a guard hook that blocks everything else,
  including chained commands. It can't edit files.
- **Profiles:** only registered profiles can be used. A non-home profile needs `allowFromPhone`. A profile signed in
  to a different account needs a code, and its sessions show only in that account's app.
- **Local only:** `profiles add/remove` and `unlock` are refused when called from any Claude session.
- **Codes:** `reboot`, `stop --all`, `denylist remove`, `approve` and cross-account starts send a 6-digit code to ntfy.

## Known limits
- Team/Enterprise orgs may require **Trusted Devices**. The PC enrolls when you sign in to the CLI, and the phone enrolls on first use.
- Without Autologon, a reboot waits at the sign-in screen and nothing starts until you log in.
- Same-user isolation: a session that can run arbitrary shell commands as you could in principle edit `rc\config`.
  The guard keeps the Orchestrator from doing this, but other auto-mode sessions are not sandboxed.
