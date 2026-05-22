#!/usr/bin/env pwsh
# Claude Code PreToolUse hook.
# Reads the per-session allowlist written by on-denied.ps1 and emits
# permissionDecision=allow when the current (tool_name, tool_input) pair
# matches an approved entry byte-for-byte. The classifier never runs in
# that case.

$ErrorActionPreference = 'Stop'

$raw  = [Console]::In.ReadToEnd()
$data = $raw | ConvertFrom-Json

$sessionId = $data.session_id
if (-not $sessionId) { exit 0 }

$userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$allowsFile = Join-Path $userHome ".claude/hooks/session-allows-$sessionId.jsonl"
if (-not (Test-Path $allowsFile)) { exit 0 }

$key = "$($data.tool_name)|" + ($data.tool_input | ConvertTo-Json -Depth 10 -Compress)

foreach ($line in Get-Content $allowsFile) {
    if ($line -eq $key) {
        @{
            hookSpecificOutput = @{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'allow'
                permissionDecisionReason = 'Approved earlier in this session via on-denied dialog'
            }
        } | ConvertTo-Json -Compress -Depth 6
        exit 0
    }
}
