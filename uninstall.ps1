#!/usr/bin/env pwsh
# Remove this repo's hook entries from ~/.claude/settings.json.
# Run with: pwsh ./uninstall.ps1

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$onDenied = (Resolve-Path (Join-Path $repoRoot 'hooks/on-denied.ps1')).Path
$onPre    = (Resolve-Path (Join-Path $repoRoot 'hooks/on-pretooluse.ps1')).Path
$targets  = @($onDenied, $onPre)

$userHome     = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$settingsPath = Join-Path $userHome '.claude/settings.json'

if (-not (Test-Path $settingsPath)) {
    Write-Host "No settings.json at $settingsPath; nothing to do."
    return
}

$backup = "$settingsPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $settingsPath $backup
Write-Host "Backed up settings.json -> $backup"

$settings = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json
if (-not $settings.hooks) {
    Write-Host "No hooks section found; nothing to remove."
    return
}

foreach ($event in @('PermissionDenied','PreToolUse')) {
    if (-not ($settings.hooks.PSObject.Properties.Name -contains $event)) { continue }

    $kept = @($settings.hooks.$event | Where-Object {
        $cmds = @($_.hooks | ForEach-Object { $_.command })
        $matches = $false
        foreach ($t in $targets) {
            if ($cmds -match [Regex]::Escape($t)) { $matches = $true; break }
        }
        -not $matches
    })

    if ($kept.Count -eq 0) {
        $settings.hooks.PSObject.Properties.Remove($event)
        Write-Host "Removed empty $event hook block."
    } else {
        $settings.hooks.$event = $kept
        Write-Host "Pruned $event entries pointing at this repo."
    }
}

$settings | ConvertTo-Json -Depth 30 | Set-Content -Path $settingsPath -Encoding utf8

# Remove the retry-contract block from CLAUDE.md if present
$claudeDir = Join-Path $userHome '.claude'
$beginMarker = '<!-- BEGIN: claude-allow-denied-hook -->'
$endMarker   = '<!-- END: claude-allow-denied-hook -->'
foreach ($n in @('CLAUDE.md','claude.md','Claude.md')) {
    $p = Join-Path $claudeDir $n
    if (-not (Test-Path $p)) { continue }
    $c = Get-Content -Raw -Path $p
    if ($c -notmatch [Regex]::Escape($beginMarker)) { continue }
    $pattern = '(?s)\r?\n?' + [Regex]::Escape($beginMarker) + '.*?' + [Regex]::Escape($endMarker) + '\r?\n?'
    $new = [Regex]::Replace($c, $pattern, '')
    Set-Content -Path $p -Value $new -Encoding utf8
    Write-Host "Removed retry-contract block from $p."
    break
}

Write-Host "Done."
