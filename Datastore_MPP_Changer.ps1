<#
.SYNOPSIS
    Reports and changes Multipath Policy for Datastores in vSphere 9.0 environment.

.DESCRIPTION
    This script connects to a vCenter server, identifies datastores that are not using the RoundRobin multipathing policy,
    generates an HTML report, and optionally changes the policy to RoundRobin.
    
    Updated for vSphere 9.0 compatibility and modern PowerShell practices.

.NOTES
    Version:        2.0
    Author:         Updated by Antigravity
    Last Updated:   2026-02-10
    Requirements:   VMware PowerCLI Module
#>

#requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$VCenterServer,

    [Parameter(Mandatory=$false)]
    [string]$ReportPath
)

# --- Configuration ---
$ReportFileName = "mp_policy.html"
# Styles for HTML Report
$CssStyle = @"
<style>
    body { font-family: Verdana, sans-serif; font-size: 14px; color: #333; background: #f4f4f4; margin: 20px; }
    h1 { color: #0056b3; border-bottom: 2px solid #0056b3; padding-bottom: 10px; }
    .timestamp { font-size: 0.9em; color: #666; margin-bottom: 20px; }
    table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.2); }
    th { background-color: #007bff; color: white; padding: 12px; text-align: left; }
    td { border: 1px solid #ddd; padding: 10px; }
    tr:nth-child(even) { background-color: #f2f2f2; }
    tr:hover { background-color: #ddd; }
    .warning { color: red; font-weight: bold; }
    .success { color: green; font-weight: bold; }
</style>
"@

# --- Helper Functions ---

function Get-DatastoreMultipathInfo {
    <#
    .SYNOPSIS
        Retrieves multipath information for all disk LUNs.
    .OUTPUTS
        PSCustomObject
    #>
    Write-Host "Gathering Datastore Multipath Information..." -ForegroundColor Cyan
    try {
        $luns = Get-VMHost | Get-ScsiLun -LunType disk -ErrorAction Stop
        
        # Process and return objects
        $results = foreach ($lun in $luns) {
            [PSCustomObject]@{
                CanonicalName   = $lun.CanonicalName
                Vendor          = $lun.Vendor
                Model           = $lun.Model
                CapacityGB      = $lun.CapacityGB
                VMHost          = $lun.VMHost.Name
                MultipathPolicy = $lun.MultipathPolicy
            }
        }
        return $results
    }
    catch {
        Write-Error "Failed to retrieve LUN information: $_"
        return $null
    }
}

function Show-Menu {
    Clear-Host
    Write-Host "================ vSphere Multipath Policy Manager ================" -ForegroundColor Cyan
    if ($VCenterServer) { Write-Host "Connected to: $VCenterServer" -ForegroundColor Gray }
    Write-Host ""
    Write-Host "0. Display ALL Datastore Multipath Policies"
    Write-Host "1. Display Non-RoundRobin Datastores"
    Write-Host "2. Generate HTML Report (Non-RoundRobin)"
    Write-Host "3. Change Non-RoundRobin Datastores to RoundRobin"
    Write-Host "Q. Quit"
    Write-Host ""
}

# --- Main Script Execution ---

# 1. Input Validation & Connection
if (-not $ReportPath) {
    $ReportPath = Read-Host "Enter the folder path to export the HTML report (e.g., C:\Reports)"
}
if (-not (Test-Path $ReportPath)) {
    try {
        New-Item -ItemType Directory -Path $ReportPath -ErrorAction Stop | Out-Null
        Write-Host "Created report directory: $ReportPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Could not create report directory at $ReportPath. Exiting."
        exit
    }
}

if (-not $VCenterServer) {
    $VCenterServer = Read-Host "Enter vCenter Server FQDN or IP"
}

# Connect to vCenter
if (-not $global:DefaultVIServer) {
    try {
        Connect-VIServer -Server $VCenterServer -ErrorAction Stop | Out-Null
        Write-Host "Successfully connected to $VCenterServer" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to vCenter Server: $_"
        exit
    }
}

# Cached Data (Lazy Loading) behavior handled in loop or via explicit refresh?
# For this interactive script, we'll fetch fresh data when needed or cache it?
# Let's fetch it on demand or once per loop iteration if specific actions are taken.

do {
    Show-Menu
    $selection = Read-Host "Please make a selection"

    switch ($selection) {
        '0' {
            Write-Host "`n--- All Datastore Policies ---" -ForegroundColor Yellow
            $allLuns = Get-DatastoreMultipathInfo
            if ($allLuns) {
                # Format-Table automatically handles output to console nicely
                $allLuns | Format-Table -AutoSize
            } else {
                Write-Warning "No LUNs found or error occurred."
            }
            Pause
        }

        '1' {
            Write-Host "`n--- Non-RoundRobin Datastores ---" -ForegroundColor Yellow
            $allLuns = Get-DatastoreMultipathInfo
            $nonRR = $allLuns | Where-Object { $_.MultipathPolicy -ne "RoundRobin" }
            
            if ($nonRR) {
                $nonRR | Format-Table -AutoSize
            } else {
                Write-Host "All datastores are configured with Round Robin policy." -ForegroundColor Green
            }
            Pause
        }

        '2' {
            Write-Host "`n--- Generating HTML Report ---" -ForegroundColor Yellow
            $allLuns = Get-DatastoreMultipathInfo
            $nonRR = $allLuns | Where-Object { $_.MultipathPolicy -ne "RoundRobin" }

            if (-not $nonRR) {
                Write-Host "All datastores are Round Robin. Generating empty report." -ForegroundColor Green
                $htmlBody = "<h2>All datastores are compliant (RoundRobin policy enabled).</h2>"
            } else {
                # Convert data to HTML fragment
                $tableFragment = $nonRR | ConvertTo-Html -Fragment
                $htmlBody = "<h2>Non-Compliant Datastores (Not RoundRobin)</h2>$tableFragment"
            }

            # Full HTML
            $fullHtml = @"
<!DOCTYPE html>
<html>
<head>
    <title>Multipath Policy Report</title>
    $CssStyle
</head>
<body>
    <h1>Multipath Policy Report</h1>
    <div class="timestamp">Generated on: $(Get-Date) for vCenter: $VCenterServer</div>
    $htmlBody
</body>
</html>
"@
            $outFile = Join-Path -Path $ReportPath -ChildPath $ReportFileName
            $fullHtml | Out-File -FilePath $outFile -Encoding UTF8
            
            Write-Host "Report generated at: $outFile" -ForegroundColor Green
            # Try to open the file
            try { Invoke-Item $outFile } catch { Write-Warning "Could not automatically open report file." }
            Pause
        }

        '3' {
            Write-Host "`n--- Remediation: Change to Round Robin ---" -ForegroundColor Red
            Write-Warning "This will change the multipath policy for ALL non-compliant datastores found."
            $confirm = Read-Host "Are you sure you want to proceed? (Y/N)"
            
            if ($confirm -eq 'Y') {
                Write-Host "Retrieving LUNs..."
                # We need the direct generic object from Get-ScsiLun to pipe to Set-ScsiLun
                # The helper function returns custom objects which Set-ScsiLun won't accept directly via pipeline usually unless property names align perfectly?
                # Safer: Re-run query to get exact objects for piping.
                try {
                    $targetLuns = Get-VMHost | Get-ScsiLun -LunType disk | Where-Object { $_.MultipathPolicy -ne "RoundRobin" }
                    
                    if ($targetLuns) {
                        foreach ($lun in $targetLuns) {
                            Write-Host "Changing policy for $($lun.CanonicalName) on $($lun.VMHost)..." -NoNewline
                            try {
                                $lun | Set-ScsiLun -MultipathPolicy "RoundRobin" -ErrorAction Stop
                                Write-Host "DONE" -ForegroundColor Green
                            } catch {
                                Write-Host "FAILED ($($_))" -ForegroundColor Red
                            }
                        }
                        Write-Host "`nRemediation Completed." -ForegroundColor Green
                    } else {
                        Write-Host "No non-RoundRobin datastores found." -ForegroundColor Green
                    }
                } catch {
                    Write-Error "Error during remediation: $_"
                }
            } else {
                Write-Host "Operation Cancelled." -ForegroundColor Yellow
            }
            Pause
        }

        'Q' {
            Write-Host "Exiting..." -ForegroundColor Cyan
            break
        }
        
        default {
            Write-Host "Invalid Selection. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }

} until ($selection -eq 'Q')