# ==============================================================================
# Script: Remove-EntraGroupMembers.ps1
# Description: Removes users from Entra ID groups based on a CSV file.
# Required CSV Headers: GroupObjectID, UPN
# Example: .\Remove-EntraGroupMembers.ps1 -CsvPath "C:\temp\GroupRemovals.csv" -LogPath "C:\temp\MyCustomLog.txt" 
#          .\Remove-EntraGroupMembers.ps1 -CsvPath "C:\temp\GroupRemovals.csv"
# ==============================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file")]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to output the log file")]
    [string]$LogPath = ".\GroupRemovals_Log.txt"
)

# Helper function for logging
function Write-Log {
    param ([string]$Message)
    $TimeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $LogLine = "[$TimeStamp] $Message"
    Write-Host $LogLine
    $LogLine | Out-File -FilePath $LogPath -Append
}

# Clear previous log if desired (Optional)
if (Test-Path $LogPath) { Remove-Item $LogPath }

# Ensure CSV exists
if (-not (Test-Path $CsvPath)) {
    Write-Log "FAILURE: CSV file not found at $CsvPath. Exiting script."
    exit
}

# Connect to Microsoft Graph with required scopes
Write-Log "Connecting to Entra ID (Microsoft Graph)..."
try {
    Connect-MgGraph -Scopes "GroupMember.ReadWrite.All", "User.Read.All" -NoWelcome
    Write-Log "Successfully connected to Microsoft Graph."
} catch {
    Write-Log "FAILURE: Could not connect to Microsoft Graph. $($_.Exception.Message)"
    exit
}

# Import the CSV data
$csvData = Import-Csv -Path $CsvPath
Write-Log "Found $($csvData.Count) records in the CSV."

# Process each row
foreach ($row in $csvData) {
    $groupObjId = $row.GroupObjectID
    $upn = $row.UPN

    # Validate row data
    if ([string]::IsNullOrWhiteSpace($groupObjId) -or [string]::IsNullOrWhiteSpace($upn)) {
        Write-Log "WARNING: Skipped a row due to missing GroupObjectID or UPN."
        continue
    }

    try {
        # Graph API requires the User Object ID to modify group membership, so we fetch the user by UPN first
        $user = Get-MgUser -UserId $upn -ErrorAction Stop
        
        # Remove the user from the group
        Remove-MgGroupMemberByRef -GroupId $groupObjId -DirectoryObjectId $user.Id -ErrorAction Stop
        
        Write-Log "SUCCESS: Removed user '$upn' from group '$groupObjId'."
    }
    catch {
        Write-Log "FAILURE: Could not remove user '$upn' from group '$groupObjId'. Error: $($_.Exception.Message)"
    }
}

Write-Log "Script execution completed."

# Disconnect session
Disconnect-MgGraph
