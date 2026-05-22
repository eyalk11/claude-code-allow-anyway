#!/usr/bin/env pwsh
# Claude Code PermissionDenied hook.
# Pops a Yes/No dialog when the auto-mode classifier denies a tool call.
# On Yes: appends (tool_name, tool_input) to a per-session allowlist
#         and returns retry:true so the model retries.
# The companion PreToolUse hook (on-pretooluse.ps1) honors the allowlist
# on the retry (and on any later identical call within the same session).

$ErrorActionPreference = 'Stop'

$raw  = [Console]::In.ReadToEnd()
$data = $raw | ConvertFrom-Json

$toolName  = $data.tool_name
$sessionId = $data.session_id
$reason    = $data.permission_denial_reason
if (-not $reason) { $reason = $data.reason }
if (-not $reason) { $reason = '(no reason given)' }

$userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$hookDir = Join-Path $userHome '.claude/hooks'
$logDir  = Join-Path $hookDir 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$raw | Out-File -FilePath (Join-Path $logDir 'last-denial.json') -Encoding utf8

$inputJsonPretty = $data.tool_input | ConvertTo-Json -Depth 10
$preview = $inputJsonPretty
if ($preview.Length -gt 1200) { $preview = $preview.Substring(0, 1200) + "`n... (truncated)" }

$title = "Claude: allow denied $toolName ?"
$msg = @"
Claude tool call was denied by the auto-mode classifier.

Tool: $toolName

Reason:
$reason

Input:
$preview

Allow this and let Claude retry?
(Future calls in THIS SESSION with the same tool+input will auto-allow with no dialog.)
"@

function Show-YesNo {
    param([string]$Title, [string]$Message)

    $isWin = $IsWindows -or ($PSVersionTable.Platform -eq $null) -or ($PSVersionTable.Platform -eq 'Win32NT')

    if ($isWin) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $r = [System.Windows.Forms.MessageBox]::Show(
            $Message, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        return $r -eq [System.Windows.Forms.DialogResult]::Yes
    }

    if ($IsMacOS) {
        $lines = $Message -split "`r?`n"
        $expr  = ($lines | ForEach-Object {
            '"' + (($_ -replace '\\','\\\\') -replace '"','\"') + '"'
        }) -join ' & linefeed & '
        $titleEsc = ($Title -replace '\\','\\\\') -replace '"','\"'

        $script = "display dialog $expr buttons {`"No`",`"Yes`"} default button `"No`" with title `"$titleEsc`" with icon caution"
        $out = $script | & osascript - 2>$null
        return ($out -match 'Yes')
    }

    # Linux: zenity if available, else default to No
    if (Get-Command zenity -ErrorAction SilentlyContinue) {
        & zenity --question --title=$Title --text=$Message
        return $LASTEXITCODE -eq 0
    }
    return $false
}

if (Show-YesNo -Title $title -Message $msg) {
    $key        = "$toolName|" + ($data.tool_input | ConvertTo-Json -Depth 10 -Compress)
    $allowsFile = Join-Path $hookDir "session-allows-$sessionId.jsonl"
    Add-Content -Path $allowsFile -Value $key -Encoding utf8

    @{
        hookSpecificOutput = @{
            hookEventName = 'PermissionDenied'
            retry         = $true
        }
    } | ConvertTo-Json -Compress -Depth 6
}
