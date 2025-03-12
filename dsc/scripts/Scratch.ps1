if (!($azureLocalArchitecture)) {
    $askForArchitecture = {
        Write-Host "`nPlease select the Azure Local architecture you'd like to deploy..."
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
        $architectureChoice = Read-Host "`nEnter the number of the Azure Local architecture you'd like to deploy"
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
        Write-Host "`nYou have chosen to deploy the $azureLocalArchitecture Azure Local architecture..." -ForegroundColor Green
    }
    .$askForArchitecture
    if ($azureLocalArchitecture -ne 'Q') {
        Write-Host "`nYou have chosen to deploy the $azureLocalArchitecture Azure Local architecture..." -ForegroundColor Green
    }
    else {
        break
    }
}
elseif ($azureLocalArchitecture -notin ("Single Machine", "2-Machine Non-Converged", "2-Machine Fully-Converged", "2-Machine Switchless Dual-Link", "3-Machine Non-Converged", "3-Machine Fully-Converged",
        "3-Machine Switchless Single-Link", "3-Machine Switchless Dual-Link", "4-Machine Non-Converged", "4-Machine Fully-Converged", "4-Machine Switchless Dual-Link")) {
    Write-Host "Incorrect Azure Local architecture specified.`nPlease re-run the script using one of the supported values" -ForegroundColor Red
    exit
}
else {
    Write-Host "`nYou have chosen to deploy the $azureLocalArchitecture Azure Local architecture..." -ForegroundColor Green
}