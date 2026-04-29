<!--
README template for a single script folder under scripts/<category>/<script-name>/.

Copy this file as README.md inside the script folder and fill in each section.
Sections marked "Optional" can be deleted if they don't apply. The required
sections at the top are: title, lead paragraph, What it does, Requirements,
Basic usage, Parameters.

Match the tone of the existing READMEs in scripts/file-system/ — clean
markdown, no emojis, prefer tables for structured information.
-->

# <Script-Name.ps1>

`<Script-Name.ps1>` <one-sentence description of what it does and who it's for>. It is intended for <forensic triage / alert investigation / data extraction / reporting / etc.>.

<Optional second paragraph: any high-level context — input formats, design constraints, why it exists. Delete if the lead sentence is enough.>

## What it does

<Narrative or bulleted description of the script's behavior. For data-collection scripts, list what is collected. For workflow scripts, describe the pipeline stages.>

<!-- Use a table when the script has many discrete outputs or capabilities:

| Output field | Description |
|---|---|
| `Field1` | What it contains. |
| `Field2` | What it contains. |
-->

## Supported input types
<!-- Optional — include only if the script discriminates between input types. -->

| Extension | Handling |
|---|---|
| `.txt` | <How it's processed.> |
| `.docx` | <How it's processed.> |

## Requirements

- Windows
- PowerShell 5.1+ (or 7+ if required)
- <Any external software, e.g. Microsoft Word for `.doc` COM automation>
- <Any required permissions, e.g. read access to target files and ACLs>
- <Any required network reach or API credentials>

## Installation
<!-- Optional — include only if the script needs special placement or loading. -->

Place the script in:

```text
E:\dev\automation-library\scripts\<category>\<script-name>\<Script-Name.ps1>
```

<!-- For function-style scripts that must be dot-sourced: -->

This script defines a function. Dot-source it before calling:

```powershell
. .\<Script-Name.ps1>
```

After dot-sourcing, the function is available in the current session.

## Basic usage

```powershell
.\<Script-Name.ps1> -<Param1> "<value>" -<Param2> "<value>"
```

## Parameters

| Parameter | Required | Description |
|---|---:|---|
| `-<Param1>` | Yes | <What it does.> |
| `-<Param2>` | Yes | <What it does.> |
| `-<Param3>` | No | <What it does. Default: <value>.> |

## Usage examples

### <Common case>

```powershell
.\<Script-Name.ps1> -<Param1> "<example value>"
```

### <Another case>

```powershell
.\<Script-Name.ps1> `
  -<Param1> "<example value>" `
  -<Param2> "<example value>"
```

## Output format
<!-- Optional — include if output structure is non-obvious. -->

<Describe the structure of what the script returns or writes. Show a sample.>

```text
<Sample output here>
```

## Pipeline usage
<!-- Optional — include only if the script accepts pipeline input. -->

The script accepts pipeline input, so it composes with `Get-ChildItem`:

```powershell
Get-ChildItem "<path>" -File -Recurse | <Function-Name>
```

## Exporting results
<!-- Optional — include if the script produces structured data worth exporting. -->

### Export to JSON

```powershell
<Function-Name> -<Param> "<value>" |
ConvertTo-Json -Depth 20 |
Out-File ".\output.json" -Encoding UTF8
```

### Export to CSV

```powershell
<Function-Name> -<Param> "<value>" |
Export-Csv ".\output.csv" -NoTypeInformation -Encoding UTF8
```

## Running with execution policy bypass

If PowerShell blocks the script, run it in a temporary bypassed session:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\<Script-Name.ps1>" -<Param1> "<value>"
```

Or for PowerShell 7:

```powershell
pwsh.exe -ExecutionPolicy Bypass -File ".\<Script-Name.ps1>" -<Param1> "<value>"
```

## Notes and limitations

- <Known limitation: e.g. does not recurse folders by itself.>
- <Platform-specific behavior: e.g. NTFS-only features.>
- <Best-effort behavior: e.g. malformed files may produce empty fields silently.>

## Troubleshooting

### <Common symptom>

<Cause and fix.>

### <Another symptom>

<Cause and fix.>

## Suggested use cases
<!-- Optional — include if the script has obvious operational use cases worth surfacing. -->

- <Use case>
- <Use case>
- <Use case>
