param(
    [string]$CsvPath = "all-results.csv",
    [string]$OutputPath = "benchmark-summary.txt"
)

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$data = Import-Csv $CsvPath

function Get-Percentile([double[]]$values, [double]$percentile) {
    $sorted = $values | Sort-Object
    $n = $sorted.Count
    $rank = ($percentile / 100) * ($n - 1)
    $lower = [math]::Floor($rank)
    $upper = [math]::Ceiling($rank)
    $frac = $rank - $lower
    if ($lower -eq $upper) {
        return $sorted[$lower]
    }
    return $sorted[$lower] * (1 - $frac) + $sorted[$upper] * $frac
}

function Get-Stats([double[]]$values) {
    $sorted = $values | Sort-Object
    $n = $sorted.Count
    $mean = ($values | Measure-Object -Average).Average
    $median = Get-Percentile $values 50
    $sumSqDiff = ($values | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum
    $stddev = [math]::Sqrt($sumSqDiff / ($n - 1))
    $p5   = Get-Percentile $values 5
    $p25  = Get-Percentile $values 25
    $p75  = Get-Percentile $values 75
    $p95  = Get-Percentile $values 95
    $iqr  = $p75 - $p25
    $cv   = if ($mean -ne 0) { ($stddev / $mean) * 100 } else { 0 }

    return [ordered]@{
        N      = $n
        Mean   = [math]::Round($mean, 2)
        Median = [math]::Round($median, 2)
        StdDev = [math]::Round($stddev, 3)
        CV_Pct = [math]::Round($cv, 2)
        Min    = [math]::Round(($sorted | Select-Object -First 1), 2)
        Max    = [math]::Round(($sorted | Select-Object -Last 1), 2)
        P5     = [math]::Round($p5, 2)
        P25    = [math]::Round($p25, 2)
        P75    = [math]::Round($p75, 2)
        P95    = [math]::Round($p95, 2)
        IQR    = [math]::Round($iqr, 2)
    }
}

$apps = $data | Select-Object -ExpandProperty App -Unique

$output = [System.Text.StringBuilder]::new()
[void]$output.AppendLine("=" * 70)
[void]$output.AppendLine("  BENCHMARK SUMMARY")
[void]$output.AppendLine("  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$output.AppendLine("=" * 70)

foreach ($app in $apps) {
    $rows = $data | Where-Object { $_.App -eq $app }
    $startupValues = $rows | ForEach-Object { [double]$_.StartupSeconds }
    $ramValues     = $rows | ForEach-Object { [double]$_.RAM_MB }

    $startupStats = Get-Stats $startupValues
    $ramStats     = Get-Stats $ramValues

    [void]$output.AppendLine("")
    [void]$output.AppendLine("-" * 70)
    [void]$output.AppendLine("  $app  (n=$($startupStats.N) runs)")
    [void]$output.AppendLine("-" * 70)

    [void]$output.AppendLine("")
    [void]$output.AppendLine("  Startup Time (seconds):")
    [void]$output.AppendLine("    Mean:    $($startupStats.Mean)s")
    [void]$output.AppendLine("    Median:  $($startupStats.Median)s")
    [void]$output.AppendLine("    StdDev:  $($startupStats.StdDev)s")
    [void]$output.AppendLine("    CV:      $($startupStats.CV_Pct)%")
    [void]$output.AppendLine("    Min:     $($startupStats.Min)s    Max: $($startupStats.Max)s")
    [void]$output.AppendLine("    P5:      $($startupStats.P5)s     P95: $($startupStats.P95)s")
    [void]$output.AppendLine("    P25:     $($startupStats.P25)s    P75: $($startupStats.P75)s")
    [void]$output.AppendLine("    IQR:     $($startupStats.IQR)s")

    [void]$output.AppendLine("")
    [void]$output.AppendLine("  RAM Usage (MB):")
    [void]$output.AppendLine("    Mean:    $($ramStats.Mean) MB")
    [void]$output.AppendLine("    Median:  $($ramStats.Median) MB")
    [void]$output.AppendLine("    StdDev:  $($ramStats.StdDev) MB")
    [void]$output.AppendLine("    CV:      $($ramStats.CV_Pct)%")
    [void]$output.AppendLine("    Min:     $($ramStats.Min) MB    Max: $($ramStats.Max) MB")
    [void]$output.AppendLine("    P5:      $($ramStats.P5) MB     P95: $($ramStats.P95) MB")
    [void]$output.AppendLine("    P25:     $($ramStats.P25) MB    P75: $($ramStats.P75) MB")
    [void]$output.AppendLine("    IQR:     $($ramStats.IQR) MB")
}

# Comparative summary
if ($apps.Count -ge 2) {
    [void]$output.AppendLine("")
    [void]$output.AppendLine("=" * 70)
    [void]$output.AppendLine("  COMPARATIVE SUMMARY")
    [void]$output.AppendLine("=" * 70)

    $table = @()
    foreach ($app in $apps) {
        $rows = $data | Where-Object { $_.App -eq $app }
        $startupValues = $rows | ForEach-Object { [double]$_.StartupSeconds }
        $ramValues     = $rows | ForEach-Object { [double]$_.RAM_MB }
        $sStats = Get-Stats $startupValues
        $rStats = Get-Stats $ramValues
        $table += [PSCustomObject]@{
            App              = $app
            "Startup Median" = "$($sStats.Median)s"
            "Startup P95"    = "$($sStats.P95)s"
            "RAM Median"     = "$($rStats.Median) MB"
            "RAM P95"        = "$($rStats.P95) MB"
            "Runs"           = $sStats.N
        }
    }

    [void]$output.AppendLine("")
    $tableStr = ($table | Format-Table -AutoSize | Out-String).Trim()
    [void]$output.AppendLine($tableStr)

    # Relative comparison (first app as baseline)
    $baseApp = $apps[0]
    $baseStartup = ($data | Where-Object { $_.App -eq $baseApp } | ForEach-Object { [double]$_.StartupSeconds } | Measure-Object -Average).Average
    $baseRam     = ($data | Where-Object { $_.App -eq $baseApp } | ForEach-Object { [double]$_.RAM_MB } | Measure-Object -Average).Average

    [void]$output.AppendLine("")
    [void]$output.AppendLine("  Relative to $baseApp (baseline = 1.00x):")

    foreach ($app in $apps) {
        $appStartup = ($data | Where-Object { $_.App -eq $app } | ForEach-Object { [double]$_.StartupSeconds } | Measure-Object -Average).Average
        $appRam     = ($data | Where-Object { $_.App -eq $app } | ForEach-Object { [double]$_.RAM_MB } | Measure-Object -Average).Average
        $startupRatio = [math]::Round($appStartup / $baseStartup, 2)
        $ramRatio     = [math]::Round($appRam / $baseRam, 2)
        [void]$output.AppendLine("    ${app}: Startup ${startupRatio}x  |  RAM ${ramRatio}x")
    }
}

[void]$output.AppendLine("")
[void]$output.AppendLine("=" * 70)

$result = $output.ToString()
$result | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host $result
Write-Host "`nSummary saved to $OutputPath"
