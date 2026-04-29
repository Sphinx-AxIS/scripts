# =================================================================================
# Run-FullCBWorkflow.ps1 - Master Controller Script (vFinal)
# =================================================================================

# --- START: Script-Wide Configuration ---
# Stop the script if any command fails
$ErrorActionPreference = 'Stop'

# Prompt the user for the API Token securely
Write-Host "Please provide your Carbon Black API Token." -ForegroundColor Yellow
$secureApiToken = Read-Host -Prompt "Paste API Token and press Enter" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiToken)
$apitoken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

# Define the paths for your child scripts
$jsonToCsvScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "ConvertJSON-ToCSV.ps1"
$convertToXlsxScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Convert-ToXlsx.ps1"

$baseOutputDirectory = "H:\Cb_query_results"

# Define ALL working directories and file paths
$jsonOutputDirectory = "H:\Cb_query_results\json_proc_docs\"
$processListCsvPath  = 'H:\Cb_query_results\process.csv'
$procSummaryCsv      = 'H:\Cb_query_results\process_summary.csv'
$eventsCsv           = 'H:\Cb_query_results\combined_sorted_events.csv'
$seenEventsFile      = 'H:\Cb_query_results\seen_events.keys'
$xlsxOutputPath      = 'H:\Cb_query_results\CB_Query_Results.xlsx'
# --- END: Configuration ---

# --- START: Prerequisite Installation Block ---
try {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Host "NuGet package provider not found. Installing..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Host "The 'ImportExcel' module is required. Installing..." -ForegroundColor Yellow
        Install-Module -Name ImportExcel -Repository PSGallery -Force -Scope CurrentUser
    }
    Import-Module -Name ImportExcel
}
catch {
    Write-Error "Failed to install or load prerequisites. Error: $($_.Exception.Message)"; return
}
# --- END: Prerequisite Block ---


# --- START: Function Definitions ---
function Build-Url {
    # This function now returns the total count, base parameters, and the dynamic folder name.
    [CmdletBinding()]
    param ([Parameter(Mandatory=$true)][string]$ApiToken)

    # --- Input and Validation Loop (with Sanitization) ---
    $dynamicFolderName = $null
    $minUpdate = $null
    $maxUpdate = $null
    
    while (-not ($minUpdate -and $maxUpdate)) {
        try {
            $hostname = Read-Host "Please enter the hostname"
            $dateStr = Read-Host "Please enter the date (e.g., 1/16/2026)"
            Write-Host "Times must be in 24-hour format with a Zulu offset." -ForegroundColor Cyan
            Write-Host "If current time is 05:00:00 -4 adjust your entry accordingly 09:00:00Z" -ForegroundColor Cyan
            $startTimeStr = Read-Host "Enter the START time"
            $endTimeStr = Read-Host "Enter the END time"

            # Sanitize inputs to create a valid folder name
            $sanitizedDate = $dateStr.Replace('/', '-')
            $sanitizedStart = $startTimeStr.Replace(':', '_')
            $sanitizedEnd = $endTimeStr.Replace(':', '_')
            $dynamicFolderName = "$($hostname)_$($sanitizedDate)_$($sanitizedStart)_$($sanitizedEnd)"

            $fullStartStr = "$dateStr $startTimeStr"; $fullEndStr = "$dateStr $endTimeStr"
            $expectedFormat = 'M/d/yyyy HH:mm:ssZ'
            $startDateTimeObj = [datetime]::ParseExact($fullStartStr, $expectedFormat, [System.Globalization.CultureInfo]::InvariantCulture)
            $endDateTimeObj = [datetime]::ParseExact($fullEndStr, $expectedFormat, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($startDateTimeObj -ge $endDateTimeObj) { throw "Validation Error: The start time must be strictly earlier than the end time." }
            $minUpdate = $startDateTimeObj.ToUniversalTime().ToString("u").Replace(" ", "T")
            $maxUpdate = $endDateTimeObj.ToUniversalTime().ToString("u").Replace(" ", "T")
        }
        catch { Write-Warning "Invalid input. $($_.Exception.Message) Please try again."; Start-Sleep -Seconds 2 }
    }
    
    # --- Main Logic for the function (Your Correct Version) ---
    try {
        $baseQueryParameters = [hashtable]@{ 
            "cb.urlver"               = "1"; "cb.comprehensive_search" = "1"; "facet" = "false";
            "sort"                    = "start desc"; "cb.min_last_update" = $minUpdate; "cb.max_last_update" = $maxUpdate;
            "cb.query_source"         = "ui"; "cb.strict" = "1"; "q" = "hostname:$hostname" 
        }
        
        Write-Host "Performing initial query to determine total number of results..."
        $probeQueryParameters = $baseQueryParameters.Clone()
        $probeQueryParameters["rows"] = "1"
        
        $queryString = $probeQueryParameters.GetEnumerator() | ForEach-Object {
            $value = [uri]::EscapeDataString($_.Value)
            "$($_.Name)=$($value)"
        } | Join-String -Separator '&'
        
        $probeUrl = "https://<Carbon Black URI>/api/v1/process?$queryString"

        Write-Host "DEBUG: Initial query URL is:" -ForegroundColor Magenta
        Write-Host $probeUrl -ForegroundColor Cyan
        
        $initialResponse = Invoke-RestMethod -Uri $probeUrl -Headers @{ "x-auth-token" = $ApiToken } -Method 'GET' -ContentType 'application/json'
        
        $totalResults = $initialResponse.total_results
        if ($totalResults -eq 0) { Write-Warning "No results found for the specified criteria. Exiting."; return $null }
        
        Write-Host "Found $totalResults process documents to download." -ForegroundColor Cyan
        
        # Return all the information the main script needs for the dynamic paths
        return [PSCustomObject]@{ TotalCount = $totalResults; BaseParameters = $baseQueryParameters; DynamicFolderName = $dynamicFolderName }
    }
    catch {
        # This passes the REAL error up to the main script.
        throw
    }
}




# --- END: Function Definitions ---


# ==========================================================
#                      MAIN WORKFLOW
# ==========================================================
try {
    # --- DYNAMIC PATH CONSTRUCTION ---
    $queryInfo = Build-Url -ApiToken $apitoken
    if ($null -eq $queryInfo) { throw "Could not build the download URL. Aborting workflow." }

    $dynamicOutputDirectory = Join-Path -Path $baseOutputDirectory -ChildPath $queryInfo.DynamicFolderName
    $jsonOutputDirectory = Join-Path -Path $dynamicOutputDirectory -ChildPath "json_proc_docs"
    $processListCsvPath  = Join-Path -Path $dynamicOutputDirectory -ChildPath 'process.csv'
    $procSummaryCsv      = Join-Path -Path $dynamicOutputDirectory -ChildPath 'process_summary.csv'
    $eventsCsv           = Join-Path -Path $dynamicOutputDirectory -ChildPath 'combined_sorted_events.csv'
    $seenEventsFile      = Join-Path -Path $dynamicOutputDirectory -ChildPath 'seen_events.keys'
    $xlsxOutputPath      = Join-Path -Path $dynamicOutputDirectory -ChildPath 'CB_Query_Results.xlsx'

    Write-Host "`nAll output will be saved to the folder: $dynamicOutputDirectory" -ForegroundColor Green
    
    # --- STEP 1: DOWNLOAD PROCESS DATA FROM CARBON BLACK ---
    if (-not (Test-Path -Path $jsonOutputDirectory)) {
        Write-Host "Creating output directory: $jsonOutputDirectory"
        New-Item -Path $jsonOutputDirectory -ItemType Directory | Out-Null
    }
    
    # --- START: Final Robust Pagination Logic ---
    $totalDownloads = $queryInfo.TotalCount
    $allResults = [System.Collections.Generic.List[object]]::new()
    $pageSize = 500
    $start = 0

    Write-Host "Downloading list of all $totalDownloads process documents in pages of $pageSize..."
    
    do {
        Write-Host " - Fetching page starting at index $start..."
    
        # Clone the base parameters and add the pagination keys for this specific page
        $pagedQueryParameters = $queryInfo.BaseParameters.Clone()
        $pagedQueryParameters['rows'] = $pageSize
        $pagedQueryParameters['start'] = $start

        # --- THIS IS THE FIX: Build the URL string manually, just like the probe query ---
        $pagedQueryParts = @(); 
        foreach ($key in $pagedQueryParameters.Keys) { 
            $encodedValue = [uri]::EscapeDataString($pagedQueryParameters[$key])
            $pagedQueryParts += "$key=$encodedValue"
        }
        $pagedQueryString = $pagedQueryParts -join "&"
        $pagedUrl = "https://<Carbon Black URI>/api/v1/process?$pagedQueryString"

        $pagedParams = @{
            uri         = $pagedUrl # Use the full URL here
            Headers     = @{ "x-auth-token" = $apitoken }
            Method      = 'GET'
            ContentType = 'application/json'
            # The -Body parameter is now gone, which is correct.
        }

        try {
            $pagedResponse = Invoke-RestMethod @pagedParams -ErrorAction Stop
            if ($pagedResponse.results) {
                $allResults.AddRange($pagedResponse.results)
            }
        } catch {
            Write-Warning "Failed to fetch page starting at index $start. Error: $($_.Exception.Message). Skipping this page."
        }
        $start += $pageSize
    } while ($allResults.Count -lt $totalDownloads -and $start -lt ($totalDownloads + $pageSize))

    $allResults | Select-Object id, segment_id | Export-Csv -Path $processListCsvPath -NoTypeInformation
    # --- END: Final Robust Pagination Logic ---

    Write-Host "Process list saved to $processListCsvPath" -ForegroundColor Green
    
    # --- The rest of the script (download loop, Step 2, Step 3) is correct ---
    $csv = Import-Csv -Path $processListCsvPath
    $downloadCounter = 0

    foreach ($item in $csv) {
        $downloadCounter++
        $itemid = $item.id
        $segment = $item.segment_id
        if ([string]::IsNullOrWhiteSpace($itemid)) { Write-Warning "Skipping row $downloadCounter because it has a blank process ID."; continue }
    
        Write-Progress -Activity "Downloading Process Event Documents" -Status "Processing $downloadCounter of $($csv.Count)" -PercentComplete (($downloadCounter / $csv.Count) * 100)
	    $fileName = "procid_$($itemid)--$($segment).json"
	    $fullPath = Join-Path -Path $jsonOutputDirectory -ChildPath $fileName

        $maxRetries = 3; $downloadSuccess = $false
        for ($retry = 1; $retry -le $maxRetries; $retry++) {
            try {
                Invoke-RestMethod -Uri ('https://<Carbon Black URI>/api/v5/process/' + $itemid + '/' + $segment + '/event') `
                    -Headers @{ "x-auth-token" = $apitoken } -Method 'GET' -ContentType 'application/json' -Outfile $fullPath -ErrorAction Stop
                $downloadSuccess = $true; break
            } catch {
                Write-Warning "Attempt $retry of $maxRetries failed for process ID $itemid. Error: $($_.Exception.Message)"
                if ($retry -lt $maxRetries) { Write-Warning "Waiting 5 seconds before retrying..."; Start-Sleep -Seconds 5 }
            }
        }
        if (-not $downloadSuccess) { Write-Error "Failed to download events for process ID $itemid after $maxRetries attempts. Skipping this file." -ErrorAction Continue; continue }
    }
    Write-Progress -Activity "Downloading Process Event Documents" -Completed
    Write-Host "STEP 1: Download completed successfully." -ForegroundColor Green

    # --- STEP 2: CONVERT JSON TO CSV ---
    Write-Host "`nSTEP 2: Starting JSON to CSV conversion..." -ForegroundColor Green
    if (Test-Path $jsonToCsvScriptPath) {
        $jsonToCsvParams = @{ JsonDirPath = $jsonOutputDirectory; ProcessSummaryCsvPath = $procSummaryCsv; CombinedEventsCsvPath = $eventsCsv; SeenEventsFilePath = $seenEventsFile }
        & $jsonToCsvScriptPath @jsonToCsvParams
        Write-Host "STEP 2: CSV Generation completed successfully." -ForegroundColor Green
    } else { throw "Child script not found: $jsonToCsvScriptPath" }

    # --- STEP 3: CONVERT CSV to XLSX ---
    Write-Host "`nSTEP 3: Starting CSV to XLSX conversion..." -ForegroundColor Green
    if (Test-Path $convertToXlsxScriptPath) {
        $xlsxParams = @{ ProcessSummaryCsvPath = $procSummaryCsv; CombinedEventsCsvPath = $eventsCsv; XlsxOutputPath = $xlsxOutputPath }
        & $convertToXlsxScriptPath @xlsxParams
        Write-Host "STEP 3: XLSX Conversion completed successfully." -ForegroundColor Green
    } else { throw "Child script not found: $convertToXlsxScriptPath" }

    Write-Host "`n=========================================="
    Write-Host "          WORKFLOW FINISHED"
    Write-Host "==========================================" -ForegroundColor Cyan

}
catch {
    # If any command fails, the script will jump to this block.
    Write-Error "A critical error occurred. The workflow has been aborted."
    Write-Error "Error details: $($_.Exception.Message)"
}
finally {
    # --- FINAL CLEANUP ---
    # (Your existing cleanup logic will work perfectly with the new dynamic paths)
    Write-Host "`nStarting final cleanup of temporary files..." -ForegroundColor Yellow
    if (Test-Path -Path $seenEventsFile) { Write-Host " - Removing $($seenEventsFile)"; Remove-Item -Path $seenEventsFile -Force }
    if (Test-Path -Path $processListCsvPath) { Write-Host " - Removing $($processListCsvPath)"; Remove-Item -Path $processListCsvPath -Force }
    Write-Host "Cleanup complete." -ForegroundColor Yellow
}