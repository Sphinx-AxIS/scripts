param(
    # These paths are now required inputs, with no default values.
    [Parameter(Mandatory=$true)]
    [string]$JsonDirPath,

    [Parameter(Mandatory=$true)]
    [string]$ProcessSummaryCsvPath,

    [Parameter(Mandatory=$true)]
    [string]$CombinedEventsCsvPath,
    
    [Parameter(Mandatory=$true)]
    [string]$SeenEventsFilePath,

    # This is an operational tweak, so it's fine to keep a default value.
    [int]$FlushEvery = 10000
)
<#
param(
    [string]$JsonDir            = 'H:\Cb_query_results\json_proc_docs\',
    [string]$ProcSummaryCsv     = 'H:\Cb_query_results\process_summary.csv',
    [string]$EventsCsv          = 'H:\Cb_query_results\combined_sorted_events.csv',
    [string]$SeenEventsPath     = 'H:\Cb_query_results\seen_events.keys',
    [int]$FlushEvery            = 10000          # flush buffer + seen-keys every N events
)
#>
Clear-Host
$ErrorActionPreference = 'Stop'

# --- Helpers -------------------------------------------------------------

function Convert-SignedIntIPaddr {
    param([Parameter(Mandatory)][long]$x)
    if ($null -eq $x) { return $null }
    $tmp = [int64]$x
    $octets = 0..3 | ForEach-Object { $tmp -band 0xFF; $tmp = $tmp -shr 8 }
    return ($octets[3..0] -join '.')
}

function Format-CBDateTime {
    param([object]$InputValue)

    if ($null -eq $InputValue) { return $null }

    # If already a DateTime, just format it
    if ($InputValue -is [datetime]) {
        return $InputValue.ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss.fff")
    }

    # Handle wrapped datetime
    if ($InputValue.PSObject -and $InputValue.PSObject.BaseObject -is [datetime]) {
        $dt = [datetime]$InputValue.PSObject.BaseObject
        return $dt.ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss.fff")
    }

    $s = $InputValue.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }

    # Allow already formatted output
    try {
        $dtAlready = [datetime]::ParseExact(
            $s,
            "MM/dd/yyyy HH:mm:ss.fff",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )
        return $dtAlready.ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss.fff")
    } catch { }

    $formats = @(
        # Process Summary (ISO)
        "yyyy-MM-ddTHH:mm:ssZ",
        "yyyy-MM-ddTHH:mm:ss.fffZ",
        "yyyy-MM-ddTHH:mm:ss.ffffffZ",
        "o",

        # Sorted Events
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.fff",
        "yyyy-MM-dd HH:mm:ss.ffffff"
    )

    foreach ($fmt in $formats) {
        try {
            $dt = [datetime]::ParseExact(
                $s,
                $fmt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal
            )
            return $dt.ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss.fff")
        } catch { }
    }

    return $null
}


# PowerShell 5.1-safe: no ternary operator anywhere
function Get-EventKey {
    param(
        [Parameter(Mandatory)]$procData,
        [Parameter(Mandatory)]$event
    )

    if ($event.event_id) { return "$($event.event_id)" }

    $pg  = $procData.id
    $seg = $procData.segment_id
    $typ = $event.type

    # Standardize on sorted_events[].time
    $t = $event.time
    if (-not $t) { $t = $event.'@timestamp' }  # optional fallback

    # discriminator per type (helps prevent duplicates)
    $discrim = $null
    switch ($typ) {
        'childproc' {
            if ($event.data) { $discrim = $event.data.path }
        }
        'netconn' {
            if ($event.data) { $discrim = ('{0}>{1}:{2}' -f $event.data.local_ip, $event.data.remote_ip, $event.data.remote_port) }
        }
        'filemod' {
            if ($event.data -is [string]) { $discrim = ($event.data -split '\|')[2] }
        }
        'regmod' {
            if ($event.data -is [string]) { $discrim = ($event.data -split '\|')[2] }
        }
        'modload' {
            if ($event.data -is [string]) { $discrim = ($event.data -split '\|')[2] }
        }
        'crossproc' {
            if ($event.data -is [string]) { $discrim = ($event.data -split '\|')[4] }
        }
        default { $discrim = $null }
    }

    return "$pg|$seg|$typ|$t|$discrim"
}

function Save-Seen {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$SeenSet,
        [Parameter(Mandatory)][string]$Path
    )
    $tmp = "$Path.tmp"
    $SeenSet | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $Path
}

# --- Init state ----------------------------------------------------------

# Durable seen-events set (prevents duplicates across reruns)
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path -LiteralPath $SeenEventsFilePath) {
    [void]$seen.UnionWith([string[]](Get-Content -LiteralPath $SeenEventsFilePath))
}

function Write-TextUtf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    
    if ($Text -notmatch "(\r\n|\n)$") {
        $Text += "`r`n"
    }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Ensure-CsvHeaderOnly {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Headers
    )

    $header = ($Headers -join ',')

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-TextUtf8NoBom -Path $Path -Text $header
        return
    }

    $looksLikeHeaderPlusData = $headerLine -match '"'
    $headerLine = Get-Content -LiteralPath $Path -TotalCount 1

    # Detect: blank column, leading/trailing commas, double commas, OR BOM on first header
    $cols = $headerLine -split ','
    $hasBom = ($headerLine.Length -gt 0 -and $headerLine[0] -eq [char]0xFEFF) -or ($cols[0] -like "*start" -and $cols[0] -ne "start")

    if ($cols -contains "" -or $headerLine -match '^,|,$|,,' -or $hasBom -or $looksLikeHeaderPlusData) {
        Remove-Item -LiteralPath $Path -Force
        Write-TextUtf8NoBom -Path $Path -Text $header
    }
}

$procHeaders = @(
    'start','hostname','parent_pid','parent_id','parent_name','process_name','cmdline',
    'username','path','process_pid','interface_ip','comms_ip','id','segment_id','sensor_id',
    'os_type','host_type','process_md5','modload_count','filemod_count','netconn_count',
    'childproc_count','last_update','last_server_update','fileless_scriptload_count',
    'regmod_count','crossproc_count','total_events_count','min_last_server_update',
    'max_last_server_update','min_last_update','max_last_update','fork_children_count',
    'exec_events_count','sorted_events_count'
)

$eventHeaders = @(
    'type','procstart','data_lastUpdated','parent_name','parent_pid','proc_name','pid','action',
    'event_time','target_name','target_pid','path','parent_id','processId','proc_segment_id',
    'target_Id','start_time','end_time','commandLine','userName','userSID','event_segment_id',
    'sub_type','requested_access','tampered','flex','proto','domain','local_ip','local_port',
    'remote_ip','remote_port','unique_id','md5_ja3','sha256_ja3s'
)

Ensure-CsvHeaderOnly -Path $ProcessSummaryCsvPath -Headers $procHeaders
Ensure-CsvHeaderOnly -Path $CombinedEventsCsvPath -Headers $eventHeaders

$buffer = New-Object System.Collections.Generic.List[object]
$processed = 0

# --- Main processing -----------------------------------------------------

Get-ChildItem -LiteralPath $JsonDirPath -Filter *.json -File | ForEach-Object {
    $jsonPath = $_.FullName
    $jsonContent = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

    if (-not (Get-Member -InputObject $jsonContent -Name 'process' -MemberType Properties)) {
        return
    }

    $procData = $jsonContent.process
    $sortedEventsCount = 0
    if ($procData.PSObject.Properties.Match('sorted_events') -and $procData.sorted_events) {
        $sortedEventsCount = $procData.sorted_events.Count
    }

    Write-Host "Processing: $($_.Name)  (sorted_events: $sortedEventsCount)"

    # Normalize IPs if present
    if ($procData.PSObject.Properties.Match('comms_ip') -and $procData.comms_ip -ne $null) {
        # Check if the property is a numeric type. If so, convert it.
        if ($procData.comms_ip -is [long] -or $procData.comms_ip -is [int]) {
            $procData.comms_ip = Convert-SignedIntIPaddr $procData.comms_ip
        }
        # If it's already a string, we assume it's correctly formatted and do nothing.
    }

    if ($procData.PSObject.Properties.Match('interface_ip') -and $procData.interface_ip -ne $null) {
        # Check if the property is a numeric type. If so, convert it.
        if ($procData.interface_ip -is [long] -or $procData.interface_ip -is [int]) {
            $procData.interface_ip = Convert-SignedIntIPaddr $procData.interface_ip
        }
        # If it's already a string, we assume it's correctly formatted and do nothing.
    }

    # Normalize selected times if present
    $procTime = @{}

    foreach ($f in 'start','last_update','last_server_update','min_last_server_update','max_last_server_update','min_last_update','max_last_update') {
        if ($procData.PSObject.Properties.Match($f) -and $procData.$f) {
            $procTime[$f] = Format-CBDateTime $procData.$f
        } else {
            $procTime[$f] = $null
        }
    }


    # Process summary row (append; you can dedupe later if desired)
    $procRow = [pscustomobject]@{
        start                      = $procTime['start']
        hostname                   = $procData.hostname
        parent_pid                 = $procData.parent_pid
        parent_id                  = $procData.parent_id
        parent_name                = $procData.parent_name
        process_name               = $procData.process_name
        cmdline                    = $procData.cmdline
        username                   = $procData.username
        path                       = $procData.path
        process_pid                = $procData.process_pid
        interface_ip               = $procData.interface_ip
        comms_ip                   = $procData.comms_ip
        id                         = $procData.id
        segment_id                 = $procData.segment_id
        sensor_id                  = $procData.sensor_id
        os_type                    = $procData.os_type
        host_type                  = $procData.host_type
        process_md5                = $procData.process_md5
        modload_count              = $procData.modload_count
        filemod_count              = $procData.filemod_count
        netconn_count              = $procData.netconn_count
        childproc_count            = $procData.childproc_count
        last_update                = $procTime['last_update']
        last_server_update         = $procTime['last_server_update']
        fileless_scriptload_count  = $procData.fileless_scriptload_count
        regmod_count               = $procData.regmod_count
        crossproc_count            = $procData.crossproc_count
        total_events_count         = $procData.total_events_count
        min_last_server_update     = $procTime['min_last_server_update']
        max_last_server_update     = $procTime['max_last_server_update']
        min_last_update            = $procTime['min_last_update']
        max_last_update            = $procTime['max_last_update']
        fork_children_count        = $procData.fork_children_count
        exec_events_count          = $procData.exec_events_count
        sorted_events_count        = $sortedEventsCount
    }
#    Write-Host $procRow
#    $hdr = Get-Content -LiteralPath $ProcSummaryCsv -TotalCount 1
#    Write-Host "CSV HEADER RAW: [$hdr]"
#    ($hdr -split ',') | ForEach-Object { Write-Host "COL: [$_]" }
    $procRow | Select-Object $procHeaders | Export-Csv -LiteralPath $ProcessSummaryCsvPath -NoTypeInformation -Append -Encoding UTF8

    # --- Events ---
    $events = $procData.sorted_events
    if ($events -and $events.Count -gt 0) {
        foreach ($event in $events) {
            $key = Get-EventKey -procData $procData -event $event
            if (-not $seen.Add($key)) { continue }  # already emitted before
            $eventTimeFmt = Format-CBDateTime $event.time
            $event | Add-Member -NotePropertyName time_fmt -NotePropertyValue $eventTimeFmt -Force
            # Build object per type (precompute any conditional fields to stay PS 5.1-safe)
            switch ($event.type) {

                'childproc' {
                    $targetname = $null
                    if ($event.data.path) {
                        $targetname = ($event.data.path -split '\\')[-1]
                    }
                    
                    # Decide which field gets the timestamp
                    $startTime = $null
                    $endTime   = $null

                    if ($event.data.type -eq 'start') {
                        $startTime = $event.time_fmt
                    }
                    elseif ($event.data.type -eq 'end') {
                        $endTime = $event.time_fmt
                    }

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $event.data.type
                        event_time        = $event.time_fmt
                        target_name       = $targetname
                        target_pid        = $event.data.pid
                        path              = $event.data.path
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = $event.data.processId
                        start_time        = $startTime
                        end_time          = $endTime
                        commandLine       = $event.data.commandLine
                        userName          = $event.data.userName
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $event.data.type
                        requested_access  = $null
                        tampered          = $event.data.is_tampered
                        flex              = $event.data.is_suppressed
                        proto             = $null
                        domain            = $null
                        local_ip          = $null
                        local_port        = $null
                        remote_ip         = $null
                        remote_port       = $null
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = $event.data.md5
                        sha256_ja3s       = $event.data.sha256
                    }
                    $buffer.Add($obj) | Out-Null
                }

                'netconn' {
                    $actionValue = $event.data.direction
                    if ($actionValue -eq 'true')  { $actionValue = 'Outbound' }
                    elseif ($actionValue -eq 'false') { $actionValue = 'Inbound' }

                    $protoValue = $event.data.proto
                    if ($protoValue -eq '6') { $protoValue = 'TCP' }
                    elseif ($protoValue -eq '1') { $protoValue = 'ICMP' }
                    else { $protoValue = 'UDP' }

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $actionValue
                        event_time        = $event.time_fmt
                        target_name       = $null
                        target_pid        = $null
                        path              = $procData.path
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = $null
                        start_time        = $null
                        end_time          = $null
                        commandLine       = $procData.cmdline
                        userName          = $procData.username
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $event.data.type
                        requested_access  = $event.data.requested_access
                        tampered          = $event.data.is_tampered
                        flex              = $event.data.type
                        proto             = $protoValue
                        domain            = $event.data.domain
                        local_ip          = $event.data.local_ip
                        local_port        = $event.data.local_port
                        remote_ip         = $event.data.remote_ip
                        remote_port       = $event.data.remote_port
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = "ja3:$($event.data.ja3)"
                        sha256_ja3s       = "ja3s:$($event.data.ja3s)"
                    }
                    $buffer.Add($obj) | Out-Null
                }

                'crossproc' {
                    $parts = $null; $targetpath = $null; $targetfile = $null
                    if ($event.data -is [string]) {
                        $parts = $event.data -split '\|'
                        if ($parts.Count -ge 5) { $targetpath = $parts[4] }
                        if ($targetpath) {
                            $targetfile = $targetpath -split '\\'
                            $targetfile = $targetfile[-1]
                        }
                    }
                    $subTypeValue = $null
                    if ($parts -and $parts.Count -ge 6) {
                        if ($parts[5] -eq '1') { $subTypeValue = 'open handle to process' } else { $subTypeValue = 'open thread in process' }
                    }
                    $requestedAccess = $null; $tampered = $null; $flex = $null
                    if ($parts -and $parts.Count -ge 9) { $requestedAccess = $parts[6]; $tampered = $parts[7]; $flex = $parts[8] }

                    $local_ip = $null; $local_port = $null; $remote_ip = $null; $remote_port = $null; $cmdLine = $null; $end_time = $null
                    if ($event.data -is [pscustomobject]) {
                        $local_ip = $event.data.local_ip; $local_port = $event.data.local_port
                        $remote_ip = $event.data.remote_ip; $remote_port = $event.data.remote_port
                        $cmdLine   = $event.data.commandLine
                        if ($event.data.end) {
                            $end_time = Format-CBDateTime $event.data.end
                        }
                    }

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $subTypeValue
                        event_time        = $event.time_fmt
                        target_name       = $targetfile
                        target_pid        = $null
                        path              = $targetpath
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = if ($parts -and $parts.Count -ge 3) { $parts[2] } else { $null }
                        start_time        = $null
                        end_time          = $null
                        commandLine       = $cmdLine
                        userName          = $procData.username
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $subTypeValue
                        requested_access  = $requestedAccess
                        tampered          = $tampered
                        flex              = $flex
                        proto             = $null
                        domain            = $null
                        local_ip          = $null
                        local_port        = $null
                        remote_ip         = $null
                        remote_port       = $null
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = if ($parts -and $parts.Count -ge 4) { $parts[3] } else { $null }
                        sha256_ja3s       = if ($parts) { $parts[-1] } else { $null }
                    }
                    $buffer.Add($obj) | Out-Null
                }

                'fileless_scriptload' {
                    $parts = $null
                    if ($event.data -is [string]) { $parts = $event.data -split '\|' }

                    $start_val = $null; $sha256_val = $null; $cmd_val = $null
                    if ($parts -and $parts.Count -ge 4) {
                        $start_val = $parts[0]
                        $sha256_val = $parts[2]
                        $cmd_val = $parts[3]
                    }

                    $end_val = $null
                    if ($event.data -is [pscustomobject] -and $event.data.end) {
                        $end_val = $event.data.end
                    }

                    $startTime = $null
                    $endTime   = $null
                    $startTime = Format-CBDateTime $start_val
                    $endTime = Format-CBDateTime $end_val

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $event.type
                        event_time        = $event.time_fmt
                        target_name       = $null
                        target_pid        = $null
                        path              = $null
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = $null
                        start_time        = $startTime
                        end_time          = $endTime
                        commandLine       = $cmd_val
                        userName          = $procData.username
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $null
                        requested_access  = $null
                        tampered          = $null
                        flex              = $null
                        proto             = $null
                        domain            = $null
                        local_ip          = $null
                        local_port        = $null
                        remote_ip         = $null
                        remote_port       = $null
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = $null
                        sha256_ja3s       = $sha256_val
                    }
                    $buffer.Add($obj) | Out-Null
                }

                'filemod' {
                    $parts = $null
                    if ($event.data -is [string]) { $parts = $event.data -split '\|' }

                    $targetpath = $null; $targetfileName = $null
                    if ($parts -and $parts.Count -ge 3) {
                        $targetpath = $parts[2]
                        $targetfileName = ($targetpath -split '\\')[-1]
                    }

                    $actionVal = $null
                    if ($parts) {
                        switch ($parts[0]) {
                            '1' { $actionVal = 'Created' }
                            '2' { $actionVal = 'First wrote to' }
                            '4' { $actionVal = 'Deleted' }
                            '8' { $actionVal = 'Last wrote to' }
                            default { $actionVal = $null }
                        }
                    }

                    $subtypeVal = 'Unknown'
                    if ($parts) {
                        switch ($parts[4]) {
                            '1'  { $subtypeVal = 'PE' }
                            '2'  { $subtypeVal = 'Elf' }
                            '3'  { $subtypeVal = 'UniversalBin' }
                            '8'  { $subtypeVal = 'EICAR' }
                            '16' { $subtypeVal = 'OfficeLegacy' }
                            '17' { $subtypeVal = 'OfficeOpenXml' }
                            '48' { $subtypeVal = 'Pdf' }
                            '64' { $subtypeVal = 'ArchivePkzip' }
                            '65' { $subtypeVal = 'ArchiveLzh' }
                            '66' { $subtypeVal = 'ArchiveLzw' }
                            '67' { $subtypeVal = 'ArchiveRar' }
                            '68' { $subtypeVal = 'ArchiveTar' }
                            '69' { $subtypeVal = 'Archive7zip' }
                            '96' { $subtypeVal = 'LNK' }
                            default { $subtypeVal = 'Unknown' }
                        }
                    }

                    $cmdLine = $null; $reqAccess = $null; $flexVal = $null; $protoVal = $null; $domainVal = $null
                    $local_ip = $null; $local_port = $null; $remote_ip = $null; $remote_port = $null; $end_val = $null
                    if ($event.data -is [pscustomobject]) {
                        $cmdLine   = $event.data.commandLine
                        $reqAccess = $event.data.requested_access
                        $flexVal   = $actionVal
                        $protoVal  = $event.data.proto
                        $domainVal = $event.data.domain
                        $local_ip  = $event.data.local_ip
                        $local_port = $event.data.local_port
                        $remote_ip  = $event.data.remote_ip
                        $remote_port = $event.data.remote_port
                        if ($event.data.end) {
                            $end_val = $event.data.end
                        }
                    }

                    $md5_val = $null; $tamperedVal = $null
                    if ($parts -and $parts.Count -ge 6) {
                        $md5_val = $parts[3]
                        $tamperedVal = $parts[5]
                    }

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $actionVal
                        event_time        = $event.time_fmt
                        target_name       = $targetfileName
                        target_pid        = $null
                        path              = $targetpath
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = $null
                        start_time        = $null
                        end_time          = $null
                        commandLine       = $cmdLine
                        userName          = $procData.username
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $subtypeVal
                        requested_access  = $reqAccess
                        tampered          = $tamperedVal
                        flex              = $flexVal
                        proto             = $protoVal
                        domain            = $domainVal
                        local_ip          = $local_ip
                        local_port        = $local_port
                        remote_ip         = $remote_ip
                        remote_port       = $remote_port
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = $md5_val
                        sha256_ja3s       = if ($event.data -is [pscustomobject]) { $event.data.sha256 } else { $null }
                    }
                    $buffer.Add($obj) | Out-Null
                }

                'regmod' {
                    $parts = $null
                    if ($event.data -is [string]) { $parts = $event.data -split '\|' }

                    $regop = $null; $regdate = $null; $regm = $null; $tampered = $null
                    if ($parts -and $parts.Count -ge 3) {
                        $regop   = $parts[0]; $regdate = $parts[1]; $regm = $parts[2]
                        if ($parts.Count -ge 4) { $tampered = $parts[-1] }
                    }

                    $actionVal = $null
                    switch ($regop) {
                        '1' { $actionVal = 'Created' }
                        '2' { $actionVal = 'First wrote to' }
                        '4' { $actionVal = 'Deleted key' }
                        default { $actionVal = 'Deleted value' }
                    }

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $actionVal
                        event_time        = $event.time_fmt
                        target_name       = $null
                        target_pid        = $null
                        path              = $regm
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = $null
                        start_time        = $null
                        end_time          = $null
                        commandLine       = $null
                        userName          = $procData.username
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $actionVal
                        requested_access  = $null
                        tampered          = $tampered
                        flex              = $null
                        proto             = $null
                        domain            = $null
                        local_ip          = $null
                        local_port        = $null
                        remote_ip         = $null
                        remote_port       = $null
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = $null
                        sha256_ja3s       = $null
                    }
                    $buffer.Add($obj) | Out-Null
                }

                'modload' {
                    $parts = $null
                    if ($event.data -is [string]) { $parts = $event.data -split '\|' }

                    $targetpath = $null; $targetfileName = $null
                    if ($parts -and $parts.Count -ge 3) {
                        $targetpath = $parts[2]
                        $targetfileName = ($targetpath -split '\\')[-1]
                    }

                    $end_val = $null; $cmdLine = $null; $reqAccess = $null; $tamperedVal = $null
                    $flexVal = $null; $protoVal = $null; $domainVal = $null
                    $local_ip = $null; $local_port = $null; $remote_ip = $null; $remote_port = $null

                    if ($event.data -is [pscustomobject]) {
                        $cmdLine   = $event.data.commandLine
                        $reqAccess = $event.data.requested_access
                        $tamperedVal = $event.data.is_tampered
                        $flexVal   = $null
                        $protoVal  = $null
                        $domainVal = $null
                        $local_ip  = $null
                        $local_port = $null
                        $remote_ip  = $null
                        $remote_port = $null
                        if ($event.data.end) {
                            $end_val = $event.data.end
                        }
                    }

                    $md5_val = $null; $sha256_val = $null; $start_val = $null; $actionVal = $null
                    if ($parts) {
                        if ($parts.Count -ge 2) { $md5_val = $parts[1] }
                        if ($parts.Count -ge 4) { $sha256_val = $parts[3] }
                        if ($parts.Count -ge 1) {
                            $start_val = $parts[0]
                        }
                    }
                    if ($event.data -is [pscustomobject]) { $actionVal = $event.data.type }

                    $obj = [PSCustomObject]@{
                        type              = $event.type
                        procstart         = $procTime['start']
                        data_lastUpdated  = $procTime['last_update']
                        parent_name       = $procData.parent_name
                        parent_pid        = $procData.parent_pid
                        proc_name         = $procData.process_name
                        pid               = $procData.process_pid
                        action            = $actionVal
                        event_time        = $event.time_fmt
                        target_name       = $targetfileName
                        target_pid        = $null
                        path              = $targetpath
                        parent_id         = $procData.parent_id
                        processId         = $procData.id
                        proc_segment_id   = $procData.segment_id
                        target_Id         = $null
                        start_time        = $null
                        end_time          = $null
                        commandLine       = $cmdLine
                        userName          = $procData.username
                        userSID           = $procData.uid
                        event_segment_id  = $event.segment_id
                        sub_type          = $flexVal
                        requested_access  = $reqAccess
                        tampered          = $tamperedVal
                        flex              = $flexVal
                        proto             = $null
                        domain            = $null
                        local_ip          = $null
                        local_port        = $null
                        remote_ip         = $null
                        remote_port       = $null
                        unique_id         = "$($procData.id)/$($procData.segment_id)"
                        md5_ja3           = $md5_val
                        sha256_ja3s       = $sha256_val
                    }
                    $buffer.Add($obj) | Out-Null
                }
            } # switch event.type

            $processed++

            if ($buffer.Count -ge $FlushEvery) {
                $buffer | Select-Object $eventHeaders | Export-Csv -LiteralPath $CombinedEventsCsvPath -NoTypeInformation -Append -Encoding UTF8
                $buffer.Clear()
                Save-Seen -SeenSet $seen -Path $SeenEventsFilePath
            }
        } # foreach event
    } else {
        Write-Host "No sorted events for $($procData.id)"
    }
}

# Final flushes
if ($buffer.Count -gt 0) {
    $buffer | Select-Object $eventHeaders | Export-Csv -LiteralPath $CombinedEventsCsvPath -NoTypeInformation -Append -Encoding UTF8
    $buffer.Clear()
}
Save-Seen -SeenSet $seen -Path $SeenEventsFilePath

Write-Host "Done. New events written this run: $processed"