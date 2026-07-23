# --- Configuration ---
param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt"),
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [string]$ProfileId,
    [string[]]$StartPages
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\resolution.ps1")
. (Join-Path $PSScriptRoot "lib\device.ps1")
. (Join-Path $PSScriptRoot "lib\profile-state.ps1")
. (Join-Path $PSScriptRoot "lib\undetectable-app.ps1")

function Read-ProfileResolution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    $resolution = $null
    while ([string]::IsNullOrWhiteSpace($resolution)) {
        $resolutionInput = Read-Host "Enter resolution for '$ProfileName' (e.g. 1920x1080)"
        $resolution = ConvertTo-ResolutionFolderName -Value $resolutionInput

        if ([string]::IsNullOrWhiteSpace($resolution)) {
            Write-Host "Use widthxheight format, for example 1920x1080." -ForegroundColor Yellow
        }
    }

    return $resolution
}

function Test-ProfileAlreadyRunningError {
    param(
        [Parameter(Mandatory = $false)]
        [object]$ApiPayload,

        [Parameter(Mandatory = $false)]
        [string]$ExceptionText
    )

    $parts = @()

    if ($ApiPayload) {
        try {
            # Serialize the full payload so nested messages (for example data.error) are searchable.
            $parts += ($ApiPayload | ConvertTo-Json -Depth 10 -Compress)
        }
        catch {
            $parts += [string]$ApiPayload
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExceptionText)) {
        $parts += $ExceptionText
    }

    $combined = ($parts -join " | ").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($combined)) {
        return $false
    }

    $alreadyRunningPatterns = @(
        "already running",
        "already started",
        "already open",
        "already launched",
        "profile is running",
        "profile already"
    )

    foreach ($pattern in $alreadyRunningPatterns) {
        if ($combined -like "*$pattern*") {
            return $true
        }
    }

    return $false
}

if (Test-Path -LiteralPath $ProfileStatePath) {
    Remove-Item -LiteralPath $ProfileStatePath -Force -ErrorAction SilentlyContinue
}

try {
    Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds

    Write-Host "Connecting to Undetectable API at $ApiUrl..." -ForegroundColor Cyan
    
    # 1. Fetch the profile list using the official endpoint
    $response = Invoke-RestMethod -Uri "$ApiUrl/list" -Method Get
    
    if ($response.code -ne 0 -or -not $response.data) {
        Write-Error "Failed to fetch profiles from API or no profiles exist."
        Exit 1
    }

    # Extract the dictionary of profiles
    # The API returns data as { "profile_id1": { "name": "Profile1" }, ... }
    $profilesData = $response.data
    
    # Convert the dictionary keys/values into a structured array we can iterate over
    $profileList = @()
    foreach ($id in $profilesData.psobject.Properties.Name) {
        $profileData = $profilesData.$id
        try {
            $profileInfoResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/getinfo/$id" -Method Get
            if ($profileInfoResponse.code -eq 0 -and $profileInfoResponse.data) {
                $profileData = $profileInfoResponse.data
            }
        }
        catch {
        }

        $profileList += [PSCustomObject]@{
            Id         = $id
            Name       = $profileData.name
            Resolution = Get-ResolutionFromProfile -Profile $profileData
            Device     = Get-DeviceFromProfile -Profile $profileData
        }
    }

    if ($profileList.Count -eq 0) {
        Write-Host "No profiles found in your Undetectable browser." -ForegroundColor Yellow
        Exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ProfileId)) {
        # 2. Display the Interactive Menu
        Write-Host "`n=== CHOOSE A PROFILE ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $profileList.Count; $i++) {
            $profileLabel = $profileList[$i].Name
            if (-not [string]::IsNullOrWhiteSpace($profileList[$i].Resolution)) {
                $profileLabel = "$profileLabel [$($profileList[$i].Resolution)]"
            }

            Write-Host (" [{0}] {1}" -f ($i + 1), $profileLabel)
        }
        Write-Host "========================================`n"

        # 3. Prompt User Choice
        $choice = -1
        while ($choice -lt 1 -or $choice -gt $profileList.Count) {
            $profileInput = Read-Host "Select a profile number to launch (1-$($profileList.Count))"
            if ([int]::TryParse($profileInput, [ref]$choice)) {
                if ($choice -lt 1 -or $choice -gt $profileList.Count) {
                    Write-Host "Invalid selection. Please choose a number within the range." -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Please enter a valid number." -ForegroundColor Yellow
            }
        }

        $selectedProfile = $profileList[$choice - 1]
    }
    else {
        $selectedProfile = $profileList | Where-Object { $_.Id -eq $ProfileId } | Select-Object -First 1
        if (-not $selectedProfile) {
            throw "Profile id '$ProfileId' was not found."
        }
    }

    $profileId = $selectedProfile.Id
    $profileName = $selectedProfile.Name
    $profileResolution = $selectedProfile.Resolution
    $profileDevice = $selectedProfile.Device

    if ([string]::IsNullOrWhiteSpace($profileResolution) -and [string]::IsNullOrWhiteSpace($ProfileId)) {
        $profileResolution = Read-ProfileResolution -ProfileName $profileName
    }

    if ([string]::IsNullOrWhiteSpace($profileDevice)) {
        $profileDevice = "desktop"
    }

    if ([string]::IsNullOrWhiteSpace($profileResolution)) {
        $profileResolution = "unknown"
    }

    # 4. Start the Profile via GET request as specified in docs
    Write-Host "`nLaunching profile: '$profileName'..." -ForegroundColor Cyan
    $startResponse = $null
    $startExceptionText = $null

    try {
        $startUri = "$ApiUrl/profile/start/$profileId"
        if (@($StartPages).Count -gt 0) {
            $encodedStartPages = [uri]::EscapeDataString(($StartPages -join ","))
            $startUri += "?start-pages=$encodedStartPages"
        }
        $startResponse = Invoke-RestMethod -Uri $startUri -Method Get
    }
    catch {
        $startExceptionText = $_.Exception.Message
    }

    $isAlreadyRunning = Test-ProfileAlreadyRunningError -ApiPayload $startResponse -ExceptionText $startExceptionText
    $isStarted = $startResponse -and ($startResponse.code -eq 0)
    
    if ($isStarted -or $isAlreadyRunning) {
        try {
            Set-OrchestrationProfileState -StatePath $ProfileStatePath -ProfileId $profileId -ProfileName $profileName -Resolution $profileResolution -Device $profileDevice
        }
        catch {
            Write-Warning "Profile launched, but the selected profile state could not be saved for later focusing/recording: $_"
        }

        if ($isStarted) {
            Write-Host "Profile started successfully at $profileDevice/$profileResolution." -ForegroundColor Green
        }
        else {
            Write-Host "Profile is already running. Treating as success at $profileDevice/$profileResolution." -ForegroundColor Green
        }
    }
    else {
        if ($startResponse) {
            Write-Host "API returned an error starting the profile: $($startResponse.status)" -ForegroundColor Red
        }
        else {
            Write-Host "An error occurred starting the profile: $startExceptionText" -ForegroundColor Red
        }
        Exit 1
    }

}
catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
    Exit 1
}