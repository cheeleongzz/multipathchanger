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

# CSS for HTML report — modern dashboard design
$CssStyle = @"
<style>
/* ============================================================
   vSphere MPP Report — Modern Dashboard Design
   Inspired by Tabler / Linear / Vercel dashboard aesthetics
   ============================================================ */

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
    --font: -apple-system, BlinkMacSystemFont, "Segoe UI", "Inter", Roboto, "Helvetica Neue", sans-serif;
    --bg:           #f1f5f9;
    --surface:      #ffffff;
    --surface-2:    #f8fafc;
    --border:       #e2e8f0;
    --border-sub:   #f1f5f9;
    --text-1:       #0f172a;
    --text-2:       #475569;
    --text-3:       #94a3b8;
    --hdr-bg:       #0f172a;
    --primary:      #3b82f6;
    --primary-dim:  #dbeafe;
    --primary-text: #1d4ed8;
    --green:        #16a34a;
    --green-dim:    #dcfce7;
    --green-text:   #166534;
    --red:          #dc2626;
    --red-dim:      #fee2e2;
    --red-text:     #991b1b;
    --amber:        #d97706;
    --amber-dim:    #fef3c7;
    --amber-text:   #92400e;
    --purple:       #7c3aed;
    --purple-dim:   #ede9fe;
    --purple-text:  #4c1d95;
    --slate-dim:    #f1f5f9;
    --slate-text:   #64748b;
    --r-sm: 8px; --r-md: 12px;
    --sh-xs: 0 1px 2px rgba(0,0,0,.05);
    --sh-sm: 0 2px 6px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.04);
    --sh-md: 0 6px 16px rgba(0,0,0,.08), 0 2px 6px rgba(0,0,0,.05);
}

body {
    font-family: var(--font);
    font-size: 14px;
    line-height: 1.6;
    color: var(--text-1);
    background: var(--bg);
    min-height: 100vh;
}

/* ── HEADER ─────────────────────────────────────────── */
.header {
    position: sticky; top: 0; z-index: 50;
    background: var(--hdr-bg);
    border-bottom: 1px solid rgba(255,255,255,.07);
    height: 58px; padding: 0 32px;
    display: flex; align-items: center; justify-content: space-between;
}
.hdr-brand { display: flex; align-items: center; gap: 12px; }
.hdr-icon {
    width: 34px; height: 34px; flex-shrink: 0;
    background: var(--primary); border-radius: var(--r-sm);
    display: flex; align-items: center; justify-content: center;
}
.hdr-title { font-size: 15px; font-weight: 600; color: #f8fafc; letter-spacing: -.01em; }
.hdr-sub   { font-size: 11px; color: #64748b; margin-top: 1px; }
.hdr-meta  { display: flex; align-items: center; gap: 20px; }
.hdr-item  { display: flex; align-items: center; gap: 6px; font-size: 12px; color: #64748b; }
.hdr-dot   { width: 7px; height: 7px; border-radius: 50%; background: #22c55e; flex-shrink: 0; }

/* ── MAIN LAYOUT ─────────────────────────────────────── */
.main { max-width: 1400px; margin: 0 auto; padding: 30px 32px 64px; }

/* ── PAGE HEADER ─────────────────────────────────────── */
.page-header { margin-bottom: 24px; }
.page-title  { font-size: 22px; font-weight: 700; letter-spacing: -.03em; margin-bottom: 7px; }
.page-meta {
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
    font-size: 12px; color: var(--text-2);
}
.meta-sep { color: var(--border); user-select: none; }

/* ── STAT CARDS ──────────────────────────────────────── */
.stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(165px, 1fr));
    gap: 14px;
    margin-bottom: 28px;
}
.stat-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--r-md);
    padding: 20px 20px 18px;
    box-shadow: var(--sh-xs);
    position: relative; overflow: hidden;
    transition: box-shadow .18s ease, transform .18s ease;
}
.stat-card:hover { box-shadow: var(--sh-md); transform: translateY(-3px); }
.stat-card::before {
    content: '';
    position: absolute; top: 0; left: 0; right: 0; height: 3px;
    border-radius: var(--r-md) var(--r-md) 0 0;
    background: var(--c-accent, var(--primary));
}
.stat-icon {
    width: 38px; height: 38px; border-radius: var(--r-sm);
    display: flex; align-items: center; justify-content: center;
    margin-bottom: 14px; flex-shrink: 0;
    background: var(--c-icon-bg, var(--primary-dim));
    color: var(--c-icon, var(--primary));
}
.stat-value { font-size: 30px; font-weight: 700; letter-spacing: -.04em; line-height: 1; margin-bottom: 4px; }
.stat-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--text-2); }
.stat-sub   { font-size: 11px; color: var(--text-3); margin-top: 4px; }

/* Progress bar (compliance %) */
.progress { height: 5px; background: var(--border); border-radius: 99px; overflow: hidden; margin-top: 12px; }
.progress-fill { height: 100%; border-radius: 99px; }

/* ── SECTION CARD ────────────────────────────────────── */
.card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--r-md);
    box-shadow: var(--sh-xs);
    overflow: hidden;
    margin-bottom: 20px;
}
.card-header {
    display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px;
    padding: 15px 22px;
    border-bottom: 1px solid var(--border);
    background: var(--surface-2);
}
.card-hl   { display: flex; align-items: center; gap: 12px; }
.card-icon {
    width: 32px; height: 32px; border-radius: var(--r-sm);
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.card-title    { font-size: 14px; font-weight: 600; letter-spacing: -.01em; }
.card-subtitle { font-size: 12px; color: var(--text-2); margin-top: 2px; }
.card-body { overflow-x: auto; }

/* Empty / all-good state */
.card-ok {
    display: flex; align-items: center; gap: 14px;
    padding: 26px 22px;
}
.card-ok-icon {
    width: 40px; height: 40px; border-radius: 50%;
    background: var(--green-dim); display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.card-ok-title { font-weight: 600; color: var(--green); }
.card-ok-desc  { font-size: 12px; color: var(--text-2); margin-top: 3px; }

/* ── TABLE ───────────────────────────────────────────── */
table { width: 100%; border-collapse: collapse; font-size: 13px; }
thead { position: sticky; top: 58px; z-index: 10; }
th {
    background: var(--surface-2);
    color: var(--text-2);
    font-size: 10.5px; font-weight: 700;
    text-transform: uppercase; letter-spacing: .08em;
    padding: 9px 16px; text-align: left;
    border-bottom: 1px solid var(--border); white-space: nowrap;
}
td { padding: 11px 16px; border-bottom: 1px solid var(--border-sub); vertical-align: middle; }
tr:last-child td { border-bottom: none; }
tbody tr { transition: background .1s; }
tbody tr:hover { background: var(--surface-2); }
.td-mono {
    font-family: "SF Mono","Cascadia Code","Fira Code",ui-monospace,monospace;
    font-size: 12px; color: var(--text-2);
}
.td-dim { color: var(--text-2); font-size: 12px; }
.td-num { font-variant-numeric: tabular-nums; }

/* ── BADGES ──────────────────────────────────────────── */
.badge {
    display: inline-flex; align-items: center;
    padding: 2px 9px; border-radius: 99px;
    font-size: 11px; font-weight: 600; letter-spacing: .03em; white-space: nowrap;
}
.badge--green  { background: var(--green-dim);  color: var(--green-text); }
.badge--red    { background: var(--red-dim);    color: var(--red-text); }
.badge--amber  { background: var(--amber-dim);  color: var(--amber-text); }
.badge--blue   { background: var(--primary-dim); color: var(--primary-text); }
.badge--purple { background: var(--purple-dim); color: var(--purple-text); }
.badge--gray   { background: var(--slate-dim);  color: var(--slate-text); }

/* ── DETAILS/SUMMARY (collapsible) ──────────────────── */
details { border-top: 1px solid var(--border); }
summary {
    padding: 13px 22px; font-size: 13px; font-weight: 500;
    cursor: pointer; color: var(--text-2);
    display: flex; align-items: center; gap: 8px;
    user-select: none;
}
summary:hover { background: var(--surface-2); }
summary::marker { display: none; }
summary::-webkit-details-marker { display: none; }
.summary-arrow { font-size: 10px; transition: transform .2s; }
details[open] .summary-arrow { transform: rotate(90deg); }

/* ── NOTE BOX ────────────────────────────────────────── */
.note {
    margin: 14px 22px; padding: 12px 16px;
    background: var(--amber-dim); border-left: 3px solid var(--amber);
    border-radius: var(--r-sm); font-size: 12px; color: var(--amber-text); line-height: 1.6;
}
.note code {
    background: rgba(0,0,0,.07); padding: 1px 5px;
    border-radius: 3px; font-family: monospace; font-size: 11px;
}

/* ── FOOTER ──────────────────────────────────────────── */
.footer {
    text-align: center; padding: 20px;
    font-size: 11px; color: var(--text-3);
    border-top: 1px solid var(--border); margin-top: 32px;
}

@media (max-width: 700px) {
    .header { padding: 0 16px; }
    .main   { padding: 20px 16px 48px; }
    .hdr-meta { display: none; }
}
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

            # --- Metrics ---
            $totalLuns      = ($allLuns | Measure-Object).Count
            $compliant      = ($allLuns | Where-Object { $_.MultipathPolicy -eq $TargetPolicy } | Measure-Object).Count
            $nonCompliant   = $totalLuns - $compliant
            $hostsScanned   = ($allLuns | Select-Object VMHost -Unique | Measure-Object).Count
            $compliancePct  = if ($totalLuns -gt 0) { [Math]::Round(($compliant / $totalLuns) * 100, 0) } else { 100 }
            $pctBarColor    = if ($compliancePct -ge 90) { '#16a34a' } elseif ($compliancePct -ge 70) { '#d97706' } else { '#dc2626' }
            $pctBadgeClass  = if ($compliancePct -ge 90) { 'green' } elseif ($compliancePct -ge 70) { 'amber' } else { 'red' }

            # --- Policy badge helper ---
            function script:Get-PolicyBadge ([string]$policy) {
                switch ($policy) {
                    'RoundRobin'       { return "<span class='badge badge--green'>RoundRobin</span>" }
                    'MostRecentlyUsed' { return "<span class='badge badge--amber'>MRU</span>" }
                    'Fixed'            { return "<span class='badge badge--blue'>Fixed</span>" }
                    default            { return "<span class='badge badge--gray'>$policy</span>" }
                }
            }
            function script:Get-HPPBadge ([string]$policy) {
                switch ($policy) {
                    'Throughput' { return "<span class='badge badge--purple'>Throughput</span>" }
                    'Latency'    { return "<span class='badge badge--blue'>Latency</span>" }
                    default      { return "<span class='badge badge--gray'>$policy</span>" }
                }
            }

            # --- Stat cards HTML ---
            $statCardsHtml = @"
<div class="stats-grid">
  <div class="stat-card" style="--c-accent:#3b82f6;--c-icon-bg:#dbeafe;--c-icon:#1d4ed8">
    <div class="stat-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/><path d="M3 12c0 1.66 4.03 3 9 3s9-1.34 9-3"/>
      </svg>
    </div>
    <div class="stat-value">$totalLuns</div>
    <div class="stat-label">Total LUNs</div>
    <div class="stat-sub">SCSI / NMP</div>
  </div>
  <div class="stat-card" style="--c-accent:#16a34a;--c-icon-bg:#dcfce7;--c-icon:#166534">
    <div class="stat-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M20 6L9 17l-5-5"/>
      </svg>
    </div>
    <div class="stat-value" style="color:#16a34a">$compliant</div>
    <div class="stat-label">Compliant</div>
    <div class="stat-sub">Policy: $TargetPolicy</div>
  </div>
  <div class="stat-card" style="--c-accent:$(if($nonCompliant -gt 0){'#dc2626'}else{'#16a34a'});--c-icon-bg:$(if($nonCompliant -gt 0){'#fee2e2'}else{'#dcfce7'});--c-icon:$(if($nonCompliant -gt 0){'#991b1b'}else{'#166534'})">
    <div class="stat-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
      </svg>
    </div>
    <div class="stat-value" style="color:$(if($nonCompliant -gt 0){'#dc2626'}else{'#16a34a'})">$nonCompliant</div>
    <div class="stat-label">Non-Compliant</div>
    <div class="stat-sub">Require remediation</div>
  </div>
  <div class="stat-card" style="--c-accent:$pctBarColor;--c-icon-bg:#f1f5f9;--c-icon:#475569">
    <div class="stat-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/>
      </svg>
    </div>
    <div class="stat-value"><span class="badge badge--$pctBadgeClass" style="font-size:20px;padding:4px 12px">$compliancePct%</span></div>
    <div class="stat-label">Compliance Rate</div>
    <div class="progress"><div class="progress-fill" style="width:$compliancePct%;background:$pctBarColor"></div></div>
  </div>
  <div class="stat-card" style="--c-accent:#7c3aed;--c-icon-bg:#ede9fe;--c-icon:#4c1d95">
    <div class="stat-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>
      </svg>
    </div>
    <div class="stat-value">$hostsScanned</div>
    <div class="stat-label">Hosts Scanned</div>
    <div class="stat-sub">ESXi hosts</div>
  </div>
</div>
"@

            # --- SCSI/NMP table card ---
            $tableHeader = "<table><thead><tr><th>Canonical Name</th><th>Vendor</th><th>Model</th><th>Cap (GB)</th><th>Paths</th><th>Policy</th><th>ESXi Host</th></tr></thead><tbody>"
            $tableFooter = "</tbody></table>"

            if (-not $nonTarget) {
                $scsiHtml = @"
<div class="card">
  <div class="card-header">
    <div class="card-hl">
      <div class="card-icon" style="background:#dcfce7;color:#166534">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>
      </div>
      <div><div class="card-title">SCSI / NMP Datastores</div><div class="card-subtitle">All $totalLuns LUN(s) are compliant</div></div>
    </div>
    <span class="badge badge--blue">SCSI / NMP</span>
  </div>
  <div class="card-ok">
    <div class="card-ok-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#16a34a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg></div>
    <div><div class="card-ok-title">All datastores are compliant</div><div class="card-ok-desc">Every SCSI LUN is configured with the $TargetPolicy policy — no action required.</div></div>
  </div>
</div>
"@
            }
            else {
                # Non-compliant table rows
                $ncRows = foreach ($lun in $nonTarget) {
                    $badge = script:Get-PolicyBadge $lun.MultipathPolicy
                    "<tr><td class='td-mono'>$($lun.CanonicalName)</td><td>$($lun.Vendor)</td><td>$($lun.Model)</td><td class='td-num'>$($lun.CapacityGB)</td><td class='td-num'>$($lun.PathCount)</td><td>$badge</td><td class='td-dim'>$($lun.VMHost)</td></tr>"
                }
                # All LUNs rows (for collapsible section)
                $allRows = foreach ($lun in $allLuns) {
                    $badge = script:Get-PolicyBadge $lun.MultipathPolicy
                    "<tr><td class='td-mono'>$($lun.CanonicalName)</td><td>$($lun.Vendor)</td><td>$($lun.Model)</td><td class='td-num'>$($lun.CapacityGB)</td><td class='td-num'>$($lun.PathCount)</td><td>$badge</td><td class='td-dim'>$($lun.VMHost)</td></tr>"
                }
                $scsiHtml = @"
<div class="card">
  <div class="card-header">
    <div class="card-hl">
      <div class="card-icon" style="background:#fee2e2;color:#991b1b">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
        </svg>
      </div>
      <div><div class="card-title">Non-Compliant Datastores</div><div class="card-subtitle">$nonCompliant LUN(s) not using $TargetPolicy policy</div></div>
    </div>
    <span class="badge badge--blue">SCSI / NMP</span>
  </div>
  <div class="card-body">$tableHeader$($ncRows -join '')$tableFooter</div>
  <details>
    <summary><span class="summary-arrow">&#9658;</span> Show all $totalLuns LUNs</summary>
    <div class="card-body">$tableHeader$($allRows -join '')$tableFooter</div>
  </details>
</div>
"@
            }

            # --- NVMe/HPP card ---
            $nvmeHtml = ""
            if ($nvmeLuns) {
                $nvmeRows = foreach ($dev in $nvmeLuns) {
                    $badge = script:Get-HPPBadge $dev.LoadBalancePolicy
                    "<tr><td class='td-mono'>$($dev.Device)</td><td>$badge</td><td class='td-num'>$($dev.ActivePaths)</td><td class='td-num'>$($dev.SuspendedPaths)</td><td class='td-dim'>$($dev.VMHost)</td></tr>"
                }
                $nvmeHtml = @"
<div class="card">
  <div class="card-header">
    <div class="card-hl">
      <div class="card-icon" style="background:#ede9fe;color:#4c1d95">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>
        </svg>
      </div>
      <div><div class="card-title">NVMe-oF HPP Devices</div><div class="card-subtitle">vSphere 7+ High Performance Plugin</div></div>
    </div>
    <span class="badge badge--purple">NVMe / HPP</span>
  </div>
  <div class="note"><strong>Note:</strong> NVMe-oF devices use the High Performance Plugin (HPP), not NMP. HPP load balance policies (<em>Throughput</em> / <em>Latency</em>) differ from SCSI multipath policies. To remediate, run: <code>esxcli storage hpp device set -d &lt;device&gt; -L Throughput</code></div>
  <div class="card-body">
    <table><thead><tr><th>Device</th><th>Load Balance Policy</th><th>Active Paths</th><th>Suspended Paths</th><th>ESXi Host</th></tr></thead>
    <tbody>$($nvmeRows -join '')</tbody></table>
  </div>
</div>
"@
            }

            # --- Assemble full HTML ---
            $ioLine = if ($TargetPolicy -eq "RoundRobin") { "<span class='meta-sep'>/</span><span>CommandsToSwitchPath: <strong>$CommandsToSwitchPath</strong></span>" } else { "" }
            $fullHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>vSphere Multipath Policy Report &mdash; $VCenterServer</title>
  $CssStyle
</head>
<body>

<header class="header">
  <div class="hdr-brand">
    <div class="hdr-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/><path d="M3 12c0 1.66 4.03 3 9 3s9-1.34 9-3"/>
      </svg>
    </div>
    <div>
      <div class="hdr-title">Multipath Policy Report</div>
      <div class="hdr-sub">vSphere $($vcVersion.Version) &middot; Script v$ScriptVersion</div>
    </div>
  </div>
  <div class="hdr-meta">
    <div class="hdr-item"><span class="hdr-dot"></span>$VCenterServer</div>
    <div class="hdr-item">$(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
  </div>
</header>

<main class="main">
  <div class="page-header">
    <h1 class="page-title">Storage Multipath Audit</h1>
    <div class="page-meta">
      <span>vCenter: <strong>$VCenterServer</strong></span>
      <span class="meta-sep">/</span>
      <span>$($vcVersion.FullString)</span>
      <span class="meta-sep">/</span>
      <span>Target Policy: <strong>$TargetPolicy</strong></span>
      $ioLine
    </div>
  </div>

  $statCardsHtml

  $scsiHtml

  $nvmeHtml
</main>

<footer class="footer">
  Generated by Datastore_MPP_Changer.ps1 v$ScriptVersion &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
</footer>

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
