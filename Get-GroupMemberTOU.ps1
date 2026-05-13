# ==============================================================================
# Variables - Update these with your specific IDs and desired file path
# ==============================================================================
$GroupId     = "YOUR_GROUP_OBJECT_ID_HERE"
$AgreementId = "YOUR_TERMS_OF_USE_AGREEMENT_ID_HERE"
$ExportPath  = "C:\temp\ToU_PIM_Eligible_Report.csv"

# ==============================================================================
# Connect to Microsoft Graph with required scopes
# ==============================================================================
$requiredScopes = @(
    "User.Read.All", 
    "PrivilegedAccess.Read.AzureADGroup", 
    "AgreementAcceptance.Read.All"
)
Connect-MgGraph -Scopes $requiredScopes -NoWelcome

# ==============================================================================
# Helper Function for Pagination
# ==============================================================================
function Get-MgGraphData {
    param([string]$Uri)
    $results = @()
    try {
        while ($Uri) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
            if ($response.value) { $results += $response.value }
            $Uri = $response.'@odata.nextLink' # Get next page if it exists
        }
    }
    catch {
        Write-Error "Failed to query Graph API: $_"
    }
    return $results
}

Write-Host "Fetching PIM Eligible users for Group ID: $GroupId..." -ForegroundColor Cyan
# Query the Beta endpoint for PIM for Groups Eligibility Schedules
$pimUri = "https://graph.microsoft.com/beta/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '$GroupId'"
$pimSchedules = Get-MgGraphData -Uri $pimUri

# Extract unique User IDs from the eligibility schedules (ignoring nested groups/service principals)
$eligibleUserIds = $pimSchedules | Where-Object { $_.principalType -eq "User" } | Select-Object -ExpandProperty principalId | Select-Object -Unique

if ($null -eq $eligibleUserIds -or $eligibleUserIds.Count -eq 0) {
    Write-Host "No eligible users found for this group. Exiting." -ForegroundColor Yellow
    Disconnect-MgGraph
    exit
}

Write-Host "Found $($eligibleUserIds.Count) PIM eligible users. Fetching Terms of Use data..." -ForegroundColor Cyan

# Query the Terms of Use acceptances for the specific Agreement
$touUri = "https://graph.microsoft.com/v1.0/identityGovernance/termsOfUse/agreements/$AgreementId/acceptances"
$touAcceptances = Get-MgGraphData -Uri $touUri

# ==============================================================================
# Process Data and Build the Report
# ==============================================================================
$Report = @()

foreach ($userId in $eligibleUserIds) {
    # Fetch User Details for readable output
    $userUri = "https://graph.microsoft.com/v1.0/users/$userId`?$select=displayName,userPrincipalName"
    $user = Invoke-MgGraphRequest -Method GET -Uri $userUri

    # Find the ToU record for this specific user
    # If a user accepted and then declined, we take the most recent record
    $userToU = $touAcceptances | Where-Object { $_.userId -eq $userId } | Sort-Object acceptedDateTime -Descending | Select-Object -First 1

    $Report += [PSCustomObject]@{
        DisplayName       = $user.displayName
        UserPrincipalName = $user.userPrincipalName
        UserId            = $userId
        PIMGroupId        = $GroupId
        ToUAgreementId    = $AgreementId
        ToUState          = if ($userToU) { $userToU.state } else { "Not Responded" }
        RespondedDateTime = if ($userToU) { $userToU.acceptedDateTime } else { "N/A" }
    }
}

# ==============================================================================
# Export Results
# ==============================================================================
$Report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Host "Script complete. Report exported to: $ExportPath" -ForegroundColor Green

# Clean up session
Disconnect-MgGraph
