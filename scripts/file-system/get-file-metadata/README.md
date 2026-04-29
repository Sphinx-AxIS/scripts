# Get-AllFileMetadata.ps1

`Get-AllFileMetadata.ps1` provides a PowerShell function named `Get-AllFileMetadata` for collecting file metadata from one file or many files. It is intended for forensic triage, file review, scripting, and quick metadata enrichment during investigations.

The function accepts a file path directly or from the pipeline and returns a structured PowerShell object containing filesystem timestamps, NTFS stream information, ownership and ACL details, file hashes, Authenticode signature data, Windows Shell extended properties, Office document metadata, embedded Office objects, and best-effort PDF metadata.

## What it collects

For each file, the function attempts to collect the following fields:

| Output field | Description |
|---|---|
| `FileSystemInfo` | Basic file details such as full path, file name, size, mode/attributes, creation time, last write time, and last access time. |
| `Streams` | NTFS alternate data stream information using `Get-Item -Stream *`. |
| `Owner` | File owner from the file ACL. |
| `ACL` | File access control entries. |
| `Hashes` | MD5, SHA1, and SHA256 hashes using `Get-FileHash`. |
| `Authenticode` | Authenticode signature information using `Get-AuthenticodeSignature`. |
| `ShellProperties` | Windows Shell extended properties exposed by `Shell.Application`. |
| `OfficeProperties` | Metadata from Office Open XML files such as `.docx`, `.xlsx`, and `.pptx`. |
| `EmbeddedObjects` | Embedded objects found inside Office Open XML files, or OLE objects discovered in legacy `.doc` files through Word COM automation. |
| `PdfMetadata` | Best-effort PDF XMP metadata and PDF Info dictionary fields. |

## Supported file types

The function can be run against any file. Some metadata categories only populate for certain file types.

| File type | Expected behavior |
|---|---|
| Any file | Filesystem info, streams, ACLs, hashes, Authenticode, and shell properties where available. |
| `.docx`, `.xlsx`, `.pptx` | Parses Office ZIP container metadata from `docProps/core.xml` and `docProps/app.xml`; also checks common embedded-object folders. |
| `.doc` | Attempts to use Microsoft Word COM automation to inspect embedded OLE objects. |
| `.pdf` | Attempts to parse XMP metadata and selected PDF Info dictionary fields. |
| Other files | Office, embedded-object, and PDF-specific sections are normally empty. |

Empty sections such as `OfficeProperties : {}` or `PdfMetadata : {}` are normal when the file type does not support that metadata category.

## Requirements

- Windows
- PowerShell 5.1 or later recommended
- NTFS volume for alternate data stream collection
- Microsoft Word installed if you want legacy `.doc` OLE-object inspection
- Permission to read the target files and their ACLs

Some features rely on Windows COM objects, especially:

- `Shell.Application` for Windows Shell extended properties
- `Word.Application` for legacy `.doc` embedded OLE object inspection

The script is therefore intended to run on Windows rather than Linux or macOS.

## Installation

Save the script as:

```powershell
Get-AllFileMetadata.ps1
```

Place it in a working scripts directory, for example:

```text
E:\dev\automation-library\scripts\file-system\Get-AllFileMetadata.ps1
```

## Loading the function

Because the file defines a function, dot-source the script before calling `Get-AllFileMetadata`:

```powershell
. .\Get-AllFileMetadata.ps1
```

After dot-sourcing, the function is available in the current PowerShell session.

## Basic usage

Analyze a single file:

```powershell
Get-AllFileMetadata -Path "D:\Tim\scripts\Powershell\File_modification\BestGuess-Extensions.ps1"
```

Show the full top-level object:

```powershell
Get-AllFileMetadata -Path "D:\Tim\scripts\Powershell\File_modification\BestGuess-Extensions.ps1" |
Format-List *
```

Store the result in a variable:

```powershell
$result = Get-AllFileMetadata -Path "D:\Tim\scripts\Powershell\File_modification\BestGuess-Extensions.ps1"
```

Then inspect individual sections:

```powershell
$result.FileSystemInfo
$result.Streams
$result.Owner
$result.ACL
$result.Hashes
$result.Authenticode
$result.ShellProperties
$result.OfficeProperties
$result.EmbeddedObjects
$result.PdfMetadata
```

## Viewing nested output clearly

PowerShell may summarize nested objects in the console. For more detail, format specific sections directly.

View hashes:

```powershell
$result.Hashes | Format-List *
```

View ACL entries:

```powershell
$result.ACL |
Format-Table IdentityReference, FileSystemRights, AccessControlType, IsInherited -AutoSize
```

View Authenticode signature details:

```powershell
$result.Authenticode | Format-List *
```

View Shell properties:

```powershell
$result.ShellProperties | Format-List *
```

View embedded objects:

```powershell
$result.EmbeddedObjects | Format-Table -AutoSize
```

View PDF metadata:

```powershell
$result.PdfMetadata | Format-List *
```

## Pipeline usage

The function accepts pipeline input. This allows it to work naturally with `Get-ChildItem`.

Analyze all files in a directory:

```powershell
Get-ChildItem "D:\Evidence" -File |
Get-AllFileMetadata
```

Analyze all files recursively:

```powershell
Get-ChildItem "D:\Evidence" -File -Recurse |
Get-AllFileMetadata
```

Analyze selected file types:

```powershell
Get-ChildItem "D:\Evidence" -File -Recurse -Include *.docx,*.xlsx,*.pptx,*.pdf |
Get-AllFileMetadata
```

Analyze recently modified files:

```powershell
Get-ChildItem "D:\Evidence" -File -Recurse |
Where-Object LastWriteTime -ge (Get-Date).AddDays(-7) |
Get-AllFileMetadata
```

## Exporting results

### Export one file to JSON

```powershell
Get-AllFileMetadata -Path "D:\Evidence\sample.pdf" |
ConvertTo-Json -Depth 20 |
Out-File ".\sample.metadata.json" -Encoding UTF8
```

### Export a directory to JSON

```powershell
Get-ChildItem "D:\Evidence" -File -Recurse |
Get-AllFileMetadata |
ConvertTo-Json -Depth 20 |
Out-File ".\metadata-folder.json" -Encoding UTF8
```

### Export selected summary fields to CSV

CSV is best for flattened summary data. Nested fields such as ACLs, shell properties, and embedded objects are better suited to JSON.

```powershell
Get-ChildItem "D:\Evidence" -File -Recurse |
Get-AllFileMetadata |
Select-Object `
  @{Name='FullName';Expression={$_.FileSystemInfo.FullName}},
  @{Name='Name';Expression={$_.FileSystemInfo.Name}},
  @{Name='Length';Expression={$_.FileSystemInfo.Length}},
  @{Name='CreationTime';Expression={$_.FileSystemInfo.CreationTime}},
  @{Name='LastWriteTime';Expression={$_.FileSystemInfo.LastWriteTime}},
  @{Name='LastAccessTime';Expression={$_.FileSystemInfo.LastAccessTime}},
  Owner,
  @{Name='MD5';Expression={$_.Hashes.MD5}},
  @{Name='SHA1';Expression={$_.Hashes.SHA1}},
  @{Name='SHA256';Expression={$_.Hashes.SHA256}},
  @{Name='SignatureStatus';Expression={$_.Authenticode.Status}} |
Export-Csv ".\metadata-summary.csv" -NoTypeInformation -Encoding UTF8
```

## Example forensic workflow

```powershell
. .\Get-AllFileMetadata.ps1

$root = "D:\Evidence"

$metadata = Get-ChildItem $root -File -Recurse |
Get-AllFileMetadata

$metadata |
ConvertTo-Json -Depth 20 |
Out-File ".\evidence-metadata-full.json" -Encoding UTF8

$metadata |
Select-Object `
  @{Name='FullName';Expression={$_.FileSystemInfo.FullName}},
  @{Name='Length';Expression={$_.FileSystemInfo.Length}},
  @{Name='LastWriteTime';Expression={$_.FileSystemInfo.LastWriteTime}},
  Owner,
  @{Name='SHA256';Expression={$_.Hashes.SHA256}},
  @{Name='SignatureStatus';Expression={$_.Authenticode.Status}} |
Export-Csv ".\evidence-metadata-summary.csv" -NoTypeInformation -Encoding UTF8
```

## Running with execution policy bypass

If PowerShell blocks the script because of local execution policy, you can start a temporary bypassed session:

```powershell
powershell.exe -ExecutionPolicy Bypass
```

Then dot-source and run the script:

```powershell
. .\Get-AllFileMetadata.ps1
Get-AllFileMetadata -Path "D:\Evidence\sample.docx"
```

Alternatively, from PowerShell 7:

```powershell
pwsh.exe -ExecutionPolicy Bypass
```

## Notes and limitations

- The script is best-effort. Some metadata sources may fail silently if the file is locked, inaccessible, malformed, unsupported, or missing required software.
- Empty metadata sections are normal for unsupported file types.
- Alternate data stream collection is NTFS-specific.
- Shell extended properties depend on Windows Shell behavior and may vary by file type, installed handlers, and operating system version.
- Legacy `.doc` OLE inspection requires Microsoft Word to be installed and available through COM automation.
- PDF parsing is intentionally lightweight and does not replace a full PDF forensic parser.
- JSON output is recommended when preserving nested metadata such as ACLs, Shell properties, embedded objects, and PDF metadata.
- CSV output is useful for summary reporting, but complex nested values should be flattened first.

## Troubleshooting

### The script runs but nothing happens

The script defines a function. Dot-source it first, then call the function:

```powershell
. .\Get-AllFileMetadata.ps1
Get-AllFileMetadata -Path "D:\Evidence\sample.pdf"
```

### `OfficeProperties`, `EmbeddedObjects`, or `PdfMetadata` are empty

This is usually expected when the file is not an Office document or PDF. For example, a `.ps1` file should normally have empty Office and PDF metadata sections.

### ACL or Owner is blank

Check whether your account has permission to read the file ACL:

```powershell
Get-Acl -LiteralPath "D:\Evidence\sample.pdf"
```

### Shell properties are sparse or missing

Shell properties depend on installed Windows property handlers. Some file types expose many properties; others expose very few.

### Legacy `.doc` embedded object checks do not work

Confirm that Microsoft Word is installed and can be launched by the current user. The legacy `.doc` path uses Word COM automation.

## Function name

The script exposes this function:

```powershell
Get-AllFileMetadata
```

Parameter:

```powershell
-Path <string>
```

The `Path` parameter is mandatory and accepts pipeline input by value or by property name. It also supports the alias `FullName`, which allows direct pipeline use from `Get-ChildItem`.
