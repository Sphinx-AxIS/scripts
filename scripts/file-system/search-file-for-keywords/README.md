# Search-Keywords.ps1

`Search-Keywords.ps1` searches a supported input file for a list of keywords and writes any matches to an output text file. It is useful for quick document triage, keyword sweeps, investigative review, and basic evidence screening.

The script supports plain-text style files such as `.txt`, `.log`, and `.csv`, as well as Microsoft Word `.doc` and `.docx` files.

## What the script does

The script:

1. Reads a keyword list from a text file.
2. Ignores blank keyword lines.
3. Removes duplicate keywords.
4. Extracts searchable text from the input file.
5. Searches for each keyword using whole-word, case-insensitive matching.
6. Writes matching results to an output file.
7. Writes `No matches found.` if no keywords are found in the input file.

Each match includes:

- The matched keyword
- The line or paragraph number
- The full line or paragraph containing the match

## Basic syntax

```powershell
.\Search-Keywords.ps1 -InputPath "<input-file>" -KeywordsPath "<keywords-file>" -OutputPath "<output-file>"
```

Example:

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\evidence\doc.docx" `
  -KeywordsPath "C:\evidence\keywords.txt" `
  -OutputPath "C:\evidence\output.txt"
```

## Parameters

| Parameter | Required | Description |
|---|---:|---|
| `-InputPath` | Yes | Path to the file you want to search. |
| `-KeywordsPath` | Yes | Path to a text file containing keywords, one per line. |
| `-OutputPath` | Yes | Path where the result file should be written. Existing files are overwritten. |

## Supported input file types

| Extension | Handling |
|---|---|
| `.txt` | Read as plain text using `Get-Content`. |
| `.log` | Read as plain text using `Get-Content`. |
| `.csv` | Read as plain text line by line. |
| `.doc` | Read using Microsoft Word COM automation. |
| `.docx` | Read using Microsoft Word COM automation by default. |

Unsupported file types will cause the script to stop with an error similar to:

```text
Unsupported input type '.ext'. Use .txt/.log/.csv/.doc/.docx.
```

## Keyword file format

The keyword file should contain one keyword or phrase per line.

Example `keywords.txt`:

```text
password
credential
invoice
bank account
admin
```

Blank lines are ignored. Duplicate entries are removed.

Leading and trailing spaces are trimmed, so this:

```text
  password  
```

is treated as:

```text
password
```

## Match behavior

The script uses:

- Case-insensitive matching
- Whole-word matching
- Literal keyword matching using regex escaping

This means a keyword such as:

```text
admin
```

will match:

```text
admin logged in
```

but should not match inside a larger word such as:

```text
administrator
```

A phrase such as:

```text
bank account
```

can match the phrase as written in the source line or paragraph.

## Output format

Matches are written using this format:

```text
Keyword: <keyword> | Line: <line-number> | Context: <full line or paragraph containing the match>
```

Example output:

```text
Keyword: password | Line: 17 | Context: The user changed the password on March 12.
Keyword: admin | Line: 42 | Context: Admin access was requested by the helpdesk technician.
```

If there are no matches, the output file contains:

```text
No matches found.
```

## Understanding line numbers

For `.txt`, `.log`, and `.csv` files, `Line` refers to the text line number in the file.

For `.doc` and `.docx` files, `Line` refers to the extracted Word paragraph number, not a visual line number as displayed in Microsoft Word. This is because Word documents do not store text in the same line-oriented way as plain text files.

## Usage examples

### Search a text file

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\evidence\notes.txt" `
  -KeywordsPath "C:\evidence\keywords.txt" `
  -OutputPath "C:\evidence\notes-keyword-hits.txt"
```

### Search a log file

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\logs\security.log" `
  -KeywordsPath "C:\cases\keywords.txt" `
  -OutputPath "C:\cases\security-keyword-hits.txt"
```

### Search a CSV file as plain text

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\exports\mailbox-export.csv" `
  -KeywordsPath "C:\cases\keywords.txt" `
  -OutputPath "C:\cases\mailbox-keyword-hits.txt"
```

### Search a Word document

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\evidence\statement.docx" `
  -KeywordsPath "C:\cases\keywords.txt" `
  -OutputPath "C:\cases\statement-keyword-hits.txt"
```

### Search a legacy `.doc` file

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\evidence\legacy-document.doc" `
  -KeywordsPath "C:\cases\keywords.txt" `
  -OutputPath "C:\cases\legacy-document-keyword-hits.txt"
```

## Example workflow

Create a keyword file:

```powershell
@"
password
credential
admin
remote access
invoice
"@ | Set-Content -Path "C:\cases\keywords.txt" -Encoding UTF8
```

Run the search:

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\evidence\document.docx" `
  -KeywordsPath "C:\cases\keywords.txt" `
  -OutputPath "C:\cases\document-keyword-hits.txt"
```

Review the results:

```powershell
Get-Content "C:\cases\document-keyword-hits.txt"
```

## Running from another directory

Use full paths if your current PowerShell location is not the same folder as the script:

```powershell
& "E:\dev\automation-library\scripts\file-system\Search-Keywords.ps1" `
  -InputPath "D:\Evidence\document.docx" `
  -KeywordsPath "D:\Evidence\keywords.txt" `
  -OutputPath "D:\Evidence\keyword-results.txt"
```

The call operator `&` is used to execute a script path that is quoted.

## Running with execution policy bypass

If PowerShell blocks the script because of execution policy, run it in a temporary bypassed session:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Search-Keywords.ps1" `
  -InputPath "C:\evidence\doc.docx" `
  -KeywordsPath "C:\evidence\keywords.txt" `
  -OutputPath "C:\evidence\output.txt"
```

## Requirements

- Windows PowerShell or PowerShell on Windows
- Microsoft Word installed for `.doc` and `.docx` support
- Read access to the input file and keyword file
- Write access to the output path

Word document support uses Microsoft Word COM automation through:

```powershell
New-Object -ComObject Word.Application
```

Because of that, `.doc` and `.docx` searching is intended for Windows systems with Microsoft Word installed.

## OpenXML `.docx` extraction note

The script includes an OpenXML-based `.docx` extraction function, but the active `.docx` path currently defaults to Word COM automation for consistency with `.doc` handling.

Inside the script, the `.docx` block uses:

```powershell
Get-TextLinesFromWordCom -Path $InputPath
```

The script comments note that this can be swapped to:

```powershell
Get-TextLinesFromDocxOpenXml -Path $InputPath
```

This may be useful if you want `.docx` searching without relying on Microsoft Word, but it will not support legacy `.doc` files.

## Troubleshooting

### The script says the input file was not found

Check the path and use `-LiteralPath`-safe syntax by wrapping the path in quotes:

```powershell
.\Search-Keywords.ps1 `
  -InputPath "C:\path with spaces\document.docx" `
  -KeywordsPath "C:\cases\keywords.txt" `
  -OutputPath "C:\cases\output.txt"
```

### The script says the keywords file was not found

Confirm the keyword file exists:

```powershell
Test-Path "C:\cases\keywords.txt"
```

### The script says no keywords were found

Make sure the keyword file has at least one non-blank line:

```powershell
Get-Content "C:\cases\keywords.txt"
```

### The output says `No matches found.`

This means the script ran successfully but did not find any whole-word keyword matches. Check for:

- Misspellings
- Different word forms
- Keywords embedded inside larger words
- OCR requirements for scanned documents
- Text stored in images rather than selectable document text

### Word documents do not search correctly

For `.doc` and `.docx` files, confirm Microsoft Word is installed and can be launched by the current user.

You can also test whether Word COM automation works:

```powershell
$word = New-Object -ComObject Word.Application
$word.Quit()
```

### Scanned PDFs or image-only documents

This script does not perform OCR and does not support PDF input. Convert the content to text first, or use an OCR-capable workflow before running keyword searches.

## Limitations

- The script does not search folders recursively by itself.
- The script processes one input file per run.
- It does not support PDF, HTML, RTF, XLSX, PST, EML, or image files.
- It does not perform OCR.
- Word line numbers are paragraph numbers, not visual line numbers.
- Output is plain text, not CSV or JSON.
- Matches are whole-word and case-insensitive; partial-word matching is not enabled.

## Batch-processing example

Although the script handles one file at a time, you can call it repeatedly from a wrapper loop.

Example: search all `.txt` files in a folder and write one output file per input file.

```powershell
$script = "E:\dev\automation-library\scripts\file-system\Search-Keywords.ps1"
$keywords = "D:\Evidence\keywords.txt"
$outputDir = "D:\Evidence\keyword-results"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Get-ChildItem "D:\Evidence" -File -Filter *.txt | ForEach-Object {
    $outFile = Join-Path $outputDir "$($_.BaseName)-keyword-hits.txt"

    & $script `
      -InputPath $_.FullName `
      -KeywordsPath $keywords `
      -OutputPath $outFile
}
```

Example: search supported document types recursively.

```powershell
$script = "E:\dev\automation-library\scripts\file-system\Search-Keywords.ps1"
$keywords = "D:\Evidence\keywords.txt"
$outputDir = "D:\Evidence\keyword-results"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Get-ChildItem "D:\Evidence" -File -Recurse |
Where-Object { $_.Extension.ToLowerInvariant() -in ".txt", ".log", ".csv", ".doc", ".docx" } |
ForEach-Object {
    $safeName = $_.FullName.Replace(":", "").Replace("\", "_")
    $outFile = Join-Path $outputDir "$safeName.keyword-hits.txt"

    & $script `
      -InputPath $_.FullName `
      -KeywordsPath $keywords `
      -OutputPath $outFile
}
```

## Exit and status behavior

The script writes a status message to the console when complete:

```text
Done. Wrote <number> match(es) to: <output-path>
```

Errors such as missing files, empty keyword lists, unsupported file extensions, or Word COM failures stop execution because the script uses:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
```

## Suggested use cases

- Keyword sweeps across investigative notes
- Triage of text exports
- Searching Windows logs exported as text
- Searching CSV exports from email, endpoint, or case-management tools
- Reviewing Word documents for names, entities, indicators, or terms of interest
- Quick case-specific hit reports
