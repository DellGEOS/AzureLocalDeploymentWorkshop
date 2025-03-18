Start-Sleep -seconds 30
$timeout = [DateTime]::Now.AddMinutes(12)
while ([DateTime]::Now -lt $timeout) {
    do {
        Write-Host "Checking to see if Windows Admin Center installation is complete..."
        $processComplete = Get-ChildItem -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
        if ($processComplete) {
            break
        }
        Write-Host "Windows Admin Center installation in progress. Checking again in 20 seconds."
        Start-Sleep -Seconds 20
        # Need to check if too much time has passed compared to $timeout
        if ([DateTime]::Now -gt $timeout) {
            throw "Windows Admin Center installation took too long. Uninstalling and trying again..."
        }
    } while (-not $processComplete)

    do {
        # Check if WindowsAdminCenter service is present and if not, wait for 10 seconds and check again
        if (-not (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue)) {
            Write-Host "Windows Admin Center not yet installed. Checking again in 10 seconds."
            Start-Sleep -Seconds 10
        }
        if ([DateTime]::Now -gt $timeout) {
            throw "Windows Admin Center installation took too long. Uninstalling and trying again..."
        }
        if ((Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue).status -ne "Running") {
            Write-Host "Attempting to start Windows Admin Center Service - this may take a few minutes if the service has just been installed."
            Start-Service WindowsAdminCenter -ErrorAction SilentlyContinue
        }
        if ([DateTime]::Now -gt $timeout) {
            throw "Windows Admin Center installation took too long. Uninstalling and trying again..."
        }
    } until ((Test-NetConnection -ErrorAction SilentlyContinue -ComputerName "localhost" -port 443).TcpTestSucceeded)
    break
}



Start-Sleep -seconds 30
function CheckTimeout {
    param ([datetime]$timeout)
    if ([DateTime]::Now -gt $timeout) {
        throw "Windows Admin Center installation took too long. Uninstalling and trying again..."
    }
}
while ([DateTime]::Now -lt $timeout) {
    do {
        Write-Host "Checking to see if Windows Admin Center installation is complete..."
        $processComplete = Get-ChildItem -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
        if ($processComplete) {
            break
        }
        Write-Host "Windows Admin Center installation in progress. Checking again in 20 seconds."
        Start-Sleep -Seconds 20
        CheckTimeout -timeout $timeout
    } while (-not $processComplete)

    do {
        if (-not (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue)) {
            Write-Host "Windows Admin Center not yet installed. Checking again in 10 seconds."
            Start-Sleep -Seconds 10
            CheckTimeout -timeout $timeout
            continue
        }

        if ((Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue).Status -ne "Running") {
            Write-Host "Attempting to start Windows Admin Center Service - this may take a few minutes if the service has just been installed."
            Start-Service WindowsAdminCenter -ErrorAction SilentlyContinue
            CheckTimeout -timeout $timeout
        }
    } until ((Test-NetConnection -ErrorAction SilentlyContinue -ComputerName "localhost" -port 443).TcpTestSucceeded)
    break
}

# Create a for loop to test if the service is running
for ($i = 1; $i -le 10; $i++) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Attempt $i to check if Windows Admin Center service is running."
    $service = Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Windows Admin Center service is now running."
        break
    }
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Windows Admin Center service is not running. Attempting to start the service."
    Start-Service WindowsAdminCenter -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    CheckTimeout -timeout $timeout
}



# During installation, Get-Process returns WindowsAdminCenter and WindowsAdminCenter.tmp

function CheckTimeout {
    param ([datetime]$timeout)
    if ([DateTime]::Now -gt $timeout) {
        throw "Windows Admin Center installation took too long. Uninstalling and trying again..."
    }
}
$timeout = [DateTime]::Now.AddMinutes(12)
while ([DateTime]::Now -lt $timeout) {
    # Firstly, check if Windows Admin Center is already installed
    # This is done by checking if the WindowsAdminCenter service is present and running, and also if Test-NetConnection to localhost on port 443 is successful
    if ((Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue) -and (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue).Status -eq "Running" -and (Test-NetConnection -ErrorAction SilentlyContinue -ComputerName "localhost" -port 443).TcpTestSucceeded) {
        Write-Host "Windows Admin Center is already installed and running."
        break
    }
    # Then check if the service is installed but not running
    if ((Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue) -and (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue).Status -ne "Running") {
        Write-Host "Windows Admin Center service is installed but not running. Attempting to start the service every 10 seconds."
        Start-Service WindowsAdminCenter -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
        CheckTimeout -timeout $timeout
        continue
    }
    # If the service is not installed, check if the installation is in progress - this can be done by checking Get-Process returns WindowsAdminCenter and WindowsAdminCenter.tmp
    if ((Get-Process -Name WindowsAdminCenter -ErrorAction SilentlyContinue) -or (Get-Process -Name WindowsAdminCenter.tmp -ErrorAction SilentlyContinue)) {
        Write-Host "Windows Admin Center installation in progress. Checking again in 20 seconds."
        Start-Sleep -Seconds 20
        CheckTimeout -timeout $timeout
        continue
    }
    # If none of the above conditions are met, then Windows Admin Center is not installed and we need to install it
    # Firstly, download the Windows Admin Center installer if it is not already present
    Write-Host "Windows Admin Center not installed, or currently being installed. Downloading the installer..."
    if (-not (Test-Path -Path "C:\WindowsAdminCenter.exe")) {
        $ProgressPreference = 'SilentlyContinue'
        Write-Host "Downloading Windows Admin Center..."
        Invoke-WebRequest -Uri 'https://aka.ms/WACDownload' -OutFile "C:\WindowsAdminCenter.exe" -UseBasicParsing
    }
    #Then install Windows Admin Center
    Write-Host "Installing Windows Admin Center - this can take up to 10 minutes..."
    if (-not (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath 'C:\WindowsAdminCenter.exe' -ArgumentList '/VERYSILENT /log=C:\WindowsAdminCenter.log'
        Start-Sleep -Seconds 30
    }

    # Wait for the installation to complete
    # Check the Get-Process to see if WindowsAdminCenter and WindowsAdminCenter.tmp are present as this indicates that the install is happening
    while ((Get-Process -Name WindowsAdminCenter -ErrorAction SilentlyContinue) -or (Get-Process -Name WindowsAdminCenter.tmp -ErrorAction SilentlyContinue)) {
        Write-Host "Windows Admin Center installation in progress. Checking again in 20 seconds."
        Start-Sleep -Seconds 20
        # Check log file for "Log closed." to indicate installation is complete
        $processComplete = Get-ChildItem -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
        if ($processComplete) {
            break
        }
        CheckTimeout -timeout $timeout
    }
}





$scriptCredential = New-Object System.Management.Automation.PSCredential ($Using:mslabUserName, (ConvertTo-SecureString $Using:msLabPassword -AsPlainText -Force))
Invoke-Command -VMName "$Using:vmPrefix-WAC" -Credential $scriptCredential -ScriptBlock {
    $retryCount = 0
    $maxRetries = 3
    while ($retryCount -lt $maxRetries) {
        try {
            function CheckTimeout {
                param ([datetime]$timeout)
                if ([DateTime]::Now -gt $timeout) {
                    throw "Windows Admin Center installation took too long. Uninstalling and trying again..."
                }
            }
            $timeout = [DateTime]::Now.AddMinutes(12)
            while ([DateTime]::Now -lt $timeout) {
                # Firstly, check if Windows Admin Center is already installed
                # This is done by checking if the WindowsAdminCenter service is present and running, and also if Test-NetConnection to localhost on port 443 is successful
                if ((Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue) -and (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue).Status -eq "Running" -and (Test-NetConnection -ErrorAction SilentlyContinue -ComputerName "localhost" -port 443).TcpTestSucceeded) {
                    Write-Host "Windows Admin Center is already installed and running."
                    break
                }
                # Then check if the service is installed but not running
                if ((Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue) -and (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue).Status -ne "Running") {
                    Write-Host "Windows Admin Center service is installed but not running. Attempting to start the service every 10 seconds."
                    Start-Service WindowsAdminCenter -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 10
                    CheckTimeout -timeout $timeout
                    continue
                }
                # If the service is not installed, check if the installation is in progress - this can be done by checking Get-Process returns WindowsAdminCenter and WindowsAdminCenter.tmp
                if ((Get-Process -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue) -or (Get-Process -Name "WindowsAdminCenter.tmp" -ErrorAction SilentlyContinue) -or (Get-Process -Name "TrustedInstaller" -ErrorAction SilentlyContinue)) {
                    Write-Host "Windows Admin Center installation in progress. Checking again in 20 seconds."
                    Start-Sleep -Seconds 20
                    CheckTimeout -timeout $timeout
                    continue
                }
                # If none of the above conditions are met, then Windows Admin Center is not installed and we need to install it
                # Clean up old log files first by testing the path to see if the file exists, before deleting it
                if (Test-Path -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue) {
                    Remove-Item -Path "C:\WindowsAdminCenter.log" -Force
                }
                # and for WAC uninstall log
                if (Test-Path -Path "C:\WACUninstall.log" -ErrorAction SilentlyContinue) {
                    Remove-Item -Path "C:\WACUninstall.log" -Force
                }
                # Then, download the Windows Admin Center installer if it is not already present
                Write-Host "Windows Admin Center not installed, or currently being installed. Downloading the installer..."
                if (-not (Test-Path -Path "C:\WindowsAdminCenter.exe")) {
                    $ProgressPreference = 'SilentlyContinue'
                    Write-Host "Downloading Windows Admin Center..."
                    Invoke-WebRequest -Uri 'https://aka.ms/WACDownload' -OutFile "C:\WindowsAdminCenter.exe" -UseBasicParsing
                }
                # Then install Windows Admin Center
                Write-Host "Installing Windows Admin Center - this can take up to 10 minutes..."
                if (-not (Get-Service WindowsAdminCenter -ErrorAction SilentlyContinue)) {
                    Start-Process -FilePath 'C:\WindowsAdminCenter.exe' -ArgumentList '/VERYSILENT /log=C:\WindowsAdminCenter.log'
                    Start-Sleep -Seconds 30
                }
                # Wait for the installation to complete
                # Check the Get-Process to see if WindowsAdminCenter and WindowsAdminCenter.tmp installation services are present as this indicates that the install is happening
                while ((Get-Process -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue) -or (Get-Process -Name "WindowsAdminCenter.tmp" -ErrorAction SilentlyContinue)) {
                    Write-Host "Windows Admin Center installation in progress. Checking again in 20 seconds."
                    Start-Sleep -Seconds 20
                    # Check log file for "Log closed." to indicate installation is complete
                    $processComplete = Get-ChildItem -Path "C:\WindowsAdminCenter.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
                    if ($processComplete) {
                        break
                    }
                    CheckTimeout -timeout $timeout
                }
            }
        }
        catch {
            Write-Host "Installation failed. Attempting to uninstall and retry. Retry count: $($retryCount + 1)"
            # First check if the final WindowsAdminCenterAccountManagement service is running and stop it
            if ((Get-Service WindowsAdminCenterAccountManagement -ErrorAction SilentlyContinue) -and (Get-Service WindowsAdminCenterAccountManagement -ErrorAction SilentlyContinue).Status -eq "Running") {
                Write-Host "Stopping Windows Admin Center Account Management service..."
                Stop-Service WindowsAdminCenterAccountManagement -Force
                Start-Sleep -Seconds 10
            }
            # Check if a previous installation is in progress and stop it
            if ((Get-Process -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue) -or (Get-Process -Name "WindowsAdminCenter.tmp" -ErrorAction SilentlyContinue) -or (Get-Process -Name "TrustedInstaller" -ErrorAction SilentlyContinue)) {
                Write-Host "Stopping previous Windows Admin Center installation process..."
                Stop-Process -Name "WindowsAdminCenter" -Force
                Stop-Process -Name "WindowsAdminCenter.tmp" -Force
                Stop-Process -Name "TrustedInstaller" -Force
                Start-Sleep -Seconds 10
            }
            # Check if Windows Admin Center is installed and uninstall it
            # Search for Uninstall exe in C:\Program Files\WindowsAdminCenter\
            $uninstallPath = Get-ChildItem -Path "C:\Program Files\WindowsAdminCenter\" -Filter "unins*.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($uninstallPath) {
                Start-Process -FilePath $uninstallPath.FullName -ArgumentList '/VERYSILENT /log=C:\WACUninstall.log'
                Start-Sleep -seconds 30
                $timeout = [DateTime]::Now.AddMinutes(7)
                while ([DateTime]::Now -lt $timeout) {
                    do {
                        # Check if the unins*.exe process is still running
                        $uninstallProcess = Get-Process -Name "unins*.exe" -ErrorAction SilentlyContinue
                        if ($uninstallProcess) {
                            Write-Host "Windows Admin Center uninstallation in progress. Checking again in 20 seconds."
                            Start-Sleep -Seconds 20
                        }
                        CheckTimeout -timeout $timeout
                        Write-Host "Checking to see if Windows Admin Center uninstallation is complete..."
                        # Check to see if "unins*.exe" process has finished running and if the log file has "Log closed." to indicate uninstallation is complete
                        while ((Get-Process -Name "unins*" -ErrorAction SilentlyContinue)) {
                            Write-Host "Windows Admin Center uninstallation still in progress. Checking again in 20 seconds."
                            Start-Sleep -Seconds 20
                            # Check log file for "Log closed." to indicate installation is complete
                            $uninstallComplete = Get-ChildItem -Path "C:\WACUninstall.log" -ErrorAction SilentlyContinue | Get-Content | Select-String "Log closed."
                            if ($uninstallComplete) {
                                break
                            }
                            CheckTimeout -timeout $timeout
                        }
                    } while (-not $uninstallComplete)
                }
                $retryCount++
            }
        }
    }
    if ($retryCount -eq $maxRetries) {
        throw "Failed to install Windows Admin Center after $maxRetries attempts."
    }
}