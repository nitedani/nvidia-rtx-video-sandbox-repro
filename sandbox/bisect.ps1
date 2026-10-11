# Which restriction makes the driver fail? For each token variant it prints, measured together in one run:
#   VSR output       repro with RTX VSR requested under that token (BLACK = all-zero frame)
#   nvdlppx.dll      WinVerifyTrust on VSR's neural-network module: the embedded signature and the catalog lookup
#   nvAIHDRx.dll     WinVerifyTrust (embedded signature) on RTX HDR's module
#   HDR VRAM         VRAM growth of the stream test with RTX VSR and RTX HDR requested (more than 100 MB/s = LEAK)
#   AI modules       which of nvppex / nvdlppx / nvAIHDRx are mapped into that same running stream process, 4 s in (? = none found or not readable)
# RTX VSR and RTX HDR must both be ON in the NVIDIA Control Panel or app. Takes about 7 minutes; nothing is shown on screen.
. "$PSScriptRoot\..\common.ps1"
Assert-Built

$store = "$env:SystemRoot\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_*"
$vsrDll = Get-ChildItem "$store\nvdlppx.dll" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
$hdrDll = Get-ChildItem "$store\nvAIHDRx.dll" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $vsrDll -or -not $hdrDll) { throw 'nvdlppx.dll / nvAIHDRx.dll not found in the driver store (is the NVIDIA driver installed?)' }
$state = Get-DriverState
if (-not $state -or -not $state.Vsr -or -not $state.Hdr) { Write-Warning 'RTX VSR and RTX HDR are not both ON in the driver: the VSR and HDR columns will read ok / flat for the wrong reason.' }

# sbx's default restricting SIDs, used when SBX_RS is not set (Sids $null below).
$default = 'users,everyone,restricted,user,logon'
function Row([string]$Label, [string]$Mode, $Sids = $null, [switch]$WriteRestricted) {
    [pscustomobject]@{ Label = $Label; Mode = $Mode; Sids = $Sids; WriteRestricted = [bool]$WriteRestricted }
}
$rows = @(
    Row 'no sandbox'                           'none'
    Row 'lowil only'                           'lowil'
    Row 'job only'                             'job'
    Row 'restricted (default 5 SIDs)'          'restricted'
    Row 'lowil+restricted+job (Chromium-like)' $script:ChromeSandbox
    Row 'default + Authenticated Users'        'restricted' "$default,auth"
    Row 'default + SYSTEM'                     'restricted' "$default,system"
    Row 'default + Administrators'             'restricted' "$default,admins"
    Row 'default + INTERACTIVE'                'restricted' "$default,interactive"
    Row 'default + SERVICE'                    'restricted' "$default,svc"
    Row 'default + NETWORK SERVICE'            'restricted' "$default,netsvc"
    Row 'default + LOCAL SERVICE'              'restricted' "$default,locsvc"
    Row 'default, WRITE_RESTRICTED flag'       'restricted' -WriteRestricted
)

function Get-VsrResult($mode) {
    $r = Get-Outcome $mode $script:VsrCheckArgs
    if ($r) { $r } else { 'did not run' }
}

# WinVerifyTrust on `dll` under the token: both answers, 'TRUSTED' / 'NOT TRUSTED' / 'no catalog' / 'did not run'.
function Get-Signature($mode, $dll) {
    $o = Invoke-Sandboxed $mode @($script:Wvt, $dll.FullName)
    $emb = [regex]::Match($o, 'embedded signature\)\s+-> \S+ (NOT TRUSTED|TRUSTED)')
    $cat = [regex]::Match($o, 'catalog [^)]*\) -> \S+ (NOT TRUSTED|TRUSTED)')
    [pscustomobject]@{
        Embedded = $(if ($emb.Success) { $emb.Groups[1].Value } else { 'did not run' })
        Catalog  = $(if ($cat.Success) { $cat.Groups[1].Value } elseif ($o -match 'no catalog found') { 'no catalog' } else { 'did not run' })
    }
}

# One stream run per row (VSR and HDR requested): VRAM growth from its output, and the AI modules mapped 4 s in.
function Get-StreamColumns($mode) {
    $s = Get-StreamResult $mode (@('--vsr', '1', '--hdr', '1', '--out', 'rgb10a2') + $script:ChromeLikeSize)
    if (-not $s) { return [pscustomobject]@{ Growth = 'did not run'; Modules = 'did not run' } }
    [pscustomobject]@{
        Growth  = '{0,4:N0} MB/s {1}' -f $s.MBperSecond, $(if ($s.MBperSecond -gt $script:LeakMBperSecond) { 'LEAK' } else { 'flat' })
        Modules = $(if ($s.Modules) { ($s.Modules -replace '\.dll$', '') -join ' ' } else { '?' })
    }
}

$fmt = '{0,-38} {1,-9} {2,-26} {3,-13} {4,-14} {5}'
$fmt -f 'token', 'VSR out', 'nvdlppx (embedded/catalog)', 'nvAIHDRx', 'HDR VRAM', 'AI modules mapped'
try {
    foreach ($r in $rows) {
        $env:SBX_RS = $r.Sids; $env:SBX_WRITE_RESTRICTED = $(if ($r.WriteRestricted) { '1' } else { $null })
        $vsrSig = Get-Signature $r.Mode $vsrDll; $hdrSig = Get-Signature $r.Mode $hdrDll; $stream = Get-StreamColumns $r.Mode
        $fmt -f $r.Label, (Get-VsrResult $r.Mode), "$($vsrSig.Embedded) / $($vsrSig.Catalog)", $hdrSig.Embedded, $stream.Growth, $stream.Modules
    }
} finally { $env:SBX_RS = $null; $env:SBX_WRITE_RESTRICTED = $null }
