$script:DefaultUndetectableStartupTimeoutSeconds = 300

function Test-UndetectableApiReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiUrl,

        [ref]$LastError
    )

    try {
        $response = Invoke-RestMethod -Uri "$ApiUrl/list" -Method Get -TimeoutSec 2 -ErrorAction Stop
        if ($response -and $response.code -eq 0) {
            $LastError.Value = $null
            return $true
        }

        $LastError.Value = if ($response) { $response | ConvertTo-Json -Depth 5 -Compress } else { "Empty response." }
        return $false
    }
    catch {
        $LastError.Value = $_.Exception.Message
        return $false
    }
}

function Wait-UndetectableApiReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiUrl,

        [Nullable[int]]$TimeoutSeconds
    )

    $effectiveTimeoutSeconds = if ($null -eq $TimeoutSeconds) { $script:DefaultUndetectableStartupTimeoutSeconds } else { $TimeoutSeconds }
    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($effectiveTimeoutSeconds)
    $lastError = $null
    $nextProgressAt = $startedAt
    while ((Get-Date) -lt $deadline) {
        if (Test-UndetectableApiReady -ApiUrl $ApiUrl -LastError ([ref]$lastError)) {
            return [PSCustomObject]@{ Ready = $true; LastError = $null }
        }

        if ((Get-Date) -ge $nextProgressAt) {
            $elapsedSeconds = [int]((Get-Date) - $startedAt).TotalSeconds
            Write-Host "Waiting for Undetectable API at $ApiUrl (${elapsedSeconds}s elapsed): $lastError" -ForegroundColor Yellow
            $nextProgressAt = (Get-Date).AddSeconds(10)
        }

        Start-Sleep -Seconds 1
    }

    return [PSCustomObject]@{ Ready = $false; LastError = $lastError }
}

function Get-UndetectableShortcutTargets {
    $shortcutRoots = @($env:ProgramData, $env:APPDATA) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($shortcutRoots.Count -eq 0) {
        return @()
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
    }
    catch {
        return @()
    }

    $targets = @()
    foreach ($root in $shortcutRoots) {
        $programsPath = Join-Path $root "Microsoft\Windows\Start Menu\Programs"
        if (-not (Test-Path -LiteralPath $programsPath)) {
            continue
        }

        $shortcuts = Get-ChildItem -Path $programsPath -Filter "*Undetectable*.lnk" -Recurse -ErrorAction SilentlyContinue
        foreach ($shortcut in $shortcuts) {
            try {
                $targetPath = $shell.CreateShortcut($shortcut.FullName).TargetPath
                if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                    $targets += $targetPath
                }
            }
            catch {
            }
        }
    }

    return $targets
}

function Get-UndetectableInstallCandidates {
    param(
        [Parameter(Mandatory = $false)]
        [string]$UndetectablePath
    )

    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
        $candidates += $UndetectablePath
    }

    $command = Get-Command "Undetectable.exe" -ErrorAction SilentlyContinue
    if ($command) {
        $candidates += $command.Source
    }

    $uninstallKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($entry in Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "Undetectable" }) {
        if (-not [string]::IsNullOrWhiteSpace($entry.InstallLocation)) {
            $candidates += (Join-Path $entry.InstallLocation "Undetectable.exe")
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.DisplayIcon)) {
            $displayIcon = $entry.DisplayIcon.Trim('"') -replace ',\d+$', ''
            if ($displayIcon -notmatch 'uninstall\.exe$') {
                $candidates += $displayIcon
            }
        }
    }

    $candidates += Get-UndetectableShortcutTargets

    $commonRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA "Programs"),
        $env:LOCALAPPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $commonRoots) {
        $candidates += (Join-Path (Join-Path $root "Undetectable") "Undetectable.exe")
    }

    return $candidates | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch 'uninstall\.exe$'
    } | Select-Object -Unique
}

function Find-UndetectableExecutable {
    param(
        [Parameter(Mandatory = $false)]
        [string]$UndetectablePath
    )

    if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
        if (-not (Test-Path -LiteralPath $UndetectablePath)) {
            throw "UndetectablePath does not exist: $UndetectablePath"
        }

        if ((Get-Item -LiteralPath $UndetectablePath).PSIsContainer) {
            $UndetectablePath = Join-Path $UndetectablePath "Undetectable.exe"
        }
    }

    foreach ($candidate in Get-UndetectableInstallCandidates -UndetectablePath $UndetectablePath) {
        if ((Test-Path -LiteralPath $candidate) -and ([IO.Path]::GetFileName($candidate) -ieq "Undetectable.exe")) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Start-UndetectableIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiUrl,

        [Parameter(Mandatory = $false)]
        [string]$UndetectablePath,

        [Nullable[int]]$TimeoutSeconds
    )

    $lastError = $null
    if (Test-UndetectableApiReady -ApiUrl $ApiUrl -LastError ([ref]$lastError)) {
        Write-Host "Undetectable API is already available." -ForegroundColor Green
        return
    }

    $executablePath = Find-UndetectableExecutable -UndetectablePath $UndetectablePath
    if ([string]::IsNullOrWhiteSpace($executablePath)) {
        throw "Could not find Undetectable.exe. Pass -UndetectablePath to scripts\open-undetectable.ps1 or scripts\start-undetectable.ps1."
    }

    Write-Host "Starting Undetectable from $executablePath..." -ForegroundColor Cyan
    Start-Process -FilePath $executablePath -WorkingDirectory (Split-Path -Parent $executablePath) | Out-Null

    $effectiveTimeoutSeconds = if ($null -eq $TimeoutSeconds) { $script:DefaultUndetectableStartupTimeoutSeconds } else { $TimeoutSeconds }
    $readiness = Wait-UndetectableApiReady -ApiUrl $ApiUrl -TimeoutSeconds $effectiveTimeoutSeconds
    if (-not $readiness.Ready) {
        throw "Started Undetectable, but the API at $ApiUrl was not ready after $effectiveTimeoutSeconds seconds. Last error: $($readiness.LastError)"
    }

    Write-Host "Undetectable API is ready." -ForegroundColor Green
}