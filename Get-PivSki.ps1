<#
.SYNOPSIS
    Retrieves the Subject Key Identifier (SKI) for PIV/Smart Card certificates.

.DESCRIPTION
    1. Queries the CurrentUser\My certificate store for candidates (Client Auth/Smart Card Logon).
    2. Displays matches found in the store.
    3. Copies the output (Certificate details and SKI) to the clipboard.
    4. Displays a popup confirming the copy.
    
    UPDATED: Physical hardware filtering has been removed. This ensures you see 
    certificates even if the hardware check fails or if the card is momentarily unreadable,
    provided the certificate is cached in the Windows Store.

.NOTES
    - If no certificates are found, the script will offer to run 'certutil' to 
      force propagation from the card to the store.
#>

# 1. Define OIDs
$ClientAuthOid     = "1.3.6.1.5.5.7.3.2"
$SmartCardLogonOid = "1.3.6.1.4.1.311.20.2.2"
$SkiOid            = "2.5.29.14"
$EkuOid            = "2.5.29.37"

function Get-PivCertsFromStore {
    Write-Host "Querying Windows Certificate Store (Cert:\CurrentUser\My)..." -ForegroundColor Gray
    $storeCerts = Get-ChildItem -Path Cert:\CurrentUser\My
    
    $candidates = @()

    foreach ($cert in $storeCerts) {
        $isMatch = $false
        
        # Method A: Standard Property Check
        if ($cert.EnhancedKeyUsageList) {
            foreach ($eku in $cert.EnhancedKeyUsageList) {
                if ($eku.ObjectId.Value -eq $ClientAuthOid -or $eku.ObjectId.Value -eq $SmartCardLogonOid) {
                    $isMatch = $true
                    break
                }
            }
        }

        # Method B: Deep Extension Check (if Property is empty)
        if (-not $isMatch) {
            $ekuExtension = $cert.Extensions | Where-Object { $_.Oid.Value -eq $EkuOid }
            if ($ekuExtension) {
                $text = $ekuExtension.Format($true)
                if ($text -match $ClientAuthOid -or $text -match $SmartCardLogonOid -or $text -match "Client Authentication" -or $text -match "Smart Card Logon") {
                    $isMatch = $true
                }
            }
        }

        if ($isMatch) {
            $candidates += $cert
        }
    }
    return $candidates
}

# --- MAIN EXECUTION ---

Write-Host "Searching for PIV certificates..." -ForegroundColor Cyan

# 1. Get Candidates
$pivCerts = Get-PivCertsFromStore

# 2. If nothing found, offer to Force Read hardware
if ($pivCerts.Count -eq 0) {
    Write-Warning "No certificates found in Windows Store."
    
    $confirmation = Read-Host "Do you want to scan the Smart Card hardware to force propagation? (This will trigger a PIN prompt) [Y/N]"
    
    if ($confirmation -eq 'Y' -or $confirmation -eq 'y') {
        Write-Host "Running 'certutil -scinfo'..." -ForegroundColor Cyan
        Write-Host "NOTE: You can click 'Cancel' on the PIN prompt to skip the private key check." -ForegroundColor Yellow
        
        $null = certutil -scinfo -silent
        
        Write-Host "Hardware read complete. Re-scanning store..." -ForegroundColor Cyan
        $pivCerts = Get-PivCertsFromStore
    }
}

# 3. Output Results & Clipboard Capture
if ($pivCerts.Count -gt 0) {
    # Initialize a StringBuilder to capture text for the clipboard
    $clipboardBuilder = [System.Text.StringBuilder]::new()

    Write-Host "`nFOUND $($pivCerts.Count) MATCHING CERTIFICATES:" -ForegroundColor Green
    
    foreach ($cert in $pivCerts) {
        # --- Display to Console ---
        Write-Host "--------------------------------------------------"
        Write-Host "Subject: " -NoNewline
        Write-Host $cert.Subject -ForegroundColor Yellow
        Write-Host "Issuer:  $($cert.Issuer)"
        Write-Host "Serial:  $($cert.SerialNumber)"
        Write-Host "Expires: " -NoNewline
        Write-Host "$($cert.NotAfter)" -ForegroundColor White

        # --- Append to Clipboard Buffer ---
        $null = $clipboardBuilder.AppendLine("--------------------------------------------------")
        $null = $clipboardBuilder.AppendLine("Subject: $($cert.Subject)")
        $null = $clipboardBuilder.AppendLine("Issuer:  $($cert.Issuer)")
        $null = $clipboardBuilder.AppendLine("Serial:  $($cert.SerialNumber)")
        $null = $clipboardBuilder.AppendLine("Expires: $($cert.NotAfter)")

        # Check Key Linkage (Info only)
        if ($cert.HasPrivateKey) {
            Write-Host "Key:     Linked (Ready for auth)" -ForegroundColor Cyan
            $null = $clipboardBuilder.AppendLine("Key:     Linked (Ready for auth)")
        } else {
            Write-Host "Key:     Not Linked (Public Cert only)" -ForegroundColor Red
            $null = $clipboardBuilder.AppendLine("Key:     Not Linked (Public Cert only)")
        }

        # SKI Extraction
        $skiExtension = $cert.Extensions | Where-Object { $_.Oid.Value -eq $SkiOid }
        if ($skiExtension) {
            try {
                $skiTyped = [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]$skiExtension
                $skiValue = $skiTyped.SubjectKeyIdentifier
                
                Write-Host "SKI:     " -NoNewline
                Write-Host $skiValue -ForegroundColor Green
                
                $null = $clipboardBuilder.AppendLine("SKI:     $skiValue")
            }
            catch {
                $rawSki = $skiExtension.Format($true)
                Write-Host "SKI (Raw): $rawSki"
                $null = $clipboardBuilder.AppendLine("SKI (Raw): $rawSki")
            }
        } else {
            Write-Warning "No Subject Key Identifier extension found."
            $null = $clipboardBuilder.AppendLine("WARNING: No Subject Key Identifier extension found.")
        }
    }
    Write-Host "--------------------------------------------------"
    $null = $clipboardBuilder.AppendLine("--------------------------------------------------")

    # --- Copy to Clipboard & Popup ---
    $finalOutput = $clipboardBuilder.ToString()
    Set-Clipboard -Value $finalOutput
    
    # Create a popup object
    $wshell = New-Object -ComObject WScript.Shell
    # Popup(Text, SecondsToWait, Title, Type)
    # Type 4160 = 4096 (SystemModal - Always On Top) + 64 (Information Icon)
    # This forces the popup to stay on top of all other windows.
    $wshell.Popup("Certificate details have been copied to your clipboard.", 0, "Script Complete", 4160) | Out-Null

} else {
    Write-Host "`nNo matches found in the local store." -ForegroundColor Red
    Write-Host "If you are sure the card is inserted, try running 'certutil -scinfo' manually in a command prompt."
}