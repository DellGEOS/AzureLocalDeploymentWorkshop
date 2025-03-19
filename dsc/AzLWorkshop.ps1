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
    Import-DscResource -ModuleName 'MSCatalogLTS' -ModuleVersion 1.0.5
    Import-DscResource -ModuleName 'Hyper-ConvertImage' -ModuleVersion 10.2

    Node localhost
    {
        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }

        [String]$mslabUri = "https://aka.ms/mslab/download"
        [String]$wsIsoUri = "https://go.microsoft.com/fwlink/p/?LinkID=2195280"
        [String]$azureLocalIsoUri = "https://aka.ms/HCIReleaseImage"
        [String]$labConfigUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/labconfig/AzureLocalLabConfig.ps1"
        #[String]$deployWACUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/wac/DeployWAC.ps1"
        [String]$rdpConfigUri = "https://raw.githubusercontent.com/DellGEOS/AzureLocalDeploymentWorkshop/main/artifacts/rdp/rdpbase.rdp"

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        if (!$customRdpPort) {
            $customRdpPort = 3389
        }

        $vmPrefix = (Get-Date -UFormat %d%b%y).ToUpper()

        # Calculate the number of Azure Local machines required
        $azureLocalMachines = if ($azureLocalArchitecture -eq "Single Machine") { 1 } else { [INT]$azureLocalArchitecture.Substring(0, 1) }

        # Determine vSwitch name and allowed VLANs based on azureLocalArchitecture
        $vSwitchName = if ($azureLocalArchitecture -like "*Fully-Converged*") { "Mgmt_Compute_Stor" } else { "Mgmt_Compute" }
        $allowedVlans = if ($azureLocalArchitecture -like "*Fully-Converged*") { "1-10,711-719" } else { "1-10" }

        # Calculate Host Memory Sizing to account for oversizing
        [INT]$totalFreePhysicalMemory = Get-CimInstance Win32_OperatingSystem -Verbose:$false | ForEach-Object { [math]::round($_.FreePhysicalMemory / 1MB) }
        [INT]$totalInfraMemoryRequired = "4"
        [INT]$memoryAvailable = [INT]$totalFreePhysicalMemory - [INT]$totalInfraMemoryRequired
        [INT]$azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
        if ($azureLocalMachineMemoryRequired -ge $memoryAvailable) {
            $memoryOptions = 48, 32, 24, 16
            $x = 0
            while ($azureLocalMachineMemoryRequired -ge $memoryAvailable) {
                $azureLocalMachineMemory = $memoryOptions[$x]
                $azureLocalMachineMemoryRequired = ([Int]$azureLocalMachineMemory * [Int]$azureLocalMachines)
                $x++
            }
        }

        # Define parameters
        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
            # If this in Azure, lock things in specifically
            $targetDrive = "V"
            $workshopPath = "$targetDrive" + ":\AzLWorkshop"
        }
        else {
            $workshopPath = "$workshopPath" + "\AzLWorkshop"
        }

        $mslabLocalPath = "$workshopPath\mslab.zip"
        $labConfigPath = "$workshopPath\LabConfig.ps1"
        $parentDiskPath = "$workshopPath\ParentDisks"
        $updatePath = "$parentDiskPath\Updates"
        $cuPath = "$updatePath\CU"
        $ssuPath = "$updatePath\SSU"
        $isoPath = "$workshopPath\ISO"
        $flagsPath = "$workshopPath\Flags"
        $azLocalVhdPath = "$parentDiskPath\AzL_G2.vhdx"

        $domainNetBios = $domainName.Split('.')[0]
        $domainAdminName = $Admincreds.UserName
        $msLabUsername = "$domainNetBios\$($Admincreds.UserName)"
        $msLabPassword = $Admincreds.GetNetworkCredential().Password

        if (!((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77")) {
            # If this is on-prem, user should have supplied a folder/path they wish to install into
            # Users can also supply a pre-downloaded ISO for both WS and Azure Local
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
                $wsISOLocalPath = "$wsIsoPath\WS2022.iso"
            }
            else {
                $wsISOLocalPath = $WindowsServerIsoPath
                $wsIsoPath = (Get-Item $wsISOLocalPath).DirectoryName
            }
        }
        else {
            $wsIsoPath = "$isoPath\WS"
            $wsISOLocalPath = "$wsIsoPath\WS2022.iso"
            $azLocalIsoPath = "$isoPath\AzureLocal"
            $azLocalISOLocalPath = "$azLocalIsoPath\AzureLocal.iso"
        }

        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {

            #### CREATE STORAGE SPACES V: & VM FOLDER ####

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]WorkshopFolder"
        }

        Script "Extract MSLab" {
            GetScript  = {
                $result = !(Test-Path -Path "$Using:mslabLocalPath")
                return @{ 'Result' = $result }
            }

            SetScript  = {
                Expand-Archive -Path "$Using:mslabLocalPath" -DestinationPath "$Using:workshopPath" -Force
                #$extractedFlag = "$Using:flagsPath\MSLabExtracted.txt"
                #New-Item $extractedFlag -ItemType file -Force
            }

            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Download MSLab"
        }

        Script "Replace LabConfig" {
            GetScript  = {
                $result = ((Get-Item $Using:labConfigPath).LastWriteTime -ge (Get-Date))
                return @{ 'Result' = $result }
            }

            SetScript  = {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri "$Using:labConfigUri" -OutFile "$Using:labConfigPath" -UseBasicParsing
            }

            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Extract MSLab"
        }

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

                if ($Using:installWAC -eq "Yes") {
                    $labConfigFile = $labConfigFile.Replace("<<installWAC>>", '$LabConfig.VMs += @{ VMName = ''WAC'' ; ParentVHD = ''Win2022Core_G2.vhdx'' ; MGMTNICs = 1 }')
                }
                else {
                    $labConfigFile = $labConfigFile.Replace("<<installWAC>>", '')
                }

                Out-File -FilePath "$Using:labConfigPath" -InputObject $labConfigFile -Force
            }

            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Replace LabConfig"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]WSISOpath"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]azLocalIsoPath"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]CU"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]SSU"
        }

        #### SET WINDOWS DEFENDER EXCLUSION FOR VM STORAGE ####

        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {

            Script defenderExclusions {
                SetScript  = {
                    $exclusionPath = "$Using:targetDrive" + ":\"
                    Add-MpPreference -ExclusionPath "$exclusionPath"               
                }
                TestScript = {
                    $exclusionPath = "$Using:targetDrive" + ":\"
                (Get-MpPreference).ExclusionPath -contains "$exclusionPath"
                }
                GetScript  = {
                    $exclusionPath = "$Using:targetDrive" + ":\"
                    @{Ensure = if ((Get-MpPreference).ExclusionPath -contains "$exclusionPath") { 'Present' } Else { 'Absent' } }
                }
                DependsOn  = "[File]WorkshopFolder"
            }

            #### REGISTRY & FIREWALL TWEAKS FOR AZURE VM ####

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

        #### ENABLE & CONFIG HYPER-V ####

        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
        if ($osInfo.ProductType -eq 3) {
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
                # Create Azure Local Host Image from ISO
                
                $scratchPath = "$Using:workshopPath\Scratch"
                New-Item -ItemType Directory -Path "$scratchPath" -Force | Out-Null
                
                # Determine if any SSUs are available
                $ssu = Test-Path -Path "$Using:ssuPath\*" -Include "*.msu"

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[file]ParentDisks", "[Script]Download Azure Local ISO", "[Script]Download SSU", "[Script]Download CU"
        }

        # Start MSLab Deployment
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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Edit LabConfig", "[Script]CreateAzLocalDisk"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]MSLab Prereqs"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]MSLab CreateParentDisks"
        }

        if ((Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77") {
            $azureUsername = $($Admincreds.UserName)
            $desktopPath = "C:\Users\$azureUsername\Desktop"
            $rdpConfigPath = "$workshopPath\$vmPrefix-DC.rdp"
        }
        else {
            $desktopPath = [Environment]::GetFolderPath("Desktop")
            $rdpConfigPath = "$desktopPath\$vmPrefix-DC.rdp"
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]MSLab DeployEnvironment"
        }

        if ($installWAC -eq 'Yes') {
            Script "Deploy WAC" {
                GetScript  = {
                    $scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
                    $result = Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
                        Write-Host "Checking if Windows Admin Center is installed and running..."
                        [bool] (((Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" })`
                                    -and (Get-Service -Name "WindowsAdminCenterAccountManagement" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" }))`
                                -and (Test-NetConnection -ComputerName "localhost" -Port 443 -ErrorAction SilentlyContinue).TcpTestSucceeded)
                    }
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
                            foreach ($service in $services) {
                                $serviceStatus = Get-Service $service -ErrorAction SilentlyContinue
                                if ($serviceStatus -and $serviceStatus.Status -ne "Running") {
                                    Write-Host "Windows Admin Center is installed but the $service service is not running. Attempting to start the service."
                                    Start-Service $service -ErrorAction Stop
                                    if ((Get-Service $service -ErrorAction SilentlyContinue).Status -eq "Running") {
                                        Write-Host "$service service started successfully."
                                        Write-Host "Windows Admin Center is installed and running."
                                        break
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
                        Write-Host "WAC Deployment complete!"
                        $wacCompletedFlag = "$Using:flagsPath\DeployWACComplete.txt"
                        New-Item $wacCompletedFlag -ItemType file -Force | Out-Null
                    }
                    else {
                        Write-Host "Windows Admin Center installation has already completed."
                        return
                    }
                }
                TestScript = {
                    # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Enable RDP on DC"
            }
        }
        else { 
            Write-Host "Skipping Windows Admin Center deployment as it was not selected."
        }

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
                }
            }
            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = $updateDCDependsOn
        }

        # Create a switch statement to populate the $vms paremeter based on the the $azureLocalMachines number. $vms should be an array of strings containing the names of the VMs that will be created.
        # The VM name that is used during the deployment is based on the $vmPrefix variable, which is set in the labconfig file and should only include the AzL VMs and not include the DC or WAC VMs.
        # The range of $azureLocalMachines is 1-4

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
                            Write-Host "Enabling Device Naming on $($nic.Name) on $($_.Name)"
                            Set-VMNetworkAdapter -VMName $($_.Name) -Name $($nic.Name) -DeviceNaming On
                        }
                    }
                }
                TestScript = {
                    # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Update DC", $vLANdependsOn
            }
        }

        # Create RDP file for the DC VM
        # if $azureLocalArchitecture is either 'Single Machine' or '*Fully-Converged', $rdpDependsOn should be "[Script]Update DC", otherwse it should be "[Script]SetStorageVLANs"
        $rdpDependsOn = switch ($azureLocalArchitecture) {
            { $_ -eq "Single Machine" -or $_ -like "*Fully-Converged" } { '[Script]Update DC' }
            Default { '[Script]SetStorageVLANs' }
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = $rdpDependsOn
        }

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
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[Script]Download RDP File"
        }

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
                    # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                    $state = [scriptblock]::Create($GetScript).Invoke()
                    return $state.Result
                }
                DependsOn  = "[Script]Edit RDP File"
            }
        }
    }
}