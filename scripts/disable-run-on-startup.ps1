$ErrorActionPreference = "Stop"

$TaskName = "Regxorder Random Undetectable Playback Intervals"

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Host "✓ Playback intervals disabled." -ForegroundColor Green
}
catch {
    if ($_.Exception.Message -match "not found") {
        Write-Host "ℹ Task is not registered." -ForegroundColor Yellow
    }
    else {
        throw
    }
}
