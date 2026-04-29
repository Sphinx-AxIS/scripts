# Kibana_API.ps1

`Kibana_API.ps1` is a starter template for invoking a Kibana API endpoint with HTTP Basic Authentication. It encodes a username and password as Base64, builds JSON request headers, sends a POST with a JSON request body, and prints the response. Use it as a starting point for a more specific Kibana automation rather than as a turnkey tool.

## What it does

1. Encodes the supplied username and password into a Base64 Basic Auth header.
2. Builds a JSON request body (defaults to `{ "query": { "match_all": {} } }`).
3. Sends a POST request to the configured Kibana API URL.
4. Prints the parsed response, or an error message on failure.

## Configuration

Three variables at the top of the script must be edited before running:

| Variable | Description |
|---|---|
| `$KibanaUrl` | Full URL to the Kibana API endpoint you want to call. |
| `$Username` | Kibana account username. |
| `$Password` | Kibana account password. |

Replace the contents of `$RequestBody` with whatever payload your target endpoint expects.

## Basic usage

```powershell
.\Kibana_API.ps1
```

The script takes no parameters. All inputs are inline variables that you edit before running.

## Requirements

- PowerShell 5.1+ or PowerShell 7+
- Network reach to the Kibana host
- Valid Kibana credentials with permission for the target endpoint

## Notes and limitations

- **Credentials are stored in plaintext** in the script. Do not commit edited copies. Before broader use, replace the static `$Username`/`$Password` with `Get-Credential`, an environment variable, or a secret store.
- The HTTP method is hardcoded to `POST`. Many Kibana endpoints require `GET` — edit the `Invoke-RestMethod` call as needed.
- The default body uses Elasticsearch query DSL (`match_all`), which is appropriate for `/api/console/proxy` or search APIs but not for most Kibana management endpoints. Adjust the body to match your target.
- The placeholder URL path (`/api/endpoint`) is illustrative; replace it with the real endpoint route.
