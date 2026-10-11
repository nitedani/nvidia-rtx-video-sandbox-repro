param([string]$Rs = "", [int]$Vsr = 1, [int]$Hdr = 0, [string]$Cdb = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe")
# Runs repro under a restricted Low-integrity token, attaches cdb (Windows SDK debugger) while repro waits at start-up,
# and logs the name of every kernel object it opens or creates (files, registry keys, sections, events...) to obj_vsr<Vsr>_hdr<Hdr>.log.
# Run it twice (for example -Vsr 1 and -Vsr 0) and diff the object names to see what a feature touches.
# Entry-only breakpoints: nothing is skipped, but the log does not say whether a call succeeded.
. "$PSScriptRoot\..\common.ps1"
Assert-Built
if (-not (Test-Path $Cdb)) { throw "cdb.exe not found at ${Cdb}. Install the Windows SDK Debugging Tools or pass -Cdb." }
$cdbScript = Join-Path $PSScriptRoot "obj_vsr${Vsr}_hdr${Hdr}.cdb"; $log = Join-Path $PSScriptRoot "obj_vsr${Vsr}_hdr${Hdr}.log"

$functions = 'NtCreateFile', 'NtOpenFile', 'NtOpenKey', 'NtOpenKeyEx', 'NtCreateKey', 'NtOpenSection', 'NtCreateSection', 'NtOpenEvent', 'NtCreateEvent',
             'NtOpenMutant', 'NtCreateMutant', 'NtOpenSemaphore', 'NtCreateSemaphore', 'NtOpenDirectoryObject'
$commands = @('.logopen /u "' + $log + '"', '.echo TRACE_START')
foreach ($f in $functions) {
    # r8 = POBJECT_ATTRIBUTES; ObjectName is at +0x10, its Buffer at +8; the desired access is in edx.
    $commands += ('bp ntdll!{0} ".if (@r8 != 0) {{ .if (poi(@r8+10) != 0) {{ .printf \"OBJ {0} access=%08x name=%mu\n\", @edx, poi(poi(@r8+10)+8) }} }}; g"' -f $f)
}
$commands += 'sxe -c "q" epr'   # quit when the process exits
$commands += 'g'
$commands | Set-Content $cdbScript -Encoding ascii

$env:SBX_RS = if ($Rs) { $Rs } else { $null }
$run = Start-Sandboxed 'lowil+restricted' (@($script:Repro, '--vsr', "$Vsr", '--hdr', "$Hdr", '--out', 'rgb10a2', '--frames', '5') + $script:ChromeLikeSize + @('--wait-ms', '15000'))
$env:SBX_RS = $null
if (-not $run.ChildPid) { "repro did not start"; return }
"attaching cdb to sandboxed repro pid $($run.ChildPid) (vsr=$Vsr hdr=$Hdr)"
$debugger = Start-Process $Cdb -ArgumentList @('-p', "$($run.ChildPid)", '-cf', (ConvertTo-QuotedArgument $cdbScript)) -PassThru -WindowStyle Hidden
if (-not $debugger.WaitForExit(60000)) { "cdb timed out; killing"; Stop-Process -Id $debugger.Id -Force }
Stop-Sandboxed $run
if (Test-Path $log) { "log: $log ($((Get-Item $log).Length) bytes)" } else { "no log produced" }
