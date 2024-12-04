# Variables
$MgmtVC = "vcf-mgmt1-vc1.lab.blaz.tech"
$WLDVC = "vcf-wld1-vc1.lab.blaz.tech"
$RootESXi = "esxi1.lab.blaz.tech"
$RootVCSA = "vcsa"

# Credentials for vCenter
$VCUsername = "administrator@vsphere.local"
$VCPassword = "VMware1!"

# Credentials for ESXi hosts
$HostUsername = "root"
$HostPassword = "VMware1!"

# Nested ESXi hosts (Workload Domain)
$WLDHosts = [ordered]@{
    "vcf-wld1-esxi1" = "vcf-wld1-esxi1.lab.blaz.tech"
    "vcf-wld1-esxi2" = "vcf-wld1-esxi2.lab.blaz.tech"
    "vcf-wld1-esxi3" = "vcf-wld1-esxi3.lab.blaz.tech"
    "vcf-wld1-esxi4" = "vcf-wld1-esxi4.lab.blaz.tech"
}

# Nested ESXi hosts (Management Domain)
$MgmtHosts = [ordered]@{
    "vcf-mgmt1-esxi1" = "vcf-mgmt1-esxi1.lab.blaz.tech"
    "vcf-mgmt1-esxi2" = "vcf-mgmt1-esxi2.lab.blaz.tech"
    "vcf-mgmt1-esxi3" = "vcf-mgmt1-esxi3.lab.blaz.tech"
    "vcf-mgmt1-esxi4" = "vcf-mgmt1-esxi4.lab.blaz.tech"
}

# Function to send logs to console
function Send-Log {
    param (
        [Parameter(Mandatory=$true)][String]$Message,
        [Parameter(Mandatory=$false)][String]$color="green"
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_hh:mm:ss"
    Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
    Write-Host -ForegroundColor $color " $message"
}

# Function to wait for a host to become reachable
function Wait-ForHost {
    param (
        [string]$HostFQDN,
        [string]$Username,
        [string]$Password,
        [int]$TimeoutSeconds = 600 # Default timeout
    )

    $ElapsedTime = 0
    do {
        try {
            $Server = Connect-VIServer -Server $HostFQDN -User $Username -Password $Password -ErrorAction Stop -NotDefault
            Send-Log -Message "...$HostFQDN is online"
            Disconnect-VIServer -Server $Server -Confirm:$false
            break
        } catch {
            if ($ElapsedTime -ge $TimeoutSeconds) {
                Send-Log -Message "Timeout reached waiting for host: $HostFQDN" -color "red"
                throw "Host $HostFQDN did not become reachable within the timeout period."
            }
            Send-Log -Message "...waiting for $HostFQDN to be reachable"
            Start-Sleep -Seconds 15
            $ElapsedTime += 15
        }
    } while ($true)
}

# Function to wait for VCSA to be fully operational
function Wait-ForVCSAReady {
    param (
        [string]$vCenter,
        [string]$Username,
        [string]$Password,
        [int]$TimeoutSeconds = 600 # Default timeout
    )

    $ElapsedTime = 
    $Ready = $false

    # Dislike sleeping... but addressing possible race condition between VCSA NTP service starting and login attempt; NTP must start and sync time first
    Send-Log -Message "Waiting 5 minutes for VCSA to boot";
    Start-Sleep -Seconds 300

    do {
        try {
            Send-Log -Message "...conneting to $vCenter"
            Connect-VIServer -Server $vCenter -User $Username -Password $Password -ErrorAction Stop -NotDefault | Out-Null
            Send-Log -Message "...testing Get-TagAssignment on $vCenter to ensure services are fully operational" 
            $Tags = Get-TagAssignment -Server $vCenter -ErrorAction Stop
            if ($Tags) {
                $Ready = $true
            }

            Disconnect-VIServer -Server $vCenter -Confirm:$false
        } catch {
            Send-Log -Message $_.Exception.InnerException?.Message -Color red
            #Disconnect-VIServer -Server $vCenter -Confirm:$false
            Send-Log -Message "...waiting for $vCenter to become fully operational"
        }

        if ($Ready) {
            Send-Log -Message "...$vCenter is fully operational"
            return
        }

        Start-Sleep -Seconds 30
        $ElapsedTime += 30

        if ($ElapsedTime -ge $TimeoutSeconds) {
            Send-Log -Message "Timeout reached waiting for VCSA: $vCenter" -color "red"
            throw "VCSA $vCenter did not become operational within the timeout period."
        }
    } while (-not $Ready)
}

# Main Script Execution

# Step 1: Ensure root ESXi host is available
Send-Log -Message "Step 1: Checking root ESXi host availability"
Wait-ForHost -HostFQDN $RootESXi -Username $HostUsername -Password $HostPassword

# Step 2: Power on root VCSA
Send-Log -Message "Step 2: Powering on root VCSA"
try {
    Connect-VIServer -Server $RootESXi -User $HostUsername -Password $HostPassword | Out-Null
    Start-VM -VM $RootVCSA -Confirm:$false -ErrorAction Stop | Out-Null
    while ((Get-VM -Name $RootVCSA).PowerState -ne "PoweredOn") {
        Start-Sleep -Seconds 10
    }
    Disconnect-VIServer -Server $RootESXi -Confirm:$false
} catch {
    if ($_.Exception.ExistingState -eq "PoweredOn") {
        Send-Log -Message "...$RootVCSA already powered on" -Color Yellow
    } else {
        Send-Log -Message $_.Exception.InnerException -Color red
    }
}

# Step 3: Wait for root VCSA to be operational
Send-Log -Message "Step 3: Waiting for root VCSA to be operational"
#Wait-ForHost -HostFQDN $RootVCSA -Username $VCUsername -Password $VCPassword
Wait-ForVCSAReady -vCenter $RootVCSA -Username $VCUsername -Password $VCPassword

# Step 4: Power on Management Domain Hosts
Send-Log -Message "Step 4: Connecting to root VCSA and powering on Management Domain hosts"
Connect-VIServer -Server $RootVCSA -User $VCUsername -Password $VCPassword | Out-Null
foreach ($VMHost in $MgmtHosts.Keys) {
    try {
        Start-VM -VM $VMHost -Confirm:$false | Out-Null
        Send-Log -Message "Started management host: $VMHost"
        $FQDN = $MgmtHosts[$VMHost]
        Wait-ForHost -HostFQDN $FQDN -Username $HostUsername -Password $HostPassword
    } catch {
        if ($_.Exception.ExistingState -eq "PoweredOn") {
            Send-Log -Message "...$FQDN already powered on" -Color Yellow
        } else {
            Send-Log -Message $_.Exception.InnerException -Color red
        }
    }
}
Disconnect-VIServer -Server $RootVCSA -Confirm:$false

# Step 5: Exit Maintenance Mode for Management Domain Hosts
Send-Log -Message "Step 5: Exiting Maintenance Mode for Management Domain Hosts"
foreach ($HostShortName in $MgmtHosts.Keys) {
    $HostFQDN = $MgmtHosts[$HostShortName]
    try {
        $Server = Connect-VIServer -Server $HostFQDN -User $HostUsername -Password $HostPassword -NotDefault
        $HostObject = Get-VMHost -Server $Server | Where-Object { $_.Name -eq $HostFQDN }

        if ($HostObject) {
            Set-VMHost -VMHost $HostObject -State Connected -Confirm:$false | Out-Null
            Send-Log -Message "Disabled Maintenance Mode on: $HostFQDN"
        } else {
            Send-Log -Message "Could not find VMHost object for: $HostFQDN" -color "red"
        }

        Disconnect-VIServer -Server $HostFQDN -Confirm:$false | Out-Null
    } catch {
        Send-Log -Message $_.Exception.InnerException -Color red
    }
}

Start-Sleep -Seconds 30

# Step 6: Power on Management Domain VCSA
Send-Log -Message "Step 6: Searching for and powering on Management Domain VCSA"
foreach ($FQDN in $MgmtHosts.Values) {
    try {
        Send-Log -Message "Connecting to $FQDN"
        Connect-VIServer -Server $FQDN -User $HostUsername -Password $HostPassword -NotDefault | Out-Null

        Send-Log -Message "...searching for vcf-mgmt1-vc1"
        $MgmtVCSA = Get-VM -Server $FQDN -Name "vcf-mgmt1-vc1" -ErrorAction SilentlyContinue
        if ($MgmtVCSA) {
            Send-Log -Message "Found vcf-mgmt1-vc1; powering on!"
            Start-VM -Server $FQDN -VM $MgmtVCSA -Confirm:$false | Out-Null
            Disconnect-VIServer -Server $FQDN -Confirm:$false
            Send-Log -Message "Disconnected from $FQDN and stopping search"
            break
        }
        Disconnect-VIServer -Server $FQDN -Confirm:$false
        Send-Log -Message "...vcf-mgmt1-vc1 not found on $FQDN - disconnected and continuing search"
    } catch {
        Send-Log -Message $_.Exception.InnerException -Color red
    }
}
#Wait-ForHost -HostFQDN $MgmtVC -Username $VCUsername -Password $VCPassword

# Step 7: Power on Management VMs by role tag
Send-Log -Message "Step 7: Waiting for Management Domain VCSA to be fully operational"
Wait-ForVCSAReady -vCenter $MgmtVC -Username $VCUsername -Password $VCPassword

Send-Log -Message "Step 7: Connecting to Management Domain VCSA and powering on Management VMs by role"
Connect-VIServer -Server $MgmtVC -User $VCUsername -Password $VCPassword | Out-Null

$Tags = @("Edge", "NSX", "SDDC", "VCSA")
foreach ($Tag in $Tags) {
    $VMsToStart = Get-VM | Where-Object {
        $_.PowerState -eq "PoweredOff" -and 
        (Get-TagAssignment -Entity $_ | Where-Object { $_.Tag.Name -eq $Tag }).Count -gt 0
    }
    foreach ($VM in $VMsToStart) {
        try {
            Start-VM -Server $MgmtVC -VM $VM -Confirm:$false | Out-Null
            Send-Log -Message "Started $Tag tagged VM: $($VM.Name)"
        } catch {
            Send-Log -Message $_.Exception.InnerException -Color red
        }
    }
}
Disconnect-VIServer -Server $MgmtVC -Confirm:$false

# Step 8: Power on Workload Domain Hosts
Send-Log -Message "Step 8: Connecting to Root VCSA and powering on Workload Domain Hosts"
Connect-VIServer -Server $RootVCSA -User $VCUsername -Password $VCPassword | Out-Null
foreach ($VMHost in $WLDHosts.Keys) {
    try {
        Start-VM -VM $VMHost -Confirm:$false | Out-Null
        Send-Log -Message "Started Workload Domain host: $VMHost"
        $FQDN = $WLDHosts[$VMHost]
        #Wait-ForHost -HostFQDN $FQDN -Username $HostUsername -Password $HostPassword
    } catch {
        Send-Log -Message $_.Exception.InnerException -Color red
    }
}
Disconnect-VIServer -Server $RootVCSA -Confirm:$false

# Step 9: Exit Maintenance Mode for Workload Domain Hosts
Send-Log -Message "Step 9: Exiting Maintenance Mode for Workload Domain Hosts"
foreach ($HostShortName in $WLDHosts.Keys) {
    $HostFQDN = $WLDHosts[$HostShortName]
    Wait-ForHost -HostFQDN $HostFQDN -Username $HostUsername -Password $HostPassword
    try {
        $Server = Connect-VIServer -Server $HostFQDN -User $HostUsername -Password $HostPassword -NotDefault | Out-Null
        $HostObject = Get-VMHost -Server $HostFQDN | Where-Object { $_.Name -eq $HostFQDN }

        if ($HostObject) {
            Set-VMHost -VMHost $HostObject -State Connected -Confirm:$false | Out-Null
            Send-Log -Message "Disabled Maintenance Mode on: $HostFQDN"
        } else {
            Send-Log -Message "Could not find VMHost object for: $HostShortName" -color "red"
        }

        Disconnect-VIServer -Server $HostFQDN -Confirm:$false
    } catch {
        Send-Log -Message $_.Exception.InnerException -Color red
    }
}

# Step 10: Power on Workload Edge Node by role tag
Send-Log -Message "Step 10: Waiting for Management Domain VCSA to be fully operational"
Wait-ForVCSAReady -vCenter $WLDVC -Username $VCUsername -Password $VCPassword

Send-Log -Message "Step 10: Connecting to Workload Domain VCSA and powering on Edge Node by role tag"
Connect-VIServer -Server $WLDVC -User $VCUsername -Password $VCPassword | Out-Null

Send-Log -Message "Searching for Edge VMs"
$EdgeVMs = Get-VM | Where-Object {
    $_.PowerState -eq "PoweredOff" -and
    (Get-TagAssignment -Entity $_ | Where-Object { $_.Tag.Name -eq "Edge" })
} 

foreach ($VM in $EdgeVMs) {
    try {
        Start-VM -VM $VM -Confirm:$false | Out-Null
        Send-Log -Message "Started Edge Node VM: $($VM.Name)"
    } catch {
        Send-Log -Message "Failed to start Edge Node VM: $($VM.Name)" -color "red"
    }
}
Disconnect-VIServer -Server $WLDVC -Confirm:$false

Send-Log -Message "Lab power-on process completed successfully!"
Write-Output "Lab powered up!"