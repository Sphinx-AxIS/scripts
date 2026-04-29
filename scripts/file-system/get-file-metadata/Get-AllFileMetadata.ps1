function Get-AllFileMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string]$Path
    )

    begin {
        try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}
    }

    process {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Error "Path not found: $Path"
            return
        }

        $fileItem = $null
        try {
            $fileItem = Get-Item -LiteralPath $Path -ErrorAction Stop
        } catch {
            Write-Error "Unable to read item: $Path. $($_.Exception.Message)"
            return
        }

        $fullPath = $fileItem.FullName
        $ext = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
        $isOfficeZip = $ext -in @('.docx', '.xlsx', '.pptx')
        $isLegacyDoc = $ext -eq '.doc'
        $isPdf = $ext -eq '.pdf'

        function Get-Sha256FromStream {
            param([System.IO.Stream]$Stream)
            $sha = $null
            try {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                [System.BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-', '')
            } finally {
                if ($sha) { $sha.Dispose() }
            }
        }

        function Convert-HashtableToObject {
            param($InputHashtable)

            $ordered = [ordered]@{}
            if ($null -eq $InputHashtable) { return [pscustomobject]$ordered }

            foreach ($key in @($InputHashtable.Keys)) {
                $ordered[[string]$key] = $InputHashtable[$key]
            }

            return [pscustomobject]$ordered
        }

        function Convert-AclAccessToObject {
            param($AccessRules)

            $items = @()
            foreach ($rule in @($AccessRules)) {
                if ($null -eq $rule) { continue }
                $items += [pscustomobject]@{
                    IdentityReference = [string]$rule.IdentityReference
                    FileSystemRights  = [string]$rule.FileSystemRights
                    AccessControlType = [string]$rule.AccessControlType
                    IsInherited       = [bool]$rule.IsInherited
                    InheritanceFlags  = [string]$rule.InheritanceFlags
                    PropagationFlags  = [string]$rule.PropagationFlags
                }
            }

            return $items
        }

        function Convert-AuthenticodeToObject {
            param($Signature)

            if ($null -eq $Signature) { return $null }

            $signer = $null
            if ($Signature.SignerCertificate) {
                $signer = [pscustomobject]@{
                    Subject    = $Signature.SignerCertificate.Subject
                    Issuer     = $Signature.SignerCertificate.Issuer
                    Thumbprint = $Signature.SignerCertificate.Thumbprint
                    NotBefore  = $Signature.SignerCertificate.NotBefore
                    NotAfter   = $Signature.SignerCertificate.NotAfter
                }
            }

            $timestamp = $null
            if ($Signature.TimeStamperCertificate) {
                $timestamp = [pscustomobject]@{
                    Subject    = $Signature.TimeStamperCertificate.Subject
                    Issuer     = $Signature.TimeStamperCertificate.Issuer
                    Thumbprint = $Signature.TimeStamperCertificate.Thumbprint
                    NotBefore  = $Signature.TimeStamperCertificate.NotBefore
                    NotAfter   = $Signature.TimeStamperCertificate.NotAfter
                }
            }

            return [pscustomobject]@{
                Status                 = [string]$Signature.Status
                StatusMessage          = $Signature.StatusMessage
                Path                   = $Signature.Path
                SignatureType          = [string]$Signature.SignatureType
                IsOSBinary             = $Signature.IsOSBinary
                SignerCertificate      = $signer
                TimeStamperCertificate = $timestamp
            }
        }

        function Get-OfficeZipProps {
            param([string]$FullPath)

            $result = [ordered]@{
                OfficeProperties = @{}
                EmbeddedObjects  = @()
            }

            $zip = $null
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($FullPath)

                foreach ($name in @('docProps/core.xml', 'docProps/app.xml')) {
                    $entry = $zip.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
                    if (-not $entry) { continue }

                    $sr = $null
                    try {
                        $sr = $entry.Open()
                        $xml = New-Object System.Xml.XmlDocument
                        $xml.PreserveWhitespace = $true
                        $xml.Load($sr)

                        foreach ($node in $xml.SelectNodes('//*')) {
                            $key = if ($name -eq 'docProps/app.xml') { "app_$($node.LocalName)" } else { $node.LocalName }
                            if ($node.InnerText -and -not $result.OfficeProperties.ContainsKey($key)) {
                                $result.OfficeProperties[$key] = $node.InnerText
                            }
                        }
                    } catch {
                    } finally {
                        if ($sr) { $sr.Close(); $sr.Dispose() }
                    }
                }

                $embedRoots = @('word/embeddings/', 'xl/embeddings/', 'ppt/embeddings/')
                $embedEntries = @($zip.Entries | Where-Object {
                    $entryName = $_.FullName
                    foreach ($root in $embedRoots) {
                        if ($entryName -like "$root*") { return $true }
                    }
                    return $false
                })

                foreach ($entry in $embedEntries) {
                    $sha256 = $null
                    $s = $null
                    $ms = $null
                    try {
                        $s = $entry.Open()
                        $ms = New-Object System.IO.MemoryStream
                        $s.CopyTo($ms)
                        $ms.Position = 0
                        $sha256 = Get-Sha256FromStream -Stream $ms
                    } catch {
                    } finally {
                        if ($s) { $s.Close(); $s.Dispose() }
                        if ($ms) { $ms.Dispose() }
                    }

                    $result.EmbeddedObjects += [pscustomobject]@{
                        PathInContainer  = $entry.FullName
                        CompressedLength = $entry.CompressedLength
                        Length           = $entry.Length
                        SHA256           = $sha256
                        GuessedType      = [System.IO.Path]::GetExtension($entry.FullName)
                    }
                }
            } catch {
            } finally {
                if ($zip) { $zip.Dispose() }
            }

            return $result
        }

        function Get-LegacyDocViaWord {
            param([string]$FullPath)

            $result = [ordered]@{
                OfficeProperties = @{}
                EmbeddedObjects  = @()
            }

            $word = $null
            $doc = $null
            try {
                $word = New-Object -ComObject Word.Application
                $word.Visible = $false
                $doc = $word.Documents.Open($FullPath, $false, $true) # ConfirmConversions=$false, ReadOnly=$true

                try {
                    foreach ($prop in $doc.BuiltInDocumentProperties) {
                        try {
                            if ($prop.Name) { $result.OfficeProperties[$prop.Name] = $prop.Value }
                        } catch {}
                    }
                } catch {}

                try {
                    foreach ($prop in $doc.CustomDocumentProperties) {
                        try {
                            if ($prop.Name) { $result.OfficeProperties[$prop.Name] = $prop.Value }
                        } catch {}
                    }
                } catch {}

                foreach ($ish in @($doc.InlineShapes)) {
                    try {
                        if ($ish.OLEFormat) {
                            $of = $ish.OLEFormat
                            $result.EmbeddedObjects += [pscustomobject]@{
                                Container  = 'InlineShape'
                                ProgID     = $of.ProgID
                                ClassType  = $of.ClassType
                                IconLabel  = $of.IconLabel
                                Object     = $of.Object -ne $null
                                SourceName = $of.SourceName
                            }
                        }
                    } catch {}
                }

                foreach ($shape in @($doc.Shapes)) {
                    try {
                        if ($shape.Type -eq 1 -and $shape.OLEFormat) { # 1 = msoEmbeddedOLEObject
                            $of = $shape.OLEFormat
                            $result.EmbeddedObjects += [pscustomobject]@{
                                Container  = 'Shape'
                                ProgID     = $of.ProgID
                                ClassType  = $of.ClassType
                                IconLabel  = $of.IconLabel
                                Object     = $of.Object -ne $null
                                SourceName = $of.SourceName
                            }
                        }
                    } catch {}
                }
            } catch {
            } finally {
                if ($doc) {
                    try { $doc.Close($false) } catch {}
                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($doc) | Out-Null } catch {}
                }
                if ($word) {
                    try { $word.Quit() } catch {}
                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null } catch {}
                }
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
            }

            return $result
        }

        function Get-PdfMetadata {
            param([string]$FullPath)

            $result = [ordered]@{}
            $fs = $null
            try {
                $fs = [System.IO.File]::Open($FullPath, 'Open', 'Read', 'ReadWrite')
                $len = $fs.Length
                $readChunk = 4MB

                $firstLength = [Math]::Min($readChunk, $len)
                $first = New-Object byte[] $firstLength
                [void]$fs.Read($first, 0, $first.Length)

                $last = $null
                if ($len -gt $readChunk) {
                    [void]$fs.Seek(-[Math]::Min($readChunk, $len), [System.IO.SeekOrigin]::End)
                    $last = New-Object byte[] ([Math]::Min($readChunk, $len))
                    [void]$fs.Read($last, 0, $last.Length)
                }
            } catch {
                return $result
            } finally {
                if ($fs) { $fs.Close(); $fs.Dispose() }
            }

            try {
                $txtFirst = [System.Text.Encoding]::ASCII.GetString($first)
                $txtLast = if ($last) { [System.Text.Encoding]::ASCII.GetString($last) } else { '' }
                $txt = $txtFirst + $txtLast

                $start = $txt.IndexOf('<?xpacket')
                $end = $txt.IndexOf('</x:xmpmeta>')
                if ($start -ge 0 -and $end -gt $start) {
                    $xmlStr = $txt.Substring($start, ($end - $start) + 12)
                    try {
                        $xml = New-Object System.Xml.XmlDocument
                        $xml.LoadXml($xmlStr)
                        $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                        $nsm.AddNamespace('rdf', 'http://www.w3.org/1999/02/22-rdf-syntax-ns#')
                        $nsm.AddNamespace('dc', 'http://purl.org/dc/elements/1.1/')
                        $nsm.AddNamespace('xmp', 'http://ns.adobe.com/xap/1.0/')
                        $nsm.AddNamespace('pdf', 'http://ns.adobe.com/pdf/1.3/')
                        $nsm.AddNamespace('xmpMM', 'http://ns.adobe.com/xap/1.0/mm/')

                        $title = $xml.SelectSingleNode('//dc:title/rdf:Alt/rdf:li', $nsm)
                        $creator = $xml.SelectNodes('//dc:creator/rdf:Seq/rdf:li', $nsm)
                        $created = $xml.SelectSingleNode('//xmp:CreateDate', $nsm)
                        $modified = $xml.SelectSingleNode('//xmp:ModifyDate', $nsm)
                        $tool = $xml.SelectSingleNode('//xmp:CreatorTool', $nsm)
                        $producer = $xml.SelectSingleNode('//pdf:Producer', $nsm)

                        if ($title) { $result['XMP_Title'] = $title.InnerText }
                        if ($creator) { $result['XMP_Creator'] = ($creator | ForEach-Object { $_.InnerText }) -join '; ' }
                        if ($created) { $result['XMP_CreateDate'] = $created.InnerText }
                        if ($modified) { $result['XMP_ModifyDate'] = $modified.InnerText }
                        if ($tool) { $result['XMP_CreatorTool'] = $tool.InnerText }
                        if ($producer) { $result['XMP_Producer'] = $producer.InnerText }
                    } catch {}
                }

                foreach ($field in @('Title', 'Author', 'Creator', 'Producer', 'Subject', 'Keywords', 'CreationDate', 'ModDate')) {
                    $match = [regex]::Match($txt, "/$field\s*\((?<v>[^)]{0,2048})\)")
                    if ($match.Success -and $match.Groups['v'].Value) {
                        $result["Info_$field"] = $match.Groups['v'].Value
                    }
                }
            } catch {}

            return $result
        }

        # Basic filesystem information. This keeps Mode from v1 and Attributes from both versions.
        $fsInfo = [pscustomobject]@{
            FullName       = $fileItem.FullName
            Name           = $fileItem.Name
            Length         = $fileItem.Length
            Mode           = $fileItem.Mode
            Attributes     = $fileItem.Attributes
            CreationTime   = $fileItem.CreationTime
            LastWriteTime  = $fileItem.LastWriteTime
            LastAccessTime = $fileItem.LastAccessTime
        }

        # NTFS alternate data streams.
        $streams = @()
        try {
            $streams = Get-Item -LiteralPath $fullPath -Stream * -ErrorAction Stop | Select-Object Stream, Length
        } catch {}

        # ACL and owner. Avoid the PowerShell 7-only null conditional operator for Windows PowerShell compatibility.
        $acl = $null
        $owner = $null
        $aclAccess = $null
        try {
            $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
            $owner = $acl.Owner
            $aclAccess = $acl.Access
        } catch {}

        # Hashes.
        $hashes = [ordered]@{}
        foreach ($alg in @('MD5', 'SHA1', 'SHA256')) {
            try {
                $hashes[$alg] = (Get-FileHash -LiteralPath $fullPath -Algorithm $alg -ErrorAction Stop).Hash
            } catch {
                $hashes[$alg] = $null
            }
        }

        # Authenticode.
        $auth = $null
        try { $auth = Get-AuthenticodeSignature -FilePath $fullPath -ErrorAction Stop } catch {}

        # Windows shell extended properties.
        $shellProps = [ordered]@{}
        $shell = $null
        try {
            $shell = New-Object -ComObject Shell.Application
            $namespace = $shell.Namespace((Split-Path -LiteralPath $fullPath))
            $shellItem = $namespace.ParseName($fileItem.Name)

            0..300 | ForEach-Object {
                $name = $namespace.GetDetailsOf($null, $_)
                if ($name -and -not $shellProps.ContainsKey($name)) {
                    $value = $namespace.GetDetailsOf($shellItem, $_)
                    if ($value) { $shellProps[$name] = $value }
                }
            }
        } catch {
            $shellProps = [ordered]@{}
        } finally {
            if ($shell) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch {} }
        }

        # Office, embeddings, and PDF-specific metadata.
        $officeProps = [ordered]@{}
        $embeddedObjects = @()
        $pdfMeta = [ordered]@{}

        if ($isOfficeZip) {
            $officeResult = Get-OfficeZipProps -FullPath $fullPath
            $officeProps = $officeResult.OfficeProperties
            $embeddedObjects = $officeResult.EmbeddedObjects
        } elseif ($isLegacyDoc) {
            $legacyResult = Get-LegacyDocViaWord -FullPath $fullPath
            $officeProps = $legacyResult.OfficeProperties
            $embeddedObjects = $legacyResult.EmbeddedObjects
        }

        if ($isPdf) {
            $pdfMeta = Get-PdfMetadata -FullPath $fullPath
        }

        [pscustomobject]@{
            FileSystemInfo   = $fsInfo
            Streams          = $streams
            Owner            = $owner
            ACL              = Convert-AclAccessToObject -AccessRules $aclAccess
            Hashes           = Convert-HashtableToObject -InputHashtable $hashes
            Authenticode     = Convert-AuthenticodeToObject -Signature $auth
            ShellProperties  = Convert-HashtableToObject -InputHashtable $shellProps
            OfficeProperties = Convert-HashtableToObject -InputHashtable $officeProps
            EmbeddedObjects  = $embeddedObjects
            PdfMetadata      = Convert-HashtableToObject -InputHashtable $pdfMeta
        }
    }
}
