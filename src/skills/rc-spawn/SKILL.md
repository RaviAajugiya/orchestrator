---
name: rc-spawn
description: Start/stop/list Claude Code Remote Control servers on this PC (phone control). Use when the user asks to open a session in a folder, list or stop remote sessions, or check the orchestrator.
---

`rc-spawn` manages Remote Control servers for this PC (installed in the `rc` folder of this Claude profile).
Never run `claude remote-control` directly and never edit anything under that `rc` folder.

Common commands (run `rc-spawn help` for all):
- `rc-spawn list` — servers and their state
- `rc-spawn start "D:\path\to\folder" [--profile P] [--permission-mode plan]`
- `rc-spawn stop <name>` · `rc-spawn restart <name>` · `rc-spawn logs <name>`
- `rc-spawn doctor` — health of the whole setup
- `rc-spawn history [--profile P] [--search X]` · `rc-spawn resume <n|id>` — continue a past chat on the phone
- `rc-spawn sessions` · `rc-spawn end <n|id>` — list / stop running background chats (history kept)

Outside the Orchestrator session, starting/stopping servers changes what is reachable from the phone,
so ask the user before running mutating commands.
