param 
(
    [PSCredential]$adminCreds,
    [ValidateSet("Single Machine", "2-Machine Non-Converged", "2-Machine Fully-Converged", "2-Machine Switchless Dual-Link", "3-Machine Non-Converged", "3-Machine Fully-Converged",
        "3-Machine Switchless Single-Link", "3-Machine Switchless Dual-Link", "4-Machine Non-Converged", "4-Machine Fully-Converged", "4-Machine Switchless Dual-Link")]
    [String]$azureLocalArchitecture,
    [ValidateSet("16", "24", "32", "48")]
    [String]$azureLocalMachineMemory,
    [ValidateSet("None", "Basic", "Full")]
    [String]$telemetryLevel,
    [ValidateSet("No", "Yes")]
    [String]$updateImages,
    [ValidateSet("No", "Yes")]
    [String]$installWAC,
    [String]$workshopPath,
    [String]$domainName,
    [String]$WindowsServerIsoPath,
    [String]$AzureLocalIsoPath,
    [Switch]$AutoDownloadWSiso,
    [Switch]$AutoDownloadAzLiso,
    [String]$dnsForwarders,
    [String]$deploymentPrefix
)

$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { Stop-Transcript | Out-Null } catch { }

try {

    # Verify Running as Admin
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "-- Restarting as Administrator" -ForegroundColor Yellow
        Start-Sleep -Seconds 1

        $exe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
        Start-Process $exe "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }
    Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq "Public" } | ForEach-Object {
        Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    # Update the Execution Policy to allow for this and future scripts to run
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

    # Ensure $adminCreds have been provided, and if not, prompt to collect them and break out if they don't provide them
    # Also need to ensure that the password is 12 characters long, and contains at least one of each of the following: uppercase, lowercase, number and special character.
    if (!($adminCreds)) {
        Write-Host "Please provide the credentials for the Azure Local nested environment..." -ForegroundColor Yellow
        $adminCreds = Get-Credential -UserName "LocalAdmin" -Message "Enter the credentials for the Azure Local nested environment in the form username\password."
        if (!($adminCreds)) {
            Write-Host "No credentials provided. Exiting..." -ForegroundColor Red
            Start-Sleep -Seconds 5
            break
        }
    }
    # Check the password length and complexity
    $password = $adminCreds.GetNetworkCredential().Password
    if ($password.Length -lt 12 -or $password -notmatch "^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^\da-zA-Z]).{12,}$") {
        Write-Host "The password provided does not meet the complexity requirements. Please rerun the script and provide a password that is at least 12 characters long, and contains at least one of each of the following: uppercase, lowercase, number and special character." -ForegroundColor Red
        Start-Sleep -Seconds 5
        break
    }

    # Need to ensure that $domainName is provided, and that it is a valid domain name, with a maximum of 1 subdomain
    if (!($domainName)) {
        $pattern = "^(?!:\/\/)(?!-)([a-zA-Z0-9-_]+\.)?[a-zA-Z0-9][a-zA-Z0-9-_]+\.[a-zA-Z]{2,11}?$"
        $retryCount = 0
        do {
            Write-Host "Please provide the domain name for the Azure Local workshop environment."
            Write-Host "The domain name should be in the format azl.lab, or corp.azl.lab. A maximum of a single subdomain is supported."
            $domainName = Read-Host "Enter the domain name for the Azure Local workshop environment"
            $domainName = $domainName -replace '\s', ''
            if ($domainName -notmatch $pattern) {
                Write-Host "Invalid domain name, please try again" -ForegroundColor Yellow
                $retryCount++
            }
        } while (($domainName -eq '' -or $domainName -notmatch $pattern) -and ($retryCount -lt 1))
        
        if ($domainName -eq '' -or $domainName -notmatch $pattern) {
            Write-Host "Invalid domain name provided. Exiting..." -ForegroundColor Red
            break
        }
    }
    elseif ($domainName) {
        # Provide user with 1 chance to enter a correct domain name
        $pattern = "^(?!:\/\/)(?!-)([a-zA-Z0-9-_]+\.)?[a-zA-Z0-9][a-zA-Z0-9-_]+\.[a-zA-Z]{2,11}?$"
        if ($domainName -notmatch $pattern) {
            Write-Host "Invalid domain name provided. Please try again." -ForegroundColor Yellow
            $domainName = Read-Host "Enter the domain name for the Azure Local workshop environment"
            $domainName = $domainName -replace '\s', ''
            if ($domainName -notmatch $pattern) {
                Write-Host "Invalid domain name provided. Exiting..." -ForegroundColor Red
                break
            }
        }
    }

    # Ensure WinRM is configured to allow DSC to run
    Write-Host "Checking PSRemoting to allow PowerShell DSC to run..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Write-Host "PSRemoting enabled..." -ForegroundColor Green

    # Need to validate if $azureLocalArchitecture has been provided and that it meets one of the supported values
    if (!($azureLocalArchitecture)) {
        $askForArchitecture = {
            Write-Host "Please select the Azure Local architecture you'd like to deploy..."
            Write-Host "1. Single Machine"
            Write-Host "2. 2-Machine Non-Converged"
            Write-Host "3. 2-Machine Fully-Converged"
            Write-Host "4. 2-Machine Switchless Dual-Link"
            Write-Host "5. 3-Machine Non-Converged"
            Write-Host "6. 3-Machine Fully-Converged"
            Write-Host "7. 3-Machine Switchless Single-Link"
            Write-Host "8. 3-Machine Switchless Dual-Link"
            Write-Host "9. 4-Machine Non-Converged"
            Write-Host "10. 4-Machine Fully-Converged"
            Write-Host "11. 4-Machine Switchless Dual-Link"
            Write-Host "Or enter 'Q' to exit"
            $architectureChoice = Read-Host "Enter the number of the Azure Local architecture you'd like to deploy"
            switch ($architectureChoice) {
                '1' { $azureLocalArchitecture = "Single Machine" }
                '2' { $azureLocalArchitecture = "2-Machine Non-Converged" }
                '3' { $azureLocalArchitecture = "2-Machine Fully-Converged" }
                '4' { $azureLocalArchitecture = "2-Machine Switchless Dual-Link" }
                '5' { $azureLocalArchitecture = "3-Machine Non-Converged" }
                '6' { $azureLocalArchitecture = "3-Machine Fully-Converged" }
                '7' { $azureLocalArchitecture = "3-Machine Switchless Single-Link" }
                '8' { $azureLocalArchitecture = "3-Machine Switchless Dual-Link" }
                '9' { $azureLocalArchitecture = "4-Machine Non-Converged" }
                '10' { $azureLocalArchitecture = "4-Machine Fully-Converged" }
                '11' { $azureLocalArchitecture = "4-Machine Switchless Dual-Link" }
                'Q' {
                    Write-Host 'Exiting...' -ForegroundColor Red
                    Start-Sleep -seconds 5
                    break 
                }
                default {
                    Write-Host "Invalid architecture choice entered. Try again." -ForegroundColor Yellow
                    .$askForArchitecture
                }
            }
            Write-Host "You have chosen to deploy the $azureLocalArchitecture Azure Local architecture..." -ForegroundColor Green
        }
        .$askForArchitecture
        if ($azureLocalArchitecture -ne 'Q') {
            Write-Host "You have chosen to deploy the $azureLocalArchitecture Azure Local architecture..." -ForegroundColor Green
        }
        else {
            break
        }
    }
    elseif ($azureLocalArchitecture -notin ("Single Machine", "2-Machine Non-Converged", "2-Machine Fully-Converged", "2-Machine Switchless Dual-Link", "3-Machine Non-Converged", "3-Machine Fully-Converged",
            "3-Machine Switchless Single-Link", "3-Machine Switchless Dual-Link", "4-Machine Non-Converged", "4-Machine Fully-Converged", "4-Machine Switchless Dual-Link")) {
        Write-Host "Incorrect Azure Local architecture specified.Please re-run the script using one of the supported values" -ForegroundColor Red
        exit
    }
    else {
        Write-Host "You have chosen to deploy the $azureLocalArchitecture Azure Local architecture..." -ForegroundColor Green
    }

    if (!($azureLocalMachineMemory)) {
        $askForMachineMemory = {
            $azureLocalMachineMemory = Read-Host "Select the memory for each of your Azure Local machines - Enter 16, 24, 32, or 48 (or Q to exit)..."
            switch ($azureLocalMachineMemory) {
                '16' { Write-Host "You have chosen $($azureLocalMachineMemory)GB memory for each of your Azure Local machines..." -ForegroundColor Green }
                '24' { Write-Host "You have chosen $($azureLocalMachineMemory)GB memory for each of your Azure Local machines..." -ForegroundColor Green }
                '32' { Write-Host "You have chosen $($azureLocalMachineMemory)GB memory for each of your Azure Local machines..." -ForegroundColor Green }
                '48' { Write-Host "You have chosen $($azureLocalMachineMemory)GB memory for each of your Azure Local machines..." -ForegroundColor Green }
                'Q' {
                    Write-Host 'Exiting...' -ForegroundColor Red
                    Start-Sleep -seconds 5
                    break 
                }
                default {
                    Write-Host "Invalid memory amount entered. Try again." -ForegroundColor Yellow
                    .$askForMachineMemory
                }
            }
        }
        .$askForMachineMemory
        if ($azureLocalMachineMemory -ne 'Q') {
            $azureLocalMachineMemory = [convert]::ToInt32($azureLocalMachineMemory)
        }
        else {
            break
        }
    }
    elseif ($azureLocalMachineMemory -notin ("16", "24", "32", "48")) {
        Write-Host "Incorrect amount of memory for your Azure Local machines specified.Please re-run the script using with either 16, 24, 32, or 48" -ForegroundColor Red
        break
    }
    elseif ($azureLocalMachineMemory -in ("16", "24", "32", "48")) {
        $azureLocalMachineMemory = [convert]::ToInt32($azureLocalMachineMemory)
    }

    if (!($telemetryLevel)) {
        $AskForTelemetry = {
            $telemetryLevel = Read-Host "Select the telemetry level for the deployment. This helps to improve the deployment experience.`nEnter Full, Basic or None (or Q to exit)..."
            switch ($telemetryLevel) {
                'Full' { Write-Host "You have chosen a telemetry level of $telemetryLevel for the deployment..." -ForegroundColor Green }
                'Basic' { Write-Host "You have chosen a telemetry level of $telemetryLevel for the deployment..." -ForegroundColor Green }
                'None' { Write-Host "You have chosen a telemetry level of $telemetryLevel for the deployment..." -ForegroundColor Green }
                'Q' {
                    Write-Host 'Exiting...' -ForegroundColor Red
                    Start-Sleep -seconds 5
                    break 
                }
                default {
                    Write-Host "Invalid telemetry level entered. Try again." -ForegroundColor Yellow
                    .$AskForTelemetry
                }
            }
        }
        .$AskForTelemetry
    }
    elseif ($telemetryLevel -notin ("Full", "Basic", "None")) {
        Write-Host "Invalid -telemetryLevel entered.`nPlease re-run the script with either Full, Basic or None." -ForegroundColor Red
        break
    }
    elseif ($telemetryLevel -in ("Full", "Basic", "None")) {
        Write-Host "You have chosen a telemetry level of $telemetryLevel for the deployment..." -ForegroundColor Green
    }

    if (!($updateImages)) {
        while ($updateInput -notin ("Y", "N", "Q")) {
            $updateInput = Read-Host "Do you wish to update your Windows Server images automatically?`nThis will increase deployment time. Enter Y or N (or Q to exit)..."
            if ($updateInput -eq "Y") {
                Write-Host "You have chosen to update your Windows Server images that are created during this process.`nThis will add additional time, but your images will have the latest patches." -ForegroundColor Green
                $updateImages = "Yes"
            }
            elseif ($updateInput -eq "N") {
                Write-Host "You have chosen not to update your images - you can patch your Windows Server VMs once they've been deployed." -ForegroundColor Yellow
                $updateImages = "No"
            }
            elseif ($updateInput -eq "Q") {
                Write-Host 'Exiting...' -ForegroundColor Red
                Start-Sleep -Seconds 5
                break 
            }
            else {
                Write-Host "Invalid entry. Try again." -ForegroundColor Yellow
            }
        }
    }
    elseif ($updateImages -eq "Yes") {
        Write-Host "You have chosen to update your Windows Server images that are created during this process.`nThis will add additional time, but your images will have the latest patches." -ForegroundColor Green
    }
    elseif ($updateImages -eq "No") {
        Write-Host "You have chosen not to update your images - you can patch your Windows Server VMs once they've been deployed." -ForegroundColor Yellow
    }
    elseif ($updateImages -notin ("Y", "N")) {
        Write-Host "Invalid entry for -updateImages.`nPlease re-run the script with either Yes or No." -ForegroundColor Red
        break
    }

    if (!($installWAC)) {
        while ($installWAC -notin ("Yes", "No", "Q")) {
            $updateInput = Read-Host "Would you like to install Windows Admin Center in the Azure Local workshop environment?`nEnter Yes or No (or Q to exit)..."
            if ($installWAC -eq "Yes") {
                Write-Host "You have chosen to install Windows Admin Center in the Azure Local workshop environment." -ForegroundColor Green
            }
            elseif ($installWAC -eq "No") {
                Write-Host "You have chosen not to install Windows Admin Center in the Azure Local workshop environment." -ForegroundColor Yellow
            }
            elseif ($installWAC -eq "Q") {
                Write-Host 'Exiting...' -ForegroundColor Red
                Start-Sleep -Seconds 5
                break 
            }
            else {
                Write-Host "Invalid entry. Try again." -ForegroundColor Yellow
            } 
        }
    }
    elseif ($installWAC -eq "Yes") {
        Write-Host "You have chosen to install Windows Admin Center in the Azure Local workshop environment." -ForegroundColor Green
    }
    elseif ($installWAC -eq "No") {
        Write-Host "You have chosen not to install Windows Admin Center in the Azure Local workshop environment." -ForegroundColor Yellow
    }
    elseif ($installWAC -notin ("Yes", "No")) {
        Write-Host "Invalid entry for -installWAC.`nPlease re-run the script with either Yes or No." -ForegroundColor Red
        break
    }

    if (!($workshopPath)) {
        Write-Host "Please select folder for deployment of the Azure Local workshop infrastructure..."
        Start-Sleep -Seconds 5
        Add-Type -AssemblyName System.Windows.Forms
        $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
            RootFolder  = "MyComputer"
            Description = "Please select folder for deployment of the Azure Local workshop infrastructure"
        }
        if ($FolderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $workshopPath = $FolderBrowser.SelectedPath
            Write-Host "Folder selected is $workshopPath" -ForegroundColor Green
        }
        else {
            Write-Host "No valid path was selected. Exiting..." -ForegroundColor Red
            Start-Sleep -Seconds 5
            exit
        }
    }

    # Need to check if there's a deployment prefix, and if not, set it to AzLDW01
    if (!($deploymentPrefix)) {
        $deploymentPrefix = "AzLDW01"
        Write-Host "No deployment prefix provided. Using default value of $deploymentPrefix" -ForegroundColor Green
    }
    else {
        Write-Host "Using deployment prefix of $deploymentPrefix" -ForegroundColor Green
    }

    # Create a Do While loop to check if the deployment prefix is already in use by checking names of existing VMs
    try {
        Do {
            $existingVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$($deploymentPrefix)*" }
            if ($existingVMs) {
                Write-Host "The deployment prefix $($deploymentPrefix) is already in use by the following VMs:" -ForegroundColor Yellow
                foreach ($vm in $existingVMs) {
                    Write-Host "$($vm.Name)"
                }
                $deploymentPrefix = Read-Host "Please enter a new deployment prefix (or Q to exit)"
                if ($deploymentPrefix -eq "Q") {
                    Write-Host 'Exiting...' -ForegroundColor Red
                    Start-Sleep -Seconds 5
                    break 
                }
            }
        } while ($existingVMs)
    }
    catch {
        Write-Host "Get-VM failed to run. This is likely due to the Hyper-V role not being installed." -ForegroundColor Green
        Write-Host "No existing VMs found with the prefix $($deploymentPrefix). Proceeding with deployment..." -ForegroundColor Green
        # Continue script execution
    }

    if (!($AutoDownloadWSiso)) {
        if (!($WindowsServerIsoPath)) {
            Write-Host "Have you downloaded a Windows Server 2022 ISO? If not, one will be downloaded automatically for you"
            $wsIsoAvailable = Read-Host "Enter Y or N"
            if ($wsIsoAvailable -eq "Y") {
                Write-Host "Please select a Windows Server 2022 ISO..."
                Start-Sleep -Seconds 3
                Add-Type -AssemblyName System.Windows.Forms
                #[reflection.assembly]::loadwithpartialname("System.Windows.Forms")
                $openFile = New-Object System.Windows.Forms.OpenFileDialog -Property @{
                    Title = "Please select a Windows Server 2022 ISO..."
                }
                $openFile.Filter = "iso files (*.iso)|*.iso|All files (*.*)|*.*" 
                if ($openFile.ShowDialog() -eq "OK") {
                    Write-Host "File $($openfile.FileName) selected" -ForegroundColor Green
                    $WindowsServerIsoPath = $($openfile.FileName)
                } 
                if (!$openFile.FileName) {
                    Write-Host "No valid ISO file was selected... Exiting" -ForegroundColor Red
                    Start-Sleep -Seconds 5
                    break
                }
            }
            else {
                Write-Host "No Windows Server 2022 ISO has been provided. One will be downloaded for you during deployment." -ForegroundColor Green
            }
        }
    }

    if (!($AutoDownloadAzLiso)) {
        if (!($AzureLocalIsoPath)) {
            Write-Host "Have you downloaded the latest Azure Local ISO? If not, one will be downloaded automatically for you"
            $AzLIsoAvailable = Read-Host "Enter Y or N"
            if ($AzLIsoAvailable -eq "Y") {
                Write-Host "Please select latest Azure Local ISO..."
                Start-Sleep -Seconds 3
                Add-Type -AssemblyName System.Windows.Forms
                #[reflection.assembly]::loadwithpartialname("System.Windows.Forms")
                $openFile = New-Object System.Windows.Forms.OpenFileDialog -Property @{
                    Title = "Please select latest Azure Local ISO..."
                }
                $openFile.Filter = "iso files (*.iso)|*.iso|All files (*.*)|*.*" 
                if ($openFile.ShowDialog() -eq "OK") {
                    Write-Host "File $($openfile.FileName) selected" -ForegroundColor Green
                    $AzureLocalIsoPath = $($openfile.FileName)
                } 
                if (!$openFile.FileName) {
                    Write-Host "No valid ISO file was selected... Exiting" -ForegroundColor Red
                    Start-Sleep -Seconds 5
                    break
                }
            }
            else {
                Write-Host "No Azure Local ISO has been provided. One will be downloaded for you during deployment." -ForegroundColor Green
            }
        }
    }

    try {
        if (!($dnsForwarders)) {
            Write-Host "Would you like to use custom external DNS forwarders?`n" 
            Write-Host "For a single DNS forwarder, use the format like this example: 8.8.8.8"
            Write-Host "For multiple DNS forwarders (maximum 2), use the format like this example, separated by a comma (,) and with no spaces: 8.8.8.8,1.1.1.1"
            Write-Host "Alternatively, to use the default AzL DNS forwarders (8.8.8.8 and 1.1.1.1), simply press Enter to skip."
            $askDnsQuestion = Read-Host "Enter your external DNS forwarder(s) IP addresses, or press enter to skip"
            if ($askDnsQuestion.Length -eq 0) {
                Write-Host "You have not entered any custom external DNS forwarders - we will use 8.8.8.8 and 1.1.1.1 as your external DNS forwarders." -ForegroundColor Green
                $customDNSForwarders = '8.8.8.8","1.1.1.1'
            }
            else {
                $dnsForwarders = $askDnsQuestion
                $dnsForwarders = $dnsForwarders -replace '\s', ''
                $pattern = '^((?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                $dnsForwarders.Split(',') | ForEach-Object { if ($_ -notmatch $pattern) {
                        throw "You have provided an invalid external DNS forwarder IPv4 address: $_.`nPlease check the guidance, validate your entries and rerun the script."
                        return
                    }
                }
                $customDNSForwarders = $dnsForwarders.Replace(',', '","')
                Write-Host "You have entered `"$customDNSForwarders`" as your custom external DNS forwarders." -ForegroundColor Green
            }
        }
        elseif ($dnsForwarders -like "Default") {
            $customDNSForwarders = '8.8.8.8","1.1.1.1'
            Write-Host "You have selected to use the default external DNS forwarders - we will use 8.8.8.8 and 1.1.1.1 as your external DNS forwarders." -ForegroundColor Green
        }
        else {
            $dnsForwarders = $dnsForwarders -replace '\s', ''
            $pattern = '^((?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
            $dnsForwarders.Split(',') | ForEach-Object { if ($_ -notmatch $pattern) {
                    throw "You have provided an invalid external DNS forwarder IPv4 address: $_.`nPlease check the guidance, validate your entries and rerun the script."
                    return
                }
            }
            $customDNSForwarders = $dnsForwarders.Replace(',', '","')
            Write-Host "You have entered $customDNSForwarders as your custom external DNS forwarders." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "$_" -ForegroundColor Red
        break
    }

    # Validate Hyper-V, starting with the management tools to allow for MOF to be successfully generated
    # Need to check for Hyper-V RSAT tools, client management and Hyper-V PowerShell
    Write-Host "Checking if Hyper-V roles/features are installed..."
    $hypervState = (Get-WindowsOptionalFeature -Online -FeatureName "*Hyper-V*" | Where-Object { $_.State -eq "Disabled" })
    if ($hypervState) {
        Write-Host "The following Hyper-V roles/features are missing and will now be installed:"
        foreach ($feature in $hypervState) {
            "$($feature.FeatureName)"
        }
        $reboot = $false
        foreach ($feature in $hypervState) {
            $rebootCheck = Enable-WindowsOptionalFeature -Online -FeatureName $($feature.FeatureName) -All -ErrorAction Stop -NoRestart -WarningAction SilentlyContinue
            if ($($rebootCheck.RestartNeeded) -eq $true) {
                $reboot = $true
            }
        }
    }

    # Download the AzLWorkshop DSC files, and unzip them to C:\AzLWorkshopHost, then copy the PS modules to the main PS modules folder
    Write-Host "Starting Azure Local workshop deployment - please do not close this PowerShell window"
    Start-Sleep -Seconds 3
    Write-Host "Downloading the Azure Local workshop files to C:\AzLWorkshop.zip..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://github.com/DellGEOS/AzureLocalDeploymentWorkshop/raw/main/dsc/AzLWorkshop.zip' `
        -OutFile 'C:\AzLWorkshop.zip' -UseBasicParsing -ErrorAction Stop

    # Expand the archive and copy modules to Program Files
    Write-Host "Unzipping Azure Local workshop files to C:\AzLWorkshopSource..."
    Expand-Archive -Path C:\AzLWorkshop.zip -DestinationPath C:\AzLWorkshopSource -Force -ErrorAction Stop
    Write-Host "Moving PowerShell DSC modules to default Program Files location..."
    Get-ChildItem -Path "C:\AzLWorkshopSource" -Directory | Copy-Item -Destination "$env:ProgramFiles\WindowsPowerShell\Modules" -Recurse -Force -ErrorAction Stop

    # Change your location
    Set-Location 'C:\AzLWorkshopSource'

    Write-Host "Loading the Azure Local workshop deployment script and generating MOF files..."
    # Load the PowerShell file into memory
    . .\AzLWorkshop.ps1

    AzLWorkshop -workshopPath $workshopPath -azureLocalArchitecture $azureLocalArchitecture -adminCreds $adminCreds -domainName $domainName `
        -azureLocalMachineMemory $azureLocalMachineMemory -telemetryLevel $telemetryLevel -updateImages $updateImages `
        -WindowsServerIsoPath $WindowsServerIsoPath -AzureLocalIsoPath $AzureLocalIsoPath -customDNSForwarders $customDNSForwarders `
        -installWAC $installWAC -deploymentPrefix $deploymentPrefix

    # Create a PS1 file that will be placed on the current user's desktop
    $ps1Path = "$env:USERPROFILE\Desktop\AzureLocalWorkshop.ps1"
    $ps1Content = @'
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

    # Verify Running as Admin
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "-- Restarting as Administrator" -ForegroundColor Yellow
        Start-Sleep -Seconds 1

        $exe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
        Start-Process $exe -ArgumentList "-NoExit", "-NoProfile", "-ExecutionPolicy Bypass", "-File `"$PSCommandPath`"" -Verb RunAs
        exit
    }

    ### START LOGGING ###
    $runTime = $(Get-Date).ToString("MMddyy-HHmmss")
    $fullLogPath = Join-Path -Path $PSScriptRoot -ChildPath "WorkshopLog_$runTime.txt"
    Write-Host "Log folder full path is $fullLogPath"
    $startTime = Get-Date -Format g
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $mofPath = "C:\AzLWorkshopSource\AzLWorkshop\"

    Start-Transcript -Path "$fullLogPath" -Append

    Write-Host "Starting Azure Local workshop deployment....a Remote Desktop icon on your desktop will indicate completion..." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Set-DscLocalConfigurationManager -Path $mofPath -Force
    try {
        Start-DscConfiguration -Path $mofPath -Wait -Force -Verbose -ErrorAction Stop
    }
    catch {
        Write-Host "Error occurred during Start-DscConfiguration: $_" -ForegroundColor Red
        throw
    }
    Write-Host "Deployment complete....use the Remote Desktop icon to connect to your Domain Controller..." -ForegroundColor Green

    $endTime = Get-Date -Format g
    $sw.Stop()
    $Hrs = $sw.Elapsed.Hours
    $Mins = $sw.Elapsed.Minutes
    $Secs = $sw.Elapsed.Seconds
    $difference = '{0:00}h:{1:00}m:{2:00}s' -f $Hrs, $Mins, $Secs

    Write-Host "Azure Local workshop deployment completed successfully, taking $difference."
    Write-Host "You started the Azure Local workshop deployment at $startTime."
    Write-Host "Azure Local workshop deployment completed at $endTime."
    Read-Host -Prompt "Press Enter to exit"
}
catch {
    Set-Location $PSScriptRoot
    throw $_
    throw $_.Exception.Message
    Read-Host -Prompt "Press Enter to exit"
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
'@
    Write-Host "Creating AzureLocalWorkshop.ps1 on your desktop..."
    $ps1Content | Out-File -FilePath $ps1Path -Force

    if ($reboot -eq $true) {
        # Create a runonce registry key to run a script at next boot
        # When a user logs in, the script window should be visible on the screen
        Write-Host "Creating a runonce registry key to run the AzureLocalWorkshop.ps1 script at next boot..."
        $command = "powershell -ExecutionPolicy Bypass -File $ps1Path"
        $run = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
        New-ItemProperty -Path $run -Name "!AzlWorkshopDeployment" -Value $command -PropertyType String -Force
    }

    Write-Host "Checking if a reboot is required before deployment..."
    if ($reboot -eq $true) {
        Write-Host "A reboot is required to finish installation..."
        Write-Host "Rebooting your host in 5 seconds...Run the AzureLocalWorkshop.ps1 from your desktop when back online..."
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
    else {
        Write-Host "Install completed. No reboot is required at this time. Run the AzureLocalWorkshop.ps1 from your desktop to start the deployment..." -ForegroundColor Green
    }
}
catch {
    Set-Location $PSScriptRoot
    throw $_.Exception.Message
    Write-Host "Deployment failed - follow the troubleshooting steps online, and then retry"
    Read-Host | Out-Null
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}