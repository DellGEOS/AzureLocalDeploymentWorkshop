configuration AzLWorkshop
{
    param 
    (
        [System.Management.Automation.PSCredential]$Admincreds,
        [Parameter(Mandatory)]
        [ValidateSet("Single Machine", "2-Machine Non-Converged", "2-Machine Fully-Converged", "2-Machine Switchless Dual-Link", "3-Machine Non-Converged", "3-Machine Fully-Converged",
            "3-Machine Switchless Single-Link", "3-Machine Switchless Dual-Link", "4-Machine Non-Converged", "4-Machine Fully-Converged", "4-Machine Switchless Dual-Link")]
        [String]$azureLocalArchitecture,
        [Parameter(Mandatory)]
        [ValidateSet("16", "24", "32", "48")]
        [Int]$azureLocalMachineMemory,
        [Parameter(Mandatory)]
        [ValidateSet("Full", "Basic", "None")]
        [String]$telemetryLevel,
        [ValidateSet("Yes", "No")]
        [String]$updateImages,
        [Parameter(Mandatory)]
        [ValidateSet("Yes", "No")]
        [String]$installWAC,
        [Parameter(Mandatory)]
        [String]$domainName,
        [String]$customRdpPort,
        [String]$workshopPath,
        [String]$WindowsServerIsoPath,
        [String]$AzureLocalIsoPath,
        [String]$customDNSForwarders,
        [String]$deploymentPrefix
    )
    
    Import-DscResource -ModuleName 'ComputerManagementDsc' -ModuleVersion 10.0.0
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'hyperVDsc' -ModuleVersion 4.0.0
    Import-DscResource -ModuleName 'StorageDSC' -ModuleVersion 6.0.1
    Import-DscResource -ModuleName 'NetworkingDSC' -ModuleVersion 9.0.0
    Import-DscResource -ModuleName 'MSCatalogLTS' -ModuleVersion 1.0.6
    Import-DscResource -ModuleName 'Hyper-ConvertImage' -ModuleVersion 10.2

    Node localhost
    {
        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }

        # Clear any existing logging
        try { Stop-Transcript | Out-Null } catch { }

        # Set core execution parameters
        $ProgressPreference = 'SilentlyContinue'
        $VerbosePreference = 'Continue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        try {

            # Set up logging for the DSC configuration
            File "TopLevelLogFolder" {
                Type            = 'Directory'
                DestinationPath = "C:\AzLWorkshopLogs"
                Ensure          = 'Present'
            }

            File "DeploymentLogFolder" {
                Type            = 'Directory'
                DestinationPath = "C:\AzLWorkshopLogs\$deploymentPrefix"
                Ensure          = 'Present'
                DependsOn       = "[File]TopLevelLogFolder"
            }

            #######################################################################
            ## Setup Logging for the DSC Configuration
            #######################################################################

            $startTime = $(Get-Date).ToString("MMddyy-HHmmss")
            $fullLogPath = "C:\AzLWorkshopLogs\$deploymentPrefix\AzLWorkshopLog_$startTime.txt"
            Start-Transcript -Path "$fullLogPath" -Append -IncludeInvocationHeader
            Write-Verbose "Log folder full path is $fullLogPath" -Verbose
            Write-Verbose "Starting AzLWorkshop configuration at $startTime" -Verbose

            #######################################################################
            ## Setup external endpoints for downloads
            #######################################################################

            [String]$mslabUri = "https://aka.ms/mslab/download"
            [String]$wsIsoUri = "https://go.microsoft.com/fwlink/p/?LinkID=2195280" # Windows Server 2022
            # [String]$wsIsoUri = "https://go.microsoft.com/fwlink/p/?LinkID=2293312" # Windows Server 2025
            [String]$azureLocalIsoUri = "https://aka.ms/HCIReleaseImage/2504"
            [String]$labConfigUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/labconfig/AzureLocalLabConfig.ps1"
            [String]$rdpConfigUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/rdp/rdpbase.rdp"
        
            #######################################################################
            ## Confirm RDP Port
            #######################################################################

            if (!$customRdpPort) {
                $customRdpPort = 3389
                Write-Verbose "No custom RDP port specified, using default of 3389" -Verbose
            }
            else {
                Write-Verbose "Custom RDP port is set to $customRdpPort" -Verbose
            }

            #######################################################################
            ## Calculate the number of Azure Local machines based on architecture
            #######################################################################

            $azureLocalMachines = if ($azureLocalArchitecture -eq "Single Machine") { 1 } else { [INT]$azureLocalArchitecture.Substring(0, 1) }
            Write-Verbose "Number of Azure Local machines is $azureLocalMachines" -Verbose

            # Calculate Host Memory Sizing to account for oversizing
            [INT]$totalFreePhysicalMemory = Get-CimInstance Win32_OperatingSystem -Verbose:$false | ForEach-Object { [math]::round($_.FreePhysicalMemory / 1MB) }
            [INT]$totalInfraMemoryRequired = "4"
            [INT]$memoryAvailable = [INT]$totalFreePhysicalMemory - [INT]$totalInfraMemoryRequired
            [INT]$azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)

            Write-Verbose "Total free physical memory is $($totalFreePhysicalMemory)MB" -Verbose
            Write-Verbose "Total Infra memory required is $($totalInfraMemoryRequired)GB" -Verbose
            Write-Verbose "Total memory available on the system, after subtracting Infra memory is $($memoryAvailable)GB" -Verbose
            Write-Verbose "Total memory required for Azure Local machines is $($azureLocalMachineMemoryRequired)GB" -Verbose
            Write-Verbose "Evaluating if the desired architecture and machine sizes can be accommodated" -Verbose

            if ($azureLocalMachineMemoryRequired -ge $memoryAvailable) {
                $memoryOptions = 48, 32, 24, 16
                $x = $memoryOptions.IndexOf($azureLocalMachineMemory) + 1
                while ($x -ne -1 -and $azureLocalMachineMemoryRequired -ge $memoryAvailable -and $x -lt $memoryOptions.Count) {
                    Write-Verbose "Memory required: $($azureLocalMachineMemoryRequired)GB, memory available: $($memoryAvailable)GB, New memory option: $($memoryOptions[$x])GB" -Verbose
                    Write-Verbose "Testing memory at $($memoryOptions[$x])GB per AzL VM and trying again" -Verbose
                    $azureLocalMachineMemory = $memoryOptions[$x]
                    $azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
                    $x++
                }
                # If the available memory is still less than the required memory, reduce the $azureLocalMachines count by 1 in a loop
                while ($azureLocalMachineMemoryRequired -ge $memoryAvailable -and $azureLocalMachines -gt 1) {
                    Write-Verbose "Memory required: $($azureLocalMachineMemoryRequired)GB, memory available: $($memoryAvailable)GB, reducing AzL VM count by 1" -Verbose
                    $azureLocalMachines--
                    $azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
                    $nodesReduced = $true
                }
                if ($nodesReduced) {
                    # Need to reset the $azureLocalArchitecture to reflect a new number of $azureLocalMachines
                    # If $azureLocalArchitecture is not "Single Machine", take the existing $azureLocalArchitecture and replace the first character with the new $azureLocalMachines count
                    Write-Verbose "Machine count has been reduced. New number of Azure Local machines is $azureLocalMachines" -Verbose
                    if ($azureLocalArchitecture -ne "Single Machine") {
                        # Need to ensure you can transition to a valid architecture
                        # If the new $azureLocalMachines count is 1, the architecture should be "Single Machine"
                        if ($azureLocalMachines -eq 1) {
                            $azureLocalArchitecture = "Single Machine"
                            Write-Verbose "Switching architecture to $azureLocalArchitecture to fit memory requirements" -Verbose
                        }
                        # if the $azureLocalArchitecture includes "Switchless Dual-Link", the new architecture should also include "Dual-Link"
                        elseif ($azureLocalArchitecture -like "*Dual-Link*") {
                            $azureLocalArchitecture = "$($azureLocalMachines)-Machine Switchless Dual-Link"
                            Write-Verbose "Switching architecture to $azureLocalArchitecture to fit memory requirements" -Verbose
                        }
                        # if the $azureLocalArchitecture includes "Switchless Single-Link", the new architecture should change to "Dual-Link"
                        elseif ($azureLocalArchitecture -like "*Single-Link*") {
                            $azureLocalArchitecture = "$($azureLocalMachines)-Machine Switchless Dual-Link"
                            Write-Verbose "Switching architecture to $azureLocalArchitecture to fit memory requirements" -Verbose
                        }
                        else {
                            # If the $azureLocalArchitecture includes "Fully-Converged" or "Non-Converged", the new architecture should just reduced the number of machines
                            $azureLocalArchitecture = "$($azureLocalMachines)-Machine $($azureLocalArchitecture.Split(" ", 2)[1])"
                            Write-Verbose "Switching architecture to $azureLocalArchitecture to fit memory requirements" -Verbose
                        }
                    }
                }
            }
            else {
                Write-Verbose "Memory required: $($azureLocalMachineMemoryRequired)GB, memory available: $($memoryAvailable)GB, no changes needed" -Verbose
            }

            #######################################################################
            ## Define variables for the workshop
            #######################################################################

            $vmPrefix = $deploymentPrefix
            $vSwitchName = if ($azureLocalArchitecture -like "*Fully-Converged*") { "Mgmt_Compute_Stor" } else { "Mgmt_Compute" } # Set based on architecture
            $allowedVlans = if ($azureLocalArchitecture -like "*Fully-Converged*") { "1-10,711-719" } else { "1-10" } # Set based on architecture

            # Set the workshop path based on the current machine - If this is running in Azure, set the workshop path to V:\AzLWorkshop
            if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
                $targetDrive = "V"
                $workshopTopLevelPath = "$targetDrive" + ":\AzLWorkshop"
                $workshopPath = "$workshopTopLevelPath" + "\$($deploymentPrefix)"
            }
            else {
                $workshopTopLevelPath = "$workshopPath" + "\AzLWorkshop"
                $workshopPath = "$workshopTopLevelPath" + "\$($deploymentPrefix)"
            }

            # Set the paths for the workshop
            $mslabLocalPath = "$workshopPath\mslab.zip"
            $labConfigPath = "$workshopPath\LabConfig.ps1"
            $createParentDisksPath = "$workshopPath\2_CreateParentDisks.ps1"
            $parentDiskPath = "$workshopPath\ParentDisks"
            $updatePath = "$parentDiskPath\Updates"
            $cuPath = "$updatePath\CU"
            $ssuPath = "$updatePath\SSU"
            $isoPath = "$workshopPath\ISO"
            $flagsPath = "$workshopPath\Flags"
            $azLocalVhdPath = "$parentDiskPath\AzL_G2.vhdx"

            # Set the domain NetBIOS name and core credentials
            $domainNetBios = $domainName.Split('.')[0]
            $domainAdminName = $Admincreds.UserName
            $msLabUsername = "$domainNetBios\$($Admincreds.UserName)"
            $msLabPassword = $Admincreds.GetNetworkCredential().Password

            # Set the ISO paths based on if this is an Azure VM. If not, use the supplied paths
            # If this is on-prem, user should have supplied a folder/path they wish to install into
            # Users can also supply a pre-downloaded ISO for both WS and Azure Local

            if (!((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77")) {
                if (!$AzureLocalIsoPath) {
                    $azLocalIsoPath = "$isoPath\AzureLocal"
                    $azLocalISOLocalPath = "$azLocalIsoPath\AzureLocal.iso"
                }
                else {
                    $azLocalISOLocalPath = $AzureLocalIsoPath
                    $azLocalIsoPath = (Get-Item $azLocalISOLocalPath).DirectoryName
                }
                if (!$WindowsServerIsoPath) {
                    $wsIsoPath = "$isoPath\WS"
                    $wsISOLocalPath = "$wsIsoPath\WinSvr.iso"
                }
                else {
                    $wsISOLocalPath = $WindowsServerIsoPath
                    $wsIsoPath = (Get-Item $wsISOLocalPath).DirectoryName
                }
            }
            else {
                $wsIsoPath = "$isoPath\WS"
                $wsISOLocalPath = "$wsIsoPath\WinSvr.iso"
                $azLocalIsoPath = "$isoPath\AzureLocal"
                $azLocalISOLocalPath = "$azLocalIsoPath\AzureLocal.iso"
            }

            # Output all the variables to the console for debugging
            Write-Verbose "All VMs will start with the prefix: $vmPrefix" -Verbose
            Write-Verbose "The vSwitch name created on your host will be: $vSwitchName" -Verbose
            Write-Verbose "The allowed VLANs for the vSwitch will be: $allowedVlans" -Verbose
            Write-Verbose "Workshop path for storing all related files is: $workshopPath" -Verbose
            Write-Verbose "MSLab local path is $mslabLocalPath" -Verbose
            Write-Verbose "LabConfig path is $labConfigPath" -Verbose
            Write-Verbose "CreateParentDisks path is $createParentDisksPath" -Verbose
            Write-Verbose "Parent disks path is $parentDiskPath" -Verbose
            Write-Verbose "Update path is $updatePath" -Verbose
            Write-Verbose "CU path is $cuPath" -Verbose
            Write-Verbose "SSU path is $ssuPath" -Verbose
            Write-Verbose "ISO path is $isoPath" -Verbose
            Write-Verbose "Flags path is $flagsPath" -Verbose
            Write-Verbose "Azure Local VHD path is $azLocalVhdPath" -Verbose
            Write-Verbose "Domain name is $domainName" -Verbose
            Write-Verbose "Domain NetBIOS name is $domainNetBios" -Verbose
            Write-Verbose "Domain admin name is $domainAdminName" -Verbose
            Write-Verbose "Azure Local ISO path is $azLocalISOLocalPath" -Verbose
            Write-Verbose "Windows Server ISO path is $wsISOLocalPath" -Verbose

            #######################################################################
            ## Configure Storage Spaces Direct (Azure only) and workshop folder
            #######################################################################

            # If this is in Azure, configure Storage Spaces Direct and then create the required folders
            if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
                Write-Verbose "Configuring Storage Spaces Direct" -Verbose
                Script StoragePool {
                    SetScript  = {
                        Write-Verbose "Creating Storage Pool" -Verbose
                        New-StoragePool -FriendlyName AzLWorkshopPool -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $true)
                    }
                    TestScript = {
                        Write-Verbose "Checking if Storage Pool exists" -Verbose
                    (Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName AzLWorkshopPool).OperationalStatus -eq 'OK'
                    }
                    GetScript  = {
                        @{Ensure = if ((Get-StoragePool -FriendlyName AzLWorkshopPool).OperationalStatus -eq 'OK') { 'Present' } Else { 'Absent' } }
                    }
                }
                Script VirtualDisk {
                    SetScript  = {
                        Write-Verbose "Creating Virtual Disk" -Verbose
                        $disks = Get-StoragePool -FriendlyName AzLWorkshopPool -IsPrimordial $False | Get-PhysicalDisk
                        $diskNum = $disks.Count
                        New-VirtualDisk -StoragePoolFriendlyName AzLWorkshopPool -FriendlyName AzLWorkshopDisk -ResiliencySettingName Simple -NumberOfColumns $diskNum -UseMaximumSize
                    }
                    TestScript = {
                        Write-Verbose "Checking if Virtual Disk exists" -Verbose                    
                    (Get-VirtualDisk -ErrorAction SilentlyContinue -FriendlyName AzLWorkshopDisk).OperationalStatus -eq 'OK'
                    }
                    GetScript  = {
                        @{Ensure = if ((Get-VirtualDisk -FriendlyName AzLWorkshopDisk).OperationalStatus -eq 'OK') { 'Present' } Else { 'Absent' } }
                    }
                    DependsOn  = "[Script]StoragePool"
                }
                Script FormatDisk {
                    SetScript  = {
                        Write-Verbose "Formatting Virtual Disk" -Verbose
                        $vDisk = Get-VirtualDisk -FriendlyName AzLWorkshopDisk
                        if ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'raw') {
                            $vDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter $Using:targetDrive -UseMaximumSize | Format-Volume -NewFileSystemLabel AzLWorkshop -AllocationUnitSize 64KB -FileSystem NTFS
                        }
                        elseif ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'GPT') {
                            $vDisk | Get-Disk | New-Partition -DriveLetter $Using:targetDrive -UseMaximumSize | Format-Volume -NewFileSystemLabel AzLWorkshop -AllocationUnitSize 64KB -FileSystem NTFS
                        }
                    }
                    TestScript = {
                        Write-Verbose "Checking if Virtual Disk is formatted" -Verbose
                    (Get-Volume -ErrorAction SilentlyContinue -FileSystemLabel AzLWorkshop).FileSystem -eq 'NTFS'
                    }
                    GetScript  = {
                        @{Ensure = if ((Get-Volume -FileSystemLabel AzLWorkshop).FileSystem -eq 'NTFS') { 'Present' } Else { 'Absent' } }
                    }
                    DependsOn  = "[Script]VirtualDisk"
                }

                Write-Verbose "Creating Workshop folder and subdirectory" -Verbose
                File "WorkshopTopLevelFolder" {
                    Type            = 'Directory'
                    DestinationPath = $workshopTopLevelPath
                    DependsOn       = "[Script]FormatDisk"
                }
                File "WorkshopFolder" {
                    Type            = 'Directory'
                    DestinationPath = $workshopPath
                    DependsOn       = "[File]WorkshopTopLevelFolder"
                }
            }
            else {
                # Running on-prem, outside of Azure
                Write-Verbose "Creating Workshop folder and subdirectory" -Verbose
                File "WorkshopTopLevelFolder" {
                    Type            = 'Directory'
                    DestinationPath = $workshopTopLevelPath
                }
                File "WorkshopFolder" {
                    Type            = 'Directory'
                    DestinationPath = $workshopPath
                    DependsOn       = "[File]WorkshopTopLevelFolder"
                }
            }

            #######################################################################
            ## Create the required folders for the workshop
            #######################################################################

            Write-Verbose "Creating the top-level ISO folder" -Verbose
            File "ISOpath" {
                DestinationPath = $isoPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]WorkshopFolder"
            }

            Write-Verbose "Creating the Flags folder" -Verbose
            File "flagsPath" {
                DestinationPath = $flagsPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]WorkshopFolder"
            }

            Write-Verbose "Creating the Windows Server ISO folder" -Verbose
            File "WSISOpath" {
                DestinationPath = $wsIsoPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]ISOpath"
            }

            Write-Verbose "Creating the Azure Local ISO folder" -Verbose
            File "azLocalIsoPath" {
                DestinationPath = $azLocalIsoPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]ISOpath"
            }

            Write-Verbose "Creating the ParentDisks folder to store VHDx files" -Verbose
            File "ParentDisks" {
                DestinationPath = $parentDiskPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]WorkshopFolder"
            }

            Write-Verbose "Creating the Updates folder to store updates" -Verbose
            File "Updates" {
                DestinationPath = $updatePath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]ParentDisks"
            }

            Write-Verbose "Creating the CU folder to store cumulative updates" -Verbose
            File "CU" {
                DestinationPath = $cuPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]Updates"
            }

            Write-Verbose "Creating the SSU folder to store servicing stack updates" -Verbose
            File "SSU" {
                DestinationPath = $ssuPath
                Type            = 'Directory'
                Force           = $true
                DependsOn       = "[File]Updates"
            }

            #######################################################################
            ## Download, extract and edit required files
            #######################################################################

            Write-Verbose "Downloading MSLab files" -Verbose
            Script "Download MSLab" {
                GetScript  = {
                    $result = Test-Path -Path "$Using:mslabLocalPath"
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri "$Using:mslabUri" -OutFile "$Using:mslabLocalPath" -UseBasicParsing
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[File]WorkshopFolder"
            }

            Write-Verbose "Extracting MSLab files to the workshop folder" -Verbose
            Script "Extract MSLab" {
                GetScript  = {
                    $result = !(Test-Path -Path "$Using:mslabLocalPath")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Expand-Archive -Path "$Using:mslabLocalPath" -DestinationPath "$Using:workshopPath" -Force
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Download MSLab"
            }

            Write-Verbose "Editing CreateParentDisks script to replace the default VHD names with the custom names to allow flexibility in deployment" -Verbose
            Script "Edit CreateParentDisks" {
                GetScript  = {
                    $result = !(Test-Path -Path "$Using:CreateParentDisksPath")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $createParentDisksFile = Get-Content -Path "$Using:CreateParentDisksPath"
                    $createParentDisksFile = $createParentDisksFile.Replace('VHDName="Win2022', 'VHDName="WinSvr')
                    $createParentDisksFile = $createParentDisksFile.Replace('VHDName="Win2025', 'VHDName="WinSvr')
                    Out-File -FilePath "$Using:CreateParentDisksPath" -InputObject $createParentDisksFile -Force
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Extract MSLab"
            }

            Write-verbose "Downloading custom LabConfig file from AzLWorkshop GitHub" -Verbose
            Script "Replace LabConfig" {
                GetScript  = {
                    Write-Verbose "Checking if LabConfig file exists and if it's an old version" -Verbose
                    $result = ((Get-Item $Using:labConfigPath).LastWriteTime -ge (Get-Date).ToUniversalTime() -and (Get-Item $Using:labConfigPath).Length -gt 10240)
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ProgressPreference = 'SilentlyContinue'
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $client = New-Object System.Net.WebClient
                    $client.DownloadFile("$Using:labConfigUri", "$Using:labConfigPath")
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Extract MSLab"
            }

            Write-Verbose "Editing LabConfig file to replace the default values with the custom values for this deployment" -Verbose
            Script "Edit LabConfig" {
                GetScript  = {
                    $result = !(Test-Path -Path "$Using:labConfigPath")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $labConfigFile = Get-Content -Path "$Using:labConfigPath"
                    $labConfigFile = $labConfigFile.Replace("<<DomainAdminName>>", $Using:domainAdminName)
                    $labConfigFile = $labConfigFile.Replace("<<AdminPassword>>", $Using:msLabPassword)
                    $labConfigFile = $labConfigFile.Replace("<<DomainNetBios>>", $Using:domainNetBios)
                    $labConfigFile = $labConfigFile.Replace("<<DomainName>>", $Using:domainName)
                    $labConfigFile = $labConfigFile.Replace("<<azureLocalMachines>>", $Using:azureLocalMachines)
                    $labConfigFile = $labConfigFile.Replace("<<azureLocalMachineMemory>>", $Using:azureLocalMachineMemory)
                    $labConfigFile = $labConfigFile.Replace("<<WSServerIsoPath>>", $Using:wsISOLocalPath)
                    $labConfigFile = $labConfigFile.Replace("<<MsuFolder>>", $Using:updatePath)
                    $labConfigFile = $labConfigFile.Replace("<<VmPrefix>>", $Using:vmPrefix)
                    $labConfigFile = $labConfigFile.Replace("<<TelemetryLevel>>", $Using:telemetryLevel)
                    $labConfigFile = $labConfigFile.Replace("<<customDNSForwarders>>", $Using:customDNSForwarders)
                    $labConfigFile = $labConfigFile.Replace("<<vSwitchName>>", $Using:vSwitchName)
                    $labConfigFile = $labConfigFile.Replace("<<allowedVlans>>", $Using:allowedVlans)

                    # customize the lab config file based on WAC being installed or not
                    if ($Using:installWAC -eq "Yes") {
                        $labConfigFile = $labConfigFile.Replace("<<installWAC>>", '$LabConfig.VMs += @{ VMName = ''WAC'' ; ParentVHD = ''WinSvrCore_G2.vhdx'' ; MGMTNICs = 1 }')
                    }
                    else {
                        $labConfigFile = $labConfigFile.Replace("<<installWAC>>", '')
                    }
                    Out-File -FilePath "$Using:labConfigPath" -InputObject $labConfigFile -Force
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Replace LabConfig"
            }

            Script "Download Windows Server ISO" {
                GetScript  = {
                    Write-Verbose "Checking if Windows Server ISO file exists" -Verbose
                    $result = Test-Path -Path $Using:wsISOLocalPath
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Downloading Windows Server ISO file" -Verbose
                    $ProgressPreference = 'SilentlyContinue'
                    $client = New-Object System.Net.WebClient
                    $client.DownloadFile("$Using:wsIsoUri", "$Using:wsISOLocalPath  ")
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[File]WSISOpath"
            }

            Script "Download Azure Local ISO" {
                GetScript  = {
                    Write-Verbose "Checking if Azure Local ISO file exists" -Verbose
                    $result = Test-Path -Path $Using:azLocalISOLocalPath
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Downloading Azure Local ISO file" -Verbose
                    $ProgressPreference = 'SilentlyContinue'
                    $client = New-Object System.Net.WebClient
                    $client.DownloadFile("$Using:azureLocalIsoUri", "$Using:azLocalISOLocalPath")    
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[File]azLocalIsoPath"
            }

            # If the user has chosen to update their images, download the latest Cumulative updates
            Script "Download CU" {
                GetScript  = {
                    if ($Using:updateImages -eq "Yes") {
                        Write-Verbose "Checking if CU file exists" -Verbose
                        $result = ((Test-Path -Path "$Using:cuPath\*" -Include "*.msu") -or (Test-Path -Path "$Using:cuPath\*" -Include "NoUpdateDownloaded.txt"))
                    }
                    else {
                        Write-Verbose "User selected to not update images with latest updates." -Verbose
                        $result = (Test-Path -Path "$Using:cuPath\*" -Include "NoUpdateDownloaded.txt")
                    }
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    if ($Using:updateImages -eq "Yes") {
                        Write-Verbose "Downloading latest CU" -Verbose
                        $ProgressPreference = 'SilentlyContinue'
                        $cuSearchString = "Cumulative Update for Microsoft server operating system*version 23H2 for x64-based Systems"
                        $cuID = "Microsoft Server operating system-23H2"
                        Write-Verbose "Looking for updates that match: $cuSearchString and $cuID" -Verbose
                        $cuUpdate = Get-MSCatalogUpdate -Search $cuSearchString -ErrorAction Stop | Where-Object Products -eq $cuID | Where-Object Title -like "*$($cuSearchString)*" | Select-Object -First 1
                        if ($cuUpdate) {
                            Write-Verbose "Found the latest update: $($cuUpdate.Title)" -Verbose
                            Write-Verbose "Downloading..." -Verbose
                            $cuUpdate | Save-MSCatalogUpdate -Destination $Using:cuPath -AcceptMultiFileUpdates
                        }
                        else {
                            Write-Verbose "No updates found, moving on..." -Verbose
                            $NoCuFlag = "$Using:cuPath\NoUpdateDownloaded.txt"
                            New-Item $NoCuFlag -ItemType file -Force
                        }
                    }
                    else {
                        Write-Verbose "User selected to not update images with latest updates." -Verbose
                        $NoCuFlag = "$Using:cuPath\NoUpdateDownloaded.txt"
                        New-Item $NoCuFlag -ItemType file -Force
                    }
                }
                TestScript = {    
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[File]CU"
            }

            Script "Download SSU" {
                GetScript  = {
                    if ($Using:updateImages -eq "Yes") {
                        Write-Verbose "Checking if SSU file exists" -Verbose
                        $result = ((Test-Path -Path "$Using:ssuPath\*" -Include "*.msu") -or (Test-Path -Path "$Using:ssuPath\*" -Include "NoUpdateDownloaded.txt"))
                    }
                    else {
                        Write-Verbose "User selected to not update images with latest updates." -Verbose
                        $result = (Test-Path -Path "$Using:ssuPath\*" -Include "NoUpdateDownloaded.txt")
                    }
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ProgressPreference = 'SilentlyContinue'
                    if ($Using:updateImages -eq "Yes") {
                        Write-Verbose "Downloading latest SSU" -Verbose
                        $ssuSearchString = "Servicing Stack Update for Microsoft server operating system*version 23H2 for x64-based Systems"
                        $ssuID = "Microsoft Server operating system-23H2"
                        Write-Verbose "Looking for updates that match: $ssuSearchString and $ssuID" -Verbose
                        $ssuUpdate = Get-MSCatalogUpdate -Search $ssuSearchString -ErrorAction Stop | Where-Object Products -eq $ssuID | Select-Object -First 1
                        if ($ssuUpdate) {
                            Write-Verbose "Found the latest update: $($ssuUpdate.Title)" -Verbose
                            Write-Verbose "Downloading..." -Verbose
                            $ssuUpdate | Save-MSCatalogUpdate -Destination $Using:ssuPath
                        }
                        else {
                            Write-Verbose "No updates found" -Verbose
                            $NoSsuFlag = "$Using:ssuPath\NoUpdateDownloaded.txt"
                            New-Item $NoSsuFlag -ItemType file -Force
                        }
                    }
                    else {
                        Write-Verbose "User selected to not update images with latest updates." -Verbose
                        $NoSsuFlag = "$Using:ssuPath\NoUpdateDownloaded.txt"
                        New-Item $NoSsuFlag -ItemType file -Force
                    }
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[File]SSU"
            }

            #######################################################################
            ## Update Windows Defender exclusions and registry keys
            #######################################################################        

            # If this is a Windows Server OS, update the Windows Defender exclusions to include the workshop path
            if ((Get-WmiObject -Class Win32_OperatingSystem).ProductType -eq "3") {

                Script defenderExclusions {
                    GetScript  = {
                        Write-Verbose "Checking if Windows Defender exclusions are set" -Verbose
                        $exclusionPath = $Using:workshopPath
                        @{Ensure = if ((Get-MpPreference).ExclusionPath -contains "$exclusionPath") { 'Present' } Else { 'Absent' } }
                    }
                    SetScript  = {
                        Write-Verbose "Adding Windows Defender exclusions" -Verbose
                        $exclusionPath = $Using:workshopPath
                        Add-MpPreference -ExclusionPath "$exclusionPath"               
                    }
                    TestScript = {
                        $exclusionPath = $Using:workshopPath
                    (Get-MpPreference).ExclusionPath -contains "$exclusionPath"
                    }
                    DependsOn  = "[File]WorkshopFolder"
                }

                # Updated various registry keys and firewall to optimize experience
                Write-Verbose "Disabling Internet Explorer ESC for Admin with registry key" -Verbose
                Registry "Disable Internet Explorer ESC for Admin" {
                    Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
                    Ensure    = 'Present'
                    ValueName = "IsInstalled"
                    ValueData = "0"
                    ValueType = "Dword"
                }
    
                Write-Verbose "Disabling Internet Explorer ESC for User with registry key" -Verbose
                Registry "Disable Internet Explorer ESC for User" {
                    Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
                    Ensure    = 'Present'
                    ValueName = "IsInstalled"
                    ValueData = "0"
                    ValueType = "Dword"
                }
            
                Write-Verbose "Disabling Windows Server Manager WAC prompt with registry key" -Verbose
                Registry "Disable Server Manager WAC Prompt" {
                    Key       = "HKLM:\SOFTWARE\Microsoft\ServerManager"
                    Ensure    = 'Present'
                    ValueName = "DoNotPopWACConsoleAtSMLaunch"
                    ValueData = "1"
                    ValueType = "Dword"
                }
    
                Write-Verbose "Disabling Network Profile prompt with registry key" -Verbose
                Registry "Disable Network Profile Prompt" {
                    Key       = 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff'
                    Ensure    = 'Present'
                    ValueName = ''
                }

                if ($customRdpPort -ne "3389") {
                    Write-Verbose "Changing RDP port to $customRdpPort with registry key" -Verbose
                    Registry "Set Custom RDP Port" {
                        Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
                        ValueName = "PortNumber"
                        ValueData = "$customRdpPort"
                        ValueType = 'Dword'
                    }
            
                    Write-Verbose "Adding custom RDP port to Windows Firewall" -Verbose
                    Firewall AddFirewallRule {
                        Name        = 'CustomRdpRule'
                        DisplayName = 'Custom Rule for RDP'
                        Ensure      = 'Present'
                        Enabled     = 'True'
                        Profile     = 'Any'
                        Direction   = 'Inbound'
                        LocalPort   = "$customRdpPort"
                        Protocol    = 'TCP'
                        Description = 'Firewall Rule for Custom RDP Port'
                    }
                }
            }

            #######################################################################
            ## Configure Hyper-V
            ####################################################################### 

            $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem

            if ($osInfo.ProductType -eq 3) {
                Write-Verbose "Configuring Hyper-V role" -Verbose
                WindowsFeature "Hyper-V" {
                    Name   = "Hyper-V"
                    Ensure = "Present"
                }
                Write-Verbose "Configuring Hyper-V Management Tools" -Verbose
                WindowsFeature "RSAT-Hyper-V-Tools" {
                    Name      = "RSAT-Hyper-V-Tools"
                    Ensure    = "Present"
                    DependsOn = "[WindowsFeature]Hyper-V" 
                }
                Write-Verbose "Configuring Hyper-V GUI Management Tools" -Verbose
                VMHost "ConfigureHyper-V" {
                    IsSingleInstance          = 'yes'
                    EnableEnhancedSessionMode = $true
                    DependsOn                 = "[WindowsFeature]Hyper-V"
                }
            }
            # Catch for Windows Client OS
            else {
                Write-Verbose "Configuring Hyper-V role and management tools" -Verbose
                WindowsOptionalFeature "Hyper-V" {
                    Name   = "Microsoft-Hyper-V-All"
                    Ensure = "Enable"
                }
            }

            #######################################################################
            ## Create Azure Local disk images
            #######################################################################

            #### Start Azure Local VHDx Creation ####
            Script "CreateAzLocalDisk" {
                GetScript  = {
                    Write-Verbose "Checking if Azure Local VHDx file exists" -Verbose
                    $result = (Test-Path -Path $Using:azLocalVhdPath) -and (Test-Path -Path "$Using:flagsPath\AzLVhdComplete.txt")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Creating Azure Local VHDx file" -Verbose
                    $scratchPath = "$Using:workshopPath\Scratch"
                    New-Item -ItemType Directory -Path "$scratchPath" -Force | Out-Null
                
                    # Determine if any SSUs are available
                    Write-Verbose "Checking for SSUs" -Verbose
                    $ssu = Test-Path -Path "$Using:ssuPath\*" -Include "*.msu"

                    # Call Convert-WindowsImage to handle creation of VHDX file
                    if ($ssu) {
                        Write-Verbose "SSU found, including in VHDX creation" -Verbose
                        Write-Verbose "Starting creation of Azure Local VHDX file with SSU" -Verbose
                        Write-Verbose "Using $Using:azLocalISOLocalPath as the source ISO" -Verbose
                        Write-Verbose "Using $Using:azLocalVhdPath as the destination VHDX" -Verbose
                        Write-Verbose "Using $Using:workshopPath\Scratch as the temporary directory" -Verbose
                        Write-Verbose "This will take a while, please be patient..." -Verbose
                        Convert-WindowsImage -SourcePath $Using:azLocalISOLocalPath -SizeBytes 127GB -VHDPath $Using:azLocalVhdPath `
                            -VHDFormat VHDX -VHDType Dynamic -VHDPartitionStyle GPT -Package $Using:ssuPath -TempDirectory $Using:scratchPath -Verbose
                    }
                    else {
                        Write-Verbose "No SSU found, creating VHDX file without SSU" -Verbose
                        Write-Verbose "Starting creation of Azure Local VHDX file without SSU" -Verbose
                        Write-Verbose "Using $Using:azLocalISOLocalPath as the source ISO" -Verbose
                        Write-Verbose "Using $Using:azLocalVhdPath as the destination VHDX" -Verbose
                        Write-Verbose "Using $Using:workshopPath\Scratch as the temporary directory" -Verbose
                        Write-Verbose "This will take a while, please be patient..." -Verbose
                        Convert-WindowsImage -SourcePath $Using:azLocalISOLocalPath -SizeBytes 127GB -VHDPath $Using:azLocalVhdPath `
                            -VHDFormat VHDX -VHDType Dynamic -VHDPartitionStyle GPT -TempDirectory $Using:scratchPath -Verbose
                    }

                    Write-Verbose "Sleeping for 30 seconds to allow for VHD to be dismounted..." -Verbose
                    Start-Sleep -Seconds 30

                    # Remove the scratch folder
                    Write-Verbose "Creation complete. Removing the scratch folder" -Verbose
                    Remove-Item -Path "$scratchPath" -Recurse -Force | Out-Null
                    $AzLVhdFlag = "$Using:flagsPath\AzLVhdComplete.txt"
                    New-Item $AzLVhdFlag -ItemType file -Force
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[file]ParentDisks", "[Script]Download Azure Local ISO", "[Script]Download SSU", "[Script]Download CU"
            }

            #######################################################################
            ## Start MSLab Prerequisites
            #######################################################################

            # https://github.com/microsoft/MSLab/blob/master/Scripts/1_Prereq.ps1
            Script "MSLab Prereqs" {
                GetScript  = {
                    Write-Verbose "Checking if MSLab prerequisites have been completed" -Verbose
                    $result = (Test-Path -Path "$Using:flagsPath\PreReqComplete.txt")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Running MSLab prerequisites" -Verbose
                    Set-Location "$Using:workshopPath"
                    .\1_Prereq.ps1
                    Write-Verbose "MSLab prerequisites complete" -Verbose
                    $preReqFlag = "$Using:flagsPath\PreReqComplete.txt"
                    New-Item $preReqFlag -ItemType file -Force
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Edit LabConfig", "[Script]CreateAzLocalDisk"
            }

            #######################################################################
            ## Create Parent Disks
            #######################################################################

            Script "MSLab CreateParentDisks" {
                GetScript  = {
                    Write-Verbose "Checking if MSLab parent disks have been created" -Verbose
                    $result = (Test-Path -Path "$Using:flagsPath\CreateDisksComplete.txt")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Creating MSLab parent disks" -Verbose
                    Set-Location "$Using:workshopPath"
                    .\2_CreateParentDisks.ps1
                    Write-Verbose "Creating parent disks complete" -Verbose
                    $parentDiskFlag = "$Using:flagsPath\CreateDisksComplete.txt"
                    New-Item $parentDiskFlag -ItemType file -Force
                }
                TestScript = {  
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]MSLab Prereqs"
            }

            #######################################################################
            ## Deploy Environment
            #######################################################################

            Script "MSLab DeployEnvironment" {
                GetScript  = {
                    Write-Verbose "Checking if MSLab deployment has been completed" -Verbose
                    $result = (Test-Path -Path "$Using:flagsPath\DeployComplete.txt")
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Deploying MSLab environment" -Verbose
                    Set-Location "$Using:workshopPath"
                    .\Deploy.ps1
                    Write-Verbose "MSLab deployment complete" -Verbose
                    $deployFlag = "$Using:flagsPath\DeployComplete.txt"
                    New-Item $deployFlag -ItemType file -Force
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]MSLab CreateParentDisks"
            }

            #######################################################################
            ## Start Domain Controller and Windows Admin Center
            #######################################################################

            Script "Start DC and WAC" {
                GetScript  = {
                    Write-Verbose "Checking if Domain Controller and Windows Admin Center are running" -Verbose
                    $result = (Get-VM -Name "$Using:vmPrefix-DC").State -eq 'Running' -and (Get-VM -Name "$Using:vmPrefix-WAC").State -eq 'Running'
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Starting Domain Controller and Windows Admin Center" -Verbose
                    Start-VM -Name "$Using:vmPrefix-DC"
                    Start-VM -Name "$Using:vmPrefix-WAC"
                    Write-Verbose "Domain Controller and Windows Admin Center started" -Verbose
                    # Wait 120 seconds for the VMs to start fully
                    Start-Sleep -Seconds 120
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]MSLab DeployEnvironment"
            }

            #######################################################################
            ## Configure the Domain Controller for RDP access
            #######################################################################

            Script "Enable RDP on DC" {
                GetScript  = {
                    Write-Verbose "Checking if RDP is enabled on the Domain Controller" -Verbose
                    $vmIpAddress = (Get-VMNetworkAdapter -Name 'Internet' -VMName "$Using:vmPrefix-DC").IpAddresses | Where-Object { $_ -notmatch ':' }
                    if ((Test-NetConnection $vmIpAddress -CommonTCPPort rdp).TcpTestSucceeded -eq "True") {
                        Write-Verbose "RDP is enabled on the Domain Controller" -Verbose
                        $result = $true
                    }
                    else {
                        Write-Verbose "RDP is not enabled on the Domain Controller" -Verbose
                        $result = $false
                    }
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Enabling RDP on the Domain Controller" -Verbose
                    $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server'-name "fDenyTSConnections" -Value 0
                        Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
                        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 1
                    }
                }
                TestScript = {   
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]MSLab CreateParentDisks"
            }

            #######################################################################
            ## Configure the Windows Admin Center VM - Download only
            #######################################################################

            # If the user has chosen to deploy WAC, need to trigger an installation of the latest WAC build
            if ($installWAC -eq 'Yes') {
                Script "Download WAC" {
                    GetScript  = {
                        $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                        $result = (Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                                Write-Verbose "Checking if Windows Admin Center has been downloaded..." -Verbose
                                [bool] (Test-Path -Path "C:\WindowsAdminCenter.exe")
                            })

                        if ($result) {
                            Write-Verbose "Windows Admin Center has already been downloaded." -Verbose
                        }
                        return @{ 'Result' = $result }
                    }
                    SetScript  = {
                        $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                        Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                            $ProgressPreference = 'SilentlyContinue'
                            Write-Verbose "Downloading Windows Admin Center..." -Verbose
                            Invoke-WebRequest -Uri 'https://aka.ms/WACDownload' -OutFile "C:\WindowsAdminCenter.exe" -UseBasicParsing
                        }
                    }
                    TestScript = {
                        $state = [scriptblock]::Create($GetScript).Invoke()
                        return $state.Result
                    }
                    DependsOn  = "[Script]MSLab CreateParentDisks"
                }
            }
            else { 
                Write-Verbose "Skipping Windows Admin Center download as it was not selected." -Verbose
            }

            #######################################################################
            ## Update the Domain Controller with final configuration
            #######################################################################
        
            Script "Update DC" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                        # Update wallpaper
                        $ProgressPreference = 'SilentlyContinue'
                        Write-Verbose "Updating wallpaper..." -Verbose
                        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/media/azlwallpaper.png' -OutFile "C:\Windows\Web\Wallpaper\Windows\azlwallpaper.png" -UseBasicParsing
                        Set-GPPrefRegistryValue -Name "Default Domain Policy" -Context User -Action Replace -Key "HKCU\Control Panel\Desktop" -ValueName Wallpaper -Value "C:\Windows\Web\Wallpaper\Windows\azlwallpaper.png" -Type String
                        # Disable Internet Explorer ESC for Admin
                        Write-Verbose "Disabling Internet Explorer Enhanced Security Configuration for Admin." -Verbose
                        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0 -Type Dword
                        # Disable Internet Explorer ESC for User
                        Write-Verbose "Disabling Internet Explorer Enhanced Security Configuration for User." -Verbose
                        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0 -Type Dword
                        # Disable Server Manager WAC Prompt
                        Write-Verbose "Disabling Server Manager WAC Prompt." -Verbose
                        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotPopWACConsoleAtSMLaunch' -Value 1 -Type Dword
                        # Disable Server Manager from starting on boot
                        Write-Verbose "Disable Server Manager from starting on boot" -Verbose
                        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1 -Type Dword
                        # Disable Network Profile Prompt
                        Write-Verbose "Disabling Network Profile Prompt." -Verbose
                        New-Item -Path 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff' -Force | Out-Null
                        # Create Shortcut for Hyper-V Manager
                        Write-Verbose "Installing Hyper-V RSAT Tools" -Verbose
                        Install-WindowsFeature -Name RSAT-Hyper-V-Tools -IncludeAllSubFeature -IncludeManagementTools
                        Write-Verbose "Creating Shortcut for Hyper-V Manager" -Verbose
                        Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\Public\Desktop" -Force
                        Write-Verbose "Installing Failover Clustering RSAT Tools" -Verbose
                        Install-WindowsFeature -Name  RSAT-Clustering-Mgmt, RSAT-Clustering-PowerShell -IncludeAllSubFeature -IncludeManagementTools
                        # Create Shortcut for Failover-Cluster Manager
                        Write-Verbose "Creating Shortcut for Failover-Cluster Manager" -Verbose
                        Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Failover Cluster Manager.lnk" -Destination "C:\Users\Public\Desktop" -Force
                        # Create Shortcut for DNS
                        Write-Verbose "Creating Shortcut for DNS Manager" -Verbose
                        Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\DNS.lnk" -Destination "C:\Users\Public\Desktop" -Force
                        # Create Shortcut for Active Directory Users and Computers
                        Write-Verbose "Creating Shortcut for AD Users and Computers" -Verbose
                        Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Active Directory Users and Computers.lnk" -Destination "C:\Users\Public\Desktop" -Force
                        # Disable Edge 'First Run' Setup
                        Write-Verbose "Disabling Edge 'First Run' Setup" -Verbose
                        $edgePolicyRegistryPath = 'HKLM:SOFTWARE\Policies\Microsoft\Edge'
                        $desktopSettingsRegistryPath = 'HKCU:SOFTWARE\Microsoft\Windows\Shell\Bags\1\Desktop'
                        $firstRunRegistryName = 'HideFirstRunExperience'
                        $firstRunRegistryValue = '0x00000001'
                        $savePasswordRegistryName = 'PasswordManagerEnabled'
                        $savePasswordRegistryValue = '0x00000000'
                        $autoArrangeRegistryName = 'FFlags'
                        $autoArrangeRegistryValue = '1075839525'
                        if (-NOT (Test-Path -Path $edgePolicyRegistryPath)) { New-Item -Path $edgePolicyRegistryPath -Force | Out-Null }
                        if (-NOT (Test-Path -Path $desktopSettingsRegistryPath)) { New-Item -Path $desktopSettingsRegistryPath -Force | Out-Null }
                        New-ItemProperty -Path $edgePolicyRegistryPath -Name $firstRunRegistryName -Value $firstRunRegistryValue -PropertyType DWORD -Force
                        New-ItemProperty -Path $edgePolicyRegistryPath -Name $savePasswordRegistryName -Value $savePasswordRegistryValue -PropertyType DWORD -Force
                        Set-ItemProperty -Path $desktopSettingsRegistryPath -Name $autoArrangeRegistryName -Value $autoArrangeRegistryValue -Force
                        # Trigger an explorer restart to apply the wallpaper
                        Write-Verbose "Restarting Explorer to apply wallpaper." -Verbose
                        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5
                    }
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Enable RDP on DC"
            }

            #######################################################################
            ## Create the vSwitches and vNICs for the Azure Local VMs
            #######################################################################

            # Create a switch statement to populate the $vms parameter based on the $azureLocalMachines number
            Write-Verbose "Setting VMs based on the number of Azure Local machines" -Verbose
            $vms = @()
            switch ($azureLocalMachines) {
                1 { $vms = @("AzL1") }
                2 { $vms = @("AzL1", "AzL2") }
                3 { $vms = @("AzL1", "AzL2", "AzL3") }
                4 { $vms = @("AzL1", "AzL2", "AzL3", "AzL4") }
            }
            Write-Verbose "VMs: $vms" -Verbose
            Write-Verbose "Creating vSwitches and vNICs for Azure Local VMs based on the desired architecture: $azureLocalArchitecture" -Verbose
            # Create the Host vSwitches and vNICs to align with the desired azureLocalArchitecture
            if ($azureLocalArchitecture -like "*Non-Converged") {
                Write-Verbose "Architecture = $azureLocalArchitecture. Creating single vSwitch for storage, and VM vNICs" -Verbose
                VMSwitch "NonConvergedSwitch" {
                    Name      = "$vmPrefix-Storage"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }
                # Create 2 storage vNICs per VM
                Write-Verbose "Creating 2 storage vNICs per VM" -Verbose
                foreach ($vm in $vms) {
                    Write-Verbose "Creating vNICs for $vm with the following names" -Verbose
                    Write-Verbose "$($vm)Storage1 and $($vm)Storage2" -Verbose
                    VMNetworkAdapter "$($vm)Storage1" {
                        Id         = "$vm-Storage1-NIC"
                        VMName     = "$vmPrefix-$vm"
                        Name       = "Storage1"
                        SwitchName = "$vmPrefix-Storage"
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]NonConvergedSwitch"
                    }
                    VMNetworkAdapter "$($vm)Storage2" {
                        Id         = "$vm-Storage2-NIC"
                        VMName     = "$vmPrefix-$vm"
                        Name       = "Storage2"
                        SwitchName = "$vmPrefix-Storage"
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]NonConvergedSwitch"
                    }
                }
            }
            elseif ($azureLocalArchitecture -eq "2-Machine Switchless Dual-Link") {
                Write-Verbose "Architecture = $azureLocalArchitecture. Creating 2 private vSwitches and VM vNICs" -Verbose
                VMSwitch "CreateStorageSwitch1-2" {
                    Name      = "$vmPrefix-Storage1-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-1" {
                    Name      = "$vmPrefix-Storage2-1"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }
                foreach ($vm in $vms) {
                    Write-Verbose "Creating vNICs for $vm with the following names" -Verbose
                    Write-Verbose "$($vm)Storage1-2 and $($vm)Storage2-1" -Verbose
                    VMNetworkAdapter "$($vm)Storage1-2" {
                        Id         = "$vm-Storage1-2-NIC"
                        VMName     = "$vmPrefix-$vm"
                        Name       = "Storage1-2"
                        SwitchName = "$vmPrefix-Storage1-2"
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]CreateStorageSwitch1-2"
                    }
                    VMNetworkAdapter "$($vm)Storage2-1" {
                        Id         = "$vm-Storage2-1-NIC"
                        VMName     = "$vmPrefix-$vm"
                        Name       = "Storage2-1"
                        SwitchName = "$vmPrefix-Storage2-1"
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]CreateStorageSwitch2-1"
                    }
                }
            }
        
            # Create vSwitch and vNICs for 3-machine switchless single-link architectures
            elseif ($azureLocalArchitecture -eq "3-Machine Switchless Single-Link") {
                # Create 1 vSwitch per VM named "Storage" plus the Number of the 2 nodes that it will connect between (e.g. Storage1-2)
                Write-Verbose "Architecture = $azureLocalArchitecture. Creating 3 private vSwitches and VM vNICs" -Verbose
                VMSwitch "CreateStorageSwitch1-2" {
                    Name      = "$vmPrefix-Storage1-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-3" {
                    Name      = "$vmPrefix-Storage2-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch1-3" {
                    Name      = "$vmPrefix-Storage1-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                $machines = 1..3
                $nics = @(
                    @{ VM = 1; NICs = @("Storage1-2", "Storage1-3") },
                    @{ VM = 2; NICs = @("Storage1-2", "Storage2-3") },
                    @{ VM = 3; NICs = @("Storage1-3", "Storage2-3") }
                )

                foreach ($machine in $machines) {
                    foreach ($nic in $nics[$machine - 1].NICs) {
                        Write-Verbose "Creating vNICs for $($machine) with the following names" -Verbose
                        Write-Verbose "$($vmPrefix)AzL$machine-$nic" -Verbose
                        VMNetworkAdapter "AzL$machine$($nic)" {
                            Id         = "AzL$machine-$nic-NIC"
                            VMName     = "$vmPrefix-AzL$machine"
                            Name       = "$nic"
                            SwitchName = "$vmPrefix-$nic"
                            Ensure     = "Present"
                            DependsOn  = "[VMSwitch]CreateStorageSwitch1-2", "[VMSwitch]CreateStorageSwitch2-3", "[VMSwitch]CreateStorageSwitch1-3"
                        }
                    }
                }
            }

            # Create vSwitch and vNICs for 3-machine switchless dual-link architectures
            elseif ($azureLocalArchitecture -like "3-Machine Switchless Dual-Link") {
                # Create 6 private vSwitches named "Storage1-2", "Storage2-1", "Storage2-3", "Storage3-2", "Storage1-3", and "Storage3-1"
                Write-Verbose "Architecture = $azureLocalArchitecture. Creating 6 private vSwitches and VM vNICs" -Verbose
                VMSwitch "CreateStorageSwitch1-2" {
                    Name      = "$vmPrefix-Storage1-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-1" {
                    Name      = "$vmPrefix-Storage2-1"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-3" {
                    Name      = "$vmPrefix-Storage2-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch3-2" {
                    Name      = "$vmPrefix-Storage3-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch1-3" {
                    Name      = "$vmPrefix-Storage1-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch3-1" {
                    Name      = "$vmPrefix-Storage3-1"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                $machineNics = @(
                    @{ VM = 1; NICs = @("Storage1-2", "Storage1-3", "Storage2-1", "Storage3-1") },
                    @{ VM = 2; NICs = @("Storage1-2", "Storage2-1", "Storage2-3", "Storage3-2") },
                    @{ VM = 3; NICs = @("Storage1-3", "Storage2-3", "Storage3-1", "Storage3-2") }
                )

                foreach ($machine in $machineNics) {
                    foreach ($nicName in $machine.NICs) {
                        Write-Verbose "Creating vNICs for $($machine.VM) with the following names" -Verbose
                        Write-Verbose "$($vmPrefix)AzL$($machine.VM)-$nicName" -Verbose
                        VMNetworkAdapter "AzL$($machine.VM)$($nicName)" {
                            Id         = "$vmPrefix-AzL$($machine.VM)-$nicName-NIC"
                            VMName     = "$vmPrefix-AzL$($machine.VM)"
                            Name       = "$nicName"
                            SwitchName = "$vmPrefix-$nicName"
                            Ensure     = "Present"
                            DependsOn  = "[VMSwitch]CreateStorageSwitch1-2", "[VMSwitch]CreateStorageSwitch2-1", "[VMSwitch]CreateStorageSwitch2-3", "[VMSwitch]CreateStorageSwitch3-2", "[VMSwitch]CreateStorageSwitch1-3", "[VMSwitch]CreateStorageSwitch3-1"
                        }
                    }
                }
            }
        
            # Create vSwitch and vNICs for 4-machine switchless dual-link architectures
            elseif ($azureLocalArchitecture -like "4-Machine Switchless Dual-Link") {
                # Create 12 private vSwitches named "Storage1-2", "Storage2-1", "Storage2-3", "Storage3-2", "Storage1-3", "Storage3-1", "Storage1-4", "Storage4-1", "Storage2-4", "Storage4-2", "Storage3-4", and "Storage4-3"
                Write-Verbose "Architecture = $azureLocalArchitecture. Creating 12 private vSwitches and VM vNICs" -Verbose
                VMSwitch "CreateStorageSwitch1-2" {
                    Name      = "$vmPrefix-Storage1-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-1" {
                    Name      = "$vmPrefix-Storage2-1"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-3" {
                    Name      = "$vmPrefix-Storage2-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch3-2" {
                    Name      = "$vmPrefix-Storage3-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch1-3" {
                    Name      = "$vmPrefix-Storage1-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch3-1" {
                    Name      = "$vmPrefix-Storage3-1"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch1-4" {
                    Name      = "$vmPrefix-Storage1-4"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch4-1" {
                    Name      = "$vmPrefix-Storage4-1"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch2-4" {
                    Name      = "$vmPrefix-Storage2-4"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch4-2" {
                    Name      = "$vmPrefix-Storage4-2"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch3-4" {
                    Name      = "$vmPrefix-Storage3-4"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                VMSwitch "CreateStorageSwitch4-3" {
                    Name      = "$vmPrefix-Storage4-3"
                    Type      = "Private"
                    Ensure    = "Present"
                    DependsOn = "[Script]Update DC"
                }

                $machineNics = @(
                    @{ VM = 1; NICs = @("Storage1-2", "Storage1-3", "Storage1-4", "Storage2-1", "Storage3-1", "Storage4-1") },
                    @{ VM = 2; NICs = @("Storage1-2", "Storage2-1", "Storage2-3", "Storage2-4", "Storage3-2", "Storage4-2") },
                    @{ VM = 3; NICs = @("Storage1-3", "Storage2-3", "Storage3-1", "Storage3-4", "Storage4-1", "Storage4-3") },
                    @{ VM = 4; NICs = @("Storage1-4", "Storage2-4", "Storage3-4", "Storage4-1", "Storage4-2", "Storage4-3") }
                )

                foreach ($machine in $machineNics) {
                    foreach ($nicName in $machine.NICs) {
                        Write-Verbose "Creating vNICs for $($machine.VM) with the following names" -Verbose
                        Write-Verbose "$($vmPrefix)AzL$($machine.VM)-$nicName" -Verbose
                        VMNetworkAdapter "AzL$($machine.VM)$($nicName)" {
                            Id         = "$vmPrefix-AzL$($machine.VM)-$nicName-NIC"
                            VMName     = "$vmPrefix-AzL$($machine.VM)"
                            Name       = "$nicName"
                            SwitchName = "$vmPrefix-$nicName"
                            Ensure     = "Present"
                            DependsOn  = "[VMSwitch]CreateStorageSwitch1-2", "[VMSwitch]CreateStorageSwitch2-1", "[VMSwitch]CreateStorageSwitch2-3", "[VMSwitch]CreateStorageSwitch3-2", "[VMSwitch]CreateStorageSwitch1-3", "[VMSwitch]CreateStorageSwitch3-1", "[VMSwitch]CreateStorageSwitch1-4", "[VMSwitch]CreateStorageSwitch4-1", "[VMSwitch]CreateStorageSwitch2-4", "[VMSwitch]CreateStorageSwitch4-2", "[VMSwitch]CreateStorageSwitch3-4", "[VMSwitch]CreateStorageSwitch4-3"
                        }
                    }
                }
            }

            #######################################################################
            ## Configuring VLANs for the Storage vNICs
            #######################################################################

            Write-Verbose "Configuring VLANs for the Storage vNICs" -Verbose

            # Set VLANs for the Storage vNICs based on the azureLocalArchitecture
            $vLANdependsOn = switch ($azureLocalArchitecture) {
                "2-Machine Non-Converged" { "[VMNetworkAdapter]$($vms[0])Storage1", "[VMNetworkAdapter]$($vms[0])Storage2", "[VMNetworkAdapter]$($vms[1])Storage1", "[VMNetworkAdapter]$($vms[1])Storage2" }
                "3-Machine Non-Converged" {
                    "[VMNetworkAdapter]$($vms[0])Storage1", "[VMNetworkAdapter]$($vms[0])Storage2", "[VMNetworkAdapter]$($vms[1])Storage1", "[VMNetworkAdapter]$($vms[1])Storage2", `
                        "[VMNetworkAdapter]$($vms[2])Storage1", "[VMNetworkAdapter]$($vms[2])Storage2" 
                }
                "4-Machine Non-Converged" {
                    "[VMNetworkAdapter]$($vms[0])Storage1", "[VMNetworkAdapter]$($vms[0])Storage2", `
                        "[VMNetworkAdapter]$($vms[1])Storage1", "[VMNetworkAdapter]$($vms[1])Storage2", `
                        "[VMNetworkAdapter]$($vms[2])Storage1", "[VMNetworkAdapter]$($vms[2])Storage2", `
                        "[VMNetworkAdapter]$($vms[3])Storage1", "[VMNetworkAdapter]$($vms[3])Storage2" 
                }
                "2-Machine Switchless Dual-Link" {
                    "[VMNetworkAdapter]$($vms[0])Storage1-2", "[VMNetworkAdapter]$($vms[0])Storage2-1", `
                        "[VMNetworkAdapter]$($vms[1])Storage1-2", "[VMNetworkAdapter]$($vms[1])Storage2-1" 
                }
                "3-Machine Switchless Single-Link" {
                    "[VMNetworkAdapter]$($vms[0])Storage1-2", "[VMNetworkAdapter]$($vms[0])Storage1-3", `
                        "[VMNetworkAdapter]$($vms[1])Storage1-2", "[VMNetworkAdapter]$($vms[1])Storage2-3", `
                        "[VMNetworkAdapter]$($vms[2])Storage1-3", "[VMNetworkAdapter]$($vms[2])Storage2-3" 
                }
                "3-Machine Switchless Dual-Link" {
                    "[VMNetworkAdapter]$($vms[0])Storage1-2", "[VMNetworkAdapter]$($vms[0])Storage1-3", "[VMNetworkAdapter]$($vms[0])Storage2-1", "[VMNetworkAdapter]$($vms[0])Storage3-1", `
                        "[VMNetworkAdapter]$($vms[1])Storage1-2", "[VMNetworkAdapter]$($vms[1])Storage2-1", "[VMNetworkAdapter]$($vms[1])Storage2-3", "[VMNetworkAdapter]$($vms[1])Storage3-2", `
                        "[VMNetworkAdapter]$($vms[2])Storage1-3", "[VMNetworkAdapter]$($vms[2])Storage2-3", "[VMNetworkAdapter]$($vms[2])Storage3-1", "[VMNetworkAdapter]$($vms[2])Storage3-2" 
                }
                "4-Machine Switchless Dual-Link" {
                    "[VMNetworkAdapter]$($vms[0])Storage1-2", "[VMNetworkAdapter]$($vms[0])Storage1-3", "[VMNetworkAdapter]$($vms[0])Storage1-4", "[VMNetworkAdapter]$($vms[0])Storage2-1", "[VMNetworkAdapter]$($vms[0])Storage3-1", "[VMNetworkAdapter]$($vms[0])Storage4-1", `
                        "[VMNetworkAdapter]$($vms[1])Storage1-2", "[VMNetworkAdapter]$($vms[1])Storage2-1", "[VMNetworkAdapter]$($vms[1])Storage2-3", "[VMNetworkAdapter]$($vms[1])Storage2-4", "[VMNetworkAdapter]$($vms[1])Storage3-2", "[VMNetworkAdapter]$($vms[1])Storage4-2", `
                        "[VMNetworkAdapter]$($vms[2])Storage1-3", "[VMNetworkAdapter]$($vms[2])Storage2-3", "[VMNetworkAdapter]$($vms[2])Storage3-1", "[VMNetworkAdapter]$($vms[2])Storage3-4", "[VMNetworkAdapter]$($vms[2])Storage4-1", "[VMNetworkAdapter]$($vms[2])Storage4-3", `
                        "[VMNetworkAdapter]$($vms[3])Storage1-4", "[VMNetworkAdapter]$($vms[3])Storage2-4", "[VMNetworkAdapter]$($vms[3])Storage3-4", "[VMNetworkAdapter]$($vms[3])Storage4-1", "[VMNetworkAdapter]$($vms[3])Storage4-2", "[VMNetworkAdapter]$($vms[3])Storage4-3" 
                }
            }

            # Perform the SetStorageVLANs script based on the $azureLocalArchitecture
            # Not necessary if $azureLocalArchitecture is either 'Single Machine' or '*Fully-Converged'
            if ($azureLocalArchitecture -notlike "Single Machine" -and $azureLocalArchitecture -notlike "*Fully-Converged") {
                Script "SetStorageVLANs" {
                    GetScript  = {
                        $result = $false
                        return @{ 'Result' = $result }
                    }
                    SetScript  = {
                        $ErrorActionPreference = "SilentlyContinue"
                        $retryCount = 0
                        $success = $false
                        do {
                            try {
                                Write-Verbose "Attempt $($retryCount + 1) to set VLANs for Storage NICs in Azure Local VMs..." -Verbose
                                Get-VM -Name "$Using:vmPrefix-AzL*" | ForEach-Object {
                                    Write-Verbose "Setting VLANs for $($_.Name)" -Verbose
                                    $nics = Get-VMNetworkAdapter -VMName $($_.Name) | Where-Object Name -like "Storage*"
                                    foreach ($nic in $nics) {
                                        Write-Verbose "Setting VLAN 711-719 on $($nic.Name) on $($_.Name)" -Verbose
                                        Set-VMNetworkAdapterVlan -VMNetworkAdapterName $($nic.Name) -VMName $($_.Name) -Trunk -AllowedVlanIdList "711-719" -NativeVlanId 0
                                        # Enable Device Naming for the NIC
                                        Set-VMNetworkAdapter -VMNetworkAdapterName $($nic.Name) -VMName $($_.Name) -DeviceNaming On
                                        Write-Verbose "Enabled Device Naming for $($nic.Name) on $($_.Name)" -Verbose
                                    }
                                }
                                $success = $true
                                Write-Verbose "VLANs set successfully for Storage NICs in Azure Local VMs." -Verbose
                            }
                            catch {
                                Write-Warning "Failed to set VLANs on $($_.Name). Error: $_" -Verbose
                                $retryCount++
                                if ($retryCount -lt $MaxRetries) {
                                    Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                    Start-Sleep -Seconds $RetryDelay
                                }
                                else {
                                    Throw "Maximum retries ($MaxRetries) reached. Unable to set VLANs on $($_.Name)."
                                }
                            }
                        } while (-not $success -and $retryCount -lt $MaxRetries)
                    }
                    TestScript = {
                        $state = [scriptblock]::Create($GetScript).Invoke()
                        return $state.Result
                    }
                    DependsOn  = "[Script]Update DC", $vLANdependsOn
                }
            }

            # Quick switch to determine the correct dependsOn for updating the AzLNicNames
            $RebootAzLDependsOn = switch ($azureLocalArchitecture) {
                { $_ -eq "Single Machine" -or $_ -like "*Fully-Converged" } { '[Script]Update DC' }
                Default { '[Script]SetStorageVLANs' }
            }

            #######################################################################
            ## Start the AzL VMs and wait for them to come online
            #######################################################################

            Write-Verbose "Starting the AzL VMs and waiting for them to come online" -Verbose

            Script "StartAzLVMs" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ErrorActionPreference = "SilentlyContinue"
                    $retryCount = 0
                    $success = $false
                    do {
                        try {
                            Write-Verbose "Attempt $($retryCount + 1) to Start the AzL VMs..." -Verbose
                            Get-VM -Name "$Using:vmPrefix-AzL*" | Start-VM -Verbose
                            $success = $true
                            Write-Verbose "AzL VMs started successfully." -Verbose
                            # Wait 240 seconds for the VMs to come online
                            Write-Verbose "Waiting for 240 seconds for the VMs to come online..." -Verbose
                            Start-Sleep -Seconds 240
                        }
                        catch {
                            Write-Warning "Failed to start AzL VMs. Error: $_" -Verbose
                            $retryCount++
                            if ($retryCount -lt $MaxRetries) {
                                Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                Start-Sleep -Seconds $RetryDelay
                            }
                            else {
                                Throw "Maximum retries ($MaxRetries) reached. Unable to start AzL VMs."
                            }
                        }
                    } while (-not $success -and $retryCount -lt $MaxRetries)
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = $RebootAzLDependsOn
            }

            #######################################################################
            ## Configuring NIC Names for the AzL VMs
            #######################################################################

            Write-Verbose "Configuring NIC Names for the AzL VMs" -Verbose

            # Update all the Nic Names in the AzL VMs to make it easier for configuring the networking during instance deployment
            Script "UpdateAzLNicNames" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ErrorActionPreference = "SilentlyContinue"
                    $scriptCredential = New-Object System.Management.Automation.PSCredential ("Administrator", (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    $retryCount = 0
                    $success = $false
                    do {
                        try {
                            Write-Verbose "Attempt $($retryCount + 1) to set NIC names for Azure Local VMs..." -Verbose
                            Get-VM -Name "$Using:vmPrefix-AzL*" | ForEach-Object {
                                Write-Verbose "Updating NIC names for $($_.Name)" -Verbose
                                Invoke-Command -VMName $($_.Name) -Credential $scriptCredential -ScriptBlock {
                                    # Create a while loop to check if there are NICs with a name like "Ethernet*" and rename them
                                    $maxRetries = 5
                                    $retryCount = 0
                                    do {
                                        $adapters = Get-NetAdapter -Name "Ethernet*" -ErrorAction SilentlyContinue
                                        if ($adapters.Count -gt 0) {
                                            Write-Verbose "Renaming NICs with names like 'Ethernet' on $($_.Name)" -Verbose
                                            foreach ($N in (Get-NetAdapterAdvancedProperty -DisplayName "Hyper-V Network Adapter Name" | Where-Object DisplayValue -NotLike "")) {
                                                $N | Rename-NetAdapter -NewName $N.DisplayValue -Verbose
                                                Write-Verbose "Renamed NIC with MAC: $($N.MacAddress) to $($N.DisplayValue)" -Verbose
                                            }
                                            Start-Sleep -Seconds 10
                                        }
                                        $retryCount++
                                    } while (($adapters.Count -gt 0) -and ($retryCount -lt $maxRetries))
                                }
                            }
                            $success = $true
                            Write-Verbose "NIC names set successfully for Azure Local VMs." -Verbose
                        }
                        catch {
                            Write-Warning "Failed to set NIC names on $($_.Name). Error: $_" -Verbose
                            $retryCount++
                            if ($retryCount -lt $MaxRetries) {
                                Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                Start-Sleep -Seconds $RetryDelay
                            }
                            else {
                                Throw "Maximum retries ($MaxRetries) reached. Unable to set NIC names on $($_.Name)."
                            }
                        }
                    } while (-not $success -and $retryCount -lt $MaxRetries)
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]StartAzLVMs"
            }

            #######################################################################
            ## Disable DHCP on the VMs and update the DHCP scope
            #######################################################################

            Write-Verbose "Disabling DHCP on the VMs and updating the DHCP scope" -Verbose

            Script "DisableDhcpOnVMs" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ErrorActionPreference = "SilentlyContinue"
                    $retryCount = 0
                    $success = $false
                    do {
                        try {
                            Write-Verbose "Attempt $($retryCount + 1) to disable DHCP on the VMs" -Verbose
                            # Get all VMs that are not the DC and disable DHCP on them
                            $vmName = Get-VM | Where-Object { $_.Name -notlike "$Using:vmPrefix-DC" }
                            Write-Verbose "Disabling DHCP on the following VMs: $($vmName.Name)" -Verbose
                            ForEach ($vm in $vmName) {
                                Write-Verbose "Disabling DHCP on $($vm.Name)" -Verbose
                                $scriptCredential = New-Object System.Management.Automation.PSCredential (".\Administrator", (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                                Invoke-Command -VMName $vm.Name -Credential $scriptCredential -ArgumentList $vm -ScriptBlock {
                                    param ($vm)
                                    Write-Verbose "Enable ping through the firewall on $($vm.Name)" -Verbose
                                    # Enable PING through the firewall
                                    Enable-NetFirewallRule -displayName "File and Printer Sharing (Echo Request - ICMPv4-In)"
                                    # Get all NICs and check if DHCP is enabled, and if so, disable it
                                    Get-NetAdapter | Get-NetIPInterface | Where-Object Dhcp -eq 'Enabled' | ForEach-Object {
                                        Write-Verbose "$($vm.Name): Disabling DHCP on $($_.InterfaceAlias)" -Verbose
                                        Set-NetIPInterface -InterfaceAlias $_.InterfaceAlias -Dhcp Disabled
                                        Write-Verbose "$($vm.Name): Disabling DHCP on $($_.InterfaceAlias) - Done" -Verbose
                                    }
                                }
                            }
                            $success = $true
                            Write-Verbose "DHCP successfully disabled on all VMs" -Verbose
                        }
                        catch {
                            Write-Warning "Failed to disable DHCP on $($vm.Name). Error: $_" -Verbose
                            $retryCount++
                            if ($retryCount -lt $MaxRetries) {
                                Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                Start-Sleep -Seconds $RetryDelay
                            }
                            else {
                                Throw "Maximum retries ($MaxRetries) reached. Unable to disable DHCP on $($vm.Name)."
                            }
                        }
                    } while (-not $success -and $retryCount -lt $MaxRetries)
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]UpdateAzLNicNames"
            }

            Script "UpdateDhcpScope" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ErrorActionPreference = "SilentlyContinue"
                    $retryCount = 0
                    $success = $false
                    do {
                        try {
                            Write-Verbose "Attempt $($retryCount + 1) to update DHCP scope" -Verbose
                            # Get the scope from DHCP by running an Invoke-Command against the DC VM
                            $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                            Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                                $DhcpScope = Get-DhcpServerv4Scope
                                Write-Verbose "DHCP Scope: $DhcpScope" -Verbose
                                $shortDhcpScope = ($DhcpScope.StartRange -split '\.')[0..2] -join '.'
                                Write-Verbose "Short DHCP Scope: $shortDhcpScope" -Verbose
                                # Start the scope at 50 to allow for Deployments with SDN optional services
                                # As per here: https://learn.microsoft.com/en-us/azure/azure-local/plan/three-node-ip-requirements?view=azloc-24113#deployments-with-sdn-optional-services
                                $newIpStartRange = ($shortDhcpScope + ".50")
                                Write-Verbose "Updating DHCP scope to start at $newIpStartRange to allow for additional optional Azure Local services" -Verbose
                                Set-DhcpServerv4Scope -ScopeId $DhcpScope.ScopeId -StartRange $newIpStartRange -EndRange $DhcpScope.EndRange
                                Write-Verbose "DHCP scope updated to start at $newIpStartRange" -Verbose
                                Get-DhcpServerv4Lease -ScopeId $DhcpScope.ScopeId | Where-Object IPAddress -like "$shortDhcpScope*" | ForEach-Object {
                                    Remove-DhcpServerv4Lease -ScopeId $DhcpScope.ScopeId -Confirm:$false -ErrorAction SilentlyContinue
                                    Write-Verbose "Removed DHCP lease for IP address $($_.IPAddress)" -Verbose
                                }
                            }
                            $success = $true
                            Write-Verbose "DHCP scope successfully updated" -Verbose
                        }
                        catch {
                            Write-Warning "Failed to disable DHCP on $Using:vmPrefix-DC. Error: $_" -Verbose
                            $retryCount++
                            if ($retryCount -lt $MaxRetries) {
                                Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                Start-Sleep -Seconds $RetryDelay
                            }
                            else {
                                Throw "Maximum retries ($MaxRetries) reached. Unable to update DHCP scope on $Using:vmPrefix-DC."
                            }
                        }
                    } while (-not $success -and $retryCount -lt $MaxRetries)
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]DisableDhcpOnVMs"
            }

            #######################################################################
            ## Set Static IPs for the VMs
            #######################################################################

            Write-Verbose "Setting Static IPs for the VMs" -Verbose

            Script "SetStaticIPs" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $ErrorActionPreference = "SilentlyContinue"
                    $retryCount = 0
                    $success = $false
                    do {
                        try {
                            Write-Verbose "Attempt $($retryCount + 1) to set static IP addresses on all VMs" -Verbose
                            $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                            $returnedValues = Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                                $DhcpScope = Get-DhcpServerv4Scope
                                Write-Verbose "DHCP Scope: $DhcpScope" -Verbose
                                $subnetMask = $DhcpScope.SubnetMask.IPAddressToString
                                Write-Verbose "Subnet Mask: $subnetMask" -Verbose
                                $gateway = (Get-DhcpServerv4OptionValue -ScopeId $DhcpScope.ScopeId -OptionId 3).Value
                                Write-Verbose "Gateway: $gateway" -Verbose
                                $dnsServers = (Get-DhcpServerv4OptionValue -ScopeId $DhcpScope.ScopeId -OptionId 6).Value
                                Write-Verbose "DNS Servers: $dnsServers" -Verbose
                                return $DhcpScope, $subnetMask, $gateway, $dnsServers
                            }
                            # Unpack the returned values
                            $DhcpScope = $returnedValues[0]
                            $shortDhcpScope = ($DhcpScope.StartRange -split '\.')[0..2] -join '.'
                            $subnetMask = @($returnedValues[1]) # Ensure it is treated as a collection
                            $gateway = @($returnedValues[2])    # Ensure it is treated as a collection
                            $dnsServers = @($returnedValues[3]) # Ensure it is treated as a collection
                            $vms = $Using:vms

                            # Starting at .11 for the first node, define the IP range for the AzL nodes based on the $azureLocalMachines variable
                            $AzLIpStart = ([ipaddress]("$shortDhcpScope.11"))
                            $AzLIpRange = @()
                            for ($i = 0; $i -lt $Using:azureLocalMachines; $i++) {
                                $ipBytes = $AzLIpStart.GetAddressBytes()
                                $ipBytes[3] += $i
                                $AzLIpRange += [ipaddress]::new($ipBytes)
                            }
                
                            # Create a hashtable to store the AzL VMs and their IP addresses
                            $AzLIpMap = @{} # Initialize as a hashtable
                            # Iterate through the arrays to create the mapping
                            for ($i = 0; $i -lt $vms.Count; $i++) {
                                $AzLIpMap[$vms[$i]] = $AzLIpRange[$i].IPAddressToString
                            }

                            # Sort the hashtable by $vms and ensure it remains a hashtable
                            $AzLIpMap = [ordered]@{}
                            foreach ($vm in $vms | Sort-Object) {
                                $AzLIpMap[$vm] = $AzLIpRange[$vms.IndexOf($vm)].IPAddressToString
                            }
                
                            if ($Using:installWAC -eq 'Yes') {
                                $wacIP = [ipaddress]("$shortDhcpScope.10")
                                $AzLIpMap.Add('WAC', $wacIP.IPAddressToString)
                            }

                            # Statically assign the IP
                            foreach ($vm in $AzLIpMap.Keys) {
                                $vmName = "$Using:vmPrefix-$vm"
                                $vmIpAddress = @()
                                $vmIpAddress = @($AzLIpMap[$vm])

                                Write-Verbose "Setting static IP for $vmName to $($vmIpAddress)" -Verbose

                                $networkAdapter = Get-VMNetworkAdapter -VMName $vmName -Name "Management1"
                                $vmToUpdate = Get-CimInstance -Namespace "root\virtualization\v2" -ClassName "Msvm_ComputerSystem" | Where-Object ElementName -eq $networkAdapter.VMName
                                $vmSettings = Get-CimAssociatedInstance -InputObject $vmToUpdate -ResultClassName "Msvm_VirtualSystemSettingData" | Where-Object VirtualSystemType -EQ "Microsoft:Hyper-V:System:Realized"
                                $vmNetAdapters = Get-CimAssociatedInstance -InputObject $vmSettings -ResultClassName "Msvm_SyntheticEthernetPortSettingData"
            
                                $networkAdapterConfiguration = @()
                                foreach ($netAdapter in $vmNetAdapters) {
                                    if ($netAdapter.ElementName -eq $networkAdapter.Name) {
                                        $networkAdapterConfiguration = Get-CimAssociatedInstance -InputObject $netAdapter -ResultClassName "Msvm_GuestNetworkAdapterConfiguration"
                                        break
                                    }
                                }
            
                                $networkAdapterConfiguration.PSBase.CimInstanceProperties["IPAddresses"].Value = $vmIpAddress
                                $networkAdapterConfiguration.PSBase.CimInstanceProperties["Subnets"].Value = $subnetMask
                                $networkAdapterConfiguration.PSBase.CimInstanceProperties["DefaultGateways"].Value = $gateway
                                $networkAdapterConfiguration.PSBase.CimInstanceProperties["DNSServers"].Value = $dnsServers
                                $networkAdapterConfiguration.PSBase.CimInstanceProperties["ProtocolIFType"].Value = 4096
                                $networkAdapterConfiguration.PSBase.CimInstanceProperties["DHCPEnabled"].Value = $false
            
                                $cimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
                                $serializedInstance = $cimSerializer.Serialize($networkAdapterConfiguration, [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)
                                $serializedInstanceString = [System.Text.Encoding]::Unicode.GetString($serializedInstance)
            
                                $service = Get-CimInstance -ClassName "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
                                $setIp = Invoke-CimMethod -InputObject $service -MethodName "SetGuestNetworkAdapterConfiguration" -Arguments @{
                                    ComputerSystem       = $vmToUpdate
                                    NetworkConfiguration = @($serializedInstanceString)
                                }
                                if ($setIp.ReturnValue -eq 0) {
                                    # completed
                                    Write-Verbose "Management1 IP on $vmName to $vmIpAddress" -Verbose
                                }
                                else {
                                    # unexpected response
                                    $setIp
                                }
                            }
                            $success = $true
                            Write-Verbose "All VMs have been assigned static IP addresses" -Verbose
                        }
                        catch {
                            Write-Warning "Failed to set a static IP on $Using:vmPrefix-$vm. Error: $_" -Verbose
                            $retryCount++
                            if ($retryCount -lt $MaxRetries) {
                                Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                Start-Sleep -Seconds $RetryDelay
                            }
                            else {
                                Throw "Maximum retries ($MaxRetries) reached. Unable to set a static IP on $Using:vmPrefix-$vm."
                            }
                        }
                    } while (-not $success -and $retryCount -lt $MaxRetries)
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]UpdateDhcpScope"
            }

            #######################################################################
            ## Update DNS Records for the VMs
            #######################################################################

            Script "UpdateDNSRecords" {
                GetScript  = {
                    $result = $false
                    return @{ 'Result' = $result }
                }
                SetScript  = {

                    do {
                        try {
                            Write-Verbose "Attempt $($retryCount + 1) to update DNS records on the DC" -Verbose
                            $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                            Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential `
                                -ArgumentList $Using:domainName, $Using:azureLocalMachines, $Using:vms, $Using:installWAC -ScriptBlock {
                                param ($domainName, $azureLocalMachines, $vms, $installWAC)

                                # Get the current DHCP info
                                $DhcpScope = Get-DhcpServerv4Scope
                                $shortDhcpScope = ($DhcpScope.StartRange -split '\.')[0..2] -join '.'

                                # Starting at .11 for the first AzL node, define the IP range for the AzL nodes based on the $azureLocalMachines variable
                                $AzLIpStart = ([ipaddress]("$shortDhcpScope.11"))
                                $AzLIpRange = @()
                                for ($i = 0; $i -lt $azureLocalMachines; $i++) {
                                    $ipBytes = $AzLIpStart.GetAddressBytes()
                                    $ipBytes[3] += $i
                                    $AzLIpRange += [ipaddress]::new($ipBytes)
                                }
                
                                # Create a hashtable to store the AzL VMs and their IP addresses
                                $AzLIpMap = @{} # Initialize as a hashtable
                                # Iterate through the arrays to create the mapping
                                for ($i = 0; $i -lt $vms.Count; $i++) {
                                    $AzLIpMap[$vms[$i]] = $AzLIpRange[$i].IPAddressToString
                                }

                                # Sort the hashtable by $vms and ensure it remains a hashtable
                                $AzLIpMap = [ordered]@{}
                                foreach ($vm in $vms | Sort-Object) {
                                    $AzLIpMap[$vm] = $AzLIpRange[$vms.IndexOf($vm)].IPAddressToString
                                }
                
                                if ($installWAC -eq 'Yes') {
                                    $wacIP = [ipaddress]("$shortDhcpScope.10")
                                    $AzLIpMap.Add('WAC', $wacIP.IPAddressToString)
                                }

                                foreach ($vm in $AzLIpMap.Keys) {
                                    $dnsName = $vm
                                    $vmIpAddress = $AzLIpMap[$vm]
                                    # Need to check if any DNS records exist for "AzL*"" or "WAC" and remove them
                                    Write-Verbose "Checking for existing DNS Record for $dnsName" -Verbose
                                    $dnsCheck = Get-DnsServerResourceRecord -Name $dnsName -ZoneName $domainName -ErrorAction SilentlyContinue
                                    foreach ($entry in $dnsCheck) {
                                        Write-Verbose "Cleaning up existing DNS entry for $($entry.HostName)" -Verbose
                                        Remove-DnsServerResourceRecord $entry.HostName -ZoneName $domainName -RRType A -Force
                                    }
                                    Write-Verbose "Creating new DNS record for $dnsName with IP: $vmIpAddress in Zone: $domainName" -Verbose
                                    Add-DnsServerResourceRecordA -Name $dnsName -ZoneName $domainName -IPv4Address $vmIpAddress -ErrorAction SilentlyContinue -CreatePtr
                                }
                            }
                            $success = $true
                            Write-Verbose "DNS records have been successfully updated" -Verbose
                        }
                        catch {
                            Write-Warning "Failed to update DNS record on the DC for $Using:vmPrefix-$vm. Error: $_" -Verbose
                            $retryCount++
                            if ($retryCount -lt $MaxRetries) {
                                Write-Verbose "Retrying in $RetryDelay seconds..." -Verbose
                                Start-Sleep -Seconds $RetryDelay
                            }
                            else {
                                Throw "Maximum retries ($MaxRetries) reached. Unable to update DNS record on the DC for $Using:vmPrefix-$vm."
                            }
                        }
                    } while (-not $success -and $retryCount -lt $MaxRetries)
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]SetStaticIPs"
            }

            #######################################################################
            ## Final tasks - Download RDP file, Edit RDP file, and Create RDP RunOnce
            #######################################################################

            Write-Verbose "Final tasks - Download RDP file, Edit RDP file, and Create RDP RunOnce" -Verbose
            Write-Verbose "Creating RDP file to access the DC VM" -Verbose

            # Create an RDP file on the desktop to easily remotely connect into the DC
            if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
                $azureUsername = $($Admincreds.UserName)
                $desktopPath = "C:\Users\$azureUsername\Desktop"
                $rdpConfigPath = "$workshopPath\$vmPrefix-DC.rdp"
            }
            else {
                $desktopPath = [Environment]::GetFolderPath("Desktop")
                $rdpConfigPath = "$desktopPath\$vmPrefix-DC.rdp"
            }

            Write-Verbose "RDP file path: $rdpConfigPath" -Verbose
        
            # Create RDP file for the DC VM
            Script "Download RDP File" {
                GetScript  = {
                    Write-Verbose "Checking if RDP file exists at $Using:rdpConfigPath" -Verbose
                    $result = Test-Path -Path "$Using:rdpConfigPath"
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Downloading RDP file from $Using:rdpConfigUri to $Using:rdpConfigPath" -Verbose
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri "$Using:rdpConfigUri" -OutFile "$Using:rdpConfigPath" -UseBasicParsing
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]UpdateDNSRecords"
            }

            # Update the RDP file with customized values for the environment
            Write-Verbose "Editing RDP file to include the VM IP address and username" -Verbose
            Script "Edit RDP file" {
                GetScript  = {
                    Write-Verbose "Checking if RDP file exists at $Using:rdpConfigPath and when it was last updated" -Verbose
                    $result = ((Get-Item $Using:rdpConfigPath).LastWriteTime -ge (Get-Date))
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Write-Verbose "Editing RDP file at $Using:rdpConfigPath" -Verbose
                    $vmIpAddress = (Get-VMNetworkAdapter -Name 'Internet' -VMName "$Using:vmPrefix-DC").IpAddresses | Where-Object { $_ -notmatch ':' }
                    Write-Verbose "VM IP Address: $vmIpAddress" -Verbose
                    $rdpConfigFile = Get-Content -Path "$Using:rdpConfigPath"
                    $rdpConfigFile = $rdpConfigFile.Replace("<<VM_IP_Address>>", $vmIpAddress)
                    Write-Verbose "RDP file updated with IP address: $vmIpAddress" -Verbose
                    $rdpConfigFile = $rdpConfigFile.Replace("<<rdpUserName>>", $Using:msLabUsername)
                    Write-Verbose "RDP file updated with username: $Using:msLabUsername" -Verbose
                    Out-File -FilePath "$Using:rdpConfigPath" -InputObject $rdpConfigFile -Force
                    Write-Verbose "RDP file saved at $Using:rdpConfigPath" -Verbose
                }
                TestScript = {
                
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Download RDP File"
            }

            # If this is in Azure, create a RunOnce that will copy the RDP file to the user's desktop

            if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
                Write-Verbose "Creating RunOnce to copy the RDP file to the user's desktop" -Verbose
                Script "Create RDP RunOnce" {
                    GetScript  = {
                        Write-Verbose "Checking if RunOnce registry key exists" -Verbose
                        $result = [bool] (Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name '!CopyRDPFile' -ErrorAction SilentlyContinue)
                        return @{ 'Result' = $result }
                    }
                    SetScript  = {
                        Write-Verbose "Creating RunOnce registry key to copy the RDP file to the user's desktop" -Verbose
                        $command = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -command `"Copy-Item -Path `'$Using:rdpConfigPath`' -Destination `'$Using:desktopPath`' -Force`""
                        Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name '!CopyRDPFile' `
                            -Value $command
                    }
                    TestScript = {   
                        $state = [scriptblock]::Create($GetScript).Invoke()
                        return $state.Result
                    }
                    DependsOn  = "[Script]Edit RDP File"
                }
            }
        }
        catch {
            Write-Verbose "An error has occured during the installation process." -Verbose
            Write-Verbose "Generating log files and storing them in C:\AzLWorkshopLogs" -Verbose
            # Need to find latest JSON file and convert to log file
            $jsonFiles = Get-ChildItem -Path "C:\Windows\system32\configuration\configurationstatus\*.json"
            foreach ($jsonFile in $jsonFiles) {
                # Copy the JSON file to the AzLWorkshopLogs folder
                Write-Verbose "Copying JSON file: $($jsonFile.FullName) to C:\AzLWorkshopLogs\$($jsonFile.Name)" -Verbose
                Copy-Item -Path $jsonFile.FullName -Destination "C:\AzLWorkshopLogs\$($jsonFile.Name)" -Force
            }
            Write-Verbose "Message => $_`n" -Verbose
        }
        finally {
            Write-Verbose ("Ending Script: " + (Get-Date).ToString("yyyyMMddHHmmss")) -Verbose
            Stop-Transcript
        }
    }
}