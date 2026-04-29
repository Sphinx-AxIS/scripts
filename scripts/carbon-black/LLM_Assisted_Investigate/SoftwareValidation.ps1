# File: SoftwareValidation.ps1
# Contains the function to check if software is approved by querying the SPOC C API.

# --- Default API Key Loading ---
# The script attempts to load the key from your specified file path.
# The $script: scope ensures the variable is available to functions inside this script.
try {
    $script:DefaultApiKey = Get-Content "H:\Scripts\powershell\CB_API\SPOCC_API.txt:APIKeyStream"
}
catch {
    # If the file can't be read, we set the variable to null and will handle the error later.
    $script:DefaultApiKey = $null
}

function Test-ApprovedSoftware {
    [CmdletBinding()]
    param(
        # The name of the software product to look for.
        [Parameter(Mandatory = $true)]
        [string]$ProductName,
        # The specific version of the software. If omitted, all versions are returned.
        [Parameter(Mandatory = $false)]
        [string]$VersionLabel,
        # The API key. If not provided, the script will try to use the default key loaded above.
        [string]$ApiKey
    )

    # --- API Key Selection Logic ---
    $effectiveApiKey = $null
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        # Priority 1: Use the key provided as a parameter.
        $effectiveApiKey = $ApiKey
        Write-Verbose "Using API key provided via the -ApiKey parameter."
    }
    else {
        # Priority 2: Fall back to the default key loaded from the file.
        $effectiveApiKey = $script:DefaultApiKey
        Write-Verbose "Using default API key loaded from file."
    }

    # STOP if no API key is available from either source.
    if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) {
        Write-Error "Execution stopped: An API key was not provided and a default key could not be loaded. Please provide a key using the -ApiKey parameter or ensure the file path is correct."
        # --- CHANGE #1: Explicitly return $false on failure ---
        return $false
    }

    # --- API Query Construction ---
    $apiUrl = "https://spoccapi.nga.mil/api/v1/public/product"
    $queryParams = @{ "product_name" = $ProductName }
    if ($PSBoundParameters.ContainsKey('VersionLabel')) {
        $queryParams['version_label'] = $VersionLabel
    }
    
    $headers = @{
        "SwapAuthorization" = "Bearer $effectiveApiKey"
    }

    # --- CHANGE #2: Initialize a flag to track approval status ---
    $isApproved = $false

    try {
        Write-Host "Querying software approval API for product '$ProductName'..." -ForegroundColor Cyan
        
        $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -Body $queryParams

        if ($response.entries -gt 0) {
            foreach ($product in $response.products) {
                Write-Host "Found product: $($product.product_name) (Manufacturer: $($product.manufacturer.name))" -ForegroundColor Green
                
                if ($product.versions.Count -gt 0) {
                    Write-Host "Displaying approval status for $($product.versions.Count) version(s):"
                    
                    # Display the detailed table to the analyst
                    $product.versions | ForEach-Object {
                        [PSCustomObject]@{
                            Version          = $_.version
                            ApprovalStatus   = $_.approval_status
                            ControlNumber    = $_.control_number
                            RiskCategory     = $_.risk_category
                            RetiresOn        = if ($_.retire_on) { [datetime]$_.retire_on } else { 'N/A' }
                        }
                    } | Format-Table

                    # --- CHANGE #3: Check for an approved version and set the flag ---
                    # Loop through versions again to check the status programmatically.
                    foreach ($version in $product.versions) {
                        # We consider it "Approved" if the status explicitly says so. Adjust if other statuses are valid.
                        if ($version.approval_status -ieq 'Approved') {
                            $isApproved = $true
                            # If we find even one approved version, we can stop looking.
                            break
                        }
                    }
                } else {
                    Write-Warning "Product found, but it has no version information."
                }
                # If we found an approved version in the inner loop, we can exit the outer product loop too.
                if ($isApproved) { break }
            }
        } else {
            Write-Warning "No product found matching the name '$ProductName'."
        }
    }
    catch {
        # If the API call fails, we cannot confirm approval.
        $statusCode = $_.Exception.Response.StatusCode
        Write-Error "API call failed with status code: $statusCode"
        $errorResponse = $_.Exception.Response.GetResponseStream()
        $streamReader = New-Object System.IO.StreamReader($errorResponse)
        $errorBody = $streamReader.ReadToEnd()
        Write-Error "Error Details: $errorBody"
        # --- CHANGE #4: Return $false on any error ---
        $isApproved = $false
    }
    
    # --- CHANGE #5: Return the final boolean status for the main script to use ---
    return $isApproved
}
