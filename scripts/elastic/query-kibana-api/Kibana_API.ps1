# Variables
$KibanaUrl = "https://your-kibana-url/api/endpoint"  # Replace with your Kibana API endpoint
$Username = "your_username"                         # Replace with your username
$Password = "your_password"                         # Replace with your password

# Base64 encode the username and password for Basic Authentication
$EncodedCredentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$Username:$Password"))

# Create headers for the HTTP request
$Headers = @{
    "Authorization" = "Basic $EncodedCredentials"
    "Content-Type"  = "application/json"
}

# Define the body of the request if needed
$RequestBody = @{
    # Replace with the body required for your query
    "query" = @{
        "match_all" = @{}
    }
} | ConvertTo-Json -Depth 10

# Make the API call
try {
    $Response = Invoke-RestMethod -Uri $KibanaUrl -Headers $Headers -Method Post -Body $RequestBody
    Write-Host "Query successful. Response:" -ForegroundColor Green
    $Response
} catch {
    Write-Host "Failed to query Kibana: $($_.Exception.Message)" -ForegroundColor Red
}
