<#
.SYNOPSIS
    Gets all groups assigned to a specific Enterprise Application in Microsoft Entra ID,
    filters out empty groups, and exports the group name and object ID to a CSV file.

.DESCRIPTION
    This script requires the Microsoft.Graph module.
    1. It connects to Microsoft Graph with the required permissions.
    2. It prompts the user for the Object ID of the Enterprise Application.
    3. It finds the Service Principal for that application.
    4. It retrieves all app role assignments for the Service Principal.
    5. It filters for assignments that are groups.
    6. It checks if those groups have members and filters out empty groups.
    7. It creates custom objects with the Group Name and Group Object ID for non-empty groups.
    8. It exports this list to a CSV file.

.PARAMETER AppObjectId
    The Object ID (Service Principal ID) of the Enterprise Application in Microsoft Entra ID.

.PARAMETER ExportPath
    The full file path where the CSV will be saved (e.g., "C:\temp\AppGroups.csv").

.EXAMPLE
    .\get_app_groups.ps1 -AppObjectId "a1b2c3d4-e5f6-7890-a1b2-c3d4e5f67890" -ExportPath "C:\temp\AppGroups.csv"
    This command will find the application with the specified Object ID, get all assigned groups that have members,
    and save their names and IDs to "C:\temp\AppGroups.csv".
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$AppObjectId,

    [Parameter(Mandatory = $true)]
    [string]$ExportPath
)

# Install Microsoft.Graph module if not already installed
$moduleName = "Microsoft.Graph"
$module = Get-Module -ListAvailable -Name $moduleName
if (-not $module) {
    Write-Host "Microsoft.Graph module not found. Installing..."
    try {
        Install-Module -Name $moduleName -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        Write-Host "Microsoft.Graph module installed successfully."
    }
    catch {
        Write-Error "Failed to install Microsoft.Graph module. Please install it manually and try again."
        return
    }
}

# Define required permissions
$scopes = @("Application.Read.All", "Group.Read.All", "AppRoleAssignment.ReadWrite.All", "GroupMember.Read.All")

# Connect to Microsoft Graph
try {
    Write-Host "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes $scopes
    Write-Host "Successfully connected to Microsoft Graph."
}
catch {
    Write-Error "Failed to connect to Microsoft Graph. $_"
    return
}

$groupAssignments = @()

try {
    # Find the Enterprise Application (Service Principal) by its Object ID
    Write-Host "Searching for Enterprise Application with Object ID '$AppObjectId'..."
    $servicePrincipal = Get-MgServicePrincipal -ServicePrincipalId $AppObjectId -ErrorAction SilentlyContinue

    if (-not $servicePrincipal) {
        Write-Warning "No Enterprise Application found with the Object ID '$AppObjectId'."
        return
    }

    Write-Host "Found Application. Object ID: $($servicePrincipal.Id)"

    # Get all app role assignments for this service principal
    Write-Host "Getting app role assignments..."
    $appAssignments = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $servicePrincipal.Id -All

    if (-not $appAssignments) {
        Write-Warning "No app role assignments found for this application."
        return
    }

    Write-Host "Processing assignments..."
    foreach ($assignment in $appAssignments) {
        # Filter for assignments that are groups
        if ($assignment.PrincipalType -eq "Group") {
            Write-Host "Found assigned group: $($assignment.PrincipalDisplayName) (ID: $($assignment.PrincipalId))"
            
            try {
                # Check if the group has at least one member. -Top 1 is most efficient.
                $members = Get-MgGroupMember -GroupId $assignment.PrincipalId -Top 1
                
                if ($members) {
                    Write-Host "--> Group has members. Adding to list."
                    # Add the group details to our list
                    $groupAssignments += [PSCustomObject]@{
                        GroupName   = $assignment.PrincipalDisplayName
                        GroupObjectId = $assignment.PrincipalId
                    }
                } else {
                    Write-Host "--> Group has no members. Skipping."
                }
            }
            catch {
                Write-Warning "--> Failed to check members for group $($assignment.PrincipalDisplayName). Error: $_. Skipping group."
            }
        }
    }

    if ($groupAssignments.Count -eq 0) {
        Write-Warning "No *groups with members* are assigned to this application."
        return
    }

    # Export the results to a CSV file
    Write-Host "Exporting $($groupAssignments.Count) groups to '$ExportPath'..."
    $groupAssignments | Export-Csv -Path $ExportPath -NoTypeInformation

    Write-Host "Export complete."

}
catch {
    Write-Error "An error occurred: $_"
}
finally {
    # Optional: Disconnect from Microsoft Graph
    # Write-Host "Disconnecting from Microsoft Graph."
    # Disconnect-MgGraph
}

