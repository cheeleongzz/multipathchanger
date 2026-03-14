<#
.SYNOPSIS
    Reports and changes Multipath Policy for Datastores in vSphere 7-9 environments.

.DESCRIPTION
    Connects to a vCenter server, audits SCSI LUN multipath policies (NMP) across
    all ESXi hosts, generates HTML and CSV reports of non-compliant datastores, and
    remediates them. Also detects NVMe-oF HPP devices on vSphere 7+ hosts.

    Supports vSphere 7.x, 8.x, and 9.x.

.PARAMETER VCenterServer
    FQDN or IP address of the vCenter Server.

.PARAMETER Credential
    PSCredential object for vCenter authentication. If omitted, PowerCLI will prompt
    or use existing session credentials.

.PARAMETER ReportPath
    Directory path where HTML and CSV reports will be saved.

.PARAMETER TargetPolicy
    Multipath policy to enforce. Valid values: RoundRobin, MostRecentlyUsed, Fixed.
    Defaults to RoundRobin (VMware recommended for most SAN arrays).

.PARAMETER CommandsToSwitchPath
    Number of I/O commands to send to a path before switching (Round Robin only).
    Set to 1 for arrays that recommend immediate switching. Default: 1000.
    Set to 0 to use bytes-based switching instead of commands.

.NOTES
    Version:        3.0
    Author:         Updated by Antigravity
    Last Updated:   2026-03-14
    Requirements:   VMware PowerCLI Module
    Compatibility:  vSphere 7.x, 8.x, 9.x
#>

#requires -Modules VMware.VimAutomation.Core

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false)]
    [string]$VCenterServer,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$ReportPath,

    [Parameter(Mandatory=$false)]
    [ValidateSet("RoundRobin", "MostRecentlyUsed", "Fixed")]
    [string]$TargetPolicy = "RoundRobin",

    [Parameter(Mandatory=$false)]
    [ValidateRange(0, 10000)]
    [int]$CommandsToSwitchPath = 1000
)

# --- Configuration ---
$ScriptVersion = "3.0"

# CSS for HTML report
$CssStyle = @"
<style>
    body { font-family: Verdana, sans-serif; font-size: 14px; color: #333; background: #f4f4f4; margin: 20px; }
    h1 { color: #0056b3; border-bottom: 2px solid #0056b3; padding-bottom: 10px; }
    h2 { color: #444; margin-top: 30px; }
    .timestamp { font-size: 0.9em; color: #666; margin-bottom: 15px; }
    .summary { background: #e8f4f8; border-left: 4px solid #007bff; padding: 10px 15px; margin-bottom: 20px; border-radius: 3px; }
    table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.2); margin-bottom: 20px; }
    th { background-color: #007bff; color: white; padding: 12px; text-align: left; }
    td { border: 1px solid #ddd; padding: 10px; }
    tr:nth-child(even) { background-color: #f2f2f2; }
    tr:hover { background-color: #e8f0fe; }
    .warning { color: #d9534f; font-weight: bold; }
    .success { color: #28a745; font-weight: bold; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.8em; font-weight: bold; }
    .badge-nvme { background: #6f42c1; color: white; }
    .badge-scsi { background: #0056b3; color: white; }
    .note { background: #fff3cd; border-left: 4px solid #ffc107; padding: 10px 15px; margin: 10px 0; border-radius: 3px; }
</style>
"@

# --- Helper Functions ---

function Get-VCenterVersion {
    <#
    .SYNOPSIS Retrieves vCenter Server version and build number via the vSphere API.
    #>
    try {
        $si = Get-View ServiceInstance -ErrorAction Stop
        return [PSCustomObject]@{
            Version    = $si.Content.About.Version
            Build      = $si.Content.About.Build
            FullString = "$($si.Content.About.Version) (Build $($si.Content.About.Build))"
        }
    }
    catch {
        return [PSCustomObject]@{ Version = "Unknown"; Build = "Unknown"; FullString = "Unknown" }
    }
}

function Get-DatastoreMultipathInfo {
    <#
    .SYNOPSIS
        Retrieves multipath policy information for all SCSI disk LUNs (NMP) across
        all ESXi hosts in the connected vCenter.
    .OUTPUTS
        PSCustomObject with Protocol, CanonicalName, Vendor, Model, CapacityGB,
        PathCount, VMHost, MultipathPolicy.
    #>
    Write-Host "Gathering SCSI LUN multipath information (NMP)..." -ForegroundColor Cyan

    $vmhosts = @(Get-VMHost | Sort-Object Name)
    $total   = $vmhosts.Count
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    for ($i = 0; $i -lt $total; $i++) {
        $vmhost = $vmhosts[$i]
        Write-Progress -Activity "Scanning ESXi Hosts for SCSI LUNs" `
            -Status "$($vmhost.Name) ($($i+1) of $total)" `
            -PercentComplete ((($i + 1) / $total) * 100)
        try {
            $luns = Get-ScsiLun -VMHost $vmhost -LunType disk -ErrorAction Stop
            foreach ($lun in $luns) {
                $pathCount = try {
                    (Get-ScsiLunPath -ScsiLun $lun -ErrorAction SilentlyContinue | Measure-Object).Count
                } catch { 0 }

                $results.Add([PSCustomObject]@{
                    Protocol        = "SCSI/NMP"
                    CanonicalName   = $lun.CanonicalName
                    Vendor          = $lun.Vendor.Trim()
                    Model           = $lun.Model.Trim()
                    CapacityGB      = [Math]::Round($lun.CapacityGB, 2)
                    PathCount       = $pathCount
                    VMHost          = $vmhost.Name
                    MultipathPolicy = $lun.MultipathPolicy.ToString()
                })
            }
        }
        catch {
            Write-Warning "  Could not retrieve LUNs from $($vmhost.Name): $_"
        }
    }
    Write-Progress -Activity "Scanning ESXi Hosts for SCSI LUNs" -Completed
    return $results
}

function Get-NVMeHPPInfo {
    <#
    .SYNOPSIS
        Retrieves NVMe-oF High Performance Plugin (HPP) device policies.
        Requires vSphere 7.0 or later. Returns empty list on older vSphere versions.
    .OUTPUTS
        PSCustomObject with VMHost, Device, LoadBalancePolicy, ActivePaths.
    #>
    Write-Host "Detecting NVMe-oF HPP devices (vSphere 7+)..." -ForegroundColor Cyan

    $vmhosts = @(Get-VMHost | Sort-Object Name)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $hppFound = $false

    foreach ($vmhost in $vmhosts) {
        try {
            $esxcli     = Get-EsxCli -VMHost $vmhost -V2 -ErrorAction Stop
            $hppDevices = $esxcli.storage.hpp.device.list.Invoke()

            if ($hppDevices) {
                $hppFound = $true
                foreach ($device in $hppDevices) {
                    $results.Add([PSCustomObject]@{
                        Protocol          = "NVMe/HPP"
                        Device            = $device.Device
                        VMHost            = $vmhost.Name
                        LoadBalancePolicy = $device.LoadBalancePolicy
                        ActivePaths       = $device.ActivePaths
                        SuspendedPaths    = if ($device.PSObject.Properties['SuspendedPaths']) { $device.SuspendedPaths } else { "N/A" }
                    })
                }
            }
        }
        catch {
            # esxcli HPP namespace not available - pre-vSphere 7 or no NVMe devices
        }
    }

    if (-not $hppFound) {
        Write-Host "  No NVMe-oF HPP devices detected on any host." -ForegroundColor Gray
    }
    return $results
}

function Show-Menu {
    param(
        [string]$VCenterInfo,
        [string]$VsphereVersion
    )
    Clear-Host
    Write-Host "========= vSphere Multipath Policy Manager v$ScriptVersion =========" -ForegroundColor Cyan
    Write-Host "  vSphere 7 / 8 / 9 Compatible" -ForegroundColor DarkCyan
    if ($VCenterInfo)    { Write-Host "  Connected to  : $VCenterInfo"    -ForegroundColor Gray }
    if ($VsphereVersion) { Write-Host "  vCenter Ver.  : $VsphereVersion" -ForegroundColor Gray }
    Write-Host ""
    Write-Host "  -- SCSI / NMP (iSCSI, Fibre Channel, SAS) --" -ForegroundColor White
    Write-Host "  0.  Display ALL datastore multipath policies"
    Write-Host "  1.  Display non-$TargetPolicy datastores"
    Write-Host "  2.  Generate HTML + CSV report (non-$TargetPolicy)"
    Write-Host "  3.  Change non-$TargetPolicy datastores to $TargetPolicy"
    Write-Host ""
    Write-Host "  -- NVMe-oF / HPP (vSphere 7+) --" -ForegroundColor White
    Write-Host "  4.  Display NVMe-oF HPP device policies"
    Write-Host ""
    Write-Host "  Q.  Quit"
    Write-Host ""
    Write-Host "  Settings:" -ForegroundColor DarkGray
    Write-Host "    Target Policy : $TargetPolicy" -ForegroundColor Yellow
    if ($TargetPolicy -eq "RoundRobin") {
        Write-Host "    IOps Value    : $CommandsToSwitchPath (CommandsToSwitchPath)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- Main Script Execution ---

# Validate or prompt for ReportPath
if (-not $ReportPath) {
    $ReportPath = Read-Host "Enter folder path to save reports (e.g., C:\Reports or /tmp/reports)"
}
if (-not (Test-Path $ReportPath)) {
    try {
        New-Item -ItemType Directory -Path $ReportPath -ErrorAction Stop | Out-Null
        Write-Host "Created report directory: $ReportPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Could not create report directory '$ReportPath': $_"
        exit 1
    }
}

# Validate or prompt for VCenterServer
if (-not $VCenterServer) {
    $VCenterServer = Read-Host "Enter vCenter Server FQDN or IP"
}

# Connect to vCenter (skip if already connected to the same server)
$alreadyConnected = $global:DefaultVIServers | Where-Object { $_.Name -eq $VCenterServer -and $_.IsConnected }
if (-not $alreadyConnected) {
    try {
        $connectParams = @{ Server = $VCenterServer; ErrorAction = 'Stop' }
        if ($Credential) { $connectParams['Credential'] = $Credential }
        Connect-VIServer @connectParams | Out-Null
        Write-Host "Connected to $VCenterServer" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to vCenter '$VCenterServer': $_"
        exit 1
    }
}

# Detect vCenter version
$vcVersion = Get-VCenterVersion
Write-Host "vCenter version: $($vcVersion.FullString)" -ForegroundColor Gray

do {
    Show-Menu -VCenterInfo $VCenterServer -VsphereVersion $vcVersion.FullString
    $selection = Read-Host "  Please make a selection"

    switch ($selection) {

        '0' {
            Write-Host "`n--- All Datastore Multipath Policies ---" -ForegroundColor Yellow
            $allLuns = Get-DatastoreMultipathInfo
            if ($allLuns) {
                $allLuns | Format-Table Protocol, CanonicalName, Vendor, Model, CapacityGB, PathCount, MultipathPolicy, VMHost -AutoSize
                Write-Host "$($allLuns.Count) LUN(s) found." -ForegroundColor Gray
            }
            else {
                Write-Warning "No SCSI LUNs found or an error occurred."
            }
            Pause
        }

        '1' {
            Write-Host "`n--- Non-$TargetPolicy Datastores ---" -ForegroundColor Yellow
            $allLuns   = Get-DatastoreMultipathInfo
            $nonTarget = $allLuns | Where-Object { $_.MultipathPolicy -ne $TargetPolicy }
            if ($nonTarget) {
                $nonTarget | Format-Table Protocol, CanonicalName, Vendor, Model, CapacityGB, PathCount, MultipathPolicy, VMHost -AutoSize
                Write-Host "$(@($nonTarget).Count) non-compliant LUN(s) found." -ForegroundColor Yellow
            }
            else {
                Write-Host "All datastores are using the $TargetPolicy policy. No action needed." -ForegroundColor Green
            }
            Pause
        }

        '2' {
            Write-Host "`n--- Generating HTML + CSV Report ---" -ForegroundColor Yellow
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $allLuns   = Get-DatastoreMultipathInfo
            $nonTarget = $allLuns | Where-Object { $_.MultipathPolicy -ne $TargetPolicy }
            $nvmeLuns  = Get-NVMeHPPInfo

            # --- CSV Export ---
            $csvFile = Join-Path $ReportPath "mp_policy_$timestamp.csv"
            if ($nonTarget) {
                $nonTarget | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
            }
            else {
                [PSCustomObject]@{ Status = "All SCSI datastores are compliant ($TargetPolicy)" } |
                    Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
            }
            Write-Host "CSV exported  : $csvFile" -ForegroundColor Green

            # --- Build HTML ---
            $totalLuns    = ($allLuns | Measure-Object).Count
            $compliant    = ($allLuns | Where-Object { $_.MultipathPolicy -eq $TargetPolicy } | Measure-Object).Count
            $nonCompliant = $totalLuns - $compliant

            $summaryHtml = @"
<div class="summary">
    <strong>SCSI/NMP Summary:</strong>
    Total LUNs: <strong>$totalLuns</strong> &nbsp;|&nbsp;
    <span class="success">Compliant: $compliant</span> &nbsp;|&nbsp;
    <span class="warning">Non-Compliant: $nonCompliant</span> &nbsp;|&nbsp;
    Target Policy: <strong>$TargetPolicy</strong>
    $(if ($TargetPolicy -eq "RoundRobin") { " &nbsp;|&nbsp; CommandsToSwitchPath: <strong>$CommandsToSwitchPath</strong>" })
</div>
"@

            if (-not $nonTarget) {
                $scsiHtml = "<p class='success'>All SCSI datastores are compliant with the $TargetPolicy policy.</p>"
            }
            else {
                $tableFragment = $nonTarget | ConvertTo-Html -Fragment
                $scsiHtml = "<h2>Non-Compliant SCSI Datastores <span class='badge badge-scsi'>SCSI/NMP</span></h2>$tableFragment"
            }

            $nvmeHtml = ""
            if ($nvmeLuns) {
                $nvmeFragment = $nvmeLuns | ConvertTo-Html -Fragment
                $nvmeHtml = @"
<h2>NVMe-oF HPP Devices <span class='badge badge-nvme'>NVMe/HPP</span></h2>
<div class="note"><strong>Note:</strong> NVMe-oF devices use the High Performance Plugin (HPP), not NMP.
HPP load balance policies (<em>Throughput</em> or <em>Latency</em>) are distinct from SCSI multipath policies.
Remediation for NVMe HPP is performed via <code>esxcli storage hpp device set</code> and is not automated by this script.</div>
$nvmeFragment
"@
            }

            $fullHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>vSphere Multipath Policy Report</title>
    $CssStyle
</head>
<body>
    <h1>vSphere Multipath Policy Report</h1>
    <div class="timestamp">
        Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp;
        vCenter   : <strong>$VCenterServer</strong> &nbsp;|&nbsp;
        Version   : <strong>$($vcVersion.FullString)</strong> &nbsp;|&nbsp;
        Script    : <strong>v$ScriptVersion</strong>
    </div>
    $summaryHtml
    $scsiHtml
    $nvmeHtml
</body>
</html>
"@
            $htmlFile = Join-Path $ReportPath "mp_policy_$timestamp.html"
            $fullHtml | Out-File -FilePath $htmlFile -Encoding UTF8
            Write-Host "HTML report   : $htmlFile" -ForegroundColor Green
            try { Invoke-Item $htmlFile } catch { Write-Warning "Could not auto-open report file." }
            Pause
        }

        '3' {
            Write-Host "`n--- Remediation: Set Policy to $TargetPolicy ---" -ForegroundColor Red
            Write-Warning "This will change the multipath policy for ALL non-compliant SCSI LUNs."
            if ($TargetPolicy -eq "RoundRobin") {
                Write-Host "  CommandsToSwitchPath will be set to: $CommandsToSwitchPath" -ForegroundColor Yellow
            }

            if ($PSCmdlet.ShouldProcess("All non-$TargetPolicy SCSI LUNs in $VCenterServer", "Set MultipathPolicy to $TargetPolicy")) {
                $confirm = Read-Host "Are you sure you want to proceed? (Y/N)"
                if ($confirm -ieq 'Y') {
                    try {
                        $targetLuns = @(Get-VMHost |
                            Get-ScsiLun -LunType disk |
                            Where-Object { $_.MultipathPolicy -ne $TargetPolicy })

                        if ($targetLuns.Count -gt 0) {
                            $success = 0
                            $failed  = 0
                            $total   = $targetLuns.Count

                            for ($i = 0; $i -lt $total; $i++) {
                                $lun  = $targetLuns[$i]
                                $desc = "$($lun.CanonicalName) on $($lun.VMHost)"
                                Write-Progress -Activity "Applying $TargetPolicy Policy" `
                                    -Status "$desc ($($i+1) of $total)" `
                                    -PercentComplete ((($i + 1) / $total) * 100)
                                Write-Host "  Changing $desc..." -NoNewline
                                try {
                                    $setParams = @{
                                        MultipathPolicy = $TargetPolicy
                                        ErrorAction     = 'Stop'
                                    }
                                    if ($TargetPolicy -eq "RoundRobin") {
                                        $setParams['CommandsToSwitchPath'] = $CommandsToSwitchPath
                                    }
                                    $lun | Set-ScsiLun @setParams | Out-Null
                                    Write-Host " OK" -ForegroundColor Green
                                    $success++
                                }
                                catch {
                                    Write-Host " FAILED: $_" -ForegroundColor Red
                                    $failed++
                                }
                            }
                            Write-Progress -Activity "Applying $TargetPolicy Policy" -Completed

                            $resultColor = if ($failed -eq 0) { 'Green' } else { 'Yellow' }
                            Write-Host "`nRemediation complete: $success succeeded, $failed failed (of $total total)." -ForegroundColor $resultColor
                        }
                        else {
                            Write-Host "No non-$TargetPolicy datastores found. Nothing to do." -ForegroundColor Green
                        }
                    }
                    catch {
                        Write-Error "Error during remediation: $_"
                    }
                }
                else {
                    Write-Host "Operation cancelled." -ForegroundColor Yellow
                }
            }
            Pause
        }

        '4' {
            Write-Host "`n--- NVMe-oF HPP Device Policies (vSphere 7+) ---" -ForegroundColor Magenta
            $nvmeLuns = Get-NVMeHPPInfo
            if ($nvmeLuns) {
                $nvmeLuns | Format-Table -AutoSize
                Write-Host ""
                Write-Host "Note: HPP load balancing is separate from NMP. Use 'Throughput' or 'Latency'" -ForegroundColor DarkYellow
                Write-Host "      policy via: esxcli storage hpp device set -d <device> -L Throughput" -ForegroundColor DarkYellow
            }
            else {
                Write-Host "No NVMe-oF HPP devices found, or not supported on this vSphere version." -ForegroundColor Gray
            }
            Pause
        }

        'Q' {
            Write-Host "Disconnecting from $VCenterServer..." -ForegroundColor Cyan
            try { Disconnect-VIServer -Server $VCenterServer -Confirm:$false -ErrorAction SilentlyContinue } catch {}
            Write-Host "Goodbye." -ForegroundColor Cyan
            break
        }

        default {
            Write-Host "Invalid selection. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }

} until ($selection -eq 'Q')
