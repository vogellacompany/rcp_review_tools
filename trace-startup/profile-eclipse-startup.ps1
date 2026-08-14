<#
.SYNOPSIS
    Poor man's profiler for Eclipse startup on Windows.

.DESCRIPTION
    Starts Eclipse, samples one thread with "jcmd Thread.print" while it comes up,
    writes every dump to a file and prints a summary: a timeline, the most frequent
    triggering frame, the hottest leaf frames and an inclusive frame count.

    Windows has no SIGQUIT, so jcmd is the only sampling method here. Each jcmd call
    starts its own JVM, which costs roughly 150 to 250 ms, so the effective interval
    is the requested interval plus that. The Linux script in this directory can sample
    an order of magnitude faster.

.EXAMPLE
    .\profile-eclipse-startup.ps1 -EclipseExe C:\eclipse\eclipse.exe -Data C:\ws\platform

.EXAMPLE
    .\profile-eclipse-startup.ps1 -AnalyzeOnly -UntilMs 7000

.EXAMPLE
    .\profile-eclipse-startup.ps1 -AnalyzeOnly -Thread "Start Level" -UntilMs 1300
#>
[CmdletBinding()]
param(
    [string]$EclipseExe = (Join-Path $PWD 'eclipse.exe'),
    [string]$Data,
    [int]$DurationSec = 25,
    [int]$IntervalMs = 250,
    [string]$Out = (Join-Path $PWD 'eclipse-startup-stacks.txt'),
    [string]$Thread = 'main',
    [int]$TargetPid = 0,
    [int]$UntilMs = 0,
    [string]$JcmdExe = 'jcmd',
    [switch]$StopAfter,
    [switch]$AnalyzeOnly,
    [string]$Filter = 'org\.eclipse\.(pde|jdt|ui|e4|core|team|search|debug|ant|equinox\.p2)'
)

$ErrorActionPreference = 'Stop'

function Test-IsDescendant {
    param([int]$ChildPid, [int]$AncestorPid)
    $p = $ChildPid
    for ($i = 0; $i -lt 20 -and $p -gt 0; $i++) {
        if ($p -eq $AncestorPid) { return $true }
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if (-not $proc) { return $false }
        $p = [int]$proc.ParentProcessId
    }
    return $false
}

# The native launcher usually loads the JVM in process, but with a -vm entry pointing
# at a java executable it forks a child instead, so the started pid is not always the JVM.
function Get-JvmPid {
    param([int]$RootPid)
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $candidates = @()
        foreach ($line in (& $JcmdExe -l 2>$null)) {
            if ($line -match '^(\d+)\s+(.*)$' -and $Matches[2] -match 'equinox\.launcher') {
                $candidates += [int]$Matches[1]
            }
        }
        if ($candidates.Count -eq 1) { return $candidates[0] }
        foreach ($c in $candidates) {
            if ($c -eq $RootPid -or (Test-IsDescendant -ChildPid $c -AncestorPid $RootPid)) { return $c }
        }
        Start-Sleep -Milliseconds 100
    }
    return 0
}

function Get-ThreadStacks {
    param([string]$File, [string]$ThreadName, [int]$Until = 0)

    $stacks = New-Object System.Collections.ArrayList
    $prefix = '"' + $ThreadName
    $cur = $null
    $label = ''
    $state = ''
    $skip = $false

    foreach ($line in [System.IO.File]::ReadLines($File)) {
        if ($line.StartsWith('===== sample ')) {
            if ($null -ne $cur -and $cur.Count -gt 0) {
                [void]$stacks.Add([pscustomobject]@{ Label = $label; State = $state; Frames = $cur })
            }
            $cur = $null
            $label = ($line -replace '=', '').Trim()
            $skip = $false
            if ($Until -gt 0 -and $label -match 't(\d+)ms') {
                $skip = ([int]$Matches[1] -gt $Until)
            }
            continue
        }
        if ($skip) { continue }
        # Prefix match, so -Thread "Start Level" finds the Equinox thread whose full
        # name carries a per run UUID.
        if ($line.StartsWith($prefix)) {
            $cur = New-Object System.Collections.ArrayList
            $state = ''
            continue
        }
        if ($null -ne $cur) {
            $t = $line.Trim()
            if ($t -eq '') {
                if ($cur.Count -gt 0) {
                    [void]$stacks.Add([pscustomobject]@{ Label = $label; State = $state; Frames = $cur })
                }
                $cur = $null
                continue
            }
            if ($t.StartsWith('java.lang.Thread.State:')) {
                $state = ($t -split '\s+')[1]
                continue
            }
            if ($t.StartsWith('at ')) { [void]$cur.Add($t) }
        }
    }
    if ($null -ne $cur -and $cur.Count -gt 0) {
        [void]$stacks.Add([pscustomobject]@{ Label = $label; State = $state; Frames = $cur })
    }
    return , $stacks
}

function Show-Summary {
    param($Stacks, [string]$ThreadName, [string]$FilterRegex)

    if (-not $Stacks -or $Stacks.Count -eq 0) {
        Write-Warning "No `"$ThreadName`" stacks found"
        return
    }

    $idleRe = 'Display\.sleep|eventLoopIdle|Display\.readAndDispatch'
    $idle = @($Stacks | Where-Object { ($_.Frames -join "`n") -match $idleRe }).Count
    $busy = $Stacks.Count - $idle

    Write-Host ""
    Write-Host "$($Stacks.Count) samples of the `"$ThreadName`" thread: $busy busy, $idle in the event loop"

    Write-Host ""
    Write-Host "Timeline:"
    foreach ($s in $Stacks) {
        $frame = $s.Frames | Where-Object { $_ -match $FilterRegex } | Select-Object -First 1
        if (-not $frame) { $frame = $s.Frames[0] }
        "{0,-24} {1,-9} {2}" -f $s.Label, $s.State, $frame
    }

    Write-Host ""
    Write-Host "Most frequent triggering frame:"
    $Stacks | ForEach-Object {
        $f = $_.Frames | Where-Object { $_ -match $FilterRegex } | Select-Object -First 1
        if ($f) { $f } else { '(no Eclipse frame)' }
    } | Group-Object | Sort-Object Count -Descending | Select-Object -First 15 |
        Format-Table Count, Name -AutoSize

    Write-Host "Hottest leaf frames:"
    $Stacks | ForEach-Object { $_.Frames[0] } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 15 |
        Format-Table Count, Name -AutoSize

    Write-Host "Frames by number of samples that contain them (inclusive cost):"
    $threshold = [Math]::Ceiling($Stacks.Count * 0.15)
    $Stacks | ForEach-Object { $_.Frames | Select-Object -Unique } |
        Group-Object | Where-Object { $_.Count -ge $threshold } |
        Sort-Object Count -Descending | Select-Object -First 40 |
        Format-Table Count, Name -AutoSize
}

if ($AnalyzeOnly) {
    if (-not (Test-Path $Out)) { throw "No such file: $Out" }
    Show-Summary -Stacks (Get-ThreadStacks -File $Out -ThreadName $Thread -Until $UntilMs) `
        -ThreadName $Thread -FilterRegex $Filter
    return
}

$launched = $null
if ($TargetPid -gt 0) {
    $jvmPid = $TargetPid
} else {
    if (-not (Test-Path $EclipseExe)) {
        throw "No such Eclipse launcher: $EclipseExe. Pass -EclipseExe <path>."
    }
    if (Get-Process eclipse -ErrorAction SilentlyContinue) {
        throw "An eclipse process is already running, close it first (or pass -TargetPid)."
    }

    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    Remove-Item $Out -ErrorAction SilentlyContinue
    Write-Host "Writing stacks to $Out"

    $launchArgs = @()
    if ($Data) { $launchArgs += @('-data', $Data) }
    $launched = if ($launchArgs.Count) {
        Start-Process -FilePath $EclipseExe -ArgumentList $launchArgs -PassThru
    } else {
        Start-Process -FilePath $EclipseExe -PassThru
    }

    $jvmPid = Get-JvmPid -RootPid $launched.Id
    if ($jvmPid -eq 0) {
        throw "Could not find the JVM process for launcher $($launched.Id)."
    }
    Write-Host "Launcher PID $($launched.Id), JVM PID $jvmPid"
}

Write-Host "Sampling for $DurationSec s every $IntervalMs ms via jcmd"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$n = 0
$captured = 0
while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
    if ($launched -and $launched.HasExited) {
        Write-Warning "eclipse exited after $([int]$sw.Elapsed.TotalSeconds) s"
        break
    }
    $n++
    $dump = & $JcmdExe $jvmPid Thread.print 2>&1
    if ($LASTEXITCODE -eq 0) {
        $captured++
        "===== sample $n t=$([int]$sw.Elapsed.TotalMilliseconds)ms =====" | Add-Content $Out -Encoding utf8
        $dump | Add-Content $Out -Encoding utf8
    }
    Start-Sleep -Milliseconds $IntervalMs
}

Write-Host "$captured of $n sampling attempts succeeded"
if ($captured -eq 0) {
    Write-Warning "Could not attach. Check whether the JVM runs in a separate process: Get-Process java,javaw"
    return
}

if ($StopAfter -and $launched) {
    Stop-Process -Id $jvmPid -ErrorAction SilentlyContinue
}

Show-Summary -Stacks (Get-ThreadStacks -File $Out -ThreadName $Thread -Until $UntilMs) `
    -ThreadName $Thread -FilterRegex $Filter
