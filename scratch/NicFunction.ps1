Function Set-VMNetworkConfiguration {
    #source:http://www.ravichaganti.com/blog/?p=2766 with some changes
    #example use: Get-VMNetworkAdapter -VMName Demo-VM-1 -Name iSCSINet | Set-VMNetworkConfiguration -IPAddress 192.168.100.1 -Subnet 255.255.0.0 -DNSServer 192.168.100.101 -DefaultGateway 192.168.100.1
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true,
            Position = 1,
            ParameterSetName = 'DHCP',
            ValueFromPipeline = $true)]
        [Parameter(Mandatory = $true,
            Position = 0,
            ParameterSetName = 'Static',
            ValueFromPipeline = $true)]
        [Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,

        [Parameter(Mandatory = $false,
            Position = 1,
            ParameterSetName = 'Static')]
        [String[]]$IPAddress = @(),

        [Parameter(Mandatory = $false,
            Position = 2,
            ParameterSetName = 'Static')]
        [String[]]$Subnet = @(),

        [Parameter(Mandatory = $false,
            Position = 3,
            ParameterSetName = 'Static')]
        [String[]]$DefaultGateway = @(),

        [Parameter(Mandatory = $false,
            Position = 4,
            ParameterSetName = 'Static')]
        [String[]]$DNSServer = @(),

        [Parameter(Mandatory = $false,
            Position = 0,
            ParameterSetName = 'DHCP')]
        [Switch]$Dhcp
    )

    $VM = Get-CimInstance -Namespace "root\virtualization\v2" -ClassName "Msvm_ComputerSystem" | Where-Object ElementName -eq $NetworkAdapter.VMName
    $VMSettings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName "Msvm_VirtualSystemSettingData" | Where-Object VirtualSystemType -EQ "Microsoft:Hyper-V:System:Realized"
    $VMNetAdapters = Get-CimAssociatedInstance -InputObject $VMSettings -ResultClassName "Msvm_SyntheticEthernetPortSettingData"

    $networkAdapterConfiguration = @()
    foreach ($netAdapter in $VMNetAdapters) {
        if ($netAdapter.ElementName -eq $NetworkAdapter.Name) {
            $networkAdapterConfiguration = Get-CimAssociatedInstance -InputObject $netAdapter -ResultClassName "Msvm_GuestNetworkAdapterConfiguration"
            break
        }
    }

    $networkAdapterConfiguration.PSBase.CimInstanceProperties["IPAddresses"].Value = $IPAddress
    $networkAdapterConfiguration.PSBase.CimInstanceProperties["Subnets"].Value = $Subnet
    $networkAdapterConfiguration.PSBase.CimInstanceProperties["DefaultGateways"].Value = $DefaultGateway
    $networkAdapterConfiguration.PSBase.CimInstanceProperties["DNSServers"].Value = $DNSServer
    $networkAdapterConfiguration.PSBase.CimInstanceProperties["ProtocolIFType"].Value = 4096

    if ($dhcp) {
        $networkAdapterConfiguration.PSBase.CimInstanceProperties["DHCPEnabled"].Value = $true
    }
    else {
        $networkAdapterConfiguration.PSBase.CimInstanceProperties["DHCPEnabled"].Value = $false
    }

    $cimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
    $serializedInstance = $cimSerializer.Serialize($networkAdapterConfiguration, [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)
    $serializedInstanceString = [System.Text.Encoding]::Unicode.GetString($serializedInstance)

    $service = Get-CimInstance -ClassName "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
    $setIp = Invoke-CimMethod -InputObject $service -MethodName "SetGuestNetworkAdapterConfiguration" -Arguments @{
        ComputerSystem       = $VM
        NetworkConfiguration = @($serializedInstanceString)
    }
    if ($setIp.ReturnValue -eq 0) {
        # completed
        WriteInfo "Success"
    }
    else {
        # unexpected response
        $setIp
    }
}