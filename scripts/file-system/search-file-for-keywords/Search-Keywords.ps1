<#
Search-Keywords.ps1
Usage:
  .\Search-Keywords.ps1 -InputPath "C:\evidence\doc.docx" -KeywordsPath "C:\evidence\keywords.txt" -OutputPath "C:\evidence\output.txt"

Keywords file: one keyword per line (blank lines ignored).
Output format:
  Keyword: <word> | Line: `<`#`> | Context: <entire string from the line containing the match>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$KeywordsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Keywords {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Keywords file not found: $Path"
    }

    $keys = Get-Content -LiteralPath $Path -ErrorAction Stop |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" } |
        Select-Object -Unique

    if (-not $keys -or $keys.Count -eq 0) {
        throw "No keywords found in: $Path"
    }

    return $keys
}

function Get-TextLinesFromTxt {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -ErrorAction Stop
}

function Get-TextLinesFromDocxOpenXml {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -ne ".docx") {
        throw "Get-TextLinesFromDocxOpenXml called with non-docx file: $Path"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry("word/document.xml")
        if (-not $entry) {
            throw "This .docx does not contain word/document.xml (unexpected format)."
        }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { $xmlText = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }

    [xml]$xml = $xmlText

    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsm.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main") | Out-Null

    $paragraphs = $xml.SelectNodes("//w:p", $nsm)
    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($p in $paragraphs) {
        $texts = $p.SelectNodes(".//w:t", $nsm)
        if ($texts -and $texts.Count -gt 0) {
            $sb = New-Object System.Text.StringBuilder
            foreach ($t in $texts) { [void]$sb.Append($t.InnerText) }
            $line = $sb.ToString().Trim()
            if ($line -ne "") { $lines.Add($line) }
        }
    }

    if ($lines.Count -eq 0) {
        $fallback = ($xmlText -replace "<[^>]+>", " " -replace "\s+", " ").Trim()
        if ($fallback) { $lines.Add($fallback) }
    }

    return $lines
}

function Get-TextLinesFromWordCom {
    <#
      Extract text from .doc or .docx using Word COM automation.
      "Line" returned is paragraph number (1-based).
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }

    $word = $null
    $doc  = $null

    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $word.DisplayAlerts = 0

        # Open read-only, don't add to recent files
        $doc = $word.Documents.Open($Path, $false, $true, $false)

        $lines = New-Object System.Collections.Generic.List[string]

        # Paragraphs are the most reliable "line-ish" unit in Word
        foreach ($p in $doc.Paragraphs) {
            $text = [string]$p.Range.Text

            if ($null -ne $text) {
                # Word paragraphs often end with `r` (0x0D)
                $clean = ($text -replace "[\r\n]+", " ").Trim()
                if ($clean -ne "") { $lines.Add($clean) }
            }
        }

        return $lines
    }
    finally {
        # Close doc and quit Word
        if ($doc -ne $null) {
            try { $doc.Close([ref]$false) } catch {}
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($doc) } catch {}
        }
        if ($word -ne $null) {
            try { $word.Quit() } catch {}
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($word) } catch {}
        }

        # Encourage COM cleanup
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

# --- Main ---

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
}

$keywords = Get-Keywords -Path $KeywordsPath

$ext = [IO.Path]::GetExtension($InputPath).ToLowerInvariant()

$lines =
    switch ($ext) {
        ".txt"  { Get-TextLinesFromTxt -Path $InputPath }
        ".log"  { Get-TextLinesFromTxt -Path $InputPath }
        ".csv"  { Get-TextLinesFromTxt -Path $InputPath }  # treat as plain lines
        ".doc"  { Get-TextLinesFromWordCom -Path $InputPath }
        ".docx" {
            # If Word is guaranteed installed, you can standardize on COM for docx too.
            # Keeping OpenXML as a fallback option, but defaulting to COM here for consistency.
            Get-TextLinesFromWordCom -Path $InputPath
            # If you prefer OpenXML for .docx, swap the line above for:
            # Get-TextLinesFromDocxOpenXml -Path $InputPath
        }
        default { throw "Unsupported input type '$ext'. Use .txt/.log/.csv/.doc/.docx." }
    }

$null = New-Item -ItemType File -Path $OutputPath -Force

$results = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $lineNum = $i + 1
    $context = $lines[$i]

    foreach ($kw in $keywords) {
        if ([string]::IsNullOrWhiteSpace($kw)) { continue }

        # Whole-word, case-insensitive
        $pattern = "(?i)\b$([Regex]::Escape($kw))\b"

        if ($context -match $pattern) {
            $results.Add("Keyword: $kw | Line: $lineNum | Context: $context")
        }
    }
}

if ($results.Count -gt 0) {
    $results | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} else {
    "No matches found." | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

Write-Host "Done. Wrote $($results.Count) match(es) to: $OutputPath"