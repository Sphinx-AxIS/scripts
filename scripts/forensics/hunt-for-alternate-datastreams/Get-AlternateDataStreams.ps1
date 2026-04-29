<#
.SYNOPSIS
    Lists and prints contents of NTFS alternate data streams on a target file.
.DESCRIPTION
    Enumerates streams attached to -Path and writes each non-default stream's
    name, size header, and raw contents to the console. Skips the default
    unnamed $DATA stream.
.EXAMPLE
    .\Get-AlternateDataStreams.ps1 -Path "C:\path\to\file.exe"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
)

Get-Item -LiteralPath $Path -Stream * |
  Where-Object { $_.Stream -notin @('::$DATA',':$DATA','$DATA') } |
  ForEach-Object {
    "`n==== [$($_.Stream)] ($(($_.Length)) bytes) ===="
    Get-Content -LiteralPath $Path -Stream $_.Stream -Raw
  }
