# Helpers shared by the scripts (dot-source it: . "$PSScriptRoot\..\common.ps1").

# The first existing path of the candidates, or $null.
function Find-Browser([string[]]$Candidates) { $Candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1 }
$script:DefaultChrome = Find-Browser @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
$script:DefaultFirefox = Find-Browser @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe", "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe")
$script:Repro = Join-Path $PSScriptRoot 'repro.exe'
$script:Sbx = Join-Path $PSScriptRoot 'sandbox\sbx.exe'
$script:Wvt = Join-Path $PSScriptRoot 'sandbox\wvt.exe'

function Assert-Built {
    $missing = @($script:Repro, $script:Sbx, $script:Wvt | Where-Object { -not (Test-Path $_) })
    if ($missing) { throw "Not built: $($missing -join ', '). Run build.bat and sandbox\build.bat first." }
}

# A Chrome-like case seen on a 3840x2160 display: 1080p video scaled to a 3076x1730 window, output colour space RGB gamma 2.2.
$script:ChromeLikeSize = @('--in-size', '1920x1080', '--out-size', '3076x1730', '--out-cs', '0', '--in-cs', '8')
# The VSR check (5 frames, RTX VSR requested) and the stream test (stops by itself after 8 s).
$script:VsrCheckArgs = @('--vsr', '1', '--hdr', '0', '--out', 'rgb10a2', '--frames', '5') + $script:ChromeLikeSize
$script:StreamArgs = @('--mode', 'stream', '--frames', '2000000', '--max-seconds', '8')

# The sbx mode that matches Chromium's GPU-process sandbox, and the VRAM growth (MB/s) above which the stream test counts as leaking.
$script:ChromeSandbox = 'lowil+restricted+job'
$script:LeakMBperSecond = 100
$script:FlatMBperSecond = 20   # below this, a process counts as flat

# Windows PowerShell 5.1 does not quote elements of -ArgumentList, so a path with a space would be split.
function ConvertTo-QuotedArgument([string]$Argument) {
    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }
    '"' + ($Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# The browser scripts' VRAM cap reads this counter; without it (e.g. on a non-English Windows) every sample is 0 and the cap never fires.
function Assert-GpuCounter {
    $s = $null; try { $s = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples } catch { }
    if (-not $s) { throw 'The "GPU Process Memory" performance counter is not available (it needs a recent Windows and its English name). Without it the VRAM cap cannot work, so the script stops.' }
}

# Dedicated GPU memory (MB) of one process, from the "GPU Process Memory" performance counter. 0 if unavailable.
function Get-GpuMB([int]$ProcessId) {
    $s = (Get-Counter "\GPU Process Memory(pid_${ProcessId}_*)\Dedicated Usage" -ErrorAction SilentlyContinue).CounterSamples
    if ($s) { [int](($s | Measure-Object CookedValue -Sum).Sum / 1MB) } else { 0 }
}

# ---- throwaway Chrome ---------------------------------------------------------------------------------------

# A Chrome with a fresh profile and the sandbox on. Returns the process and its profile folder.
function Start-ThrowawayChrome([string]$Url, [string[]]$ExtraArgs = @(), [string]$ChromeExe = '') {
    if (-not $ChromeExe) { $ChromeExe = $script:DefaultChrome }
    if (-not $ChromeExe) { throw 'Chrome not found in the usual folders: pass -ChromeExe <path to chrome.exe>' }
    $dir = Join-Path $env:TEMP ("vsr-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $chromeArgs = @("--user-data-dir=$dir", "--no-first-run", "--no-default-browser-check", "--force-high-performance-gpu",
                    "--autoplay-policy=no-user-gesture-required", "--start-maximized", "--new-window") + $ExtraArgs + @($Url)
    [pscustomobject]@{ Process = (Start-Process $ChromeExe -ArgumentList ($chromeArgs | ForEach-Object { ConvertTo-QuotedArgument $_ }) -PassThru); Dir = $dir }
}

function Get-ThrowawayChromeProcesses($Chrome) {
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($Chrome.Dir) }
}

function Find-ChromeGpuProcess($Chrome) {
    Get-ThrowawayChromeProcesses $Chrome | Where-Object { $_.CommandLine -match '--type=gpu-process' } | Select-Object -First 1
}

# Samples the GPU process's VRAM every 2 s (plus the query time) for $Seconds while $While holds; stops at the first sample above $CapMB.
function Watch-ChromeGpuVram($Chrome, [double]$Seconds, [int]$CapMB, [scriptblock]$While = { $true }) {
    $clock = [Diagnostics.Stopwatch]::StartNew(); $samples = @(); $capped = $false
    while ($clock.Elapsed.TotalSeconds -lt $Seconds -and (& $While)) {
        Start-Sleep -Seconds 2
        $gpu = Find-ChromeGpuProcess $Chrome
        $mb = if ($gpu) { Get-GpuMB $gpu.ProcessId } else { 0 }
        $samples += [pscustomobject]@{ T = $clock.Elapsed.TotalSeconds; Mb = $mb }
        if ($mb -gt $CapMB) { $capped = $true; break }
    }
    [pscustomobject]@{ Samples = $samples; Capped = $capped }
}

# Stops only the Chrome processes that belong to this profile folder, then deletes the folder.
function Stop-ThrowawayChrome($Chrome) {
    Get-ThrowawayChromeProcesses $Chrome | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Remove-Item $Chrome.Dir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- sandboxed runs -----------------------------------------------------------------------------------------

# Starts `sbx <mode> <command...>` hidden and returns the sandboxed child's pid, which sbx prints on stderr.
# Environment variables set by the caller (SBX_RS, SBX_WRITE_RESTRICTED) are inherited.
function Start-Sandboxed([string]$Mode, [string[]]$Command) {
    $base = Join-Path $env:TEMP ("sbx-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $errFile = "$base.err"
    $sbxArgs = (@($Mode) + $Command) | ForEach-Object { ConvertTo-QuotedArgument $_ }
    $launcher = Start-Process $script:Sbx -ArgumentList $sbxArgs -PassThru -WindowStyle Hidden -RedirectStandardError $errFile -RedirectStandardOutput "$base.out"
    $childPid = 0
    for ($i = 0; $i -lt 40 -and -not $childPid; $i++) {
        Start-Sleep -Milliseconds 250
        $m = [regex]::Match([string](Get-Content $errFile -Raw -ErrorAction SilentlyContinue), 'child pid (\d+)')
        if ($m.Success) { $childPid = [int]$m.Groups[1].Value } elseif ($launcher.HasExited) { break }
    }
    [pscustomobject]@{ Launcher = $launcher; ChildPid = $childPid; ErrFile = $errFile; OutFile = "$base.out" }
}

# Stops the sandboxed child (by pid, never by name) and removes the temp files.
function Stop-Sandboxed($Run) {
    if ($Run.ChildPid) { Stop-Process -Id $Run.ChildPid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-Item $Run.ErrFile, $Run.OutFile -Force -ErrorAction SilentlyContinue
}

# Runs `sbx <mode> <command...>` to completion and returns its combined output.
function Invoke-Sandboxed([string]$Mode, [string[]]$Command) {
    (& $script:Sbx $Mode @Command 2>&1 | Out-String)
}

# ---- measurements -------------------------------------------------------------------------------------------

# Are RTX VSR / RTX HDR on? A normal process that requests them maps nvdlppx.dll / nvAIHDRx.dll only if on. $null if repro did not reach the driver.
function Get-DriverState {
    $run = Start-Process -FilePath $script:Repro -WindowStyle Hidden -PassThru -ArgumentList (
        $script:StreamArgs + @('--vsr', '1', '--hdr', '1', '--out', 'rgb10a2') + $script:ChromeLikeSize)
    try {
        $deadline = (Get-Date).AddSeconds(6)
        do { Start-Sleep -Milliseconds 500; $modules = Get-LoadedNvidiaModules $run.Id } until (($modules -contains 'nvppex.dll') -or $run.HasExited -or (Get-Date) -gt $deadline)
        Start-Sleep -Milliseconds 1500   # the AI modules load a moment after nvppex.dll
        $modules = Get-LoadedNvidiaModules $run.Id
    } finally { if (-not $run.HasExited) { Stop-Process -Id $run.Id -Force } }
    if ($modules -notcontains 'nvppex.dll') { return $null }
    [pscustomobject]@{ Vsr = ($modules -contains 'nvdlppx.dll'); Hdr = ($modules -contains 'nvAIHDRx.dll') }
}

# The stream test under `sbx <mode>`: fps, VRAM growth per s and per frame after the first second, stop reason, AI modules mapped 4 s in; $null under 2 samples.
function Get-StreamResult([string]$Mode, [string[]]$ReproArgs) {
    $run = Start-Sandboxed $Mode (@($script:Repro) + $script:StreamArgs + $ReproArgs)
    if (-not $run.ChildPid) { Stop-Sandboxed $run; return $null }
    Start-Sleep -Seconds 4
    $modules = Get-LoadedNvidiaModules $run.ChildPid
    [void]$run.Launcher.WaitForExit(30000)
    $o = [string](Get-Content $run.OutFile -Raw)
    Stop-Sandboxed $run
    $lines = @([regex]::Matches($o, 'stream (?:end )?t=([\d.]+) frame=(\d+) vram_mb=(\d+)') | ForEach-Object {
        [pscustomobject]@{ T = [double]$_.Groups[1].Value; Frame = [int]$_.Groups[2].Value; Mb = [double]$_.Groups[3].Value } } | Where-Object { $_.T -ge 1 })
    $reason = [regex]::Match($o, 'reason=(\S+)').Groups[1].Value
    if ($lines.Count -lt 2) { return $null }
    $first = $lines[0]; $last = $lines[-1]; $dt = $last.T - $first.T; $dframes = $last.Frame - $first.Frame
    [pscustomobject]@{
        Seconds = $dt; Frames = $dframes; Reason = $reason; FirstMb = $first.Mb; LastMb = $last.Mb
        Fps = $dframes / $dt; MBperSecond = ($last.Mb - $first.Mb) / $dt
        MBperFrame = $(if ($dframes -gt 0) { ($last.Mb - $first.Mb) / $dframes } else { 0 })
        Modules = $modules
    }
}

# Runs repro once under `sbx <mode>` and returns its outcome: 'BLACK', 'ok', or $null if it did not run.
function Get-Outcome([string]$Mode, [string[]]$ReproArgs) {
    $m = [regex]::Match((Invoke-Sandboxed $Mode (@($script:Repro) + $ReproArgs)), 'RESULT .*-> (\w+)')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

# Names of the NVIDIA AI/video modules mapped into a running process; empty if its modules cannot be read.
function Get-LoadedNvidiaModules([int]$ProcessId) {
    try { @((Get-Process -Id $ProcessId -ErrorAction Stop).Modules | Where-Object { $_.ModuleName -match '^(nvdlppx|nvAIHDRx|nvppex)' } | ForEach-Object { $_.ModuleName } | Sort-Object -Unique) }
    catch { @() }
}

# ---- token description --------------------------------------------------------------------------------------

# The security context of a process (token, integrity, restricting SIDs, groups) as text.
function Get-TokenDescription([int]$ProcessId) {
    if (-not ('Tok' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Tok {
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint acc, bool inh, int pid);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr t, int cls, IntPtr buf, int len, out int ret);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr str);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint n);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
  [DllImport("advapi32.dll")] static extern bool LookupAccountSid(string sys, IntPtr sid, StringBuilder name, ref int nl, StringBuilder dom, ref int dl, out int use);
  // An SID that does not resolve to an account is printed without its numbers (they may derive from the account): the output is meant to be shared.
  static string SidStr(IntPtr sid){ IntPtr s; ConvertSidToStringSid(sid, out s); string t = Marshal.PtrToStringUni(s); return t.Substring(0, Math.Min(6, t.Length)) + "<unresolved, rest hidden>"; }
  static string Name(IntPtr sid){ var n=new StringBuilder(256); var d=new StringBuilder(256); int nl=256, dl=256, u; return LookupAccountSid(null,sid,n,ref nl,d,ref dl,out u) ? d+"\\"+n : SidStr(sid); }
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  // TOKEN_INFORMATION_CLASS values.
  const int TokenGroups = 2, TokenPrivileges = 3, TokenRestrictedSids = 11, TokenIntegrityLevel = 25, TokenIsAppContainer = 29, TokenIsRestricted = 40;
  const int BufSize = 1 << 16;
  public static string Describe(int pid) {
    var sb = new StringBuilder();
    IntPtr hp = OpenProcess(0x1000, false, pid); if (hp==IntPtr.Zero) return "OpenProcess failed "+Marshal.GetLastWin32Error();
    IntPtr tk; if(!OpenProcessToken(hp, 0x8, out tk)) { int err = Marshal.GetLastWin32Error(); CloseHandle(hp); return "OpenProcessToken failed "+err; }
    // TOKEN_GROUPS: a DWORD count, then SID_AND_ATTRIBUTES entries { PSID, DWORD } aligned to the pointer size.
    int ptr = IntPtr.Size, entry = 2 * IntPtr.Size;
    int ret; IntPtr buf = Marshal.AllocHGlobal(BufSize);
    try {
      if (GetTokenInformation(tk, TokenIsAppContainer, buf, 4, out ret)) sb.AppendLine("IsAppContainer       : " + Marshal.ReadInt32(buf));
      if (GetTokenInformation(tk, TokenIntegrityLevel, buf, BufSize, out ret)) { IntPtr sid = Marshal.ReadIntPtr(buf); IntPtr cnt = GetSidSubAuthorityCount(sid); int c = Marshal.ReadByte(cnt); int rid = Marshal.ReadInt32(GetSidSubAuthority(sid,(uint)(c-1))); sb.AppendLine("Integrity RID        : 0x" + rid.ToString("x") + (rid==0x1000?" (Low)":rid==0x2000?" (Medium)":rid==0x3000?" (High)":rid==0x0000?" (Untrusted)":"")); }
      if (GetTokenInformation(tk, TokenIsRestricted, buf, BufSize, out ret)) sb.AppendLine("IsRestricted         : " + Marshal.ReadInt32(buf));
      if (GetTokenInformation(tk, TokenRestrictedSids, buf, BufSize, out ret)) { int n = Marshal.ReadInt32(buf); sb.AppendLine("Restricting SIDs     : " + n); IntPtr p = buf + ptr; for (int i=0;i<n;i++){ IntPtr sid = Marshal.ReadIntPtr(p); sb.AppendLine("    restricting: " + Name(sid)); p += entry; } }
      if (GetTokenInformation(tk, TokenPrivileges, buf, BufSize, out ret)) { int n = Marshal.ReadInt32(buf); sb.AppendLine("Privileges held     : " + n); }
      if (GetTokenInformation(tk, TokenGroups, buf, BufSize, out ret)) { int n = Marshal.ReadInt32(buf); int deny=0, en=0; IntPtr p = buf + ptr; for (int i=0;i<n;i++){ uint at = (uint)Marshal.ReadInt32(p+ptr); if ((at&0x10)!=0) deny++; if ((at&0x4)!=0) en++; p += entry; } sb.AppendLine("Groups               : " + n + " (enabled " + en + ", deny-only " + deny + ")"); }
    } finally { Marshal.FreeHGlobal(buf); CloseHandle(tk); CloseHandle(hp); }
    return sb.ToString();
  }
}
'@
    }
    [Tok]::Describe($ProcessId)
}
