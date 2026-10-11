param([string]$Url = ([uri](Join-Path $PSScriptRoot 'test-video.html')).AbsoluteUri, [string]$Firefox = '', [int]$Seconds = 40, [int]$CapMB = 6000)
# Starts a throwaway Firefox profile on $Url (a visible window opens) and prints
#   - the VRAM of every Firefox process about every 1.5 to 2 s, stopping at $CapMB so a leak cannot fill the GPU
#     (the cap is checked between samples, so it can be overshot by about 1 GB; on a card with 8 GB or less lower -CapMB),
#   - the token of one process of each type (Get-TokenDescription in common.ps1),
# then closes the processes of its own profile, also if something fails. The window is sized to the screen, at most 3200x1700, so that the
# video is shown larger than its source (RTX VSR only upscales); on a screen narrower than about 1900 px the script warns, because the
# video then may not be larger than its 1280 px source. Firefox is looked for in the usual folders; -Firefox overrides.
. "$PSScriptRoot\..\common.ps1"
if (-not $Firefox) { $Firefox = $script:DefaultFirefox }
if (-not $Firefox) { throw 'Firefox not found in the usual folders: pass -Firefox <path to firefox.exe>' }
Assert-GpuCounter

$dir = Join-Path $env:TEMP ('ff-profile-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir | Out-Null
@('user_pref("media.autoplay.default", 0);', 'user_pref("media.autoplay.blocking_policy", 0);', 'user_pref("browser.shell.checkDefaultBrowser", false);',
  'user_pref("browser.startup.homepage_override.mstone", "ignore");', 'user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);',
  'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);', 'user_pref("browser.aboutwelcome.enabled", false);') | Set-Content (Join-Path $dir 'user.js')

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Win { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  // The largest visible top-level window of the process with the given class name.
  public static IntPtr Find(uint pid, string cls) {
    IntPtr best = IntPtr.Zero; long bestArea = 0;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new System.Text.StringBuilder(128); GetClassName(h, sb, 128); if (sb.ToString() != cls) return true;
      RECT r; GetWindowRect(h, out r); long a = (long)(r.R - r.L) * (r.B - r.T); if (a > bestArea) { bestArea = a; best = h; } return true; }, IntPtr.Zero);
    return best; } }
'@
[void][Win]::SetProcessDPIAware()

# The browser process of this profile (the one with the profile folder on its command line) and everything below it.
function Get-ProfileProcesses {
    $all = Get-CimInstance Win32_Process -Filter "Name='firefox.exe'"
    $ids = @($all | Where-Object { $_.CommandLine -match [regex]::Escape($dir) -and $_.CommandLine -notmatch 'contentproc' } | ForEach-Object ProcessId)
    $grew = $true
    while ($grew) { $grew = $false; foreach ($p in $all) { if ($ids -contains $p.ParentProcessId -and $ids -notcontains $p.ProcessId) { $ids += $p.ProcessId; $grew = $true } } }
    $all | Where-Object { $ids -contains $_.ProcessId }
}
function Get-Type($p) { if ($p.CommandLine -match 'contentproc') { ($p.CommandLine.Trim() -split '\s+')[-1] } else { 'main' } }

try {
    Start-Process -FilePath $Firefox -ArgumentList (@('-no-remote', '-new-instance', '-profile', $dir, $Url) | ForEach-Object { ConvertTo-QuotedArgument $_ }) | Out-Null
    # Firefox's launcher process exits and hands over: find the browser by its profile folder.
    $main = $null
    for ($i = 0; $i -lt 40 -and -not $main; $i++) {
        Start-Sleep -Milliseconds 500
        $m = Get-ProfileProcesses | Where-Object { $_.CommandLine -notmatch 'contentproc' } | Select-Object -First 1
        if ($m -and [Win]::Find([uint32]$m.ProcessId, 'MozillaWindowClass') -ne [IntPtr]::Zero) { $main = $m }
    }
    if (-not $main) { throw 'Firefox browser process or its window not found' }

    $h = [Win]::Find([uint32]$main.ProcessId, 'MozillaWindowClass')
    $width = [Math]::Min(3200, [Win]::GetSystemMetrics(0) - 200); $height = [Math]::Min(1700, [Win]::GetSystemMetrics(1) - 200)
    [void][Win]::MoveWindow($h, 100, 100, $width, $height, $true)
    Start-Sleep -Seconds 3
    $r = New-Object Win+RECT; [void][Win]::GetWindowRect($h, [ref]$r)
    "started firefox pid $($main.ProcessId); window now {0}x{1} at ({2},{3})" -f ($r.R - $r.L), ($r.B - $r.T), $r.L, $r.T
    if (($r.R - $r.L) -lt 1900) { Write-Warning 'The window is narrower than about 1900 px: the video may not be shown larger than its 1280 px source, so RTX VSR may not engage.' }

    $clock = [Diagnostics.Stopwatch]::StartNew(); $samples = @{}; $stopped = ''
    while ($clock.Elapsed.TotalSeconds -lt $Seconds -and -not $stopped) {
        Start-Sleep -Milliseconds 1200
        $c = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        foreach ($p in Get-ProfileProcesses) {
            $mb = [int](($c | Where-Object { $_.InstanceName -like "pid_$($p.ProcessId)_*" } | Measure-Object CookedValue -Sum).Sum / 1MB)
            $key = '{0} pid {1}' -f (Get-Type $p), $p.ProcessId
            if (-not $samples.ContainsKey($key)) { $samples[$key] = @() }
            $samples[$key] += $mb
            if ($mb -gt $CapMB) { $stopped = "cap hit by $key at $mb MB"; break }
        }
    }
    "elapsed {0:N0} s. {1}" -f $clock.Elapsed.TotalSeconds, $(if ($stopped) { $stopped } else { 'cap not reached' })
    foreach ($k in ($samples.Keys | Sort-Object)) { $v = $samples[$k]; '{0,-22} samples {1,2}  first {2,5} MB  last {3,5} MB  max {4,5} MB' -f $k, $v.Count, $v[0], $v[-1], ($v | Measure-Object -Maximum).Maximum }

    "--- tokens (one process of each type)"
    $seen = @{}
    foreach ($p in Get-ProfileProcesses) {
        $t = Get-Type $p; if ($seen[$t]) { continue }; $seen[$t] = $true
        "=== $t (pid $($p.ProcessId))"
        ((Get-TokenDescription $p.ProcessId) -split "`r?`n") | Where-Object { $_ }
    }
} finally {
    foreach ($p in (Get-ProfileProcesses | Sort-Object ProcessId -Descending)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
"stopped the processes of this profile"
