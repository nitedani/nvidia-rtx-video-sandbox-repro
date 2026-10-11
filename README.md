# RTX Video in sandboxed processes: black frames and a VRAM leak

On my RTX 5080 with driver 616.56, Chrome shows black video when RTX Video Super Resolution (VSR) is on, and its GPU process fills the video memory when RTX Video HDR is on. Firefox leaks the same way. This repo reproduces both without a browser. It runs the D3D11 video processor in a process with a restricted Windows token, the kind of token both browsers give their GPU process:

- With RTX VSR on, `VideoProcessorBlt` returns `S_OK` and writes an all-zero frame.
- With RTX HDR on, the process loses about 9.4 MB of VRAM per frame (304 MB/s at 32 frames per second).

In a normal process both features work. My guess at the cause, from tracing, is that the driver can't load its AI modules in the restricted process because their signature check fails there. I have no driver source, so below I keep what I measured apart from what I inferred.

## Run it

You need Windows 11, an NVIDIA RTX card, and Visual Studio 2022 with the C++ workload. Turn on RTX VSR and RTX HDR in the NVIDIA Control Panel (Video > Adjust video image settings > RTX video enhancement) or the NVIDIA app. On my machine RTX HDR could only be turned on with Windows' own HDR setting on. Then, in PowerShell:

```
git clone https://github.com/nitedani/nvidia-rtx-video-sandbox-repro
cd nvidia-rtx-video-sandbox-repro
.\build.bat
.\sandbox\build.bat
powershell -ExecutionPolicy Bypass -File .\check.ps1
```

`check.ps1` takes about 20 seconds and draws nothing on screen. On my machine it printed this (`results/check-output.txt`):

```
RTX VSR is ON and RTX HDR is ON in the driver (a normal process that requests a feature loads its AI module only when the feature is on).
VSR gives an all-zero frame in a restricted-token process  REPRODUCED      normal process: ok, restricted: BLACK
RTX HDR leaks VRAM in a restricted-token process           REPRODUCED      normal 0 MB/s, restricted 304 MB/s (9.4 MB per frame at 32 frames/s), restricted process loaded: nvppex.dll
P010 to NV12 with BT.2020 PQ gives an all-zero frame       REPRODUCED      PQ: BLACK, BT.709: ok
```

The third line is a separate bug, described at the end. A line prints `skipped` when its feature is off in the Control Panel. On the RTX HDR line, `restricted process loaded` lists the driver's video modules in the sandboxed process; `nvAIHDRx.dll` is missing there, and in a normal process it loads. The leak test stops after 8 seconds, so it can't fill the card. The exit code is 1 if any line reproduces, otherwise 2 if a line was skipped or could not run, otherwise 0.

`BLACK` means every value the test samples is zero: the whole luma plane for NV12 or P010 output, and every 4th pixel of a 16-row strip through the middle for RGB output. A frame is only judged after `VideoProcessorBlt` returned exactly `S_OK`; on any other result `repro.exe` prints the HRESULT and exits with 3, and `check.ps1` shows `could not run`.

The black frame by hand, first in a normal process, then in a restricted one:

```
.\repro.exe --vsr 1 --out rgb10a2 --in-size 1920x1080 --out-size 3076x1730 --out-cs 0 --in-cs 8
.\sandbox\sbx.exe restricted .\repro.exe --vsr 1 --out rgb10a2 --in-size 1920x1080 --out-size 3076x1730 --out-cs 0 --in-cs 8
```

The first prints a `RESULT` line ending in `-> ok`, the second one ending in `-> BLACK`. The colour spaces are `DXGI_COLOR_SPACE_TYPE` numbers (0 is full-range RGB, 8 is studio-range BT.709 YCbCr), and `.\repro.exe --help` lists the options.

### In a browser

These scripts open a visible window with a throwaway profile, play the bundled test clip, and print the VRAM of the browser's processes until it reaches a cap (6000 MB by default, `-CapMB` to change it):

```
powershell -ExecutionPolicy Bypass -File .\capture\leak_test.ps1
powershell -ExecutionPolicy Bypass -File .\capture\firefox_check.ps1
```

RTX VSR only upscales, so the video has to be shown larger than its 1280-pixel source: the scripts need a screen wider than about 1900 pixels. Keep the screen on while they run: with the screen off, Chrome stayed flat until I turned its occlusion tracking off, and then it leaked (`results/chrome-screen-off.txt`). They find Chrome and Firefox in the usual install folders; `-ChromeExe` and `-Firefox` take another path.

## What I found

### Why I think it's the driver

`repro.cpp` is a plain D3D11 program with no browser code. It creates a video processor, turns on NVIDIA's RTX Video stream extensions with `VideoProcessorSetStreamExtension`, and calls `VideoProcessorBlt`. It uses the same GUIDs, versions and methods as [Chromium's `swap_chain_presenter.cc`](https://github.com/chromium/chromium/blob/26d17c7ff99f7c4777dbc6cd76884f33b3494353/ui/gl/swap_chain_presenter.cc#L210-L316). `sandbox/sbx.c` builds its token with the public `CreateRestrictedToken` call. Firefox's GPU process has the same kind of token as Chrome's and leaks the same way, so it isn't Chrome's code.

A call that can't do its work should return an error, not `S_OK` with an empty frame, and it shouldn't lose memory every frame, whatever token the caller has. What I haven't shown: that other programs with a restricted token are affected, and whether NVIDIA's guidance for these extensions says anything about sandboxed callers.

### Measured

- **What triggers it.** A restricted token. Low integrity alone and a job object alone don't. Adding Authenticated Users, SYSTEM or Administrators to the token's restricting SIDs (the second list of groups every access check must also pass), or setting the `WRITE_RESTRICTED` flag, fixes both bugs. INTERACTIVE, SERVICE, NETWORK SERVICE and LOCAL SERVICE don't (`results/token-fingerprint.txt`, made by `sandbox/bisect.ps1`; each cell is a single run, not repeated).
- **The modules.** In a normal process the driver loads `nvdlppx.dll` (VSR) and `nvAIHDRx.dll` (RTX HDR). In the restricted process, over 5 frames with one feature requested per run, it tries to open `nvdlppx.dll` 15 times and `nvAIHDRx.dll` 14 times and never loads either. The same runs show 17 `CatRoot2\dberr.txt` events and 540 operations on the `SystemCertificates\CA` registry key. With neither feature requested (both still on in the Control Panel), all of these are zero (`results/trace-summary.txt` from `sandbox/trace_objs.ps1`; `results/trace-summary-rerun.txt` repeats the VSR run with the same counts). I count the debugger's breakpoint hits on entry, so these are attempts; I can't tell which of them succeeded.
- **The signature check.** `WinVerifyTrust` on both DLLs succeeds in a normal process. In the restricted process the embedded-signature check returns `0x80096005` and the catalog lookup fails with `ERROR_SERVICE_NOT_ACTIVE` (1062) (`results/wvt-output.txt`). Across the token table the embedded check follows the outcome and the catalog lookup doesn't: with Authenticated Users added there's still no catalog entry, yet everything works.
- **Chrome's token.** Chrome's GPU process runs at Low integrity with a restricted token and 5 restricting SIDs: Users, Everyone, RESTRICTED, one SID that doesn't resolve to an account, and the logon session (`results/chrome-gpu-token.txt`). `sbx.exe` builds the same list with the current user in place of the unresolved SID, and it keeps more groups enabled, 14 against Chrome's 4 (`results/sbx-token.txt`). I haven't tested whether those differences matter; both show the same two bugs.
- **Chrome.** Stock Chrome 155 with its default sandbox, on Twitch, with the video shown larger than its source (`results/chrome-matrix.txt`):

  | RTX VSR | RTX HDR | GPU process VRAM | Video on my screen |
  |---|---|---|---|
  | off | off | flat | not recorded |
  | on | off | flat | black |
  | off | on | 339 MB to 6 GB in about 18 s, when I stopped it | not recorded |
  | on | on | 14,772 MB at the first sample | black |

  In the RTX HDR only row the GPU process id changed once on the way (a restart or a crash; I didn't look); `results/chrome-vram-samples.txt` has its raw samples. I judged black by looking at my screen. A DevTools screenshot showed normal video, I think because it captures the page before the video overlay is drawn, so this repo has no images.
- **Firefox.** Firefox 157.0.1's GPU process has the same token shape as Chrome's. Its VRAM went from 298 MB to 6,360 MB in 17 s on Twitch, and from 1,806 MB to 6,549 MB in 20 s on the bundled clip, when my cap stopped it (`results/firefox-check.txt`). Chrome on the bundled clip grew 283 MB/s (`results/chrome-leak-test-bundled-clip.txt`). I didn't record the picture in these runs.
- **Chrome with its GPU sandbox off.** With `--disable-gpu-sandbox` (the other processes stay sandboxed), both features worked: on Twitch RTX VSR upscaled the video and RTX HDR was applied, and the GPU process stayed flat at about 950 MB. `--no-sandbox` did the same. So turning off only the GPU process sandbox is enough for the driver to work. These were early runs, before I controlled the window size, so their samples are not in `results/`.

The machine is in `results/environment.txt`. It's all one machine, one driver and one video site.

### Inferred

The driver verifies each AI module with `WinVerifyTrust` when it loads it, and that check needs access a restricted token doesn't have. When the check fails, VSR is skipped without an error. Both modules are retried about three times per frame, but only the RTX HDR path loses memory on each attempt, so the leak is in RTX HDR's failure path.

### Unknown

- Which object the check is denied. The SID pattern points at something Authenticated Users, SYSTEM and Administrators can write to, but Users and Everyone can't.
- What the leaked 9.4 MB per frame is.
- Whether Chrome's black video is the same all-zero frame the repro writes.
- Why the first run of a freshly built `repro.exe` with VSR on writes a different, non-black frame from the runs after it (`results/first-run-warmup.txt`).

### A separate bug: BT.2020 conversions

Without the RTX Video extensions requested, `VideoProcessorBlt` returns `S_OK` and writes an all-zero frame in 44 of 400 runs: 10 input by 10 output colour spaces, for each of 4 NV12/P010 format pairs (`results/colorspace-sweep.csv`, made by `sandbox/colorspace_sweep.ps1`). In every failing run both colour spaces are BT.2020 YCbCr: DXGI 10, 11, 13 or 16. The [Chromium issue 556956704](https://issues.chromium.org/issues/556956704) page links NVIDIA developer bug 6723321 for a BT.2020 YUV-to-YUV copy that writes zeros, so NVIDIA may already have this one; the sweep is a fuller list of the failing pairs.

### Reported by others

In [Brave issue 51910](https://github.com/brave/brave-browser/issues/51910), a [January 2026 comment](https://github.com/brave/brave-browser/issues/51910#issuecomment-3756999708) says NVIDIA is working on a fix for black video with RTX VSR on driver 591.74, and suggested launching the browser with `--no-sandbox` in the meantime. [Another commenter](https://github.com/brave/brave-browser/issues/51910#issuecomment-3870058490) says that flag makes RTX VSR work. I haven't checked either.

## Files

| Path | What it is |
|---|---|
| `check.ps1` | The 20-second check above. |
| `repro.cpp` | The video-processor test. `--mode check` writes one frame and reads it back; `--mode stream` plays frames to a hidden swap chain the way a browser does and prints the VRAM. |
| `sandbox/sbx.c` | Runs a program under a restricted token. Modes `lowil`, `restricted` and `job` combine with `+` (`lowil+restricted+job`); `none` runs it unchanged. `SBX_RS` picks the restricting SIDs. |
| `sandbox/wvt.c` | Runs `WinVerifyTrust` on a file, embedded and catalog. |
| `sandbox/bisect.ps1` | The token table. Takes several minutes. |
| `sandbox/trace_objs.ps1`, `sandbox/summarize_trace.ps1` | Log what the sandboxed program opens and count it. Needs `cdb` from the Windows SDK debugging tools (`-Cdb` takes its path). |
| `sandbox/colorspace_sweep.ps1` | The 400-run colour-space sweep. |
| `sandbox/inspect_gpu_sandbox.ps1` | Starts a throwaway Chrome for a few seconds and prints the token of its processes. |
| `capture/leak_test.ps1`, `capture/firefox_check.ps1` | The browser checks above. |
| `capture/leak_trace.ps1`, `capture/cdp_mem.js` | Like `leak_test.ps1`, with Chrome's own GPU memory accounting next to the Windows counters. Needs Node 22 or newer. |
| `capture/test-720p.mp4`, `capture/test-video.html` | The test clip (8 seconds, 1280x720 H.264, made with `ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -t 8 -c:v libx264 -profile:v high -pix_fmt yuv420p -preset veryslow -crf 38 -g 60 -movflags +faststart test-720p.mp4`) and the page that loops it. |
| `common.ps1`, `build.bat`, `sandbox/build.bat`, `vsenv.bat` | Shared script helpers and the build. |
| `results/` | The measurements quoted above. In the token dumps I replaced the logon session number and my account name by hand. |
