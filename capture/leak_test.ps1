param([string]$Url = ([uri](Join-Path $PSScriptRoot 'test-video.html')).AbsoluteUri, [int]$Seconds = 40, [int]$CapMB = 6000, [string]$ChromeExe = '')
# Throwaway Chrome (fresh profile, sandbox on): samples the GPU process's VRAM every 2 s plus the time a sample takes
# (each sample is timed) and stops Chrome at CapMB or after $Seconds, so a leak cannot fill the GPU.
. "$PSScriptRoot\..\common.ps1"

Assert-GpuCounter
$chrome = Start-ThrowawayChrome $Url -ChromeExe $ChromeExe
try { $watch = Watch-ChromeGpuVram $chrome $Seconds $CapMB } finally { Stop-ThrowawayChrome $chrome }
$samples = $watch.Samples

"== $Url  $(if ($watch.Capped) { "stopped at the $CapMB MB cap" })"
($samples | ForEach-Object { '{0,5:N1}s {1,6} MB' -f $_.T, $_.Mb }) -join "`n"
$active = @($samples | Where-Object { $_.Mb -gt 0 })
if ($active.Count -ge 2) {
    $first = $active[0]; $last = $active[-1]
    'growth: {0:N0} MB/s over {1:N1} s (first {2} MB, last {3} MB)' -f (($last.Mb - $first.Mb) / ($last.T - $first.T)), ($last.T - $first.T), $first.Mb, $last.Mb
}
