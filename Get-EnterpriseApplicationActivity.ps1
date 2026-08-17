# ==============================================================================
# Script: Get-SAMLAppActivityReport.ps1
# Description: Queries SAML Enterprise Apps for 30-day sign-in activity and 
#              SAML signing certificate expiration dates.
# ==============================================================================

# 1. Connect to Microsoft Graph with required scopes
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.Read.All", "AuditLog.Read.All"

# 2. Define the timeframe (Past 30 Days)
$startDate = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
$exportPath = "C:\temp\SAML_Apps_Activity_Report.csv"

# Create export directory if it doesn't exist
$exportDir = Split-Path $exportPath
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir | Out-Null }

# 3. Retrieve all Enterprise Applications (Service Principals) configured for SAML
Write-Host "Fetching SAML configured Enterprise Applications..." -ForegroundColor Cyan
# PreferredSingleSignOnMode 'saml' indicates a SAML SSO configuration
$samlApps = Get-MgServicePrincipal -All -Property "Id, DisplayName, AppId, PreferredSingleSignOnMode, KeyCredentials" | 
    Where-Object { $_.PreferredSingleSignOnMode -eq "saml" }

$report = @()
$totalApps = $samlApps.Count
$counter = 1

Write-Host "Found $totalApps SAML applications. Analyzing activity..." -ForegroundColor Yellow

# 4. Loop through each application to gather details
foreach ($app in $samlApps) {
    Write-Progress -Activity "Processing Applications" -Status "Checking $($app.DisplayName)" -PercentComplete (($counter / $totalApps) * 100)
    
    # --- Get SAML Signing Certificate Expiration ---
    # SAML signing certs typically have a Usage of "Verify" or "Sign"
    $certs = $app.KeyCredentials | Where-Object { $_.Usage -eq "Verify" }
    if ($certs) {
        # If multiple certs exist (e.g., during rollover), grab the one with the furthest expiration date
        $certExpiration = ($certs | Sort-Object EndDateTime -Descending)[0].EndDateTime
    } else {
        $certExpiration = "No Certificate Found"
    }

    # --- Get Last Sign-in Activity ---
    # Query the Entra ID audit logs for the most recent sign-in within the last 30 days
    try {
        $lastSignIn = Get-MgAuditLogSignIn -Filter "appId eq '$($app.AppId)' and createdDateTime ge $startDate" -Top 1 -Sort "createdDateTime DESC" -ErrorAction Stop
        
        $lastSignInDate = if ($lastSignIn) {
            $lastSignIn.CreatedDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        } else {
            "No activity in past 30 days"
        }
    } catch {
        $lastSignInDate = "Error retrieving logs"
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
