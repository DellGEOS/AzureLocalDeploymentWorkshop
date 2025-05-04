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
        [String]$customDNSForwarders
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

        # Set the external endpoints for downloads
        [String]$mslabUri = "https://aka.ms/mslab/download"
        [String]$wsIsoUri = "https://go.microsoft.com/fwlink/p/?LinkID=2195280" # Windows Server 2022
        # [String]$wsIsoUri = "https://go.microsoft.com/fwlink/p/?LinkID=2293312" # Windows Server 2025
        [String]$azureLocalIsoUri = "https://aka.ms/HCIReleaseImage/2504"
        [String]$labConfigUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/labconfig/AzureLocalLabConfig.ps1"
        [String]$rdpConfigUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/rdp/rdpbase.rdp"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        if (!$customRdpPort) {
            $customRdpPort = 3389
        }

        # Set the VM prefix based on the current date
        # This is used to create unique VM names for the Azure Local machines
        $vmPrefix = (Get-Date -UFormat %d%b%y).ToUpper()

        # Calculate the number of Azure Local machines based on the architecture
        $azureLocalMachines = if ($azureLocalArchitecture -eq "Single Machine") { 1 } else { [INT]$azureLocalArchitecture.Substring(0, 1) }

        # Calculate Host Memory Sizing to account for oversizing
        [INT]$totalFreePhysicalMemory = Get-CimInstance Win32_OperatingSystem -Verbose:$false | ForEach-Object { [math]::round($_.FreePhysicalMemory / 1MB) }
        [INT]$totalInfraMemoryRequired = "4"
        [INT]$memoryAvailable = [INT]$totalFreePhysicalMemory - [INT]$totalInfraMemoryRequired
        [INT]$azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
        # If the available memory is less than the required memory, adjust the memory to the next lowest option
        if ($azureLocalMachineMemoryRequired -ge $memoryAvailable) {
            $memoryOptions = 48, 32, 24, 16
            $x = $memoryOptions.IndexOf($azureLocalMachineMemory) + 1
            while ($x -ne -1 -and $azureLocalMachineMemoryRequired -ge $memoryAvailable -and $x -lt $memoryOptions.Count) {
                Write-Host "Memory required: $($azureLocalMachineMemoryRequired)GB, memory available: $($memoryAvailable)GB, New memory option: $($memoryOptions[$x])GB"
                Write-Host "Testing memory at $($memoryOptions[$x])GB per AzL VM and trying again"
                $azureLocalMachineMemory = $memoryOptions[$x]
                $azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
                $x++
            }
            # If the available memory is still less than the required memory, reduce the $azureLocalMachines count by 1 in a loop
            while ($azureLocalMachineMemoryRequired -ge $memoryAvailable -and $azureLocalMachines -gt 1) {
                Write-Host "Memory required: $($azureLocalMachineMemoryRequired)GB, memory available: $($memoryAvailable)GB, reducing AzL VM count by 1"
                $azureLocalMachines--
                $azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
                $nodesReduced = $true
            }
            if ($nodesReduced) {
                # Need to reset the $azureLocalArchitecture to reflect a new number of $azureLocalMachines
                # if $azureLocalArchitecture is not "Single Machine", take the existing $azureLocalArchitecture and replace the first character with the new $azureLocalMachines count
                if ($azureLocalArchitecture -ne "Single Machine") {
                    # Need to ensure you can transition to a valid architecture
                    # If the new $azureLocalMachines count is 1, the architecture should be "Single Machine"
                    if ($azureLocalMachines -eq 1) {
                        $azureLocalArchitecture = "Single Machine"
                        Write-Host "Switching architecture to Single Machine to fit memory requirements"
                    }
                    # if the $azureLocalArchitecture includes "Switchless Dual-Link", the new architecture should also include "Dual-Link"
                    elseif ($azureLocalArchitecture -like "*Dual-Link*") {
                        $azureLocalArchitecture = "$($azureLocalMachines)-Machine Switchless Dual-Link"
                        Write-Host "Switching architecture to $($azureLocalMachines)-Machine Switchless Dual-Link to fit memory requirements"
                    }
                    # if the $azureLocalArchitecture includes "Switchless Single-Link", the new architecture should change to "Dual-Link"
                    elseif ($azureLocalArchitecture -like "*Single-Link*") {
                        $azureLocalArchitecture = "$($azureLocalMachines)-Machine Switchless Dual-Link"
                        Write-Host "Switching architecture to $($azureLocalMachines)-Machine Switchless Dual-Link to fit memory requirements"
                    }
                    else {
                        # If the $azureLocalArchitecture includes "Fully-Converged" or "Non-Converged", the new architecture should just reduced the number of machines
                        $azureLocalArchitecture = "$($azureLocalMachines)-Machine $($azureLocalArchitecture.Split(" ", 2)[1])"
                    }
                }
            }
        }

        # Determine vSwitch name and allowed VLANs based on azureLocalArchitecture
        $vSwitchName = if ($azureLocalArchitecture -like "*Fully-Converged*") { "Mgmt_Compute_Stor" } else { "Mgmt_Compute" }
        $allowedVlans = if ($azureLocalArchitecture -like "*Fully-Converged*") { "1-10,711-719" } else { "1-10" }

        # Set the workshop path based on the current machine - If this is running in Azure, set the workshop path to V:\AzLWorkshop
        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
            # If this in Azure, lock things in specifically
            $targetDrive = "V"
            $workshopPath = "$targetDrive" + ":\AzLWorkshop"
        }
        else {
            $workshopPath = "$workshopPath" + "\AzLWorkshop"
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

        # Set the PS gallery as trusted to allow for DSC module installation
        Script "SetPSGalleryTrusted" {
            GetScript  = {
                $result = (Get-PSRepository -Name PSGallery).InstallationPolicy -eq 'Trusted'
                return @{ 'Result' = $result }
            }
            SetScript  = {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
        }
        
        # Ensure that nuget is installed for the PSGallery to work properly
        Script "InstallNuget" {
            GetScript  = {
                $result = (Get-PackageProvider -Name NuGet -ForceBootstrap).Name -eq 'NuGet'
                return @{ 'Result' = $result }
            }
            SetScript  = {
                Install-PackageProvider -Name NuGet -ForceBootstrap
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
        }

        # Install the PowerShellGet package provider over the top of the default version 1.0.0.1 to allow for the Evergreen module to be installed
        Script "InstallPowerShellGet" {
            GetScript  = {
                $installedVersion = (Get-PackageProvider -Name PowerShellGet -ErrorAction SilentlyContinue).Version
                $result = $installedVersion -and ($installedVersion -ne '1.0.0.1')
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $installedVersion = (Get-PackageProvider -Name PowerShellGet -ErrorAction SilentlyContinue).Version
                if ($installedVersion -eq '1.0.0.1') {
                    Write-Host "PowerShellGet version is 1.0.0.1. Installing the latest version..."
                    Install-PackageProvider -Name PowerShellGet -Force
                    # Reload the module to ensure the latest version is used
                    Remove-Module PowerShellGet -Force
                    Import-Module PowerShellGet -Force
                    Write-Host "PowerShellGet has been updated to the latest version."
                }
                else {
                    Write-Host "PowerShellGet is already up-to-date."
                }
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
        }
        
        # Install the Evergreen module to allow for Edge to be installed later
        Script "InstallEvergreen" {
            GetScript  = {
                $result = (Get-Module -Name Evergreen).Name -eq 'Evergreen'
                return @{ 'Result' = $result }
            }
            SetScript  = {
                Install-Module -Name Evergreen -Force
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
        }

        # If this is in Azure, configure Storage Spaces Direct and then create the required folders
        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {

            Script StoragePool {
                SetScript  = {
                    New-StoragePool -FriendlyName WorkshopPool -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $true)
                }
                TestScript = {
                (Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName WorkshopPool).OperationalStatus -eq 'OK'
                }
                GetScript  = {
                    @{Ensure = if ((Get-StoragePool -FriendlyName WorkshopPool).OperationalStatus -eq 'OK') { 'Present' } Else { 'Absent' } }
                }
            }
            Script VirtualDisk {
                SetScript  = {
                    $disks = Get-StoragePool -FriendlyName WorkshopPool -IsPrimordial $False | Get-PhysicalDisk
                    $diskNum = $disks.Count
                    New-VirtualDisk -StoragePoolFriendlyName WorkshopPool -FriendlyName WorkshopDisk -ResiliencySettingName Simple -NumberOfColumns $diskNum -UseMaximumSize
                }
                TestScript = {
                (Get-VirtualDisk -ErrorAction SilentlyContinue -FriendlyName WorkshopDisk).OperationalStatus -eq 'OK'
                }
                GetScript  = {
                    @{Ensure = if ((Get-VirtualDisk -FriendlyName WorkshopDisk).OperationalStatus -eq 'OK') { 'Present' } Else { 'Absent' } }
                }
                DependsOn  = "[Script]StoragePool"
            }
            Script FormatDisk {
                SetScript  = {
                    $vDisk = Get-VirtualDisk -FriendlyName WorkshopDisk
                    if ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'raw') {
                        $vDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter $Using:targetDrive -UseMaximumSize | Format-Volume -NewFileSystemLabel AzLWorkshop -AllocationUnitSize 64KB -FileSystem NTFS
                    }
                    elseif ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'GPT') {
                        $vDisk | Get-Disk | New-Partition -DriveLetter $Using:targetDrive -UseMaximumSize | Format-Volume -NewFileSystemLabel AzLWorkshop -AllocationUnitSize 64KB -FileSystem NTFS
                    }
                }
                TestScript = { 
                (Get-Volume -ErrorAction SilentlyContinue -FileSystemLabel AzLWorkshop).FileSystem -eq 'NTFS'
                }
                GetScript  = {
                    @{Ensure = if ((Get-Volume -FileSystemLabel AzLWorkshop).FileSystem -eq 'NTFS') { 'Present' } Else { 'Absent' } }
                }
                DependsOn  = "[Script]VirtualDisk"
            }

            File "WorkshopFolder" {
                Type            = 'Directory'
                DestinationPath = $workshopPath
                DependsOn       = "[Script]FormatDisk"
            }
        }
        else {
            # Running on-prem, outside of Azure
            File "WorkshopFolder" {
                Type            = 'Directory'
                DestinationPath = $workshopPath
            }
        }

        File "ISOpath" {
            DestinationPath = $isoPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]WorkshopFolder"
        }

        File "flagsPath" {
            DestinationPath = $flagsPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]WorkshopFolder"
        }

        File "WSISOpath" {
            DestinationPath = $wsIsoPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]ISOpath"
        }

        File "azLocalIsoPath" {
            DestinationPath = $azLocalIsoPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]ISOpath"
        }

        File "ParentDisks" {
            DestinationPath = $parentDiskPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]WorkshopFolder"
        }

        File "Updates" {
            DestinationPath = $updatePath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]ParentDisks"
        }

        File "CU" {
            DestinationPath = $cuPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]Updates"
        }

        File "SSU" {
            DestinationPath = $ssuPath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[File]Updates"
        }

        # Download the latest MSlab files - this is a zip file that contains the MSLab scripts and files
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

        # Extract the MSLab files to the workshop folder
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

        # Edit the CreateParentDisks script to replace the default VHD names with the custom names to allow flexibility in deployment
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

        # Download the latest customized LabConfig file - this is a script that contains the configuration for the MSLab deployment
        Script "Replace LabConfig" {
            GetScript  = {
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

        # Replace the LabConfig file with the customized version using variables specific to this deployment
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

        # If the user has not provided a Windows Server ISO, download one
        Script "Download Windows Server ISO" {
            GetScript  = {
                $result = Test-Path -Path $Using:wsISOLocalPath
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $ProgressPreference = 'SilentlyContinue'
                Start-BitsTransfer -Source $Using:wsIsoUri -Destination $Using:wsISOLocalPath   
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]WSISOpath"
        }

        # If the user has not provides an Azure Local ISO, download the latest one.
        Script "Download Azure Local ISO" {
            GetScript  = {
                $result = Test-Path -Path $Using:azLocalISOLocalPath
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $ProgressPreference = 'SilentlyContinue'
                Start-BitsTransfer -Source $Using:azureLocalIsoUri -Destination $Using:azLocalISOLocalPath            
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
                    $result = ((Test-Path -Path "$Using:cuPath\*" -Include "*.msu") -or (Test-Path -Path "$Using:cuPath\*" -Include "NoUpdateDownloaded.txt"))
                }
                else {
                    $result = (Test-Path -Path "$Using:cuPath\*" -Include "NoUpdateDownloaded.txt")
                }
                return @{ 'Result' = $result }
            }
            SetScript  = {
                if ($Using:updateImages -eq "Yes") {
                    $ProgressPreference = 'SilentlyContinue'
                    $cuSearchString = "Cumulative Update for Microsoft server operating system*version 23H2 for x64-based Systems"
                    $cuID = "Microsoft Server operating system-23H2"
                    Write-Host "Looking for updates that match: $cuSearchString and $cuID"
                    $cuUpdate = Get-MSCatalogUpdate -Search $cuSearchString -ErrorAction Stop | Where-Object Products -eq $cuID | Where-Object Title -like "*$($cuSearchString)*" | Select-Object -First 1
                    if ($cuUpdate) {
                        Write-Host "Found the latest update: $($cuUpdate.Title)"
                        Write-Host "Downloading..."
                        $cuUpdate | Save-MSCatalogUpdate -Destination $Using:cuPath -AcceptMultiFileUpdates
                    }
                    else {
                        Write-Host "No updates found, moving on..."
                        $NoCuFlag = "$Using:cuPath\NoUpdateDownloaded.txt"
                        New-Item $NoCuFlag -ItemType file -Force
                    }
                }
                else {
                    Write-Host "User selected to not update images with latest updates."
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

        # If the user has chosen to update their images, download the latest Servicing Stack Update
        Script "Download SSU" {
            GetScript  = {
                if ($Using:updateImages -eq "Yes") {
                    $result = ((Test-Path -Path "$Using:ssuPath\*" -Include "*.msu") -or (Test-Path -Path "$Using:ssuPath\*" -Include "NoUpdateDownloaded.txt"))
                }
                else {
                    $result = (Test-Path -Path "$Using:ssuPath\*" -Include "NoUpdateDownloaded.txt")
                }
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $ProgressPreference = 'SilentlyContinue'
                if ($Using:updateImages -eq "Yes") {
                    $ssuSearchString = "Servicing Stack Update for Microsoft server operating system*version 23H2 for x64-based Systems"
                    $ssuID = "Microsoft Server operating system-23H2"
                    Write-Host "Looking for updates that match: $ssuSearchString and $ssuID"
                    $ssuUpdate = Get-MSCatalogUpdate -Search $ssuSearchString -ErrorAction Stop | Where-Object Products -eq $ssuID | Select-Object -First 1
                    if ($ssuUpdate) {
                        Write-Host "Found the latest update: $($ssuUpdate.Title)"
                        Write-Host "Downloading..."
                        $ssuUpdate | Save-MSCatalogUpdate -Destination $Using:ssuPath
                    }
                    else {
                        Write-Host "No updates found"
                        $NoSsuFlag = "$Using:ssuPath\NoUpdateDownloaded.txt"
                        New-Item $NoSsuFlag -ItemType file -Force
                    }
                }
                else {
                    Write-Host "User selected to not update images with latest updates."
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

        # If this is a Windows Server OS, update the Windows Defender exclusions to include the workshop path
        if ((Get-WmiObject -Class Win32_OperatingSystem).ProductType -eq "3") {

            Script defenderExclusions {
                GetScript  = {
                    $exclusionPath = $Using:workshopPath
                    @{Ensure = if ((Get-MpPreference).ExclusionPath -contains "$exclusionPath") { 'Present' } Else { 'Absent' } }
                }
                SetScript  = {
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
            Registry "Disable Internet Explorer ESC for Admin" {
                Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
                Ensure    = 'Present'
                ValueName = "IsInstalled"
                ValueData = "0"
                ValueType = "Dword"
            }
    
            Registry "Disable Internet Explorer ESC for User" {
                Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
                Ensure    = 'Present'
                ValueName = "IsInstalled"
                ValueData = "0"
                ValueType = "Dword"
            }
            
            Registry "Disable Server Manager WAC Prompt" {
                Key       = "HKLM:\SOFTWARE\Microsoft\ServerManager"
                Ensure    = 'Present'
                ValueName = "DoNotPopWACConsoleAtSMLaunch"
                ValueData = "1"
                ValueType = "Dword"
            }
    
            Registry "Disable Network Profile Prompt" {
                Key       = 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff'
                Ensure    = 'Present'
                ValueName = ''
            }

            if ($customRdpPort -ne "3389") {

                Registry "Set Custom RDP Port" {
                    Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
                    ValueName = "PortNumber"
                    ValueData = "$customRdpPort"
                    ValueType = 'Dword'
                }
            
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

        # Enable and configure Hyper-V
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem

        # First, check if $osInfo.BuildNumber is greater than or equal to 26100 and $osInfo.ProductType -eq 3
        if ($osInfo.BuildNumber -ge 26100 -and $osInfo.ProductType -eq 3) {
            WindowsOptionalFeature "Hyper-V" {
                Name   = "Microsoft-Hyper-V"
                Ensure = "Enable"
            }
            VMHost "ConfigureHyper-V" {
                IsSingleInstance          = 'yes'
                EnableEnhancedSessionMode = $true
                DependsOn                 = "[WindowsOptionalFeature]Hyper-V"
            }
        }
        # Catch for Windows Server OS 2022
        elseif ($osInfo.ProductType -eq 3) {
            WindowsFeature "Hyper-V" {
                Name   = "Hyper-V"
                Ensure = "Present"
            }
            WindowsFeature "RSAT-Hyper-V-Tools" {
                Name      = "RSAT-Hyper-V-Tools"
                Ensure    = "Present"
                DependsOn = "[WindowsFeature]Hyper-V" 
            }
            VMHost "ConfigureHyper-V" {
                IsSingleInstance          = 'yes'
                EnableEnhancedSessionMode = $true
                DependsOn                 = "[WindowsFeature]Hyper-V"
            }
        }
        # Catch for Windows Client OS
        else {
            WindowsOptionalFeature "Hyper-V" {
                Name   = "Microsoft-Hyper-V-All"
                Ensure = "Enable"
            }
        }

        #### Start Azure Local VHDx Creation ####
        Script "CreateAzLocalDisk" {
            GetScript  = {
                $result = (Test-Path -Path $Using:azLocalVhdPath) -and (Test-Path -Path "$Using:flagsPath\AzLVhdComplete.txt")
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $scratchPath = "$Using:workshopPath\Scratch"
                New-Item -ItemType Directory -Path "$scratchPath" -Force | Out-Null
                
                # Determine if any SSUs are available
                $ssu = Test-Path -Path "$Using:ssuPath\*" -Include "*.msu"

                # Call Convert-WindowsImage to handle creation of VHDX file
                if ($ssu) {
                    Convert-WindowsImage -SourcePath $Using:azLocalISOLocalPath -SizeBytes 127GB -VHDPath $Using:azLocalVhdPath `
                        -VHDFormat VHDX -VHDType Dynamic -VHDPartitionStyle GPT -Package $Using:ssuPath -TempDirectory $Using:scratchPath -Verbose
                }
                else {
                    Convert-WindowsImage -SourcePath $Using:azLocalISOLocalPath -SizeBytes 127GB -VHDPath $Using:azLocalVhdPath `
                        -VHDFormat VHDX -VHDType Dynamic -VHDPartitionStyle GPT -TempDirectory $Using:scratchPath -Verbose
                }

                Write-Host "Sleeping for 30 seconds to allow for VHD to be dismounted..."
                Start-Sleep -Seconds 30

                # Remove the scratch folder
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

        # Start MSLab Deployment by calling Prereq script to automate setup
        # https://github.com/microsoft/MSLab/blob/master/Scripts/1_Prereq.ps1
        Script "MSLab Prereqs" {
            GetScript  = {
                $result = (Test-Path -Path "$Using:flagsPath\PreReqComplete.txt")
                return @{ 'Result' = $result }
            }
            SetScript  = {
                Set-Location "$Using:workshopPath"
                .\1_Prereq.ps1
                $preReqFlag = "$Using:flagsPath\PreReqComplete.txt"
                New-Item $preReqFlag -ItemType file -Force
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Edit LabConfig", "[Script]CreateAzLocalDisk"
        }

        # Create the Windows Server VHDx files - GUI and Core
        Script "MSLab CreateParentDisks" {
            GetScript  = {
                $result = (Test-Path -Path "$Using:flagsPath\CreateDisksComplete.txt")
                return @{ 'Result' = $result }
            }
            SetScript  = {
                Set-Location "$Using:workshopPath"
                .\2_CreateParentDisks.ps1
                $parentDiskFlag = "$Using:flagsPath\CreateDisksComplete.txt"
                New-Item $parentDiskFlag -ItemType file -Force
            }
            TestScript = {  
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]MSLab Prereqs"
        }

        # Trigger the MSLab deployment by calling Deploy.ps1, which pulls in the customized LabConfig.ps1
        Script "MSLab DeployEnvironment" {
            GetScript  = {
                $result = (Test-Path -Path "$Using:flagsPath\DeployComplete.txt")
                return @{ 'Result' = $result }
            }
            SetScript  = {
                Set-Location "$Using:workshopPath"
                .\Deploy.ps1
                $deployFlag = "$Using:flagsPath\DeployComplete.txt"
                New-Item $deployFlag -ItemType file -Force
                Write-Host "Sleeping for 2 minutes to allow for AzL nested hosts to reboot as required"
                Start-Sleep -Seconds 120
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]MSLab CreateParentDisks"
        }

        <#
        Create a switch statement to populate the $vms parameter based on the the $azureLocalMachines number
        $vms should be an array of strings containing the names of the VMs that will be created.
        The VM name that is used during the deployment is based on the $vmPrefix variable.
        This is set in the labconfig file and should only include the AzL VMs and not include the DC or WAC VMs.
        The range of $azureLocalMachines is 1-4
        #>

        # Ensure that the DC accepts RDP access
        Script "Enable RDP on DC" {
            GetScript  = {
                $vmIpAddress = (Get-VMNetworkAdapter -Name 'Internet' -VMName "$Using:vmPrefix-DC").IpAddresses | Where-Object { $_ -notmatch ':' }
                if ((Test-NetConnection $vmIpAddress -CommonTCPPort rdp).TcpTestSucceeded -eq "True") {
                    $result = $true
                }
                else {
                    $result = $false
                }
                return @{ 'Result' = $result }
            }
            SetScript  = {
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

        # If the user has chosen to deploy WAC, need to trigger an installation of the latest WAC build
        if ($installWAC -eq 'Yes') {
            Script "Deploy WAC" {
                GetScript  = {
                    $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    $result = (Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                            Write-Host "Checking if Windows Admin Center is installed and running..."
                            [bool] (((Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" })`
                                        -and (Get-Service -Name "WindowsAdminCenterAccountManagement" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" }))`
                                    -and (Test-NetConnection -ComputerName "localhost" -Port 443 -ErrorAction SilentlyContinue).TcpTestSucceeded)
                        }) -and (Test-Path -Path "$Using:flagsPath\DeployWACComplete.txt")
                    # Write a message if the result is true, that installation must already be complete
                    if ($result) {
                        Write-Host "Windows Admin Center is already installed and running."
                    }
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    if (!(Test-Path -Path "$Using:flagsPath\StartWACDeploy.txt")) {
                        Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                            if (-not (Test-Path -Path "C:\WindowsAdminCenter.exe")) {
                                $ProgressPreference = 'SilentlyContinue'
                                Write-Host "Downloading Windows Admin Center..."
                                Invoke-WebRequest -Uri 'https://aka.ms/WACDownload' -OutFile "C:\WindowsAdminCenter.exe" -UseBasicParsing
                            }
                            Write-Host "Installing Windows Admin Center - this can take up to 10 minutes..."
                            Start-Process -FilePath 'C:\WindowsAdminCenter.exe' -ArgumentList '/VERYSILENT /log=C:\WindowsAdminCenter.log'
                            Write-Host "Windows Admin Center installation started. Checking again in 3 minutes."
                        }
                        # Create a flag to indicate the installation has started
                        $wacStartedFlag = "$Using:flagsPath\StartWACDeploy.txt"
                        New-Item $wacStartedFlag -ItemType file -Force | Out-Null
                        Start-Sleep -Seconds 180
                    }
                    else {
                        Write-Host "Windows Admin Center installation has already started. Moving on to check for completion."
                    }
                    if (!(Test-Path -Path "$Using:flagsPath\DeployWACComplete.txt")) {
                        Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                            # Start checking for the installation to complete by checking for the log file for the "Log closed." message. This should run for a maximum of 10 minutes
                            $timeout = 600
                            $logCheck = Get-ChildItem -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
                            while (-not $logCheck) {
                                Write-Host "Checking every 20 seconds for Windows Admin Center installation completion..."
                                Start-Sleep -Seconds 20
                                $timeout -= 20
                                if ($timeout -le 0) {
                                    throw "Windows Admin Center installation timed out."
                                }
                                $logCheck = Get-ChildItem -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
                            }
                            # Check the Windows Admin Center key services using a foreach loop
                            $services = @("WindowsAdminCenter", "WindowsAdminCenterAccountManagement")
                            $timeout = 600
                            foreach ($service in $services) {
                                $serviceStatus = Get-Service $service -ErrorAction SilentlyContinue
                                while ($serviceStatus -and $serviceStatus.Status -ne "Running") {
                                    Write-Host "Windows Admin Center is installed but the $service service is not running. Attempting to start the service."
                                    Start-Service $service -Confirm:$false -ErrorAction SilentlyContinue
                                    if ((Get-Service $service -ErrorAction SilentlyContinue).Status -eq "Running") {
                                        Write-Host "$service service started successfully."
                                        Write-Host "Windows Admin Center is installed and running."
                                        break
                                    }
                                    else {
                                        Write-Host "Waiting 20 seconds for $service service to start."
                                        Start-Sleep -Seconds 20
                                        $timeout -= 20
                                        if ($timeout -le 0) {
                                            throw "Windows Admin Center installation timed out during service enablement."
                                        }
                                    }
                                }
                            }
                            $timeout = 600
                            Write-Host "Checking if WAC is responding on port 443."
                            while (!((Test-NetConnection -ComputerName "localhost" -Port 443 -ErrorAction SilentlyContinue).TcpTestSucceeded)) {
                                Write-Host "WAC is not yet responding on port 443. Waiting 20 seconds"
                                Start-Sleep -Seconds 20
                                $timeout -= 20
                                if ($timeout -le 0) {
                                    throw "Windows Admin Center installation timed out."
                                }
                            }
                        }
                        # Final check to see if WAC is working
                        $finalWACCheck = Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                            (Test-NetConnection -ComputerName "localhost" -Port 443 -ErrorAction SilentlyContinue).TcpTestSucceeded
                        }
                        if ($finalWACCheck) {
                            Write-Host "Windows Admin Center is now accessible on port 443."
                            Write-Host "WAC Deployment complete!"
                            $wacCompletedFlag = "$Using:flagsPath\DeployWACComplete.txt"
                            New-Item $wacCompletedFlag -ItemType file -Force | Out-Null
                        }
                        else {
                            throw "Windows Admin Center installation failed. Unable to access WAC on port 443."
                        }
                    }
                    else {
                        Write-Host "Windows Admin Center installation has already completed."
                        return
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
            Write-Host "Skipping Windows Admin Center deployment as it was not selected."
        }

        # Quick switch to determine the correct dependsOn for when to update the DC
        $updateDCDependsOn = switch ($installWAC) {
            'Yes' { "[Script]Deploy WAC" }
            'No' { "[Script]Enable RDP on DC" }
        }

        Script "Update DC" {
            GetScript  = {
                Start-Sleep -Seconds 10
                $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                $result = Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                    $wallpaperSet = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper -eq "C:\Windows\Web\Wallpaper\Windows\azlwallpaper.png"
                    $certExists = (Get-ChildItem Cert:\LocalMachine\Root\ | Where-Object subject -like "CN=WindowsAdminCenterSelfSigned")
                    $ieEscAdminDisabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -ErrorAction SilentlyContinue).IsInstalled -eq 0
                    $ieEscUserDisabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -ErrorAction SilentlyContinue).IsInstalled -eq 0
                    $wacPromptDisabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotPopWACConsoleAtSMLaunch' -ErrorAction SilentlyContinue).DoNotPopWACConsoleAtSMLaunch -eq 1
                    $networkProfilePromptDisabled = Test-Path 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff'
                    return ($wallpaperSet -and $certExists -and $ieEscAdminDisabled -and $ieEscUserDisabled -and $wacPromptDisabled -and $networkProfilePromptDisabled)
                }
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                    # Update wallpaper
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/media/azlwallpaper.png' -OutFile "C:\Windows\Web\Wallpaper\Windows\azlwallpaper.png" -UseBasicParsing
                    Set-GPPrefRegistryValue -Name "Default Domain Policy" -Context User -Action Replace -Key "HKCU\Control Panel\Desktop" -ValueName Wallpaper -Value "C:\Windows\Web\Wallpaper\Windows\azlwallpaper.png" -Type String
                    # if WAC VM exists and is running, update WAC certificate
                    $GatewayServerName = "WAC"
                    Start-Sleep 10
                    $cert = Invoke-Command -ComputerName $GatewayServerName -ScriptBlock { Get-ChildItem Cert:\LocalMachine\My\ | Where-Object subject -eq "CN=WindowsAdminCenterSelfSigned" }
                    if ($cert) {
                        Write-Host "Exporting WAC certificate from $GatewayServerName onto DC."
                        $cert | Export-Certificate -FilePath $env:TEMP\WACCert.cer
                        Import-Certificate -FilePath $env:TEMP\WACCert.cer -CertStoreLocation Cert:\LocalMachine\Root\
                    }
                    # Disable Internet Explorer ESC for Admin
                    Write-Host "Disabling Internet Explorer Enhanced Security Configuration for Admin."
                    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0 -Type Dword
                    # Disable Internet Explorer ESC for User
                    Write-Host "Disabling Internet Explorer Enhanced Security Configuration for User."
                    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0 -Type Dword
                    # Disable Server Manager WAC Prompt
                    Write-Host "Disabling Server Manager WAC Prompt."
                    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotPopWACConsoleAtSMLaunch' -Value 1 -Type Dword
                    # Disable Network Profile Prompt
                    Write-Host "Disabling Network Profile Prompt."
                    New-Item -Path 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff' -Force | Out-Null
                    # Trigger an explorer restart to apply the wallpaper
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 5
                    # Find the latest path to current Microsoft Edge Binaries
                    $edgeURI = (Get-EvergreenApp -Name MicrosoftEdge | `
                            Where-Object { $_.Architecture -eq "x64" -and $_.Channel -eq "Stable" -and $_.Release -eq "Enterprise" }).URI
                    # Download the file using bits transfer if the file doesn't already exist
                    $edgePath = "C:\MicrosoftEdgeEnterpriseX64.msi"
                    if (!(Test-Path -Path "$edgePath")) {
                        Write-Host "Downloading latest Microsoft Edge Enterprise MSI..."
                        $ProgressPreference = 'SilentlyContinue'   
                        Start-BitsTransfer -Source $edgeURI -Destination $edgePath -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Host "Microsoft Edge Enterprise MSI already exists. Skipping download."
                    }
                    # Install the file using msiexec
                    Write-Host "Installing Microsoft Edge Enterprise..."
                    Start-Process msiexec.exe -ArgumentList "/i $edgePath /quiet /norestart" -Wait -NoNewWindow
                }
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = $updateDCDependsOn
        }

        # Create a switch statement to populate the $vms parameter based on the $azureLocalMachines number
        $vms = @()
        switch ($azureLocalMachines) {
            1 { $vms = @("AzL1") }
            2 { $vms = @("AzL1", "AzL2") }
            3 { $vms = @("AzL1", "AzL2", "AzL3") }
            4 { $vms = @("AzL1", "AzL2", "AzL3", "AzL4") }
        }

        # Create the Host vSwitches and vNICs to align with the desired azureLocalArchitecture
        if ($azureLocalArchitecture -like "*Non-Converged") {
            VMSwitch "NonConvergedSwitch" {
                Name      = "Storage"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }
            # Create 2 storage vNICs per VM
            foreach ($vm in $vms) {
                VMNetworkAdapter "$($vm)Storage1" {
                    Id         = "$vm-Storage1-NIC"
                    VMName     = "$vmPrefix-$vm"
                    Name       = "Storage1"
                    SwitchName = "Storage"
                    Ensure     = "Present"
                    DependsOn  = "[VMSwitch]NonConvergedSwitch"
                }
                VMNetworkAdapter "$($vm)Storage2" {
                    Id         = "$vm-Storage2-NIC"
                    VMName     = "$vmPrefix-$vm"
                    Name       = "Storage2"
                    SwitchName = "Storage"
                    Ensure     = "Present"
                    DependsOn  = "[VMSwitch]NonConvergedSwitch"
                }
            }
        }
        elseif ($azureLocalArchitecture -eq "2-Machine Switchless Dual-Link") {
            # Create 2 private vSwitches named "Storage1" and "Storage2"
            VMSwitch "CreateStorageSwitch1-2" {
                Name      = "Storage1-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-1" {
                Name      = "Storage2-1"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }
            foreach ($vm in $vms) {
                VMNetworkAdapter "$($vm)Storage1-2" {
                    Id         = "$vm-Storage1-2-NIC"
                    VMName     = "$vmPrefix-$vm"
                    Name       = "Storage1-2"
                    SwitchName = "Storage1-2"
                    Ensure     = "Present"
                    DependsOn  = "[VMSwitch]CreateStorageSwitch1-2"
                }
                VMNetworkAdapter "$($vm)Storage2-1" {
                    Id         = "$vm-Storage2-1-NIC"
                    VMName     = "$vmPrefix-$vm"
                    Name       = "Storage2-1"
                    SwitchName = "Storage2-1"
                    Ensure     = "Present"
                    DependsOn  = "[VMSwitch]CreateStorageSwitch2-1"
                }
            }
        }
        
        # Create vSwitch and vNICs for 3-machine switchless single-link architectures
        elseif ($azureLocalArchitecture -eq "3-Machine Switchless Single-Link") {
            # Create 1 vSwitch per VM named "Storage" plus the Number of the 2 nodes that it will connect between (e.g. Storage1-2)
            VMSwitch "CreateStorageSwitch1-2" {
                Name      = "Storage1-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-3" {
                Name      = "Storage2-3"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch1-3" {
                Name      = "Storage1-3"
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
                    VMNetworkAdapter "AzL$machine$($nic)" {
                        Id         = "AzL$machine-$nic-NIC"
                        VMName     = "$vmPrefix-AzL$machine"
                        Name       = $nic
                        SwitchName = $nic
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]CreateStorageSwitch1-2", "[VMSwitch]CreateStorageSwitch2-3", "[VMSwitch]CreateStorageSwitch1-3"
                    }
                }
            }
        }

        # Create vSwitch and vNICs for 3-machine switchless dual-link architectures
        elseif ($azureLocalArchitecture -like "3-Machine Switchless Dual-Link") {
            # Create 6 private vSwitches named "Storage1-2", "Storage2-1", "Storage2-3", "Storage3-2", "Storage1-3", and "Storage3-1"
            VMSwitch "CreateStorageSwitch1-2" {
                Name      = "Storage1-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-1" {
                Name      = "Storage2-1"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-3" {
                Name      = "Storage2-3"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch3-2" {
                Name      = "Storage3-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch1-3" {
                Name      = "Storage1-3"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch3-1" {
                Name      = "Storage3-1"
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
                    VMNetworkAdapter "AzL$($machine.VM)$($nicName)" {
                        Id         = "$vmPrefix-AzL$($machine.VM)-$nicName-NIC"
                        VMName     = "$vmPrefix-AzL$($machine.VM)"
                        Name       = $nicName
                        SwitchName = $nicName
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]CreateStorageSwitch1-2", "[VMSwitch]CreateStorageSwitch2-1", "[VMSwitch]CreateStorageSwitch2-3", "[VMSwitch]CreateStorageSwitch3-2", "[VMSwitch]CreateStorageSwitch1-3", "[VMSwitch]CreateStorageSwitch3-1"
                    }
                }
            }
        }
        
        # Create vSwitch and vNICs for 4-machine switchless dual-link architectures
        elseif ($azureLocalArchitecture -like "4-Machine Switchless Dual-Link") {
            # Create 12 private vSwitches named "Storage1-2", "Storage2-1", "Storage2-3", "Storage3-2", "Storage1-3", "Storage3-1", "Storage1-4", "Storage4-1", "Storage2-4", "Storage4-2", "Storage3-4", and "Storage4-3"
            VMSwitch "CreateStorageSwitch1-2" {
                Name      = "Storage1-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-1" {
                Name      = "Storage2-1"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-3" {
                Name      = "Storage2-3"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch3-2" {
                Name      = "Storage3-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch1-3" {
                Name      = "Storage1-3"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch3-1" {
                Name      = "Storage3-1"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch1-4" {
                Name      = "Storage1-4"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch4-1" {
                Name      = "Storage4-1"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch2-4" {
                Name      = "Storage2-4"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch4-2" {
                Name      = "Storage4-2"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch3-4" {
                Name      = "Storage3-4"
                Type      = "Private"
                Ensure    = "Present"
                DependsOn = "[Script]Update DC"
            }

            VMSwitch "CreateStorageSwitch4-3" {
                Name      = "Storage4-3"
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
                    VMNetworkAdapter "AzL$($machine.VM)$($nicName)" {
                        Id         = "$vmPrefix-AzL$($machine.VM)-$nicName-NIC"
                        VMName     = "$vmPrefix-AzL$($machine.VM)"
                        Name       = $nicName
                        SwitchName = $nicName
                        Ensure     = "Present"
                        DependsOn  = "[VMSwitch]CreateStorageSwitch1-2", "[VMSwitch]CreateStorageSwitch2-1", "[VMSwitch]CreateStorageSwitch2-3", "[VMSwitch]CreateStorageSwitch3-2", "[VMSwitch]CreateStorageSwitch1-3", "[VMSwitch]CreateStorageSwitch3-1", "[VMSwitch]CreateStorageSwitch1-4", "[VMSwitch]CreateStorageSwitch4-1", "[VMSwitch]CreateStorageSwitch2-4", "[VMSwitch]CreateStorageSwitch4-2", "[VMSwitch]CreateStorageSwitch3-4", "[VMSwitch]CreateStorageSwitch4-3"
                    }
                }
            }
        }

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
                    $result = $true
                    # Retrieve the list of VMs where the name matches the $vmPrefix-AzL* pattern
                    Get-VM -Name "$Using:vmPrefix-AzL*" | ForEach-Object {
                        $nics = Get-VMNetworkAdapter -VMName $($_.Name) | Where-Object Name -like "Storage*"
                        foreach ($nic in $nics) {
                            $vlanSettings = Get-VMNetworkAdapterVlan -VMNetworkAdapterName $($nic.Name) -VMName $($_.Name)
                            if (($vlanSettings.AllowedVlanIdListString -ne "711-719") -or $vlanSettings.NativeVlanId -ne 0) {
                                $result = $false
                                Write-Host "Correct VLAN settings for $($nic.Name) on $($_.Name): $result"
                            }
                        }
                    }
                    return @{ 'Result' = $result }
                }
                SetScript  = {
                    Get-VM -Name "$Using:vmPrefix-AzL*" | ForEach-Object {
                        $nics = Get-VMNetworkAdapter -VMName $($_.Name) | Where-Object Name -like "Storage*"
                        foreach ($nic in $nics) {
                            Write-Host "Setting VLAN 711-719 on $($nic.Name) on $($_.Name)"
                            Set-VMNetworkAdapterVlan -VMNetworkAdapterName $($nic.Name) -VMName $($_.Name) -Trunk -AllowedVlanIdList "711-719" -NativeVlanId 0
                            # Enable Device Naming for the NIC
                            Set-VMNetworkAdapter -VMNetworkAdapterName $($nic.Name) -VMName $($_.Name) -DeviceNaming On
                        }
                    }
                }
                TestScript = {
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Update DC", $vLANdependsOn
            }
        }

        # Quick switch to determine the correct dependsOn for updating the AzLNicNames
        $updateAzLNicNamesDependsOn = switch ($azureLocalArchitecture) {
            { $_ -eq "Single Machine" -or $_ -like "*Fully-Converged" } { '[Script]Update DC' }
            Default { '[Script]SetStorageVLANs' }
        }

        # Update all the Nic Names in the AzL VMs to make it easier for configuring the networking during instance deployment
        Script "UpdateAzLNicNames" {
            GetScript  = {
                $result = $true
                $scriptCredential = New-Object System.Management.Automation.PSCredential ("Administrator", (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                # Retrieve the list of VMs where the name matches the $vmPrefix-AzL* pattern
                Get-VM -Name "$Using:vmPrefix-AzL*" | ForEach-Object {
                    # Check inside each VM using Invoke-Command to see if any of the network adapters have the name "Ethernet*"
                    $ethernetCheck = Invoke-Command -VMName $($_.Name) -Credential $scriptCredential -ScriptBlock {
                        $ethernetNics = Get-NetAdapter | Where-Object { $_.Name -like "Ethernet*" }
                        return $ethernetNics
                    }
                    if ($ethernetCheck) {
                        $result = $false
                        $result = $result
                        Write-Host "NICs with name like 'Ethernet' found in $($_.Name)"
                        Write-Host "These names will be updated to ease deployment."
                    }
                    else {
                        Write-Host "No NICs with name like 'Ethernet' found in $($_.Name)"
                        Write-Host "No changes are necessary."
                    }
                }
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $scriptCredential = New-Object System.Management.Automation.PSCredential ("Administrator", (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                Get-VM -Name "$Using:vmPrefix-AzL*" | ForEach-Object {
                    $AzLNics = Get-VMNetworkAdapter -VMName $($_.Name)
                    foreach ($nic in $AzLNics) {
                        $formattedMac = $nic.MacAddress -replace '(.{2})(?!$)', '$1-'
                        Write-Host "Updating NIC $($nic.Name) inside VM: $($_.Name)"
                        Write-Host "NIC MAC Address: $formattedMac"
                        # Identfiy if this is a storage NIC
                        if ($nic.Name -like "Storage*") {
                            Invoke-Command -VMName $($_.Name) -Credential $scriptCredential -ScriptBlock { 
                                param($formattedMac, $nic)
                                Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $formattedMac } | Rename-NetAdapter -NewName "$($nic.Name)"
                                Write-Host "Renamed NIC with MAC: $formattedMac to $($nic.Name)"
                            } -ArgumentList $formattedMac, $nic
                        }
                        # Perform same update on the Management NICs, which are identified -notlike "Storage*"
                        else {
                            Invoke-Command -VMName $($_.Name) -Credential $scriptCredential -ScriptBlock { 
                                param($formattedMac, $nic)
                                # Identify the target NIC by matching the MAC address
                                $targetNic = Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $formattedMac }
                                # Update the NIC name to match the existing -RegistryKeyword 'HyperVNetworkAdapterName'.DisplayValue value for that specific adapter
                                $newName = (Get-NetAdapterAdvancedProperty -RegistryKeyword 'HyperVNetworkAdapterName' | Where-object { $_.Name -eq $targetNic.Name }).DisplayValue
                                Rename-NetAdapter -Name $targetNic.Name -NewName $newName
                                Write-Host "Renamed NIC with MAC: $formattedMac to $newName"
                            } -ArgumentList $formattedMac, $nic
                        }
                    }
                }
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = $updateAzLNicNamesDependsOn
        }

        Script "DisableDhcpOnVMs" {
            GetScript  = {
                $result = $false
                return @{ 'Result' = $result }
            }
            SetScript  = {
                # Get all VMs that are not the DC and disable DHCP on them
                $vmName = Get-VM | Where-Object { $_.Name -notlike "$Using:vmPrefix-DC" }
                ForEach ($vm in $vmName) {
                    $scriptCredential = New-Object System.Management.Automation.PSCredential (".\Administrator", (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    Invoke-Command -VMName $vm.Name -Credential $scriptCredential -ArgumentList $vm -ScriptBlock {
                        param ($vm)
                        Write-Host "Enable ping through the firewall on $($vm.Name)"
                        # Enable PING through the firewall
                        Enable-NetFirewallRule -displayName "File and Printer Sharing (Echo Request - ICMPv4-In)"
                        # Get all NICs and check if DHCP is enabled, and if so, disable it
                        Get-NetAdapter | Get-NetIPInterface | Where-Object Dhcp -eq 'Enabled' | ForEach-Object {
                            Write-Host "$($vm.Name): Disabling DHCP on $($_.InterfaceAlias)"
                            Set-NetIPInterface -InterfaceAlias $_.InterfaceAlias -Dhcp Disabled
                        }
                    }
                }
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
                # Get the scope from DHCP by running an Invoke-Command against the DC VM
                $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                    $DhcpScope = Get-DhcpServerv4Scope
                    $shortDhcpScope = ($DhcpScope.StartRange -split '\.')[0..2] -join '.'
                    # Start the scope at 50 to allow for Deployments with SDN optional services
                    # As per here: https://learn.microsoft.com/en-us/azure/azure-local/plan/three-node-ip-requirements?view=azloc-24113#deployments-with-sdn-optional-services
                    $newIpStartRange = ($shortDhcpScope + ".50")
                    Write-Host "Updating DHCP scope to start at $newIpStartRange to allow for additional optional Azure Local services"
                    Set-DhcpServerv4Scope -ScopeId $DhcpScope.ScopeId -StartRange $newIpStartRange -EndRange $DhcpScope.EndRange
                    Get-DhcpServerv4Lease -ScopeId $DhcpScope.ScopeId | Where-Object IPAddress -like "$shortDhcpScope*" | ForEach-Object {
                        Remove-DhcpServerv4Lease -ScopeId $DhcpScope.ScopeId -Confirm:$false -ErrorAction SilentlyContinue
                    }
                }
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]DisableDhcpOnVMs"
        }

        Script "SetStaticIPs" {
            GetScript  = {
                $result = $false
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                $returnedValues = Invoke-Command -VMName "$Using:vmPrefix-DC" -Credential $scriptCredential -ScriptBlock {
                    $DhcpScope = Get-DhcpServerv4Scope
                    $subnetMask = $DhcpScope.SubnetMask.IPAddressToString
                    $gateway = (Get-DhcpServerv4OptionValue -ScopeId $DhcpScope.ScopeId -OptionId 3).Value
                    $dnsServers = (Get-DhcpServerv4OptionValue -ScopeId $DhcpScope.ScopeId -OptionId 6).Value
                    return $DhcpScope, $subnetMask, $gateway, $dnsServers
                }

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
                        Write-Host "Management1 IP on $vmName to $vmIpAddress"
                    }
                    else {
                        # unexpected response
                        $setIp
                    }
                }
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]UpdateDhcpScope"
        }

        Script "UpdateDNSRecords" {
            GetScript  = {
                $result = $false
                return @{ 'Result' = $result }
            }
            SetScript  = {
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
                        Write-Host "Checking for existing DNS Record for $dnsName"
                        $dnsCheck = Get-DnsServerResourceRecord -Name $dnsName -ZoneName $domainName -ErrorAction SilentlyContinue
                        foreach ($entry in $dnsCheck) {
                            Write-Host "Cleaning up existing DNS entry for $($entry.HostName)"
                            Remove-DnsServerResourceRecord $entry.HostName -ZoneName $domainName -RRType A -Force
                        }
                        Write-Host "Creating new DNS record for $dnsName with IP: $vmIpAddress in Zone: $domainName"
                        Add-DnsServerResourceRecordA -Name $dnsName -ZoneName $domainName -IPv4Address $vmIpAddress -ErrorAction SilentlyContinue -CreatePtr
                    }
                }
            }
            TestScript = {
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]SetStaticIPs"
        }

        #### Final tasks - Download RDP file, Edit RDP file, and Create RDP RunOnce ####

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
        
        # Create RDP file for the DC VM
        Script "Download RDP File" {
            GetScript  = {
                $result = Test-Path -Path "$Using:rdpConfigPath"
                return @{ 'Result' = $result }
            }
            SetScript  = {
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
        Script "Edit RDP file" {
            GetScript  = {
                $result = ((Get-Item $Using:rdpConfigPath).LastWriteTime -ge (Get-Date))
                return @{ 'Result' = $result }
            }
            SetScript  = {
                $vmIpAddress = (Get-VMNetworkAdapter -Name 'Internet' -VMName "$Using:vmPrefix-DC").IpAddresses | Where-Object { $_ -notmatch ':' }
                $rdpConfigFile = Get-Content -Path "$Using:rdpConfigPath"
                $rdpConfigFile = $rdpConfigFile.Replace("<<VM_IP_Address>>", $vmIpAddress)
                $rdpConfigFile = $rdpConfigFile.Replace("<<rdpUserName>>", $Using:msLabUsername)
                Out-File -FilePath "$Using:rdpConfigPath" -InputObject $rdpConfigFile -Force
            }
            TestScript = {
                
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Download RDP File"
        }

        # If this is in Azure, create a RunOnce that will copy the RDP file to the user's desktop
        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
            Script "Create RDP RunOnce" {
                GetScript  = {
                    $result = [bool] (Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name '!CopyRDPFile' -ErrorAction SilentlyContinue)
                    return @{ 'Result' = $result }
                }
                SetScript  = {
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
}