<#
.SYNOPSIS
    Finds all SharePoint Online sites a user has access to and exports results to CSV.
    Requires PnP.PowerShell module.

.DESCRIPTION
    This script iterates through all site collections, checks if a specific user
    has permissions, and records the site URL, title, and permission levels.

.EXAMPLE
  .\FindUserSites.ps1 -TargetUserEmail "john.doe@contoso.com" -AdminUrl "https://contoso-admin.sharepoint.com" -OutputCsv "C:\Reports\JohnDoe_Access.csv"
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$TargetUserEmail,

    [Parameter(Mandatory=$true)]
    [string]$AdminUrl, # e.g., https://yourtenant-admin.sharepoint.com

    [string]$OutputCsv = "C:\temp\UserSitePermissions_$(Get-Date -Format 'yyyyMMdd').csv"
)

# --- 1. Connect to SharePoint Admin Center ---
Write-Host "Connecting to SharePoint Admin Center at $AdminUrl..." -ForegroundColor Cyan
try {
    Connect-PnPOnline -Url $AdminUrl -Interactive
}
catch {
    Write-Error "Could not connect to Admin Center. Please check URL and credentials."
    return
}

# --- 2. Get All Site Collections ---
Write-Host "Fetching all site collections (this may take time)..." -ForegroundColor Cyan
$AllSites = Get-PnPTenantSite | Where-Object { $_.Template -ne "SPSPERS#10" } # Exclude Personal OneDrive Sites

$Results = @()
$Counter = 0
$Total = $AllSites.Count

# --- 3. Iterate Through Each Site ---
foreach ($Site in $AllSites) {
    $Counter++
    $ProgressParams = @{
        Activity = "Auditing Sites"
        Status   = "Processing $($Site.Url) ($Counter of $Total)"
        PercentComplete = ($Counter / $Total) * 100
    }
    Write-Progress @ProgressParams

    try {
        # Connect to the specific site
        Connect-PnPOnline -Url $Site.Url -Interactive -WarningAction SilentlyContinue
        
        # Check if user exists in the site's User Information List
        $User = Get-PnPUser -Identity $TargetUserEmail -ErrorAction SilentlyContinue

        if ($User) {
            # Get Effective Permissions (The "Rights")
            $Permissions = Get-PnPUserPermissions -Identity $TargetUserEmail -ErrorAction SilentlyContinue
            
            # Get Group Membership (The "Explicit" assignment)
            $SiteGroups = Get-PnPGroup
            $UserGroups = @()
            
            foreach ($Group in $SiteGroups) {
                # Check if user is in this specific group
                if (Get-PnPGroupMember -Identity $Group.Title -ErrorAction SilentlyContinue | Where-Object { $_.Email -eq $TargetUserEmail }) {
                    $UserGroups += $Group.Title
                }
            }

            # If we found permissions or groups, record it
            if ($Permissions.Kind -or $UserGroups) {
                
                $Props = [PSCustomObject]@{
                    SiteTitle      = $Site.Title
                    SiteUrl        = $Site.Url
                    UserEmail      = $TargetUserEmail
                    # Join permission kinds with a comma (e.g., "FullControl, WebDesigner")
                    PermissionKind = ($Permissions.Kind -join ", ")
                    # Join groups with a comma
                    MemberOfGroups = ($UserGroups -join ", ")
                }
                
                $Results += $Props
                Write-Host " [MATCH] Found access in: $($Site.Title)" -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Warning "Could not query site: $($Site.Url). Skipping."
    }
}

# --- 4. Export Results to CSV ---
if ($Results.Count -gt 0) {
    # Ensure directory exists
    $Dir = Split-Path $OutputCsv -Parent
    if (!(Test-Path $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    }

    # Export
    $Results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Audit Complete. Found $($Results.Count) sites." -ForegroundColor Green
    Write-Host "Results saved to: $OutputCsv" -ForegroundColor Green
    
    # Optional: Open the CSV location
    Invoke-Item $OutputCsv
}
else {
    Write-Host "Audit Complete. No sites found for user $TargetUserEmail." -ForegroundColor Yellow
}
