param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("pre-sessions", "main-sessions", "post-sessions")]
    [string]$SessionType,

    [Parameter(Mandatory = $true)]
    [string]$SessionName,

    [Parameter(Mandatory = $false)]
    [string]$Resolution,

    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\resolution.ps1")
. (Join-Path $PSScriptRoot "lib\profile-state.ps1")

$resolutionWasProvided = $PSBoundParameters.ContainsKey("Resolution") -and -not [string]::IsNullOrWhiteSpace($Resolution)
$resolutionFolder = ConvertTo-ResolutionFolderName -Value $Resolution

if ($resolutionWasProvided -and [string]::IsNullOrWhiteSpace($resolutionFolder)) {
    throw "Invalid recording resolution '$Resolution'. Use widthxheight format, for example 1920x1080."
}

if (-not $resolutionWasProvided -and [string]::IsNullOrWhiteSpace($resolutionFolder)) {
    $resolutionFolder = Get-OrchestrationProfileResolution -StatePath $ProfileStatePath
}

if ([string]::IsNullOrWhiteSpace($resolutionFolder)) {
    throw "No recording resolution is available. Launch an Undetectable profile first or enter a resolution like 1920x1080."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetDirectory = Join-Path (Join-Path $repoRoot $SessionType) $resolutionFolder
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

Write-Output ".\$SessionType\$resolutionFolder\$SessionName.json"