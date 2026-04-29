## Entry: export processes by host for a time frame
================================================

## Summary:\
This automation orchestrates a full Carbon Black data collection and processing workflow. It retrieves process data from the Carbon Black API, converts raw JSON output into structured CSV format, and further transforms the data into Excel (XLSX) for analyst-friendly review and reporting. The workflow enables efficient triage and analysis of endpoint activity by standardizing and exporting data into usable formats.

## Category: EDR / Endpoint Triage

### Language: PowerShell

### Status: Production

### Primary Script: Run-FullCBWorkflow.ps1

### Supporting Scripts: ConvertJSON-ToCSV.ps1, Convert-ToXlsx.ps1

## Components
----------

Run-FullCBWorkflow.ps1:\
Acts as the main controller. Coordinates API queries, data retrieval, and calls downstream processing scripts.

ConvertJSON-ToCSV.ps1:\
Parses Carbon Black JSON event/process data and converts it into structured CSV format for analysis.

Convert-ToXlsx.ps1:\
Converts CSV output into Excel (XLSX) format for easier analyst consumption and reporting.

## Inputs
------

- Carbon Black API credentials\
- Query parameters (hostname, Start time, End time)

## Outputs
-------

- JSON (raw)\
- CSV (structured)\
- XLSX (final report format)

## Tags
----

carbon-black, edr, triage, data-processing, reporting, powershell