<#
    Regxorder Batch Playback Script
#>
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot

# Function to handle the folder scanning and user selection
function Get-SessionSelection {
    param (
        [string]$Folder,
        [bool]$MultiSelect
    )

    $folderPath = ".\$Folder"

    if (-not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath | Out-Null
    }

    $folderFullPath = (Resolve-Path -LiteralPath $folderPath).Path

    # Fetch all .json files in the folder and any resolution subfolders.
    $files = @(Get-ChildItem -Path $folderPath -Filter *.json -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relativeName = $_.FullName.Substring($folderFullPath.Length).TrimStart('\', '/')
        [PSCustomObject]@{
            DisplayName = $relativeName
            Path        = ".\$Folder\$relativeName"
        }
    })
    
    if ($files.Count -eq 0) {
        Write-Host "  [No .json sessions found in $Folder]" -ForegroundColor Yellow
        return @()
    }

    # Print the available options with 1-based indices
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host "  [$($i + 1)] $($files[$i].DisplayName)"
    }
    Write-Host ""

    while ($true) {
        if ($MultiSelect) {
            $inputStr = Read-Host "Select indices to play (comma-separated, e.g., 1,3,2 or press Enter to skip)"
            if ([string]::IsNullOrWhiteSpace($inputStr)) { return @() }
            
            # Split by comma and clean up whitespace
            $indices = $inputStr.Split(',') | ForEach-Object { $_.Trim() }
            $selectedFiles = @()
            $valid = $true

            foreach ($idx in $indices) {
                if ($idx -match '^\d+$') {
                    $num = [int]$idx
                    if ($num -ge 1 -and $num -le $files.Count) {
                        $selectedFiles += $files[$num - 1].Path
                    }
                    else {
                        Write-Host "  Error: Index $num is out of range." -ForegroundColor Red
                        $valid = $false
                    }
                }
                else {
                    Write-Host "  Error: '$idx' is not a valid number." -ForegroundColor Red
                    $valid = $false
                }
            }
            if ($valid) { return $selectedFiles }
        }
        else {
            # Single selection mode (for main-sessions)
            $inputStr = Read-Host "Select exactly ONE index to play"
            if ($inputStr -match '^\d+$') {
                $num = [int]$inputStr
                if ($num -ge 1 -and $num -le $files.Count) {
                    return @($files[$num - 1].Path)
                }
            }
            Write-Host "  Error: Invalid selection. Please choose a single valid index." -ForegroundColor Red
        }
    }
}

# --- Main Script Execution ---
Clear-Host
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "               REGXORDER PLAYBACK UTILITY          " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Gather Pre-Sessions (Multi-select)
Write-Host ">>> Available PRE-SESSIONS:" -ForegroundColor Green
$preToPlay = @(Get-SessionSelection -Folder "pre-sessions" -MultiSelect $true)
Write-Host ""

# 2. Gather Main Sessions (Single-select)
Write-Host ">>> Available MAIN-SESSIONS:" -ForegroundColor Green
$mainToPlay = @(Get-SessionSelection -Folder "main-sessions" -MultiSelect $false)
Write-Host ""

# 3. Gather Post-Sessions (Multi-select)
Write-Host ">>> Available POST-SESSIONS:" -ForegroundColor Green
$postToPlay = @(Get-SessionSelection -Folder "post-sessions" -MultiSelect $true)
Write-Host ""

# Combine all targets into a single queue
$playbackQueue = @($preToPlay) + @($mainToPlay) + @($postToPlay)

if ($playbackQueue.Count -eq 0) {
    Write-Host "No sessions selected. Exiting." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    exit
}

# Display Queue Summary
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "READY FOR PLAYBACK QUEUE:" -ForegroundColor Cyan
foreach ($item in $playbackQueue) {
    Write-Host " -> $item" -ForegroundColor Gray
}
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "Press 'ctrl+shift+f10' to stop individual sessions."
Write-Host "Close this terminal window at any time to halt the entire sequence."
Write-Host ""
Read-Host "Press [ENTER] to start back-to-back playback..."

# Loop and execute the CLI back-to-back
foreach ($sessionPath in $playbackQueue) {
    Write-Host "Now Playing: $sessionPath ..." -ForegroundColor Magenta
    
    # Start playback, then shift focus to the selected browser once playback is beginning.
    $process = Start-Process -FilePath (Join-Path $repoRoot "regxorder-cli.exe") -ArgumentList "play", "--input", $sessionPath, "--stop-hotkey", "ctrl+shift+f10" -WorkingDirectory $repoRoot -NoNewWindow -PassThru
    Start-Sleep -Milliseconds 250
    & (Join-Path $PSScriptRoot "focus-undetectable-window.ps1") | Out-Null
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        Write-Host "Playback failed for $sessionPath with exit code $($process.ExitCode)." -ForegroundColor Red
        exit $process.ExitCode
    }
}

Write-Host ""
Write-Host "All selected sessions finished playing successfully!" -ForegroundColor Green
Start-Sleep -Seconds 3