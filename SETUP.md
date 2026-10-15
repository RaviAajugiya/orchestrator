# Setup

About 10 minutes. Windows 10/11 only.

## 1. Requirements
- **Claude Code CLI**, native (`%USERPROFILE%\.local\bin\claude.exe`) or npm
  (`npm i -g @anthropic-ai/claude-code`). Check with `claude --version`.
- **Node.js** on PATH (`node --version`).
- A **claude.ai account** (Pro/Max/Team/Enterprise). Remote Control does not work with API-key login, and
  `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` must **not** be set as user or system environment variables.
- **Claude app** on your phone, signed in to the same account.
- Optional, but recommended: the **ntfy** app (https://ntfy.sh) for alerts and 6-digit confirm codes.

## 2. Create a dedicated Claude profile
rc-spawn refuses to install into the default `~\.claude`, so it gets its own profile folder.
Pick a short name (lowercase letters, digits, `-` or `_`). This guide uses `work`.

```powershell
$env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-work"
claude            # sign in with your claude.ai account, accept the prompts, then /exit
```
Make sure `%USERPROFILE%\.claude-work\settings.json` exists. If it doesn't, create it with the content `{}`.

## 3. Install
Clone (or unzip) this repo somewhere permanent, for example `D:\Tools\orchestrator`. The install points back to it.
In a **normal (non-admin) PowerShell**:

```powershell
git clone <repo-url> D:\Tools\orchestrator
cd D:\Tools\orchestrator
Get-ChildItem -Recurse | Unblock-File          # files from a zip/download are blocked by Windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -HomeProfileDir "$env:USERPROFILE\.claude-work"
```

What it does:
- copies the code to `%USERPROFILE%\.claude-work\rc\`
- adds `rc\bin` to your user PATH
- registers a logon task `\rc-spawn\StartAll`, or a Startup-folder shortcut if task registration fails
- installs the `rc-spawn` skill into the profile
- starts the watchdog, which brings the **Orchestrator** up within about 30 seconds

The profile name is taken from the folder name (`.claude-work` → `work`). Pass `-HomeProfileName` to override it.
Other switches: `-NoTasks -NoPath -NoStart -NoSkill`, and `-ClaudePath <claude.exe>` if Claude isn't found.

## 4. Check it
Open a **new** terminal (to pick up the PATH change):
```powershell
rc-spawn doctor
rc-spawn list
```
Everything should be `OK`. Fix any `FAIL` lines before continuing.

## 5. Phone
1. Claude app → **Code** tab → you should see **Orchestrator** under your PC.
2. Say `list`, then try `start a session in D:\Projects\something`.
3. Open the new session it names, in the same Code tab.

## 6. Notifications (recommended)
1. Install the ntfy app and subscribe to the topic in `%USERPROFILE%\.claude-work\rc\config\notify.json`.
   Treat this topic like a password: anyone who knows it can read your codes.
2. Set `"enabled": true` in that file.
3. Run `rc-spawn doctor --send-test`. A test message should arrive on your phone.

Without ntfy, the commands that need a code (`reboot`, `stop --all`, `approve`, `denylist remove`) can only be done at the PC.

## 7. Optional extras
- **More profiles** (for example a second account): create it as in step 2, then at the PC run
  `rc-spawn profiles add personal "$env:USERPROFILE\.claude-personal" --allow-from-phone`.
- **Never open a folder:** `rc-spawn denylist add "D:\secret"`.
- **Short names:** `rc-spawn alias add api "D:\Projects\my-api"`.
- **Auto-start after reboot** needs Windows to sign in automatically (for example Sysinternals Autologon).
  Otherwise everything starts when you log in.

## Upgrade / uninstall
```powershell
# after replacing the files in this folder with a newer copy:
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -HomeProfileDir "$env:USERPROFILE\.claude-work"
# remove everything (the profile's settings.json is never touched):
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -HomeProfileDir "$env:USERPROFILE\.claude-work"
```

## Troubleshooting
| Symptom | Fix |
|---|---|
| `does not look like a Claude profile` | create `settings.json` (`{}`) in the profile folder |
| `claude.exe not found` | pass `-ClaudePath "C:\path\to\claude.exe"` |
| `rc-spawn` not recognized | open a new terminal, or install without `-NoPath` |
| Orchestrator missing on the phone | `rc-spawn doctor`, then `rc-spawn logs orchestrator`; check the CLI is signed in with `claude auth status` (with `CLAUDE_CONFIG_DIR` set) |
| `AUTH_FAIL` / `not enrolled` | sign in again in that profile (step 2); Team orgs: complete Trusted Device enrollment |
| `Workspace not trusted` | run `claude` once in that folder with the same profile and accept the trust prompt |
| `... set at User scope (Remote Control will refuse)` | remove that environment variable, then sign out of Windows and back in |
| Scripts blocked | `Get-ChildItem -Recurse \| Unblock-File` in this folder |
