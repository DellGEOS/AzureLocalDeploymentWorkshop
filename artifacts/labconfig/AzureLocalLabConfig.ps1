# Define core lab characteristics
$LabConfig = @{ DomainAdminName = '<<DomainAdminName>>'; AdminPassword = '<<AdminPassword>>'; DCEdition = '4'; ServerISOFolder = '<<WSServerIsoPath>>'; `
                ServerMSUsFolder = '<<MsuFolder>>'; DomainNetbiosName = '<<DomainNetBios>>'; DefaultOUName = "AzLWorkshop"; DomainName = '<<DomainName>>'; `
                Internet = $true ; TelemetryLevel = '<<TelemetryLevel>>'; AutoStartAfterDeploy = $false; VMs = @(); AutoClosePSWindows = $true; `
                DHCPscope="192.168.1.0"; DHCPscopeState = "Active"; AutoCleanUp = $true; SwitchName = "<<vSwitchName>>"; Prefix = "<<VmPrefix>>-"; AllowedVLANs="<<allowedVlans>>"; `
                CustomDnsForwarders=@("<<customDNSForwarders>>"); AdditionalNetworksConfig=@()
}

# Deploy Azure Local machines
1..<<azureLocalMachines>> | ForEach-Object { 
        $VMNames = "AzL" ; $LABConfig.VMs += @{ VMName = "$VMNames$_" ; Configuration = 'S2D' ; `
                        ParentVHD = 'AzL_G2.vhdx' ; HDDNumber = 12; HDDSize = 50GB ; `
                        MemoryStartupBytes = <<azureLocalMachineMemory>>GB; MGMTNICs = 2 ; vTPM = $true ; NestedVirt = $true ; VMProcessorCount = "Max"; Unattend="NoDjoin"; DisableTimeIC = $true
        } 
}

# Deploy Windows Admin Center Management Server
<<installWAC>>

#Management machine
#$LabConfig.VMs += @{ VMName = 'MGMT' ; ParentVHD = 'WinSvr_G2.vhdx'; MGMTNICs=1 ; AddToolsVHD=$True }