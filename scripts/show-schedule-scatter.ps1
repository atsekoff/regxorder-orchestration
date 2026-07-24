param(
    [datetime]$From = (Get-Date).Date,
    [datetime]$To = (Get-Date).Date.AddDays(1),
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\schedule-scatter.html")
)

$ErrorActionPreference = "Stop"
$fetcherPath = Join-Path $PSScriptRoot "..\bin\bettingpair-fetch.exe"
$json = & $fetcherPath --from $From.ToString("yyyy-MM-dd") --to $To.ToString("yyyy-MM-dd")
if ($LASTEXITCODE -ne 0) {
    throw "Schedule fetch failed with exit code $LASTEXITCODE."
}

$response = $json | ConvertFrom-Json
$events = if ($null -ne $response.schedules) {
    @(
        foreach ($schedule in $response.schedules) {
            foreach ($click in $schedule.clicks) {
                $parts = $click.time.Split(":")
                [PSCustomObject]@{
                    Date        = $click.date
                    Time        = $click.time
                    MinuteOfDay = ([int]$parts[0] * 60) + [int]$parts[1]
                    Schedule    = "PC $($schedule.pc)"
                    Market      = $click.name
                    Country     = $click.country
                    Url         = $click.url
                }
            }
        }
    )
}
else {
    @(
        foreach ($market in $response.schedule) {
            foreach ($day in $market.events) {
                foreach ($time in $day.times) {
                    $parts = $time.Split(":")
                    [PSCustomObject]@{
                        Date        = $day.date
                        Time        = $time
                        MinuteOfDay = ([int]$parts[0] * 60) + [int]$parts[1]
                        Schedule    = "$($market.name)/$($market.country)"
                        Market      = $market.name
                        Country     = $market.country
                        Url         = $market.url
                    }
                }
            }
        }
    )
}

$lanes = @($events | Group-Object Date, Schedule | Sort-Object { $_.Group[0].Date }, { $_.Group[0].Schedule })
$width = 1500
$left = 190
$right = 30
$top = 70
$laneHeight = 52
$plotWidth = $width - $left - $right
$height = $top + ($lanes.Count * $laneHeight) + 70
$culture = [Globalization.CultureInfo]::InvariantCulture
$html = [Text.StringBuilder]::new()

[void]$html.AppendLine('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">')
[void]$html.AppendLine('<title>Schedule event distribution</title><style>body{margin:0;background:#f4f1e8;color:#202522;font-family:Segoe UI,sans-serif}main{padding:24px}h1{font-size:22px;margin:0 0 4px}p{margin:0 0 18px;color:#59615c}.chart{overflow-x:auto;background:#fff;border:1px solid #c9cec9}svg{display:block;min-width:1100px}.grid{stroke:#dce0dc;stroke-width:1}.axis{fill:#59615c;font-size:12px}.lane{fill:#202522;font-size:13px}.point{stroke:#fff;stroke-width:2}.Megapari{fill:#cf3f32}.Wintopia{fill:#147d78}</style></head><body><main>')
[void]$html.AppendLine("<h1>Exact schedule event times</h1><p>$($From.ToString('yyyy-MM-dd')) through $($To.ToString('yyyy-MM-dd')) · $($response.timezone) · $($events.Count) events</p><div class=`"chart`">")
[void]$html.AppendLine("<svg viewBox=`"0 0 $width $height`" role=`"img`" aria-label=`"Scatter plot of exact schedule event times`">")

for ($hour = 0; $hour -le 24; $hour++) {
    $x = $left + ($hour / 24 * $plotWidth)
    [void]$html.AppendLine([string]::Format($culture, '<line class="grid" x1="{0:F2}" y1="45" x2="{0:F2}" y2="{1}"/><text class="axis" x="{0:F2}" y="35" text-anchor="middle">{2:00}:00</text>', $x, ($height - 45), ($hour % 24)))
}

for ($laneIndex = 0; $laneIndex -lt $lanes.Count; $laneIndex++) {
    $laneEvents = $lanes[$laneIndex].Group
    $lane = $laneEvents[0]
    $y = $top + ($laneIndex * $laneHeight)
    $label = "$($lane.Date)  $($lane.Schedule)"
    [void]$html.AppendLine("<text class=`"lane`" x=`"$($left - 12)`" y=`"$($y + 4)`" text-anchor=`"end`">$label</text>")
    [void]$html.AppendLine("<line class=`"grid`" x1=`"$left`" y1=`"$y`" x2=`"$($width - $right)`" y2=`"$y`"/>")
    foreach ($event in $laneEvents) {
        $x = $left + ($event.MinuteOfDay / 1440 * $plotWidth)
        $title = "$($event.Date) $($event.Time) · $($event.Market)/$($event.Country)"
        [void]$html.AppendLine([string]::Format($culture, '<circle class="point {0}" cx="{1:F2}" cy="{2}" r="6"><title>{3}</title></circle>', $event.Market, $x, $y, $title))
    }
}

[void]$html.AppendLine('</svg></div></main></body></html>')
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $html.ToString())
Write-Output "Created $([IO.Path]::GetFullPath($OutputPath)) with $($events.Count) events."