# Launch a throwaway Chrome (sandbox ON) and describe the security context of its GPU process: token, integrity, AppContainer, restricting SIDs, groups.
param([string]$ChromeExe = '')
. "$PSScriptRoot\..\common.ps1"
$chrome = Start-ThrowawayChrome 'about:blank' -ChromeExe $ChromeExe
try {
    Start-Sleep -Seconds 7
    $all = Get-ThrowawayChromeProcesses $chrome
    foreach ($t in 'gpu-process','renderer','utility') {
        $x = $all | Where-Object { $_.CommandLine -match "--type=$t" } | Select-Object -First 1
        if ($x) { "=== $t (pid $($x.ProcessId))"; Get-TokenDescription $x.ProcessId }
    }
    $g = Find-ChromeGpuProcess $chrome
    if ($g) { "=== GPU process sandbox flags on its command line: " + $(if ($g.CommandLine -match '--(no-sandbox|disable-gpu-sandbox)') { $Matches[0] } else { 'none' }) }
} finally { Stop-ThrowawayChrome $chrome }
