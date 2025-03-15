$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try {

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
    Write-Host "`nLog folder full path is $fullLogPath"
    $startTime = Get-Date -Format g
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $mofPath = "C:\AzLWorkshopSource\AzLWorkshop\"

    Start-Transcript -Path "$fullLogPath" -Append

    Write-Host "`nStarting Azure Local workshop deployment....a Remote Desktop icon on your desktop will indicate completion..." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Set-DscLocalConfigurationManager -Path $mofPath -Force
    try {
        Start-DscConfiguration -Path $mofPath -Wait -Force -Verbose -ErrorAction Stop
    }
    catch {
        Write-Host "Error occurred during Start-DscConfiguration: $_" -ForegroundColor Red
        throw
    }
    Write-Host "`nDeployment complete....use the Remote Desktop icon to connect to your Domain Controller..." -ForegroundColor Green

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