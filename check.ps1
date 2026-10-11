# Does this machine show the bugs? One line per bug, in about 20 seconds. Nothing is drawn on screen.
# Needs an NVIDIA RTX GPU with RTX VSR and RTX HDR both ON in the NVIDIA Control Panel or app.
# Build first: build.bat and sandbox\build.bat. The stream test stops by itself after 8 s or when it uses a third of the GPU memory budget (at most 6000 MB).
# Exit code: 0 no bug reproduced (a fixed driver), 1 at least one reproduced, 2 nothing reproduced but something could not be tested.
. "$PSScriptRoot\common.ps1"

try { Assert-Built } catch { Write-Output $_.Exception.Message; exit 2 }
$lines = @()
function Report([string]$Name, [string]$Status, [string]$Detail) { $script:lines += [pscustomobject]@{ Status = $Status }; '{0,-58} {1,-15} {2}' -f $Name, $Status, $Detail }

$state = Get-DriverState
if (-not $state) { Write-Output 'repro.exe did not reach the NVIDIA driver: check that an NVIDIA RTX GPU is present.'; exit 2 }
"RTX VSR is $(if ($state.Vsr) { 'ON' } else { 'OFF' }) and RTX HDR is $(if ($state.Hdr) { 'ON' } else { 'OFF' }) in the driver (a normal process that requests a feature loads its AI module only when the feature is on)."

# 1. VSR in a restricted-token process: an all-zero frame, S_OK.
$name = 'VSR gives an all-zero frame in a restricted-token process'
if (-not $state.Vsr) { Report $name 'skipped' 'turn RTX VSR on in the Control Panel first' }
else {
    $normal = Get-Outcome 'none' $script:VsrCheckArgs; $restricted = Get-Outcome 'restricted' $script:VsrCheckArgs
    if (-not $normal -or -not $restricted) { Report $name 'could not run' '' }
    else { Report $name $(if ($restricted -eq 'BLACK' -and $normal -eq 'ok') { 'REPRODUCED' } else { 'not reproduced' }) "normal process: $normal, restricted: $restricted" }
}

# 2. RTX HDR in a restricted-token process: VRAM grows every frame.
$name = 'RTX HDR leaks VRAM in a restricted-token process'
if (-not $state.Hdr) { Report $name 'skipped' 'turn RTX HDR on in the Control Panel first' }
else {
    $args2 = @('--hdr', '1', '--vsr', '0', '--out', 'rgb10a2') + $script:ChromeLikeSize
    $normal = Get-StreamResult 'none' $args2; $restricted = Get-StreamResult $script:ChromeSandbox $args2
    if (-not $normal -or -not $restricted) { Report $name 'could not run' '' }
    else {
        $leak = $restricted.MBperSecond -gt $script:LeakMBperSecond -and $normal.MBperSecond -lt $script:FlatMBperSecond
        Report $name $(if ($leak) { 'REPRODUCED' } else { 'not reproduced' }) ('normal {0:N0} MB/s, restricted {1:N0} MB/s ({2:N1} MB per frame at {3:N0} frames/s), restricted process loaded: {4}' -f $normal.MBperSecond, $restricted.MBperSecond, $restricted.MBperFrame, $restricted.Fps, $(if ($restricted.Modules) { $restricted.Modules -join ' ' } else { 'none of nvppex, nvAIHDRx' }))
    }
}

# 3. Independent of RTX Video: a BT.2020 PQ 10-bit to 8-bit YUV copy returns all zeros.
$name = 'P010 to NV12 with BT.2020 PQ gives an all-zero frame'
$pq = Get-Outcome 'none' @('--vsr', '0', '--hdr', '0', '--out', 'nv12', '--in', 'p010', '--out-cs', 'pq', '--frames', '3')
$g22 = Get-Outcome 'none' @('--vsr', '0', '--hdr', '0', '--out', 'nv12', '--in', 'p010', '--out-cs', 'g22', '--frames', '3')
if (-not $pq -or -not $g22) { Report $name 'could not run' '' }
else { Report $name $(if ($pq -eq 'BLACK' -and $g22 -eq 'ok') { 'REPRODUCED' } else { 'not reproduced' }) "PQ: $pq, BT.709: $g22" }

if ($lines.Status -contains 'REPRODUCED') { exit 1 }
if ($lines.Status -contains 'skipped' -or $lines.Status -contains 'could not run') { exit 2 }
exit 0
