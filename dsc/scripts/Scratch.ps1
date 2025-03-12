# Firstly, validate if Hyper-V is installed and prompt to enable and reboot if not
Write-Host "Checking if required Hyper-V role/features are installed..."
$hypervState = Get-WindowsOptionalFeature -Online -FeatureName *Hyper-V* | Where-Object { $_.State -eq "Disabled" }

if ($hypervState) {
    Write-Host "`nThe following Hyper-V role/features are missing:`n"
    $hypervState.DisplayName | ForEach-Object { Write-Host $_ }

    Write-Host "`nDo you wish to enable them now?" -ForegroundColor Green
    if ((Read-Host "(Type Y or N)") -eq "Y") {
        Write-Host "`nYou chose to install the required Hyper-V role/features.`nYou will be prompted to reboot your machine once completed.`nRerun this script when back online..."
        Start-Sleep -Seconds 10

        $reboot = $false
        foreach ($feature in $hypervState) {
            $rebootCheck = Enable-WindowsOptionalFeature -Online -FeatureName $feature.FeatureName -ErrorAction Stop -NoRestart -WarningAction SilentlyContinue
            if ($rebootCheck.RestartNeeded) {
                $reboot = $true
            }
        }

        if ($reboot) {
            Write-Host "`nInstall completed. A reboot is required to finish installation - reboot now?`nIf not, you will need to reboot before deploying the Hybrid Jumpstart..." -ForegroundColor Green
            if ((Read-Host "(Type Y or N)") -eq "Y") {
                Start-Sleep -Seconds 5
                Restart-Computer -Force
            }
            else {
                Write-Host 'You did not enter "Y" to confirm rebooting your host. Exiting...' -ForegroundColor Red
                break
            }
        }
        else {
            Write-Host "Install completed. No reboot is required at this time. Continuing process..." -ForegroundColor Green
        }
    }
    else {
        Write-Host 'You did not enter "Y" to confirm installing the required Hyper-V role/features. Exiting...' -ForegroundColor Red
        break
    }
}
else {
    Write-Host "`nAll required Hyper-V role/features are present. Continuing process..." -ForegroundColor Green
}