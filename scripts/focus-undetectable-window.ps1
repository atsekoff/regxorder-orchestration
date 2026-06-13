param (
    [string]$WindowTitle,
    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt"),
    [int]$MaxAttempts = 10,
    [int]$DelayMilliseconds = 500
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\profile-state.ps1")

if ([string]::IsNullOrWhiteSpace($WindowTitle) -and (Test-Path -LiteralPath $ProfileStatePath)) {
    $profileState = Get-OrchestrationProfileState -StatePath $ProfileStatePath
    if ($profileState) {
        $WindowTitle = $profileState.ProfileName
    }
}

if ([string]::IsNullOrWhiteSpace($WindowTitle)) {
    throw "No Undetectable profile title is available to focus."
}

if (-not ("UndetectableWindowFocus" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class UndetectableWindowFocus
{
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static IntPtr FindWindowByTitle(string titlePart)
    {
        IntPtr foundHandle = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd))
            {
                return true;
            }

            StringBuilder sb = new StringBuilder(512);
            GetWindowText(hWnd, sb, sb.Capacity);
            if (sb.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                foundHandle = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return foundHandle;
    }
}
"@
}

$windowHandle = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt $MaxAttempts -and $windowHandle -eq [IntPtr]::Zero; $attempt++) {
    $windowHandle = [UndetectableWindowFocus]::FindWindowByTitle($WindowTitle)
    if ($windowHandle -eq [IntPtr]::Zero) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
}

if ($windowHandle -eq [IntPtr]::Zero) {
    throw "Could not find a visible window matching '$WindowTitle'."
}

$focusSucceeded = $false
for ($attempt = 0; $attempt -lt $MaxAttempts -and -not $focusSucceeded; $attempt++) {
    [UndetectableWindowFocus]::ShowWindow($windowHandle, 9) | Out-Null
    [UndetectableWindowFocus]::SetForegroundWindow($windowHandle) | Out-Null
    Start-Sleep -Milliseconds $DelayMilliseconds
    $focusSucceeded = ([UndetectableWindowFocus]::GetForegroundWindow() -eq $windowHandle)
}

if (-not $focusSucceeded) {
    throw "Failed to set foreground window for '$WindowTitle'."
}

Write-Host "Focused browser window '$WindowTitle'." -ForegroundColor Green
