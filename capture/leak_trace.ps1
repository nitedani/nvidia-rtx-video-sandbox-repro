param([string]$Url = ([uri](Join-Path $PSScriptRoot 'test-video.html')).AbsoluteUri, [int]$CapMB = 6000, [string]$ChromeExe = '')
# Throwaway sandboxed Chrome while its VRAM leaks: records Chrome's own memory accounting (DevTools memory-infra, see
# cdp_mem.js) next to the GPU process's real VRAM, each sample timed. If Chrome's own numbers stay flat while the VRAM
# climbs, the growth is in memory Chrome does not track. Needs Node 22 or newer. Chrome is stopped at CapMB.
. "$PSScriptRoot\..\common.ps1"

$port = 9555
$traceSeconds = 13
$nodeVersion = try { node --version } catch { '' }
if ($nodeVersion -notmatch '^v(2[2-9]|[3-9]\d|\d{3,})\.') { throw "Node 22 or newer is needed (cdp_mem.js uses its built-in WebSocket); found: $(if ($nodeVersion) { $nodeVersion } else { 'no node on PATH' })" }
Assert-GpuCounter
$chrome = Start-ThrowawayChrome $Url @("--remote-debugging-port=$port") $ChromeExe
$outFile = Join-Path $env:TEMP "cdp_mem_$port.out"
$node = $null
try {
    $node = Start-Process node -ArgumentList @((ConvertTo-QuotedArgument (Join-Path $PSScriptRoot 'cdp_mem.js')), "$port", "$traceSeconds") -PassThru -RedirectStandardOutput $outFile -WindowStyle Hidden
    $watch = Watch-ChromeGpuVram $chrome ($traceSeconds + 14) $CapMB { -not $node.HasExited }
    if (-not $watch.Capped -and -not $node.HasExited) { $null = $node.WaitForExit(20000) }
} finally {
    Stop-ThrowawayChrome $chrome
    if ($node -and -not $node.HasExited) { Stop-Process -Id $node.Id -Force }
}

"GPU-process VRAM (time s: MB): " + (($watch.Samples | ForEach-Object { '{0:N0}s: {1}' -f $_.T, $_.Mb }) -join '  ') + $(if ($watch.Capped) { " (stopped at the $CapMB MB cap)" })
if (Test-Path $outFile) { Get-Content $outFile; Remove-Item $outFile -ErrorAction SilentlyContinue }
