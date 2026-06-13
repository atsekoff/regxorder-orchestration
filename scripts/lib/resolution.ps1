function ConvertTo-ResolutionFolderName {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    if ($Value -match '(?i)(\d{3,5})\s*x\s*(\d{3,5})') {
        return "$($matches[1])x$($matches[2])"
    }

    return $null
}

function Get-ResolutionFromText {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    return ConvertTo-ResolutionFolderName -Value $Text
}

function Get-ResolutionFromWidthHeightPair {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Value,

        [int]$Depth = 0
    )

    if ($null -eq $Value -or $Depth -gt 6) {
        return $null
    }

    if ($Value -is [string]) {
        return Get-ResolutionFromText -Text $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            $result = Get-ResolutionFromWidthHeightPair -Value $item -Depth ($Depth + 1)
            if ($result) {
                return $result
            }
        }
    }

    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' })
    if ($properties.Count -eq 0) {
        return $null
    }

    $widthProperty = $properties | Where-Object { $_.Name -match '^(width|screenWidth|screen_width|windowWidth|window_width|viewportWidth|viewport_width)$' } | Select-Object -First 1
    $heightProperty = $properties | Where-Object { $_.Name -match '^(height|screenHeight|screen_height|windowHeight|window_height|viewportHeight|viewport_height)$' } | Select-Object -First 1

    if ($widthProperty -and $heightProperty) {
        $width = 0
        $height = 0
        if ([int]::TryParse([string]$widthProperty.Value, [ref]$width) -and [int]::TryParse([string]$heightProperty.Value, [ref]$height)) {
            if ($width -gt 0 -and $height -gt 0) {
                return "${width}x${height}"
            }
        }
    }

    foreach ($property in $properties) {
        $result = Get-ResolutionFromWidthHeightPair -Value $property.Value -Depth ($Depth + 1)
        if ($result) {
            return $result
        }
    }

    return $null
}

function Get-ResolutionFromProfile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Profile
    )

    $nameResolution = Get-ResolutionFromText -Text $Profile.name
    if ($nameResolution) {
        return $nameResolution
    }

    $candidatePropertyNames = @(
        "resolution",
        "screenResolution",
        "screen_resolution",
        "screen",
        "display",
        "viewport",
        "window"
    )

    foreach ($propertyName in $candidatePropertyNames) {
        $property = $Profile.PSObject.Properties | Where-Object { $_.Name -ieq $propertyName } | Select-Object -First 1
        if ($property) {
            $textResolution = Get-ResolutionFromText -Text ([string]$property.Value)
            if ($textResolution) {
                return $textResolution
            }

            $pairResolution = Get-ResolutionFromWidthHeightPair -Value $property.Value
            if ($pairResolution) {
                return $pairResolution
            }
        }
    }

    $nestedResolution = Get-ResolutionFromWidthHeightPair -Value $Profile
    if ($nestedResolution) {
        return $nestedResolution
    }

    try {
        $jsonResolution = Get-ResolutionFromText -Text ($Profile | ConvertTo-Json -Depth 12 -Compress)
        if ($jsonResolution) {
            return $jsonResolution
        }
    }
    catch {
        return $null
    }

    return $null
}