# ==============================================================================
# Script: Get-SAMLAppActivityReport.ps1
# Description: Queries SAML Enterprise Apps for 30-day sign-in activity and 
#              SAML signing certificate expiration dates. Includes a timeout safeguard.
# ==============================================================================

# 1. Connect to Microsoft Graph with required scopes
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.Read.All", "AuditLog.Read.All"

# 2. Define the timeframe and timeout settings
$startDate = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
$exportPath = "C:\temp\SAML_Apps_Activity_Report.csv"
$TimeoutSeconds = 15 # Maximum seconds to wait per application's audit log query

# Create export directory if it doesn't exist
$exportDir = Split-Path $exportPath
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir | Out-Null }

# 3. Retrieve all Enterprise Applications (Service Principals) configured for SAML
Write-Host "Fetching SAML configured Enterprise Applications..." -ForegroundColor Cyan
$samlApps = Get-MgServicePrincipal -All -Property "Id", "DisplayName", "AppId", "PreferredSingleSignOnMode", "KeyCredentials" | 
    Where-Object { $_.PreferredSingleSignOnMode -eq "saml" }

$report = @()
$totalApps = $samlApps.Count
$counter = 1

Write-Host "Found $totalApps SAML applications. Analyzing activity..." -ForegroundColor Yellow

# 4. Loop through each application to gather details
foreach ($app in $samlApps) {
    Write-Progress -Activity "Processing Applications" -Status "Checking $($app.DisplayName)" -PercentComplete (($counter / $totalApps) * 100)
    
    # --- Get SAML Signing Certificate Expiration ---
    $certs = $app.KeyCredentials | Where-Object { $_.Usage -match "Verify|Sign" }
    
    if ($certs) {
        $certExpiration = ($certs | Sort-Object EndDateTime -Descending)[0].EndDateTime
    } else {
        $certExpiration = "No Certificate Found"
    }

    # --- Get Last Sign-in Activity (With Timeout Guard) ---
    try {
        # Start the Graph query in a lightweight background thread
        $job = Start-ThreadJob -ScriptBlock {
            param($AppId, $StartDate)
            Get-MgAuditLogSignIn -Filter "appId eq '$AppId' and createdDateTime ge $StartDate" -Top 1 -Sort "createdDateTime DESC" -ErrorAction Stop
        } -ArgumentList $app.AppId, $startDate
        
        # Wait for the job to complete OR for the timeout to expire
        $jobStatus = Wait-Job -Job $job -Timeout $TimeoutSeconds
        
        if ($null -eq $jobStatus) {
            # Wait-Job returns null if the timeout was reached before completion
            Stop-Job -Job $job
            Remove-Job -Job $job
            $lastSignInDate = "Timed out (> $TimeoutSeconds sec)"
            Write-Host "`n[Warning] $($app.DisplayName) timed out and was skipped." -ForegroundColor Yellow
        } else {
            # The query finished successfully within the time limit
            $lastSignIn = Receive-Job -Job $job
            Remove-Job -Job $job
            
            $lastSignInDate = if ($lastSignIn) {
                $lastSignIn.CreatedDateTime.ToString("yyyy-MM-dd HH:mm:ss")
            } else {
                "No activity in past 30 days"
            }
        }
    } catch {
        # Failsafe for general syntax or connection errors
        $lastSignInDate = "Error retrieving logs"
        if (Get-Job -Id $job.Id -ErrorAction SilentlyContinue) { Remove-Job -Job $job -Force }
    }

    # Compile the data object
    $report += [PSCustomObject]@{
        'Application Name'      = $app.DisplayName
        'ObjectID'              = $app.Id
        'AppID'                 = $app.AppId
        'Last Sign-On Date'     = $lastSignInDate
        'Cert Expiration Date'  = $certExpiration
    }

    $counter++
}

# 5. Export to CSV
$report | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
Write-Host "`nAnalysis complete! Report exported to: $exportPath" -ForegroundColor Green
