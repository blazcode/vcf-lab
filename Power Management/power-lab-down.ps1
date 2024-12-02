# Variables
$MgmtVC = "vcf-mgmt1-vc1.lab.blaz.tech"
$WLDVC = "vcf-wld1-vc1.lab.blaz.tech"
$RootESXi = "esxi1.lab.blaz.tech"
$RootVCVM = "vcsa.lab.blaz.tech"

# Credentials for vCenter
$VCUsername = "administrator@vsphere.local"
$VCPassword = "VMware1!"

# Credentials for ESXi hosts
$HostUsername = "root"
$HostPassword = "VMware1!"

# Nested ESXi hosts (Workload Domain)
$WLDHosts = @(
    "vcf-wld1-esxi1.lab.blaz.tech",
    "vcf-wld1-esxi2.lab.blaz.tech",
    "vcf-wld1-esxi3.lab.blaz.tech",
    "vcf-wld1-esxi4.lab.blaz.tech"
)

# Nested ESXi hosts (Management Domain)
$MgmtHosts = @(
    "vcf-mgmt1-esxi1.lab.blaz.tech",
    "vcf-mgmt1-esxi2.lab.blaz.tech",
    "vcf-mgmt1-esxi3.lab.blaz.tech",
    "vcf-mgmt1-esxi4.lab.blaz.tech"
)

# Function to send logs to Discord and console
function Send-Log {
    param (
        [Parameter(Mandatory=$true)][String]$Message,
        [Parameter(Mandatory=$false)][String]$color="green"
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_hh:mm:ss"
    Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
    Write-Host -ForegroundColor $color " $message"
}

# Function to shut down VMs via vCenter, excluding the VCSA by omitting it from TagPriority
function Shutdown-VMs {
    param (
        [string]$vCenter,
        [string[]]$TagPriority = @() # Ordered list of tags to process
    )

    Send-Log -Message "...connecting to $vCenter"
    Connect-VIServer -Server $vCenter -User $VCUsername -Password $VCPassword | Out-Null

    # Process VMs by tag priority
    foreach ($Tag in $TagPriority) {
        Send-Log -Message "...searching for powered on VMs tagged: $Tag"
        $TaggedVMs = Get-VM | Where-Object {
            $_.PowerState -eq "PoweredOn" -and 
            (Get-TagAssignment -Entity $_).Tag.Name -eq $Tag
        }
        Send-Log -Message "...found: $TaggedVMs"
        foreach ($VM in $TaggedVMs) {
            Send-Log -Message "...shutting down VM: $VM"
            Shutdown-VMGuest -VM $VM -Confirm:$false | Out-Null
            while ((Get-VM -Name $VM.Name).PowerState -ne "PoweredOff") {
                Send-Log -Message "......waiting for power off"
                Start-Sleep -Seconds 10
            }
        }
    }

    Disconnect-VIServer -Server $vCenter -Confirm:$false
}

# Function to shut down vCenters on management hosts directly
function Shutdown-VCSAs {
    param (
        [string[]]$Hosts
    )

    foreach ($VMHost in $Hosts) {
        Connect-VIServer -Server $VMHost -User $HostUsername -Password $HostPassword | Out-Null

        # Identify and power off all vCLS VMs
        Send-Log -Message "...searching for VCSAs on: $VMHost"
        $VCSAs = Get-VM | Where-Object { $_.Name -like "*-vc1" }
        foreach ($VCSA in $VCSAs) {
            Send-Log -Message "...shutting down: $VCSA"
            Shutdown-VMGuest -VM $VCSA -Confirm:$false | Out-Null
            while ((Get-VM -Name $VCSA.Name).PowerState -ne "PoweredOff") {
                Send-Log "...waiting for $VCSA to be powered off"
                Start-Sleep -Seconds 10
            }
        }
    }
}

# Function to shut down ESXi hosts directly
function Shutdown-NestedHosts {
    param (
        [string[]]$Hosts
    )

    foreach ($VMHost in $Hosts) {
        Send-Log -Message "...connecting to $VMHost"
        Connect-VIServer -Server $VMHost -User $HostUsername -Password $HostPassword | Out-Null
        
        # Identify and power off all vCLS VMs
        Send-Log -Message "...searching for vCLS VMs to shutdown"
        $vCLSVms = Get-VM -Server $VMHost | Where-Object { $_.Name -like "vCLS-*" }
        foreach ($vCLS in $vCLSVms) {
            Send-Log -Message "...found: $vCLS"
            $vCLS
            Stop-VM -VM $vCLS -Confirm:$false | Out-Null
            while ((Get-VM -Name $vCLS.Name).PowerState -ne "PoweredOff") {
                Send-Log -Message "...waiting for $vCLS to be powered off"
                Start-Sleep -Seconds 10
            }
        }

        # Place host in Maintenance Mode with NoDataMigration evacuation mode
        Send-Log -Message "...putting $VMHost in maintenance mode"
        Set-VMHost -VMHost $VMHost -State "Maintenance" -VsanDataMigrationMode NoDataMigration -Confirm:$false | Out-Null

        # Verify the host is in Maintenance Mode
        $HostState = (Get-VMHost -Name $VMHost).State
        while ($HostState -ne "Maintenance") {
            Send-Log -Message "...waiting for $VMHost to be in maintenance mode"
            Start-Sleep -Seconds 10
            $HostState = (Get-VMHost -Name $VMHost).State
        }

        # Power off the host
        Send-Log -Message "...powering off host: $VMHost"
        Stop-VMHost -VMHost $VMHost -Force -Confirm:$false | Out-Null
        Disconnect-VIServer -Server $VMHost -Confirm:$false
    }
}

# Main Script Execution

Send-Log -Message "Beginning lab shutdown!"

# Step 1: Shutdown VMs in Workload Domain
Send-Log -Message "Step1: Shutting down all VMs in Workload Domain"
Shutdown-VMs -vCenter $WLDVC -TagPriority @("Edge", "NSX")

# Step 2: Shutdown Workload Domain Hosts Directly
Send-Log -Message "Step 2: Shutting down nested ESXi hosts in Workload Domain"
Shutdown-NestedHosts -Hosts $WLDHosts

# Step 3: Shutdown VMs in Management Domain
Send-Log -Message "Step 3: Shutting down all VMs in Management Domain"
Shutdown-VMs -vCenter $MgmtVC -TagPriority @("Edge", "NSX", "SDDC")

Shutdown-VCSAs -Hosts $MgmtHosts

# Step 4: Shutdown Management Domain Hosts Directly
Send-Log -Message "Step 4: Shutting down nested ESXi hosts in Management Domain"
Shutdown-NestedHosts -Hosts $MgmtHosts

# Step 5: Shutdown Root VCSA via ESXi Host
Send-Log -Message "Step 5: Connecting directly to ESXi host to shut down Root VCSA"
Connect-VIServer -Server $RootESXi -User $HostUsername -Password $HostPassword | Out-Null
$RootVC = Get-VM -Name "vcsa"
Send-Log -Message "Shutting down Root VCSA: $($RootVC.Name)"
Shutdown-VMGuest -VM $RootVC -Confirm:$false | Out-Null
while ((Get-VM -Name $RootVC.Name).PowerState -ne "PoweredOff") {
    Start-Sleep -Seconds 10
}

Send-Log -Message "Root VCSA powered off"
Send-Log -Message "All systems successfully powered off!"