# File: Get-CBProcessTree.ps1
#
# Contains the primary function Get-CBProcessTreeData, which gathers all data
# for a process and all of its children, returning it as a single object.

# --- Configuration (EDIT these for your environment before running) ---
$CBServer        = "<your-cb-server>:<port>"                  # e.g. "cb.example.com:8443"
$CBAPIKey        = Get-Content "<path-to-cb-api-key-file>"    # supports NTFS ADS, e.g. ".\cred.txt:APIKeyStream"
$EventOutputRoot = "<path-to-event-output-directory>"         # where per-process event JSON gets written
$APIURLv1 = "https://$CBServer/api/v1" # For Process Metadata (like children)
$APIURLv4 = "https://$CBServer/api/v4" # For Process Events

# --- Main Reusable Function ---
function Get-CBProcessTreeData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$InitialProcessId,
        [Parameter(Mandatory = $true)]
        [string]$InitialProcessSegmentId
    )

    # Initialize variables to hold all the data we collect
    $allProcessEvents = @()
    $initialProcessSummary = $null
    $initialProcessName = ""
    $uniqueChildNames = @()
    # This gets basic info and, importantly, the list of children.
    function Get-CBRawProcessDataInternal {
        param ([string]$ProcessID, [string]$ProcessSegmentID)
        try {
            $processUrl = "$APIURLv1/process/$ProcessID/$ProcessSegmentID"
            $headers = @{"X-Auth-Token" = $CBAPIKey}
            Write-Verbose "Getting Raw Process Data for PID: $ProcessID"
            return Invoke-RestMethod -Uri $processUrl -Headers $headers -Method Get -ErrorAction Stop
        }
        catch { Write-Warning "Error getting raw process data for PID: $ProcessID. Details: $($_.Exception.Message)"; return $null }
    }

    # --- Internal Helper Function to get detailed Process Events (v4 API) ---
    # This version correctly saves files and sets permissions.
    function Get-CBProcessEventsInternal {
        param ([string]$ProcessID, [string]$ProcessSegmentID)
        try {
            $eventUrl = "$APIURLv4/process/$ProcessID/$ProcessSegmentID/event"
            $headers = @{"X-Auth-Token" = $CBAPIKey}
            Write-Verbose "Getting Process Events for PID: $ProcessID"
            $processEventData = Invoke-RestMethod -Uri $eventUrl -Headers $headers -Method Get -ErrorAction Stop
            if ($null -ne $processEventData) {
                $outputDir = $EventOutputRoot; if (!(Test-Path -Path $outputDir -PathType Container)) { New-Item -ItemType Directory -Path $outputDir }; $outputFile = Join-Path $outputDir "$($ProcessID)_$($ProcessSegmentID)_events.json"; $processEventData | ConvertTo-Json -Depth 10 | Out-File $outputFile; Write-Host "Process events saved to: $outputFile" -ForegroundColor DarkGray
				try {
					$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
					$acl = Get-Acl $outputFile
					$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, "FullControl", "Allow")
					$acl.SetAccessRule($accessRule)
					$acl | Set-Acl $outputFile
					Write-Verbose "Set FullControl permission for $currentUser on $outputFile"
				}
				catch {
					Write-Warning "Could not set file permissions on '$outputFile'. Error: $($_.Exception.Message)"
				}
            }
            return $processEventData
        }
        catch { Write-Warning "Error getting process events for PID: $ProcessID. Details: $($_.Exception.Message)"; return $null }
    }

    # --- Main Logic ---
    Write-Host "Starting investigation for Process Tree starting with PID: $InitialProcessId"
    # 1. Get the initial process's raw data
    $initialRawData = Get-CBRawProcessDataInternal -ProcessID $InitialProcessId -ProcessSegmentID $InitialProcessSegmentId
    if (-not $initialRawData) { Write-Error "Failed to get initial process data. Cannot continue."; return $null }
    
    # 2. Capture both the summary object AND the process name from the raw data
    $initialProcessSummary = $initialRawData
    $initialProcessName = $initialRawData.process.process_name

    # 3. Get the detailed events for the initial process
    $initialEvents = Get-CBProcessEventsInternal -ProcessID $InitialProcessId -ProcessSegmentID $InitialProcessSegmentId
    if ($initialEvents) { $allProcessEvents += $initialEvents }

    # 4. Check for and process any children
    if ($initialRawData.process.childproc_count -gt 0 -and $initialRawData.children) {
        Write-Host "Found $($initialRawData.children.Count) child processes. Retrieving their events."
        
        # --- START of CHANGE #2: Extract the list of unique child names from the data we already have ---
        $uniqueChildNames = $initialRawData.children | Select-Object -ExpandProperty process_name -Unique
        # --- END of CHANGE #2 ---

        foreach ($child in $initialRawData.children) {
            $childEvents = Get-CBProcessEventsInternal -ProcessID $child.id -ProcessSegmentID $child.segment_id
            if ($childEvents) { $allProcessEvents += $childEvents }
        }
    }
    else { Write-Host "No child processes found for initial process." }

    # 5. Return a single custom object containing ALL the data the main script needs
    Write-Host "Finished collecting data for the process tree."
    $resultObject = [PSCustomObject]@{
        InitialProcessSummary = $initialProcessSummary
        ProcessTreeEvents     = $allProcessEvents
        InitialProcessName    = $initialProcessName
        # --- START of CHANGE #3: Add the new list of child names to the object we are returning ---
        UniqueChildNames      = $uniqueChildNames
        # --- END of CHANGE #3 ---
    }
    return $resultObject
}
