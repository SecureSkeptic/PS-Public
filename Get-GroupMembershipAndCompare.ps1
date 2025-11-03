<#
.SYNOPSIS
    Gets members from a list of imported groups and two specified groups.
    This version includes members from NESTED groups (transitive members).

.DESCRIPTION
    This script reads a list of group names from an input CSV. It finds all unique
    members across all those groups, including members of nested groups (List A).
    
    It also gets all unique members from two specified "compare" groups,
    including members of nested groups (List B).
    
    It then generates an output CSV with two columns, side-by-side:
    1. ImportedGroupMembers: All unique members from the imported groups.
    2. CompareGroupMembers:  All unique members from the two compare groups.
    
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
$outputCsvPath = "C:\temp\GroupLists.csv"

# The display names of the two specific groups you want to list.
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

# A HashSet ensures all members are unique
$compareMembersHashSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

foreach ($groupName in @($compareGroupNameA, $compareGroupNameB)) {
    try {
        $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
        if ($group) {
            Write-Host " - Found compare group '$groupName' (getting transitive members...)"
            
            # CHANGED: Use Get-MgGroupTransitiveMember to include nested group members
            $members = Get-MgGroupTransitiveMember -GroupId $group.Id -All | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' }
            
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

# --- 4. Get Members from Imported Groups (from CSV) ---

Write-Host "Processing groups from input CSV ($inputCsvPath)..." -ForegroundColor Green
if (-not (Test-Path $inputCsvPath)) {
    Write-Error "Input CSV not found at $inputCsvPath"
    return
}

$groupsToProcess = Import-Csv -Path $inputCsvPath
# A HashSet ensures all members are unique
$allImportedMembersHashSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

foreach ($row in $groupsToProcess) {
    $groupName = $row.$groupColumnName
    if ([string]::IsNullOrWhiteSpace($groupName)) { continue }

    try {
        $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
        if ($group) {
            Write-Host " - Getting members for '$groupName' (getting transitive members...)"
            
            # CHANGED: Use Get-MgGroupTransitiveMember to include nested group members
            $members = Get-MgGroupTransitiveMember -GroupId $group.Id -All | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' }
            
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

# --- 5. Combine Lists and Build Report ---

Write-Host "Combining lists for report..." -ForegroundColor Green

# Convert HashSets to Lists for indexed access
$importedList = [System.Collections.Generic.List[string]]::new($allImportedMembersHashSet)
$compareList = [System.Collections.Generic.List[string]]::new($compareMembersHashSet)

# Sort the lists alphabetically
$importedList.Sort()
$compareList.Sort()

# Find the length of the longer list to set the number of rows
$maxRows = [System.Math]::Max($importedList.Count, $compareList.Count)
$outputData = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($i = 0; $i -lt $maxRows; $i++) {
    
    # Get the member for column 1, or $null if the list is shorter
    $importedMember = $null
    if ($i -lt $importedList.Count) {
        $importedMember = $importedList[$i]
    }
    
    # Get the member for column 2, or $null if the list is shorter
    $compareMember = $null
    if ($i -lt $compareList.Count) {
        $compareMember = $compareList[$i]
    }
    
    # Create the custom object for the CSV row
    $outputData.Add(
        [PSCustomObject]@{
            ImportedGroupMembers = $importedMember
            CompareGroupMembers  = $compareMember
        }
    )
}

# --- 6. Export to CSV ---

$outputData | Export-Csv -Path $outputCsvPath -NoTypeInformation
Write-Host "Report complete! Saved to $outputCsvPath" -ForegroundColor Cyan
