# Capability Matrix

A feature-by-feature index of `automation-library`. Use this to find scripts by **what they do** rather than where they sit in the folder tree. For per-script summaries see [CATALOG.md](CATALOG.md).

---

## Quick reference

| Need to... | Look at |
|---|---|
| Investigate a Carbon Black watchlist alert end-to-end | [llm-assisted-investigate](scripts/carbon-black/llm-assisted-investigate/) |
| Pull Carbon Black process data for a host across a time range | [export-processes-by-host](scripts/carbon-black/export-processes-by-host/) |
| Build an analyst-ready XLSX report from CB JSON | [export-processes-by-host](scripts/carbon-black/export-processes-by-host/) (Convert-ToXlsx.ps1 step) |
| Collect full forensic metadata for a file (hashes, signatures, ACLs, streams, Office/PDF props) | [get-file-metadata](scripts/file-system/get-file-metadata/) |
| Find keywords in a file with line numbers and context | [search-file-for-keywords](scripts/file-system/search-file-for-keywords/) |
| Convert epoch-millisecond timestamps to UTC | [convert-epoch-time](scripts/forensics/convert-epoch-time/) |
| List and read NTFS alternate data streams on a file | [hunt-for-alternate-datastreams](scripts/forensics/hunt-for-alternate-datastreams/) or [get-file-metadata](scripts/file-system/get-file-metadata/) |
| Send an authenticated POST to a Kibana API endpoint | [query-kibana-api](scripts/elastic/query-kibana-api/) |
| Track Codex token usage, context utilization, and burn rate | [get-codex-usage](scripts/llm/get-codex-usage/) |

---

## Capability index

### Data sources

| Capability | Scripts |
|---|---|
| Carbon Black EDR API | llm-assisted-investigate, export-processes-by-host |
| SPOC C software approval API | llm-assisted-investigate |
| Kibana API (HTTP Basic Auth) | query-kibana-api |
| Local NTFS file system | get-file-metadata, hunt-for-alternate-datastreams |
| Office Open XML (`.docx`, `.xlsx`, `.pptx`) | get-file-metadata, search-file-for-keywords |
| Legacy MS Office (`.doc`, via Word COM) | get-file-metadata |
| PDF (XMP / Info dictionary) | get-file-metadata |
| Codex JSONL session logs | get-codex-usage |

### Investigation and triage

| Capability | Scripts |
|---|---|
| Carbon Black process tree retrieval | llm-assisted-investigate, export-processes-by-host |
| Watchlist alert investigation workflow | llm-assisted-investigate |
| Software approval validation | llm-assisted-investigate |
| LLM prompt generation from EDR data | llm-assisted-investigate |
| File metadata for forensic triage | get-file-metadata |
| Keyword search across file content | search-file-for-keywords |
| NTFS alternate data stream discovery | get-file-metadata, hunt-for-alternate-datastreams |
| Epoch timestamp normalization | convert-epoch-time |

### Hashing and signatures

| Capability | Scripts |
|---|---|
| MD5 / SHA1 / SHA256 file hashes | get-file-metadata |
| Authenticode signature inspection | get-file-metadata |

### Identity and access

| Capability | Scripts |
|---|---|
| File owner | get-file-metadata |
| File ACL enumeration | get-file-metadata |

### Data transformation and output

| Capability | Scripts |
|---|---|
| JSON → CSV | export-processes-by-host (ConvertJSON-ToCSV.ps1) |
| CSV → XLSX | export-processes-by-host (Convert-ToXlsx.ps1) |
| Epoch ms → UTC ISO-8601 | convert-epoch-time |
| Pipeline-friendly (composes with `Get-ChildItem`) | get-file-metadata |
| Structured object output for downstream filtering | get-file-metadata |

### Operational diagnostics

| Capability | Scripts |
|---|---|
| LLM token / context utilization tracking | get-codex-usage |
| Burn-rate analysis (avg / peak) | get-codex-usage |
| Rate-limit awareness with reset timing | get-codex-usage |

---

## Platform requirements

| Script | OS | PowerShell | External requirements |
|---|---|---|---|
| llm-assisted-investigate | Windows | 5.1+ | Carbon Black API key, SPOC C API key, network reach to CB server, `process_map.csv` |
| export-processes-by-host | Windows | 5.1+ | Carbon Black API key; Excel installed for XLSX step |
| get-file-metadata | Windows | 5.1+ | NTFS volume; MS Word installed for legacy `.doc` OLE inspection (optional) |
| search-file-for-keywords | Windows | 5.1+ | — |
| convert-epoch-time | Cross-platform | 5.1+ | — |
| hunt-for-alternate-datastreams | Windows | 5.1+ | NTFS volume |
| query-kibana-api | Cross-platform | 5.1+ | Kibana host; valid Kibana credentials |
| get-codex-usage | Windows | 5.1+ | Codex VS Code extension with local session logs under `$HOME\.codex\sessions\` |
