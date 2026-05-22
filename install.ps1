#!/usr/bin/env pwsh
# Cross-platform installer for the claude-allow-denied-hook.
# Adds PermissionDenied + PreToolUse entries to ~/.claude/settings.json
# pointing at this repo's hooks/ scripts. Backs up settings.json first.
# Run with: pwsh ./install.ps1   (works on Windows, macOS, Linux)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hooksDir = Join-Path $repoRoot 'hooks'
$onDenied = (Resolve-Path (Join-Path $hooksDir 'on-denied.ps1')).Path
$onPre    = (Resolve-Path (Join-Path $hooksDir 'on-pretooluse.ps1')).Path

$userHome     = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$claudeDir    = Join-Path $userHome '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'

if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

if (Test-Path $settingsPath) {
    $raw = Get-Content -Raw -Path $settingsPath
    $backup = "$settingsPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $settingsPath $backup
    Write-Host "Backed up existing settings.json -> $backup"
    $settings = $raw | ConvertFrom-Json
} else {
    Write-Host "No existing settings.json; creating one."
    $settings = [pscustomobject]@{}
}

function Ensure-Property {
    param($Obj, [string]$Name, $Default)
    if (-not ($Obj.PSObject.Properties.Name -contains $Name)) {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Default
    }
}

Ensure-Property -Obj $settings -Name 'hooks' -Default ([pscustomobject]@{})

function Build-HookEntry {
    param([string]$ScriptPath)
    [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{
                type    = 'command'
                command = "pwsh -NoProfile -File `"$ScriptPath`""
                shell   = 'powershell'
                timeout = 120
            }
        )
    }
}

function Set-EventEntry {
    param($HooksObj, [string]$EventName, [string]$ScriptPath)

    $entry = Build-HookEntry -ScriptPath $ScriptPath

    if ($HooksObj.PSObject.Properties.Name -contains $EventName) {
        $existing = @($HooksObj.$EventName)

        # Drop any prior entry that points at the same script (idempotent reinstall)
        $filtered = @($existing | Where-Object {
            $cmds = @($_.hooks | ForEach-Object { $_.command })
            -not ($cmds -match [Regex]::Escape($ScriptPath))
        })

        $HooksObj.$EventName = @($filtered + $entry)
    } else {
        $HooksObj | Add-Member -NotePropertyName $EventName -NotePropertyValue @($entry)
    }
}

Set-EventEntry -HooksObj $settings.hooks -EventName 'PermissionDenied' -ScriptPath $onDenied
Set-EventEntry -HooksObj $settings.hooks -EventName 'PreToolUse'       -ScriptPath $onPre

$json = $settings | ConvertTo-Json -Depth 30
$json | Set-Content -Path $settingsPath -Encoding utf8

function Update-ClaudeMd {
    param([string]$ClaudeDir, [string]$RepoRoot)

    $bt = [char]0x60   # backtick, kept out of the here-string to avoid pwsh escaping
    $beginMarker = '<!-- BEGIN: claude-allow-denied-hook -->'
    $endMarker   = '<!-- END: claude-allow-denied-hook -->'

    $block = @"
$beginMarker
### auto-mode denial retry contract

Two custom Claude Code hooks installed from the repo at ${bt}$RepoRoot${bt} (${bt}hooks/on-denied.ps1${bt} on ${bt}PermissionDenied${bt}, ${bt}hooks/on-pretooluse.ps1${bt} on ${bt}PreToolUse${bt}) let me override ${bt}Denied by auto mode classifier${bt} via a Yes/No desktop dialog. Approving writes the exact ${bt}(tool_name, tool_input)${bt} pair to a per-session allowlist at ${bt}~/.claude/hooks/session-allows-<session_id>.jsonl${bt}; the PreToolUse hook then auto-allows future calls in this session that match that pair **byte-for-byte**.

When a tool call is denied and Claude Code surfaces ${bt}retry: true${bt}, I MUST retry with **identical** ${bt}tool_name${bt} and **identical** ${bt}tool_input${bt} — no rephrasing the bash command, no edits to ${bt}description${bt}, no whitespace tweaks, no swapping ${bt}tail -3${bt} for ${bt}tail -5${bt}, no adding/removing ${bt}2>&1${bt}, nothing. Any change breaks the allowlist match and the classifier denies the retry. If a retry feels wrong to repeat verbatim, do not retry — ask the user instead.
$endMarker
"@

    $candidates = @('CLAUDE.md','claude.md','Claude.md')
    $mdPath = $null
    foreach ($n in $candidates) {
        $p = Join-Path $ClaudeDir $n
        if (Test-Path $p) { $mdPath = $p; break }
    }
    if (-not $mdPath) { $mdPath = Join-Path $ClaudeDir 'CLAUDE.md' }

    if (-not (Test-Path $mdPath)) {
        Set-Content -Path $mdPath -Value ($block + "`n") -Encoding utf8
        Write-Host "Created $mdPath with retry-contract block."
        return
    }

    $content = Get-Content -Raw -Path $mdPath

    if ($content -match [Regex]::Escape($beginMarker)) {
        $pattern = '(?s)' + [Regex]::Escape($beginMarker) + '.*?' + [Regex]::Escape($endMarker)
        # Use a scriptblock for the replacement to avoid regex backref interpretation in $block
        $new = [Regex]::Replace($content, $pattern, { param($m) $block })
        Set-Content -Path $mdPath -Value $new -Encoding utf8
        Write-Host "Updated retry-contract block in $mdPath."
        return
    }

    # Legacy: a pre-marker section may already exist. Replace from heading to next ## heading or EOF.
    $legacyPattern = '(?ms)^### auto-mode denial retry contract.*?(?=^\#\#)|^### auto-mode denial retry contract.*\z'
    if ([Regex]::IsMatch($content, $legacyPattern)) {
        $new = [Regex]::Replace($content, $legacyPattern, { param($m) $block + "`n`n" })
        Set-Content -Path $mdPath -Value $new -Encoding utf8
        Write-Host "Replaced legacy retry-contract section in $mdPath (markers added)."
        return
    }

    $sep = if ($content.EndsWith("`n")) { "`n" } else { "`n`n" }
    Set-Content -Path $mdPath -Value ($content + $sep + $block + "`n") -Encoding utf8
    Write-Host "Appended retry-contract block to $mdPath."
}

Update-ClaudeMd -ClaudeDir $claudeDir -RepoRoot $repoRoot

Write-Host ""
Write-Host "Installed hooks into $settingsPath :"
Write-Host "  PermissionDenied -> $onDenied"
Write-Host "  PreToolUse       -> $onPre"
Write-Host ""
Write-Host "Open /hooks in Claude Code (or restart) to pick up the new settings."
