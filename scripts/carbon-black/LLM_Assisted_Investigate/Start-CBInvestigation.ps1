<#
.SYNOPSIS
    Automates the initial investigation of a Carbon Black watchlist alert by generating structured LLM prompts.
.DESCRIPTION
    This script takes a Carbon Black UI search URL, converts it to an API query, fetches the resulting processes,
    retrieves the full process tree event data for each process, and then generates a detailed LLM prompt for analysis.
.NOTES
    Requires 'Get-CBProcessTree.ps1', 'SoftwareValidation.ps1', 'process_map.csv', and 'whitelist.txt' to be in the same directory.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$WatchlistUrl,
    [Parameter(Mandatory = $false)]
    [string]$AlertName
)

# --- [ Step 1: Import Toolkits and Load Whitelist/Maps ] ---
try {
    . ".\Get-CBProcessTree.ps1"; Write-Host "✅ Carbon Black toolkit loaded." -f Green
    . ".\SoftwareValidation.ps1"; Write-Host "✅ Software Validation toolkit loaded." -f Green

    $mapFilePath = ".\process_map.csv"; $script:ProcessNameMap = @{}; if (Test-Path $mapFilePath) { $importedData = Import-Csv -Path $mapFilePath -Encoding UTF8; if ($null -eq $importedData) { throw "Import-Csv read 'process_map.csv' but returned null." }; $importedData | ForEach-Object { $key = $_.process_name.Trim(); $value = $_.official_product_name.Trim(); if (-not [string]::IsNullOrEmpty($key)) { $script:ProcessNameMap[$key.ToLower()] = $value } }; if ($script:ProcessNameMap.Count -eq 0) { throw "Process map file is empty." }; Write-Host "✅ Process name map loaded ($($script:ProcessNameMap.Count) entries)." -f Green } else { Write-Warning "File 'process_map.csv' not found." }
    $whitelistFilePath = ".\whitelist.txt"; $script:InternalWhitelist = @{}; if (Test-Path $whitelistFilePath) { Get-Content $whitelistFilePath | ForEach-Object { $line = $_.Trim(); if (-not [string]::IsNullOrEmpty($line) -and $line -notlike '#*') { $script:InternalWhitelist[$line.ToLower()] = $true } }; Write-Host "✅ Internal whitelist loaded ($($script:InternalWhitelist.Count) entries)." -f Green } else { Write-Warning "File 'whitelist.txt' not found." }

} catch {
    Write-Error "❌ CRITICAL: Failed to load a required script or file. Error: $($_.Exception.Message)"
    exit
}


# --- [ Step 2, 3, & 4: Get Inputs, Parse URL, and Query API ] ---
if ([string]::IsNullOrEmpty($WatchlistUrl)) { $WatchlistUrl = Read-Host "Please paste the Carbon Black URL" }
if ([string]::IsNullOrEmpty($AlertName)) { $AlertName = Read-Host "Please enter the Alert/Watchlist Name" }
Write-Host "✅ Alert Name set to: '$AlertName'" -f Green

try {
    $processIdentifiers = $null
    if ($WatchlistUrl -like "*/#/analyze/*") {
        Write-Host "Detected 'Analyze' URL." -f Cyan
        if ($WatchlistUrl -match '/#/analyze/([^/]+)/([^/?]+)') {
            $processId = $Matches[1]; $segmentId = $Matches[2]; $processIdentifiers = [PSCustomObject]@{ id = $processId; segment_id = $segmentId }
            Write-Host "✅ Extracted Process ID: $processId" -f Green
        } else { throw "Could not parse 'Analyze' URL." }
    }
    elseif ($WatchlistUrl -like "*/#/search*") {
        Write-Host "Detected 'Search' URL." -f Cyan
        $ApiUrl = $WatchlistUrl -replace '/#/search\?', '/api/v1/process?'
        if ($ApiUrl -eq $WatchlistUrl) { $ApiUrl = $WatchlistUrl -replace '/#/search/q=', '/api/v1/process?q=' }
        if ($ApiUrl -match 'rows=\d+') { $ApiUrl = $ApiUrl -replace 'rows=\d+', 'rows=200' } else { $ApiUrl += "&rows=200" }
        $ApiUrl += "&cb.group=id"; if (-not ($ApiUrl -like "*/api/v1/process?*")) { throw "URL conversion failed." }
        Write-Host "✅ URL converted." -f Green; $headers = @{"X-Auth-Token" = $CBAPIKey}; Write-Host "⏳ Querying API for process list..."
        $apiResponse = Invoke-RestMethod -Uri $ApiUrl -Method Get -Headers $headers -ErrorAction Stop
        if ($null -eq $apiResponse.results -or $apiResponse.results.Count -eq 0) { Write-Warning "API query returned no processes."; exit }
        $processIdentifiers = $apiResponse.results | Select-Object id, segment_id
    }
    else { throw "Unrecognized URL type." }

    if ($processIdentifiers) {
        Write-Host "✅ Found $($processIdentifiers.Count) initial process(es) to investigate." -f Green
    }
} catch {
    Write-Error "❌ Failed during URL processing or API query. Error: $($_.Exception.Message)"
    exit
}


# --- [ Step 5: Get Full Process Data and Generate LLM Prompts ] ---
$allPrompts = @()

foreach ($process in $processIdentifiers) {
    Write-Host "--------------------------------------------------" -ForegroundColor Yellow
    Write-Host "⏳ Investigating Process Tree starting with ID: $($process.id)"
    
    $processDataObject = Get-CBProcessTreeData -InitialProcessId $process.id -InitialProcessSegmentId $process.segment_id
    if ($null -eq $processDataObject) { Write-Warning "Skipping PID $($process.id)."; continue }
    
    $initialProcessSummary = $processDataObject.InitialProcessSummary
    $processTreeEvents = $processDataObject.ProcessTreeEvents
    $initialProcessName = $processDataObject.InitialProcessName
    $uniqueChildNames = $processDataObject.UniqueChildNames

    # Check Approval Status for the PARENT process
    $parentApprovalStatus = "Unknown"; $parentProductNameForCheck = ""
    if (-not [string]::IsNullOrEmpty($initialProcessName)) {
        $baseProductName = ($initialProcessName -replace '\.[^.]+$').Trim().ToLower()
        if ($script:InternalWhitelist.ContainsKey($baseProductName)) {
            $parentApprovalStatus = "Approved (Internal Whitelist)"; $parentProductNameForCheck = "N/A (Whitelisted)"; Write-Host "✅ Parent '$baseProductName' on internal whitelist." -f Green
        } else {
            if ($script:ProcessNameMap.ContainsKey($baseProductName)) { $parentProductNameForCheck = $script:ProcessNameMap[$baseProductName]; Write-Host "Mapped parent '$baseProductName' to '$parentProductNameForCheck'." -f Cyan } else { $parentProductNameForCheck = $baseProductName }
            $isApproved = Test-ApprovedSoftware -ProductName $parentProductNameForCheck; $parentApprovalStatus = if ($isApproved) { "Approved" } else { "Not Approved" }; Write-Host "✅ API Approval for parent '$parentProductNameForCheck': $parentApprovalStatus"
        }
    }

    # Check Approval Status for all unique CHILD processes
    $childApprovalStatuses = @{}
    if ($uniqueChildNames.Count -gt 0) {
        Write-Host "--- Checking approval for child processes ---"
        foreach ($childName in $uniqueChildNames) {
            $childBaseName = ($childName -replace '\.[^.]+$').Trim().ToLower()
            if ([string]::IsNullOrEmpty($childBaseName)) { continue }
            if ($script:InternalWhitelist.ContainsKey($childBaseName)) {
                $childApprovalStatuses[$childName] = "Approved (Internal Whitelist)"
            } else {
                $childProductNameForCheck = ""
                if ($script:ProcessNameMap.ContainsKey($childBaseName)) { $childProductNameForCheck = $script:ProcessNameMap[$childBaseName] } else { $childProductNameForCheck = $childBaseName }
                $isChildApproved = Test-ApprovedSoftware -ProductName $childProductNameForCheck; $childApprovalStatuses[$childName] = if ($isChildApproved) { "Approved" } else { "Not Approved" }
            }
            Write-Host "  - Child '$($childName)': $($childApprovalStatuses[$childName])"
        }
        Write-Host "--- Finished checking children ---"
    }

    # Build the markdown string for the child status section
    $childStatusMarkdown = ""
    if ($childApprovalStatuses.Count -gt 0) {
        foreach ($key in $childApprovalStatuses.Keys) { $childStatusMarkdown += "*   ``$key``: $($childApprovalStatuses[$key])`n" }
    } else { $childStatusMarkdown = "*   No child processes were spawned by the initial process." }

    # The data cleaning/modification logic from your script
	foreach ($event in $processTreeEvents) { if ($null -ne $event.process) { if ($event.process.PSObject.Properties.Name -contains 'modload_complete') { $event.process.PSObject.Properties.Remove('modload_complete') }; if ($null -ne $event.process.binaries) { $binariesObject = $event.process.binaries; $keysToRemove = [System.Collections.Generic.List[string]]@(); foreach ($property in $binariesObject.PSObject.Properties) { $binaryDetails = $property.Value; if ($null -ne $binaryDetails -and $binaryDetails.PSObject.Properties.Name -contains 'digsig_result' -and $binaryDetails.digsig_result -eq "Signed") { $keysToRemove.Add($property.Name) } }; if ($keysToRemove.Count -gt 0) { foreach ($key in $keysToRemove) { $binariesObject.PSObject.Properties.Remove($key) } } }; if ($null -ne $event.process.filemod_complete) { for ($i = 0; $i -lt $event.process.filemod_complete.Count; $i++) { $line = $event.process.filemod_complete[$i]; $parts = $line -split '\|'; if ($parts.Count -gt 0) { $actionType = switch ($parts[0]) { '1' { 'Created' } '2' { 'First wrote to' } '4' { 'Deleted' } '8' { 'Last wrote to' } default { $parts[0] } }; $parts[0] = $actionType; $event.process.filemod_complete[$i] = $parts -join '|' } } } } }
    
    $JSONFormattedProcessSummary = $initialProcessSummary | ConvertTo-Json -Depth 10
    $JSONFormattedProcessTreeEvents = $processTreeEvents | ConvertTo-Json -Depth 10
    
    # The PromptTemplate here-string starts on the next line
    $PromptTemplate = @"
You are a **Tier 2 Security Operations Center (SOC) Analyst** investigating a **Carbon Black EDR Watchlist Alert**.

Your job is to determine whether the activity is **Benign**, **Suspicious**, or **Malicious**, based ONLY on the alert data provided (unless you clearly label assumptions).  
You must produce a **structured investigation report** that can be pasted into a SOC ticket.

---

## Operational Context & Rules

### Internal IP Address Ranges
Treat the following IP ranges as **internal**, unless there are other indicators suggesting compromise (beaconing patterns, known bad ports, suspicious processes, strange timing, lateral movement indicators, etc.):

- `214.28.0.0/16`
- `164.214.0.0/16`

### Process Approval Context
Carbon Black approval statuses may indicate prior review, but **approval does NOT automatically mean benign**.
Use approval status only as a supporting factor.

### Investigation Principles (Tier 2 Standard)
- Prefer **behavioral indicators** over file names alone
- Do not rely on single weak indicators (e.g., “powershell.exe = malicious”)
- Identify if activity matches:
  - normal IT/admin activity
  - expected enterprise tooling
  - malware tradecraft (LOLBins, persistence, credential access, discovery, C2)

---

## Alert Context

- **Alert Source:** Carbon Black EDR
- **Watchlist Name:** "$($AlertName)"
- **Initial Process ID Under Investigation:** $($process.id)
- **Initial Process Name:** "$($initialProcessName)"
- **Initial Process Approval Status:** "$($parentApprovalStatus)"

---

## Child Process Approval Status
$($childStatusMarkdown)

---

## Evidence Provided (Raw Alert Data)

### JSON Formatted Initial Process Summary
```json
$($JSONFormattedProcessSummary)
"@
# --- END of Prompt Template ---
    $allPrompts += $PromptTemplate
}

# --- [ Step 6: Output Final Prompts ] ---
if ($allPrompts.Count -gt 0) {
    Write-Host "--------------------------------------------------" -f Green
    Write-Host "Generation complete. $($allPrompts.Count) prompt(s) have been created."
    $finalOutput = $allPrompts -join "`n`n--- (New Prompt) ---`n`n"
    Set-Clipboard -Value $finalOutput
    Write-Host "Prompt(s) have been copied to your clipboard." -f Green
} else {
    Write-Warning "Script finished, but no prompts were generated."
}

Write-Host "Script finished."