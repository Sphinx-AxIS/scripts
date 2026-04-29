param (
    [Parameter(Mandatory = $true)]
    [string]$ProcessSummaryCsvPath,
    [Parameter(Mandatory = $true)]
    [string]$CombinedEventsCsvPath,
    [Parameter(Mandatory = $true)]
    [string]$XlsxOutputPath,
    [switch]$SkipAutoFitCombinedEvents,
    [int]$ProgressInterval = 5000,
    # --- NEW PARAMETER ---
    [int]$MaxRowsPerSheet = 900000
)

$ErrorActionPreference = 'Stop'
Import-Module ImportExcel -ErrorAction Stop
Add-Type -AssemblyName Microsoft.VisualBasic

# --- (Input validation and helper functions are unchanged) ---
if ([string]::IsNullOrWhiteSpace($XlsxOutputPath)) { throw "XlsxOutputPath must be a file path like C:\temp\output.xlsx" }
if ((Split-Path $XlsxOutputPath -Leaf) -notmatch '\.xlsx$') { throw "XlsxOutputPath must include a filename ending in .xlsx" }
function Try-ParseCbDate { param([string]$Value) ; if ([string]::IsNullOrWhiteSpace($Value)) { return $null } ; $formats = @('MM/dd/yyyy HH:mm:ss.fff','MM/dd/yyyy HH:mm:ss') ; foreach ($format in $formats) { try { return [datetime]::ParseExact($Value, $format, [System.Globalization.CultureInfo]::InvariantCulture) } catch {} } ; return $null }
function Try-ParseInt64 { param([string]$Value) ; if ([string]::IsNullOrWhiteSpace($Value)) { return $null } ; $clean = $Value.Trim() ; if ($clean -notmatch '^\d+$') { return $null } ; return [int64]$clean }
function Get-HeaderMapFromSheet { param([Parameter(Mandatory = $true)]$Sheet) ; $map = @{} ; if (-not $Sheet -or -not $Sheet.Dimension) { return $map } ; $endCol = $Sheet.Dimension.End.Column ; for ($column = 1; $column -le $endCol; $column++) { $header = ($Sheet.Cells[1, $column].Text).Trim() ; if ($header -and -not $map.ContainsKey($header)) { $map[$header] = $column } } ; return $map }

# --- MODIFIED: Write-CombinedEventsWorksheet Function ---
function Write-CombinedEventsWorksheet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvPath,
        [Parameter(Mandatory = $true)]
        # This now takes the whole package so it can add sheets
        $ExcelPackage,
        [Parameter(Mandatory = $true)]
        [string]$BaseSheetName,
        [Parameter(Mandatory = $true)]
        [int]$MaxRows,
        [int]$ProgressInterval = 5000
    )

    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($CsvPath)
    $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true
    $parser.TrimWhiteSpace = $false

    $totalRowCounter = 1
    $headers = $null
    
    # --- Rollover Logic Variables ---
    $sheetNumber = 1
    $currentRowOnSheet = 1
    $currentWorksheet = $null

    try {
        while (-not $parser.EndOfData) {
            # --- Sheet Creation Logic ---
            if ($currentWorksheet -eq $null -or $currentRowOnSheet -gt $MaxRows) {
                if ($currentWorksheet -ne $null) {
                    Write-Host "   Reached max rows for sheet. Rolling over..."
                    $sheetNumber++
                }
                $sheetName = "${BaseSheetName}_${sheetNumber}"
                Write-Host " - Creating worksheet '$sheetName'..."
                $currentWorksheet = $ExcelPackage.Workbook.Worksheets.Add($sheetName)
                $currentRowOnSheet = 1 # Reset row counter for new sheet

                # Write headers to the new sheet if we already have them
                if ($headers) {
                    for ($column = 0; $column -lt $headers.Length; $column++) {
                        $currentWorksheet.SetValue($currentRowOnSheet, $column + 1, $headers[$column])
                    }
                    $currentRowOnSheet++
                }
            }

            $fields = $parser.ReadFields()
            if (-not $fields) { continue }

            # --- Header Handling (only for the very first row of the file) ---
            if ($totalRowCounter -eq 1) {
                $headers = $fields
                # The first sheet was already created, so we just write headers to it
                for ($column = 0; $column -lt $headers.Length; $column++) {
                    $currentWorksheet.SetValue($currentRowOnSheet, $column + 1, $headers[$column])
                }
                $currentRowOnSheet++
                $totalRowCounter++
                continue
            }

            # --- Data Row Processing ---
            for ($column = 0; $column -lt $fields.Length; $column++) {
                $headerName = if ($headers -and $column -lt $headers.Length) { $headers[$column] } else { '' }
                $value = $fields[$column]

                switch ($headerName) {
                    'proc_segment_id'  { $value = Try-ParseInt64 $value; break }
                    'event_segment_id' { $value = Try-ParseInt64 $value; break }
                    'procstart'        { $value = Try-ParseCbDate $value; break }
                    'event_time'       { $value = Try-ParseCbDate $value; break }
                    'start_time'       { $value = Try-ParseCbDate $value; break }
                    'end_time'         { $value = Try-ParseCbDate $value; break }
                    'pid'              { $value = [string]$value; break }
                    'parent_pid'       { $value = [string]$value; break }
                    'processId'        { $value = [string]$value; break }
                    'target_Id'        { $value = [string]$value; break }
                }
                
                $currentWorksheet.SetValue($currentRowOnSheet, $column + 1, $value)
            }

            if ($ProgressInterval -gt 0 -and (($totalRowCounter - 1) % $ProgressInterval) -eq 0) {
                Write-Host ("   Wrote {0} total Combined_Events rows..." -f ($totalRowCounter - 1))
            }
            
            $currentRowOnSheet++
            $totalRowCounter++
        }
    }
    finally {
        $parser.Close()
    }
}

# --- (File existence checks are unchanged) ---
if (-not (Test-Path -LiteralPath $ProcessSummaryCsvPath)) { throw "Missing process summary CSV: $ProcessSummaryCsvPath" }
if (-not (Test-Path -LiteralPath $CombinedEventsCsvPath)) { throw "Missing combined events CSV: $CombinedEventsCsvPath" }

# --- (STEP 1: Reading small CSV is unchanged) ---
Write-Host 'STEP 1: Reading and preparing process_summary.csv...'
$procSummaryData = Import-Csv -LiteralPath $ProcessSummaryCsvPath
$procDateCols = @('start','last_update','last_server_update','min_last_server_update','max_last_server_update','min_last_update','max_last_update') ; $procIntCols = @('segment_id') ; $procTextCols = @('process_pid', 'parent_pid', 'id', 'parent_id', 'process_md5')
$procSummaryData = $procSummaryData | ForEach-Object { foreach ($columnName in $procDateCols) { if ($_.PSObject.Properties.Match($columnName)) { $_.$columnName = Try-ParseCbDate $_.$columnName } } ; foreach ($columnName in $procIntCols) { if ($_.PSObject.Properties.Match($columnName)) { $_.$columnName = Try-ParseInt64 $_.$columnName } } ; foreach ($columnName in $procTextCols) { if ($_.PSObject.Properties.Match($columnName)) { $_.$columnName = [string]($_.PSObject.Properties[$columnName].Value) } } ; $_ }

Write-Host 'STEP 2: Building Excel workbook...'
if (Test-Path -LiteralPath $XlsxOutputPath) { Remove-Item -LiteralPath $XlsxOutputPath -Force }

Write-Host " - Creating 'Process_Summary' worksheet..."
$excelPackage = $procSummaryData | Export-Excel `
    -Path $XlsxOutputPath `
    -WorksheetName 'Process_Summary' `
    -AutoSize `
    -PassThru `
    -ErrorAction Stop

# --- MODIFIED: Calling the streaming function ---
Write-Host " - Streaming rows into 'Combined_Events' sheets..."
# We no longer create the sheet here; the function will do it.
Write-CombinedEventsWorksheet `
    -CsvPath $CombinedEventsCsvPath `
    -ExcelPackage $excelPackage `
    -BaseSheetName 'Combined_Events' `
    -MaxRows $MaxRowsPerSheet `
    -ProgressInterval $ProgressInterval

# --- MODIFIED: Auto-fitting logic ---
if (-not $SkipAutoFitCombinedEvents) {
    # Find all sheets that start with "Combined_Events"
    $eventSheets = $excelPackage.Workbook.Worksheets | Where-Object { $_.Name -like 'Combined_Events_*' }
    foreach ($sheet in $eventSheets) {
        if ($sheet.Dimension) {
            Write-Host " - Auto-fitting '$($sheet.Name)' columns..."
            $sheet.Cells[$sheet.Dimension.Address].AutoFitColumns()
        }
    }
}

# --- (STEP 3: Formatting logic is mostly unchanged, but now loops) ---
Write-Host 'STEP 3: Applying column formats...'
$timestampFormat = 'mm/dd/yyyy hh:mm:ss.000'
$procSummaryFormats = @{ 'process_pid'='@';'parent_pid'='@';'id'='@';'parent_id'='@';'process_md5'='@';'segment_id'='0';'start'=$timestampFormat;'last_update'=$timestampFormat;'last_server_update'=$timestampFormat;'min_last_server_update'=$timestampFormat;'max_last_server_update'=$timestampFormat;'min_last_update'=$timestampFormat;'max_last_update'=$timestampFormat }
$eventsFormats = @{ 'pid'='@';'parent_pid'='@';'processId'='@';'target_Id'='@';'proc_segment_id'='0';'event_segment_id'='0';'procstart'=$timestampFormat;'event_time'=$timestampFormat;'start_time'=$timestampFormat;'end_time'=$timestampFormat }

$procSummarySheet = $excelPackage.Workbook.Worksheets['Process_Summary']
if (-not $procSummarySheet) { throw "Process_Summary worksheet is missing!" }
$procHeaderMap = Get-HeaderMapFromSheet -Sheet $procSummarySheet
Write-Host " - Formatting 'Process_Summary' sheet..."
foreach ($columnName in $procSummaryFormats.Keys) { if ($procHeaderMap.ContainsKey($columnName)) { $procSummarySheet.Column($procHeaderMap[$columnName]).Style.Numberformat.Format = $procSummaryFormats[$columnName] } }

# --- MODIFIED: Formatting now loops through all event sheets ---
$eventSheets = $excelPackage.Workbook.Worksheets | Where-Object { $_.Name -like 'Combined_Events_*' }
foreach ($sheet in $eventSheets) {
    Write-Host " - Formatting '$($sheet.Name)' sheet..."
    $eventsHeaderMap = Get-HeaderMapFromSheet -Sheet $sheet
    foreach ($columnName in $eventsFormats.Keys) {
        if ($eventsHeaderMap.ContainsKey($columnName)) {
            $sheet.Column($eventsHeaderMap[$columnName]).Style.Numberformat.Format = $eventsFormats[$columnName]
        }
    }
}

Write-Host 'STEP 4: Saving workbook...'
Close-ExcelPackage -ExcelPackage $excelPackage
Write-Host "Successfully created and formatted XLSX file at: $XlsxOutputPath"
