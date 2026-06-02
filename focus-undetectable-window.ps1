param (
    [string]$WindowTitle,
    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt"),
    [int]$MaxAttempts = 10,
    [int]$DelayMilliseconds = 500
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WindowTitle) -and (Test-Path -LiteralPath $ProfileStatePath)) {
    $WindowTitle = (Get-Content -LiteralPath $ProfileStatePath -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($WindowTitle)) {
    Write-Warning "No Undetectable profile title is available to focus."
    exit 0
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
    Write-Warning "Could not find a visible window matching '$WindowTitle'."
    exit 0
}

[UndetectableWindowFocus]::ShowWindow($windowHandle, 9) | Out-Null
Start-Sleep -Milliseconds 100
[UndetectableWindowFocus]::SetForegroundWindow($windowHandle) | Out-Null

Write-Host "Focused browser window '$WindowTitle'." -ForegroundColor Green