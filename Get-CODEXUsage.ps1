param(
    [string]$SessionFile,
    [int]$RecentEventsForAverage = 5
)

function Convert-FromUnixTime {
    param($UnixTime)

    if ($null -eq $UnixTime -or $UnixTime -eq '' -or [double]$UnixTime -le 0) {
        return $null
    }

    try {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixTime).ToLocalTime().DateTime
    }
    catch {
        return $null
    }
}

function Format-Number {
    param([Nullable[double]]$Value)

    if ($null -eq $Value) {
        return "N/A"
    }

    return "{0:N0}" -f $Value
}

function Format-Percent {
    param([Nullable[double]]$Value)

    if ($null -eq $Value) {
        return "N/A"
    }

    return "{0:N1}%" -f $Value
}

function Get-HeatLevel {
    param(
        [double]$LastTotalTokens,
        [double]$ContextPercent,
        [double]$PrimaryUsedPercent
    )

    if ($LastTotalTokens -ge 100000 -or $ContextPercent -ge 80 -or $PrimaryUsedPercent -ge 80) {
        return "HOT"
    }
    elseif ($LastTotalTokens -ge 50000 -or $ContextPercent -ge 60 -or $PrimaryUsedPercent -ge 50) {
        return "WARM"
    }
    else {
        return "COOL"
    }
}

try {
    if (-not $SessionFile) {
        $sessionsRoot = Join-Path $HOME ".codex\sessions"

        if (-not (Test-Path $sessionsRoot)) {
            throw "Codex sessions directory not found: $sessionsRoot"
        }

        $SessionFile = Get-ChildItem -Path $sessionsRoot -Filter *.jsonl -Recurse -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not (Test-Path $SessionFile)) {
        throw "Session file not found: $SessionFile"
    }

    $tokenEvents = foreach ($line in Get-Content -Path $SessionFile) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop

            if ($obj.payload.type -eq "token_count") {
                [PSCustomObject]@{
                    Timestamp   = [datetime]$obj.timestamp
                    Info        = $obj.payload.info
                    RateLimits  = $obj.payload.rate_limits
                }
            }
        }
        catch {
            # Ignore malformed/non-JSON lines
        }
    }

    if (-not $tokenEvents -or $tokenEvents.Count -eq 0) {
        throw "No token_count events found in: $SessionFile"
    }
	
function Format-TimeSpan {
    param($Span)

    if ($null -eq $Span) {
        return "N/A"
    }

    if ($Span.TotalSeconds -lt 0) {
        return "expired"
    }

    return "{0:%d}d {0:hh}h {0:mm}m {0:ss}s" -f $Span
}

$latest = $tokenEvents[-1]
$recent = $tokenEvents | Select-Object -Last $RecentEventsForAverage

$total = $latest.Info.total_token_usage
$last  = $latest.Info.last_token_usage
$ctxWindow = [double]$latest.Info.model_context_window

$effectiveLastInput = [double]$last.input_tokens - [double]$last.cached_input_tokens
$contextPercent = if ($ctxWindow -gt 0) { ([double]$total.total_tokens / $ctxWindow) * 100 } else { 0 }

$primaryReset   = Convert-FromUnixTime $latest.RateLimits.primary.resets_at
$secondaryReset = Convert-FromUnixTime $latest.RateLimits.secondary.resets_at

$now = [datetime]::Now

$primaryTimeRemaining = if ($primaryReset) {
    New-TimeSpan -Start $now -End ([datetime]$primaryReset)
} else {
    $null
}

$secondaryTimeRemaining = if ($secondaryReset) {
    New-TimeSpan -Start $now -End ([datetime]$secondaryReset)
} else {
    $null
}

$recentTotals = $recent | ForEach-Object { [double]$_.Info.last_token_usage.total_tokens }

$avgRecentTotal = if ($recentTotals.Count -gt 0) {
    ($recentTotals | Measure-Object -Average).Average
} else {
    $null
}

$maxRecentTotal = if ($recentTotals.Count -gt 0) {
    ($recentTotals | Measure-Object -Maximum).Maximum
} else {
    $null
}

$remainingContext = [double]$ctxWindow - [double]$total.total_tokens

$turnsLeftAtAverage = if ($avgRecentTotal -ne $null -and [double]$avgRecentTotal -gt 0) {
    [math]::Floor($remainingContext / [double]$avgRecentTotal)
} else {
    $null
}

$turnsLeftAtPeak = if ($maxRecentTotal -ne $null -and [double]$maxRecentTotal -gt 0) {
    [math]::Floor($remainingContext / [double]$maxRecentTotal)
} else {
    $null
}

$heat = Get-HeatLevel `
    -LastTotalTokens ([double]$last.total_tokens) `
    -ContextPercent $contextPercent `
    -PrimaryUsedPercent ([double]$latest.RateLimits.primary.used_percent)

Write-Host ""
Write-Host "Codex Session Usage Summary" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "Session file         : $SessionFile"
Write-Host "Latest event time    : $($latest.Timestamp.ToLocalTime())"
Write-Host "Plan type            : $($latest.RateLimits.plan_type)"
Write-Host "Limit ID             : $($latest.RateLimits.limit_id)"
Write-Host "Heat                 : $heat"
Write-Host ""

Write-Host "Context Window"
Write-Host "--------------"
Write-Host ("Model context window : {0}" -f (Format-Number $ctxWindow))
Write-Host ("Total tokens in ctx  : {0}" -f (Format-Number $total.total_tokens))
Write-Host ("Context used         : {0}" -f (Format-Percent $contextPercent))
Write-Host ""

Write-Host "Latest Request"
Write-Host "--------------"
Write-Host ("Input tokens         : {0}" -f (Format-Number $last.input_tokens))
Write-Host ("Cached input tokens  : {0}" -f (Format-Number $last.cached_input_tokens))
Write-Host ("Effective new input  : {0}" -f (Format-Number $effectiveLastInput))
Write-Host ("Output tokens        : {0}" -f (Format-Number $last.output_tokens))
Write-Host ("Reasoning tokens     : {0}" -f (Format-Number $last.reasoning_output_tokens))
Write-Host ("Last request total   : {0}" -f (Format-Number $last.total_tokens))
Write-Host ""

Write-Host "Session Totals"
Write-Host "--------------"
Write-Host ("Total input tokens   : {0}" -f (Format-Number $total.input_tokens))
Write-Host ("Total cached input   : {0}" -f (Format-Number $total.cached_input_tokens))
Write-Host ("Total output tokens  : {0}" -f (Format-Number $total.output_tokens))
Write-Host ("Total reasoning tok  : {0}" -f (Format-Number $total.reasoning_output_tokens))
Write-Host ("Grand total tokens   : {0}" -f (Format-Number $total.total_tokens))
Write-Host ""

Write-Host "Recent Burn Rate"
Write-Host "----------------"
Write-Host ("Average last {0} req : {1}" -f $recent.Count, (Format-Number $avgRecentTotal))
Write-Host ("Peak last {0} req    : {1}" -f $recent.Count, (Format-Number $maxRecentTotal))
Write-Host ""

Write-Host "Rate Limits"
Write-Host "-----------"
Write-Host ("Primary used         : {0}" -f (Format-Percent $latest.RateLimits.primary.used_percent))
Write-Host ("Primary window       : {0} minutes" -f $latest.RateLimits.primary.window_minutes)
Write-Host ("Primary resets at    : {0}" -f $(if ($primaryReset) { $primaryReset } else { "N/A" }))
Write-Host ("Primary resets in    : {0}" -f (Format-TimeSpan $primaryTimeRemaining))
Write-Host ("Secondary used       : {0}" -f (Format-Percent $latest.RateLimits.secondary.used_percent))
Write-Host ("Secondary window     : {0} minutes" -f $latest.RateLimits.secondary.window_minutes)
Write-Host ("Secondary resets at  : {0}" -f $(if ($secondaryReset) { $secondaryReset } else { "N/A" }))
Write-Host ("Secondary resets in  : {0}" -f (Format-TimeSpan $secondaryTimeRemaining))
Write-Host ("Credits              : {0}" -f $(if ($null -ne $latest.RateLimits.credits) { $latest.RateLimits.credits } else { "N/A" }))
Write-Host ("Remaining ctx tokens : {0}" -f (Format-Number $remainingContext))
Write-Host ("Turns left @ avg burn: {0}" -f $(if ($turnsLeftAtAverage -ne $null) { $turnsLeftAtAverage } else { "N/A" }))
Write-Host ("Turns left @ peak burn: {0}" -f $(if ($turnsLeftAtPeak -ne $null) { $turnsLeftAtPeak } else { "N/A" }))

if ($turnsLeftAtPeak -ne $null -and $turnsLeftAtPeak -le 0) {
    Write-Host "Warning: one more peak-sized request may exceed remaining context." -ForegroundColor Yellow
}

Write-Host ""

Write-Host "Rule of Thumb"
Write-Host "-------------"
if ($contextPercent -ge 80) {
    Write-Host "You are close to the context ceiling. Expect truncation or limit pressure soon." -ForegroundColor Yellow
}
elseif ([double]$last.total_tokens -ge 50000) {
    Write-Host "Your last request was large. You are burning hot." -ForegroundColor Yellow
}
elseif ([double]$latest.RateLimits.primary.used_percent -ge 80) {
    Write-Host "You are close to the primary rate limit window." -ForegroundColor Yellow
}
else {
    Write-Host "Usage looks moderate right now." -ForegroundColor Green
}
}
catch {
    Write-Error $_
}