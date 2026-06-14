. (Join-Path $PSScriptRoot "resolution.ps1")
. (Join-Path $PSScriptRoot "device.ps1")

function Get-OrchestrationProfileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    $stateText = (Get-Content -LiteralPath $StatePath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($stateText)) {
        return $null
    }

    try {
        $state = $stateText | ConvertFrom-Json -ErrorAction Stop
        $profileName = $state.ProfileName
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            $profileName = $state.Name
        }

        $resolution = ConvertTo-ResolutionFolderName -Value $state.Resolution
        if ([string]::IsNullOrWhiteSpace($resolution)) {
            $resolution = ConvertTo-ResolutionFolderName -Value $profileName
        }

        $device = ConvertTo-DeviceFolderName -Value $state.Device
        if ([string]::IsNullOrWhiteSpace($device)) {
            $device = ConvertTo-DeviceFolderName -Value $profileName
        }

        return [PSCustomObject]@{
            ProfileId   = $state.ProfileId
            ProfileName = $profileName
            Resolution  = $resolution
            Device      = $device
            RawText     = $stateText
        }
    }
    catch {
        return [PSCustomObject]@{
            ProfileId   = $null
            ProfileName = $stateText
            Resolution  = ConvertTo-ResolutionFolderName -Value $stateText
            Device      = ConvertTo-DeviceFolderName -Value $stateText
            RawText     = $stateText
        }
    }
}

function Get-OrchestrationProfileResolution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    $state = Get-OrchestrationProfileState -StatePath $StatePath
    if ($state) {
        return $state.Resolution
    }

    return $null
}

function Get-OrchestrationProfileDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    $state = Get-OrchestrationProfileState -StatePath $StatePath
    if ($state) {
        return $state.Device
    }

    return $null
}

function Set-OrchestrationProfileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileId,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$Resolution,

        [Parameter(Mandatory = $true)]
        [string]$Device
    )

    $profileState = [PSCustomObject]@{
        ProfileId   = $ProfileId
        ProfileName = $ProfileName
        Resolution  = ConvertTo-ResolutionFolderName -Value $Resolution
        Device      = ConvertTo-DeviceFolderName -Value $Device
    }

    Set-Content -LiteralPath $StatePath -Value ($profileState | ConvertTo-Json -Compress) -Encoding UTF8 -ErrorAction Stop
}