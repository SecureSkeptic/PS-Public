# Install the module if you haven't already:
# Install-Module Microsoft.Graph -Scope CurrentUser

# Connect to Microsoft Graph with the required permissions
Connect-MgGraph -Scopes "Policy.Read.All", "User.Read.All", "Group.Read.All", "RoleManagement.Read.Directory", "Application.Read.All"

# Define output path
$CsvPath = "C:\temp\ConditionalAccessPolicies.csv"

Write-Host "Fetching Conditional Access Policies..." -ForegroundColor Cyan
$Policies = Get-MgIdentityConditionalAccessPolicy

# Initialize caches to prevent redundant API calls and speed up the script
$Script:UserCache  = @{}
$Script:GroupCache = @{}
$Script:RoleCache  = @{}
$Script:AppCache   = @{}

# Helper function to check if a string is a GUID
function Test-IsGuid {
    param([string]$String)
    return $String -match "^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$"
}

# Helper functions to resolve ObjectIds to DisplayNames
function Get-ResolvedName {
    param (
        [string[]]$Ids,
        [string]$Type
    )

    if ($null -eq $Ids -or $Ids.Count -eq 0) { return $null }

    $ResolvedNames = foreach ($Id in $Ids) {
        if (-not (Test-IsGuid -String $Id)) {
            $Id # Return built-in strings like "All", "None", "GuestsOrExternalUsers" as-is
            continue
        }

        try {
            switch ($Type) {
                "User" {
                    if (-not $Script:UserCache.ContainsKey($Id)) {
                        $User = Get-MgUser -UserId $Id -Property DisplayName -ErrorAction Stop
                        $Script:UserCache[$Id] = $User.DisplayName
                    }
                    $Script:UserCache[$Id]
                }
                "Group" {
                    if (-not $Script:GroupCache.ContainsKey($Id)) {
                        $Group = Get-MgGroup -GroupId $Id -Property DisplayName -ErrorAction Stop
                        $Script:GroupCache[$Id] = $Group.DisplayName
                    }
                    $Script:GroupCache[$Id]
                }
                "Role" {
                    if (-not $Script:RoleCache.ContainsKey($Id)) {
                        # CA policies use Role Template IDs
                        $Role = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $Id -ErrorAction Stop
                        $Script:RoleCache[$Id] = $Role.DisplayName
                    }
                    $Script:RoleCache[$Id]
                }
                "App" {
                    if (-not $Script:AppCache.ContainsKey($Id)) {
                        # CA policies use the AppId (Client ID), not the Enterprise App ObjectId
                        $App = Get-MgServicePrincipal -Filter "appId eq '$Id'" -Property DisplayName -ErrorAction Stop
                        if ($App) {
                            $Script:AppCache[$Id] = $App.DisplayName
                        } else {
                            $Script:AppCache[$Id] = "Unknown App ($Id)"
                        }
                    }
                    $Script:AppCache[$Id]
                }
            }
        }
        catch {
            "Orphaned or Inaccessible $Type ($Id)"
        }
    }
    
    return $ResolvedNames -join "; "
}

$ExportData = foreach ($Policy in $Policies) {
    Write-Host "Processing Policy: $($Policy.DisplayName)" -ForegroundColor Yellow

    # Parse Conditions
    $Conditions = $Policy.Conditions
    
    # Users, Groups, Roles
    $IncludedUsers  = Get-ResolvedName -Ids $Conditions.Users.IncludeUsers -Type "User"
    $ExcludedUsers  = Get-ResolvedName -Ids $Conditions.Users.ExcludeUsers -Type "User"
    $IncludedGroups = Get-ResolvedName -Ids $Conditions.Users.IncludeGroups -Type "Group"
    $ExcludedGroups = Get-ResolvedName -Ids $Conditions.Users.ExcludeGroups -Type "Group"
    $IncludedRoles  = Get-ResolvedName -Ids $Conditions.Users.IncludeRoles -Type "Role"
    $ExcludedRoles  = Get-ResolvedName -Ids $Conditions.Users.ExcludeRoles -Type "Role"

    # Applications
    $IncludedApps = Get-ResolvedName -Ids $Conditions.Applications.IncludeApplications -Type "App"
    $ExcludedApps = Get-ResolvedName -Ids $Conditions.Applications.ExcludeApplications -Type "App"

    # Platforms & Locations
    $IncludedPlatforms = $Conditions.Platforms.IncludePlatforms -join "; "
    $ExcludedPlatforms = $Conditions.Platforms.ExcludePlatforms -join "; "
    $IncludedLocations = $Conditions.Locations.IncludeLocations -join "; "
    $ExcludedLocations = $Conditions.Locations.ExcludeLocations -join "; "
    $ClientAppTypes    = $Conditions.ClientAppTypes -join "; "

    # Parse Controls
    $GrantControls   = $Policy.GrantControls.BuiltInControls -join "; "
    $SessionControls = if ($Policy.SessionControls) {
        $Policy.SessionControls.PSObject.Properties | Where-Object { $_.Value.IsEnabled -eq $true } | Select-Object -ExpandProperty Name -join "; "
    } else { $null }

    # Construct the final object
    [PSCustomObject]@{
        PolicyName           = $Policy.DisplayName
        State                = $Policy.State
        CreatedDateTime      = $Policy.CreatedDateTime
        ModifiedDateTime     = $Policy.ModifiedDateTime
        Id                   = $Policy.Id
        IncludedUsers        = $IncludedUsers
        ExcludedUsers        = $ExcludedUsers
        IncludedGroups       = $IncludedGroups
        ExcludedGroups       = $ExcludedGroups
        IncludedRoles        = $IncludedRoles
        ExcludedRoles        = $ExcludedRoles
        IncludedApps         = $IncludedApps
        ExcludedApps         = $ExcludedApps
        IncludedPlatforms    = $IncludedPlatforms
        ExcludedPlatforms    = $ExcludedPlatforms
        IncludedLocations    = $IncludedLocations
        ExcludedLocations    = $ExcludedLocations
        ClientAppTypes       = $ClientAppTypes
        GrantControls        = $GrantControls
        CustomAuthentication = $Policy.GrantControls.CustomAuthenticationFactors -join "; "
        SessionControls      = $SessionControls
    }
}

# Export the results
$ExportData | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
Write-Host "Export complete! File saved to: $CsvPath" -ForegroundColor Green
