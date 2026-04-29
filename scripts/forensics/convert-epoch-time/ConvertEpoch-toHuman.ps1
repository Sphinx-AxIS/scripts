Get-Content .\epochs.txt | ForEach-Object {
    [PSCustomObject]@{
        EpochMS = $_
        UTC     = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$_).ToString("yyyy-MM-ddTHH:mm:sszzz")
    }
} | Export-Csv .\converted.csv -NoTypeInformation