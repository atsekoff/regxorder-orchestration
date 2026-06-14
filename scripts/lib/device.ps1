function ConvertTo-DeviceFolderName {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -match '\b(android|iphone|ios|ipad|mobile|phone|tablet)\b') {
        return "mobile"
    }

    if ($normalized -match '\b(desktop|windows|win\d+|w10|w11|macos|mac|linux|pc)\b') {
        return "desktop"
    }

    return $null
}

function Get-DeviceFromProfile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Profile
    )

    $candidatePropertyNames = @(
        "device",
        "deviceType",
        "device_type",
        "platform",
        "os",
        "name"
    )

    foreach ($propertyName in $candidatePropertyNames) {
        $property = $Profile.PSObject.Properties | Where-Object { $_.Name -ieq $propertyName } | Select-Object -First 1
        if ($property) {
            $device = ConvertTo-DeviceFolderName -Value ([string]$property.Value)
            if ($device) {
                return $device
            }
        }
    }

    try {
        return ConvertTo-DeviceFolderName -Value ($Profile | ConvertTo-Json -Depth 12 -Compress)
    }
    catch {
        return $null
    }
}