<#
.SYNOPSIS
    Converts epoch-millisecond timestamps to UTC ISO-8601 and writes a CSV.
.DESCRIPTION
    Reads one epoch-millisecond integer per line from -InputPath and writes
    a two-column CSV (EpochMS, UTC) to -OutputPath.
.EXAMPLE
    .\ConvertEpoch-toHuman.ps1 -InputPath .\epochs.txt -OutputPath .\converted.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Get-Content -LiteralPath $InputPath | ForEach-Object {
    [PSCustomObject]@{
        EpochMS = $_
        UTC     = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$_).ToString("yyyy-MM-ddTHH:mm:sszzz")
    }
} | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
