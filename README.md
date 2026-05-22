# claude-allow-denied-hook

A pair of Claude Code hooks that let you override `Denied by auto mode classifier`
via a desktop Yes/No dialog, and remember the approval for the rest of the session.

Cross-platform: Windows, macOS, and Linux (via zenity). Pure PowerShell —
installer uses `pwsh`, which runs on every OS.

## How it works

1. Claude tries a tool call in auto mode.
2. The auto-mode classifier denies it.
3. **`PermissionDenied`** hook → `on-denied.ps1` pops a Yes/No dialog showing
   the tool name, the classifier's reason, and the full input.
4. Click **Yes** → the exact `(tool_name, tool_input)` pair is appended to a
   per-session allowlist file (`~/.claude/hooks/session-allows-<session_id>.jsonl`),
   and the hook returns `retry: true` so Claude retries the call.
5. **`PreToolUse`** hook → `on-pretooluse.ps1` runs on the retry (and on every
   later call in the same session). If the current call matches an approved
   entry byte-for-byte, the hook emits `permissionDecision: allow` and the
   classifier never runs.

Net effect: one Yes click approves the operation for the rest of the session.
A new session starts fresh.

## Install

You need [PowerShell 7+](https://github.com/PowerShell/PowerShell) on macOS/Linux.
Windows ships with `pwsh` available.

```bash
git clone <this-repo> claude-allow-denied-hook
cd claude-allow-denied-hook
pwsh ./install.ps1
```

The installer:
- Backs up `~/.claude/settings.json` (timestamped `.bak` file).
- Adds `PermissionDenied` and `PreToolUse` entries pointing at this repo's hooks.
- Is idempotent — running it again replaces this repo's entries in place rather
  than duplicating them.

After install, open `/hooks` in Claude Code (or restart) so the settings watcher
picks up the change.

## Uninstall

```bash
pwsh ./uninstall.ps1
```

Removes only the entries that point at this repo. Other hooks in your
`settings.json` are left alone.

## Caveats

- **Auto mode only.** `PermissionDenied` only fires when the auto-mode classifier
  rejects a tool call. In `default` / `plan` mode, denials are user-driven and
  this hook is dead code.
- **Byte-for-byte matching.** The session allowlist stores the exact JSON of the
  approved `tool_input`. When Claude is told to retry via `retry: true`, the
  *model* decides what to retry — including possibly rephrasing the command.
  A rephrased retry won't match the allowlist. Mitigation: drop a note into
  your `CLAUDE.md` telling Claude that, after `retry: true`, it MUST retry the
  identical `tool_name` and `tool_input` — no rephrasing, whitespace tweaks,
  or `description` edits.
- **Some denials are sticky.** Destructive operations on shared infrastructure
  (deleting cloud resources, force-pushing, etc.) may continue to be denied
  even after approval if the classifier escalates its reasoning. The
  `PreToolUse` allowlist bypasses the classifier on subsequent identical
  calls, so the practical workaround is: approve once, then any later
  identical retry in the session passes through silently.
- **macOS dialog** uses `osascript`'s `display dialog`. Linux requires
  `zenity` for the dialog; without it the hook auto-answers "No".

## Files

```
hooks/
  on-denied.ps1        # PermissionDenied handler (dialog + allowlist write)
  on-pretooluse.ps1    # PreToolUse handler      (allowlist match -> allow)
install.ps1            # Adds entries to ~/.claude/settings.json
uninstall.ps1          # Removes entries from ~/.claude/settings.json
```

The hooks read/write `~/.claude/hooks/` for their state files:

```
~/.claude/hooks/session-allows-<session_id>.jsonl   # one approval per line
~/.claude/hooks/logs/last-denial.json               # most recent denial payload
```

## License

MIT
