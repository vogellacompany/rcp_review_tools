<#
.SYNOPSIS
    Prints the full thread stack of the samples that match a regular expression.

.DESCRIPTION
    Companion to profile-eclipse-startup.ps1. The summary there prints one frame per
    sample so the timeline stays readable; this prints the complete stack of the
    samples you care about. It reports how many samples matched before printing, so a
    count of zero tells you the filter missed rather than leaving you with an empty
    result.

.EXAMPLE
    .\show-blocking-stack.ps1 -Match 'Workbench\.initializeImages'

.EXAMPLE
    .\show-blocking-stack.ps1 -Match 'AbstractBundleContainer\.resolve' -Count 2

.EXAMPLE
    .\show-blocking-stack.ps1 -Thread "Start Level" -Match 'Activator'
#>
[CmdletBinding()]
param(
    [string]$File = (Join-Path $PWD 'eclipse-startup-stacks.txt'),
    [string]$Match = 'AbstractBundleContainer\.resolve',
    [int]$Count = 1,
    [string]$Thread = 'main'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $File)) { throw "No such file: $File" }

$stacks = New-Object System.Collections.ArrayList
$prefix = '"' + $Thread
$cur = $null
$label = ''
$state = ''

foreach ($line in [System.IO.File]::ReadLines($File)) {
    if ($line.StartsWith('===== sample ')) {
        if ($null -ne $cur -and $cur.Count -gt 0) {
            [void]$stacks.Add([pscustomobject]@{ Label = $label; State = $state; Frames = $cur })
        }
        $cur = $null
        $label = ($line -replace '=', '').Trim()
        continue
    }
    # Prefix match, so -Thread "Start Level" finds the Equinox thread whose full name
    # carries a per run UUID.
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

$hits = @($stacks | Where-Object { ($_.Frames -join "`n") -match $Match })
Write-Host "$($hits.Count) of $($stacks.Count) samples match '$Match'"

foreach ($s in ($hits | Select-Object -First $Count)) {
    Write-Host ""
    Write-Host "----- $($s.Label) ($($s.State)) -----"
    $s.Frames
}
