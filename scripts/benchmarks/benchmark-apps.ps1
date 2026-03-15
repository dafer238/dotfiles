$apps = @(
    @{
        Name = "Bruno"
        Path = "C:\Users\dafer\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Scoop Apps\Bruno.lnk"
        Process = "bruno"
    },
    @{
        Name = "ApiArk"
        Path = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\ApiArk\ApiArk.lnk"
        Process = "apiark"
    }
)

$runs = 5
$results = @()

function Wait-ForIdle($processName) {
    $maxWait = 60
    $intervalMs = 250
    $waited = 0
    do {
        $procs = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        $cpu = ($procs | Measure-Object -Property CPU -Sum).Sum
        Start-Sleep -Milliseconds $intervalMs
        $waited += $intervalMs
        $procs = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        $cpu2 = ($procs | Measure-Object -Property CPU -Sum).Sum
    } while (($cpu2 - $cpu) -gt 0.025 -and $waited -lt ($maxWait * 1000))
}

function Get-ProcessTreeMemory($rootPid) {

    $all = Get-CimInstance Win32_Process

    $children = [System.Collections.ArrayList]@($rootPid)

    $index = 0
    while ($index -lt $children.Count) {
        $current = $children[$index]

        $all | Where-Object { $_.ParentProcessId -eq $current } |
        ForEach-Object { [void]$children.Add($_.ProcessId) }

        $index++
    }

    $total = 0

    foreach ($id in $children) {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc) {
            $total += $proc.WorkingSet64
        }
    }

    return $total
}

foreach ($app in $apps) {

    for ($i=1; $i -le $runs; $i++) {

        Write-Host "Running $($app.Name) test $i..."

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $p = Start-Process $app.Path -PassThru

        # Poll every 100ms for the actual process to appear (timeout 30s)
        $proc = $null
        $waitMs = 0
        while (-not $proc -and $waitMs -lt 30000) {
            Start-Sleep -Milliseconds 100
            $waitMs += 100
            $proc = Get-Process -Name $app.Process -ErrorAction SilentlyContinue
        }

        if (!$proc) {
            Write-Warning "Process not found for $($app.Name) after 30s"
            continue
        }

        Wait-ForIdle $app.Process

        $sw.Stop()

        $ramBytes = Get-ProcessTreeMemory $p.Id
		$ramMB = [math]::Round($ramBytes / 1MB,2)

        $results += [PSCustomObject]@{
            App = $app.Name
            Run = $i
            StartupSeconds = [math]::Round($sw.Elapsed.TotalSeconds,2)
            RAM_MB = $ramMB
        }

        Stop-Process -Name $app.Process -Force
        Start-Sleep 5
    }
}

$results | Export-Csv -Path "benchmark-results.csv" -NoTypeInformation
$results | Format-Table -AutoSize