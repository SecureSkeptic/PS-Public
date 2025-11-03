<#
.SYNOPSIS
    Compares Entra ID group membership from a CSV list against two specific groups.

.DESCRIPTION
    This script reads a list of group names from an input CSV. It finds all unique
    members across all those groups.
    
    It also gets all unique members from two specified "compare" groups (e.g., "All Staff"
    and "External Users").
    
    It then generates an output CSV with two columns:
    1. AllImportedMembers: A unique list of all users found in the imported groups.
    2. InCompareGroups:    Shows the user's UPN *if* they were also found in one of
                           the two compare groups. This column is blank otherwise.

.NOTES
    Requires the Microsoft.Graph.Groups module.
    Install with: Install-Module Microsoft.Graph.Groups
    
    You must connect before running:
    Connect-MgGraph -Scopes "Group.Read.All", "GroupMember.Read.All", "User.Read.All"
#>

# --- 1. Configuration (Please Edit These Values) ---

# The CSV file containing the list of groups to check.
$inputCsvPath = "C:\temp\groups-to-check.csv"

# The name of the column in your CSV that contains the group names.
$groupColumnName = "GroupName"

# The path for the final report.
$outputCsvPath = "C:\temp\MembershipComparison.csv"

# The display names of the two specific groups you want to compare against.
$compareGroupNameA = "All Staff"
$compareGroupNameB = "IT Department"

# --- 2. Prerequisites ---

# Check for module and connect
if (-not (Get-Module -Name Microsoft.Graph.Groups -ListAvailable)) {
    Write-Warning "Microsoft.Graph.Groups module not found. Please install it:"
    Write-Warning "Install-Module Microsoft.Graph.Groups -Scope CurrentUser"
    return
}

# Check for connection
if (-not (Get-MgContext)) {
    Write-Warning "Not connected to Microsoft Graph. Please connect first:"
    Write-Warning 'Connect-MgGraph -Scopes "Group.Read.All", "GroupMember.Read.All", "User.Read.All"'
    Connect-MgGraph -Scopes "Group.Read.All", "GroupMember.Read.All", "User.Read.All"
}

# --- 3. Get Members of "Compare" Groups ---

Write-Host "Fetching members from compare groups ($compareGroupNameA, $compareGroupNameB)..." -ForegroundColor Green

# A HashSet provides very fast lookups (e.g., .Contains())
$compareMembersHashSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

foreach ($groupName in @($compareGroupNameA, $compareGroupNameB)) {
    try {
        $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
        if ($group) {
            Write-Host " - Found compare group '$groupName'"
            # Get members that are users and add their UserPrincipalName to the HashSet
            $members = Get-MgGroupMember -GroupId $group.Id -All | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' }
            foreach ($member in $members) {
                $compareMembersHashSet.Add($member.AdditionalProperties.userPrincipalName)
            }
        } else {
            Write-Warning "Compare group '$groupName' not found."
        }
    } catch {
        Write-Warning "Error processing compare group '$groupName': $_"
    }
}
Write-Host "Found $($compareMembersHashSet.Count) unique members in compare groups."

---

# --- 4. Get Members from Imported Groups (from CSV) ---

Write-Host "Processing groups from input CSV ($inputCsvPath)..." -ForegroundColor Green
if (-not (Test-Path $inputCsvPath)) {
    Write-Error "Input CSV not found at $inputCsvPath"
    return
}

$groupsToProcess = Import-Csv -Path $inputCsvPath
$allImportedMembersHashSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

foreach ($row in $groupsToProcess) {
    $groupName = $row.$groupColumnName
    if ([string]::IsNullOrWhiteSpace($groupName)) { continue }

    try {
        $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
        if ($group) {
            Write-Host " - Getting members for '$groupName'..."
            # Get members that are users and add their UPN to the other HashSet
            $members = Get-MgGroupMember -GroupId $group.Id -All | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' }
            foreach ($member in $members) {
                $allImportedMembersHashSet.Add($member.AdditionalProperties.userPrincipalName)
            }
        } else {
            Write-Warning "Imported group '$groupName' not found."
        }
    } catch {
        Write-Warning "Error processing imported group '$groupName': $_"
    }
}
Write-Host "Found $($allImportedMembersHashSet.Count) unique members across all imported groups."

---

# --- 5. Compare Lists and Build Report ---

Write-Host "Comparing memberships and building report..." -ForegroundColor Green
$outputData = foreach ($upn in $allImportedMembersHashSet) {
    
    # This will be the value for the second column
    $inCompareGroup = $null 
    
    # Check if this UPN exists in our fast lookup list
    if ($compareMembersHashSet.Contains($upn)) {
        $inCompareGroup = $upn
    }
    
    # Create the custom object for the CSV row
    [PSCustomObject]@{
        AllImportedMembers = $upn
        InCompareGroups    = $inCompareGroup
    }
}

# --- 6. Export to CSV ---

$outputData | Export-Csv -Path $outputCsvPath -NoTypeInformation
Write-Host "Report complete! Saved to $outputCsvPath" -ForegroundColor Cyan