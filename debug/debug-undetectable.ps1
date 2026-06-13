param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [switch]$TestCreate
)

$ErrorActionPreference = "Stop"

# Import helper functions (scripts/lib lives one level up from this debug folder)
. (Join-Path $PSScriptRoot "..\scripts\lib\undetectable-app.ps1")

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "   Undetectable API Configuration Debugger  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Start or Verify Undetectable
try {
    Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds
}
catch {
    Write-Host "Error connecting to or starting Undetectable: $_" -ForegroundColor Red
    exit 1
}

# 2. Get existing profiles to inspect their structures and configuration IDs
Write-Host "`n[Step 2] Querying Existing Profiles (/list)..." -ForegroundColor Yellow
try {
    $profilesResponse = Invoke-RestMethod -Uri "$ApiUrl/list" -Method Get -TimeoutSec 20
    if ($profilesResponse.code -eq 0 -and $profilesResponse.data) {
        $profilesData = $profilesResponse.data
        $profileKeys = @($profilesData.psobject.Properties.Name)
        
        Write-Host "Found $($profileKeys.Count) existing profiles." -ForegroundColor Green
        
        if ($profileKeys.Count -gt 0) {
            # Let's inspect the first profile in detail to see its schema/structure
            $firstProfileId = $profileKeys[0]
            $firstProfile = $profilesData.$firstProfileId
            
            Write-Host "`n--- Example Profile Scheme (Id: $firstProfileId) ---" -ForegroundColor Cyan
            $firstProfile | ConvertTo-Json -Depth 5 | Write-Host
            
            Write-Host "`nKey profile attributes summarized:" -ForegroundColor Cyan
            foreach ($id in $profileKeys) {
                $p = $profilesData.$id
                Write-Host " - Name: '$($p.name)' | Config ID: '$($p.config_id)' | Resolution: '$($p.screen)' | OS: '$($p.os)' | Browser: '$($p.browser)'"
            }
        }
    }
    else {
        Write-Host "No profiles found or /list returned an error: $($profilesResponse.message)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Failed to query profiles from /list: $_" -ForegroundColor Red
}

# 3. Get all configurations from configslist
Write-Host "`n[Step 3] Querying Configurations (/configslist)..." -ForegroundColor Yellow
try {
    $configsResponse = Invoke-RestMethod -Uri "$ApiUrl/configslist" -Method Get -TimeoutSec 20
    if ($configsResponse.code -ne 0 -or -not $configsResponse.data) {
        Write-Host "Failed to fetch Undetectable configurations: $($configsResponse.message)" -ForegroundColor Red
    }
    else {
        $configsData = $configsResponse.data
        $configIds = @($configsData.PSObject.Properties.Name)
        
        Write-Host "Available configurations count: $($configIds.Count)" -ForegroundColor Green
        
        if ($configIds.Count -gt 0) {
            # Analyze configs OS and Browsers
            $osCounts = @{}
            $browserCounts = @{}
            $configsList = @()
            
            foreach ($id in $configIds) {
                $config = $configsData.$id
                $osCounts[$config.os] = $osCounts[$config.os] + 1
                $browserCounts[$config.browser] = $browserCounts[$config.browser] + 1
                $configsList += [PSCustomObject]@{
                    Id        = $id
                    Os        = $config.os
                    Browser   = $config.browser
                    Screen    = $config.screen
                    UserAgent = $config.useragent
                }
            }
            
            Write-Host "`nBreakdown of available Configurations by OS:" -ForegroundColor Cyan
            $osCounts.Keys | ForEach-Object { Write-Host " - $_ : $($osCounts[$_]) configs" }
            
            Write-Host "`nBreakdown of available Configurations by Browser:" -ForegroundColor Cyan
            $browserCounts.Keys | ForEach-Object { Write-Host " - $_ : $($browserCounts[$_]) configs" }
            
            Write-Host "`n--- Example Configuration (ID: $($configIds[0])) ---" -ForegroundColor Cyan
            $configsData.$($configIds[0]) | ConvertTo-Json -Depth 5 | Write-Host
        }
    }
}
catch {
    Write-Host "Failed to fetch /configslist: $_" -ForegroundColor Red
}

# 4. Explore parameter options
Write-Host "`n[Step 4] Variable Parameters Options Guide..." -ForegroundColor Yellow

$cpuValues = @(2, 4, 6, 8, 12, 16)
$memoryValues = @(2, 4, 8, 16)
$resolutions = @("1280x720", "1366x768", "1440x900", "1536x864", "1920x1080", "1920x1200", "2560x1440")
$languagePairs = @("en-US, en", "en-GB, en", "es-ES, en", "fr-FR, en", "de-DE, en")

Write-Host "The following parameters are customizable upon profile creation:" -ForegroundColor Cyan
Write-Host " - CPU Cores options: $($cpuValues -join ', ')"
Write-Host " - Memory GB options: $($memoryValues -join ', ') GB"
Write-Host " - Screen Resolution options (Standard): $($resolutions -join ', ')"
Write-Host " - Language (Accept-Language format): $($languagePairs -join ' OR ')"
Write-Host " - Geolocation: e.g. 'auto' or precise details"
Write-Host " - Timezone: e.g. 'auto' or timezone identifier (e.g., 'America/New_York')"
Write-Host " - Type: local OR cloud"

# 5. Build and print prototype payload
Write-Host "`n[Step 5] Building Prototype Profile Payload..." -ForegroundColor Yellow
if ($configIds -and $configIds.Count -gt 0) {
    $exampleConfig = $configsData.$($configIds[0])
    
    $prototypePayload = [ordered]@{
        name       = "Debug_Profile_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        configid   = $configIds[0]
        type       = "cloud" # local/cloud
        cpu        = 4
        memory     = 8
        language   = "en-US, en"
        resolution = $exampleConfig.screen
    }
    
    Write-Host "Proposed JSON Payload for /profile/create:" -ForegroundColor Cyan
    $prototypePayload | ConvertTo-Json -Depth 5 | Write-Host
}
else {
    Write-Host "Could not build prototype payload: No configurations fetched." -ForegroundColor Red
}

# 6. Optional live create test: escalating payloads to isolate the cause of failures.
# Per API docs: all params are optional (minimal request = name only); with configid,
# OS/Browser are ignored and mismatched params (e.g. resolution on Android) are silently
# ignored rather than rejected. So if every payload below fails identically, the cause is
# account/role permissions, NOT an invalid profile configuration.
if ($TestCreate) {
    Write-Host "`n[Step 6] Live Create Test (-TestCreate)..." -ForegroundColor Yellow

    if (-not ($configIds -and $configIds.Count -gt 0)) {
        Write-Host "Cannot run create test: no configurations available." -ForegroundColor Red
    }
    else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $testConfigId = $configIds[0]

        $attempts = @(
            [PSCustomObject]@{
                Label   = "A) Name only (absolute minimum)"
                Payload = [ordered]@{ name = "Debug_A_$stamp" }
            },
            [PSCustomObject]@{
                Label   = "B) Name + configid (all Config defaults)"
                Payload = [ordered]@{ name = "Debug_B_$stamp"; configid = $testConfigId }
            },
            [PSCustomObject]@{
                Label   = "C) Documented os/browser example (no configid)"
                Payload = [ordered]@{ name = "Debug_C_$stamp"; os = "Windows"; browser = "Chrome" }
            }
        )

        foreach ($attempt in $attempts) {
            Write-Host "`n--- Attempt $($attempt.Label) ---" -ForegroundColor Cyan
            $json = $attempt.Payload | ConvertTo-Json -Depth 5
            Write-Host "Request body: $json"
            try {
                $resp = Invoke-RestMethod -Uri "$ApiUrl/profile/create" -Method Post -ContentType "application/json" -Body $json -TimeoutSec 60
                Write-Host "Raw response:" -ForegroundColor Green
                $resp | ConvertTo-Json -Depth 5 | Write-Host
                if ($resp.code -eq 0) {
                    Write-Host "RESULT: SUCCESS (profile created)." -ForegroundColor Green
                }
                else {
                    Write-Host "RESULT: API error -> $($resp.data.error)" -ForegroundColor Red
                }
            }
            catch {
                Write-Host "RESULT: Request threw -> $_" -ForegroundColor Red
            }
        }

        Write-Host "`nInterpretation:" -ForegroundColor Cyan
        Write-Host " - If A, B and C all fail with the same 'permissions' error, the profile"
        Write-Host "   configuration is valid and the block is account/role/plan permissions."
        Write-Host " - If A/B succeed but the full random payload fails, a specific parameter is at fault."
    }
}
else {
    Write-Host "`n[Step 6] Live Create Test skipped. Re-run with -TestCreate to attempt real creation." -ForegroundColor DarkGray
}

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "Debugger executed successfully." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
