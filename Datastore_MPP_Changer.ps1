#requires -Modules VMware.VimAutomation.Core
write-host "Modules VMware.VimAutomation.Core Loaded!!"

# Style of the Report in Css
$css=”<style>
body {
font-family: Verdana, sans-serif;
font-size: 14px;
color: #666666;
background: #FEFEFE;
border-width: 1px;
border-style: solid;
border-color: black;
}
#title{
color:#FF0000;
font-size: 30px;
font-weight: bold;
padding-top:25px;
margin-left:35px;
height: 50px;
}

</style>”

# HTML Markup
$PageBoxOpener=”<div id=’box1’>”
$ReportHeader=”<div id=’boxheader’>Multipath Policy Report $clustername</div>”
#CanonicalName, Vendor, Model, CapacityGB, VMHost, MultipathPolicy
$ReportTable=”<table><tr><th>Concanical Name</th><th>Vendor</th><th>Model</th><th>CapacityGB</th><th>VMHost</th><th>Multipath Policy</th></tr>”
$BoxContentOpener=”<div id=’boxcontent’>”
$PageBoxCloser=”</div>”
$br=”<br>”

function get-info
{
$canonical= Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select CanonicalName
$vendor = Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select-Object Vendor
$model = Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select-Object Model
$capacity = Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select-Object CapacityGB
$vmhost = Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select-Object VMHost
$mpp = Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select-Object MultipathPolicy
}

function Show-Menu
{
    param (
        [string]$Title = 'Change Multipath Policy Menu'
    )
   
    Write-Host "================ $Title ================" -ForegroundColor Green
    Write-Host "Press '0' to display all datastore's Multipath policy."
    Write-Host "Press '1' to display datastores which is not configured as Round Robin Policy."
    Write-Host "Press '2' to create a simple HTML report for the datastore without Round Robin multipath policy."
    Write-Host "Press '3' to change the datastores listed in option 1 to Round Robin"
    Write-Host "Press 'q' to quit."
    "`n"
}

function checkpath
{
	#Check and display the multipath policy of all LUN and multipath policy
    Get-Cluster $clustername | Get-VMHost | Get-ScsiLun -LunType disk | Select-Object CanonicalName, Vendor, Model, CapacityGB, VMHost, MultipathPolicy | FT
    "`n"
}

Write-Host "Enter the required information" -ForegroundColor Yellow
             $folder = Read-Host -Prompt "Enter the folder to export the HTML report:"
			 $vcenter = Read-Host -Prompt "Please enter vcenter server FQDN or IP address"
             $clustername = Read-Host -Prompt "Please enter the cluster name"
             Connect-VIServer $vcenter
			 clear-host
             #Grab all information for html report
			 write-host "Getting Existing Datastore Multipath Policy (Excluding NFS)"
             get-info
			 checkpath

do {
Show-Menu 
$selection = Read-Host "Please make a selection"
switch ($selection)
     {
         '0' {
             Write-Host "Display all Disk LUN and Multipath Policy" -ForegroundColor Yellow
             #Check the multipath policy of all LUN and multipath policy
             checkpath

         } 
         '1' {
             Write-Host "Datastores which is not configured as Round Robin Multipath Policy" -ForegroundColor Yellow
             $mpReport = Get-Cluster $clustername | Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Select-Object CanonicalName, Vendor, Model, CapacityGB, VMHost, MultipathPolicy | FT
             
			 $mpReport
			 
             If (-not $mpReport){   
             Write-Host "**********All datastores are configured with Round Robin policy**********" -ForegroundColor Green
             Write-Host "Press any key to return to main menu." -ForegroundColor Yellow
             pause
             clear-host
            }

         } 
         '2' {
             Write-Host "Creating Simple HTML report to display Datastores which is not configured as Round Robin Multipath Policy" -ForegroundColor Yellow
             $Report = Get-Cluster $clustername | Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | 
             select CanonicalName, Vendor, Model, CapacityGB, VMHost, MultipathPolicy

             If (-not $Report){   
             $Report = [PSCustomObject]@{
             CanonicalName = "All datastores are configured to round robin policy"
             Vendor = ""
             Model = ""
             CapacityGB = ""
             VMHost = ""
             MultipathPolicy = ""
            }
}

             #ConvertTo-Html CanonicalName, Vendor, Model, CapacityGB, VMHost, MultipathPolicy 
             $Report = $Report | 
             ConvertTo-Html -Title "Multipath Report" -Head "<div id='title'>Multipath Policy Report</div>$br<div id='subtitle'>Report generated on:$(Get-Date)</div>” -Body "$css $PageBoxOpener $BoxContentOpener $ReportHeader <tr><td>$canonical</td><td>$vendor</td><td>$model</td><td></td><td>$capacity</td><td>$vmhost</td><td>$mpp</td></tr> $PageBoxCloser </table>"
             
             $Report | Out-File $folder\mp_policy.html
             & $folder\mp_policy.html
         }
         '3' {
             Write-Host "Changing the datastores listed in option 2 to Round Robin..." -ForegroundColor Green
             Get-Cluster $clustername | Get-VMHost | Get-ScsiLun -LunType disk | where {$_.MultipathPolicy -ne "RoundRobin"} | Set-ScsiLun -MultipathPolicy "RoundRobin"
             Write-Host "Operation Completed" -ForegroundColor Green
             Write-Host "Press any key to return to main menu." -ForegroundColor Yellow
             pause
             clear-host
         }
         'q' {
            exit
         
         }
          Default {Write-Host "Invalid Choice. Try again." -ForegroundColor Red
          pause
          clear-host}
     }
 }
 until ($selection -eq 'q')