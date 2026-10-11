param([string]$OutFile = "$PSScriptRoot\..\results\colorspace-sweep.csv")
# Which YCbCr colour-space pairs make VideoProcessorBlt return an all-zero frame (RTX Video not involved)?
# Tries every pair of 10 colour spaces (input x output) for NV12/P010 input and output, 400 runs, and writes a CSV.
# Colour-space numbers are DXGI_COLOR_SPACE_TYPE values:
#   6 STUDIO_G22_LEFT_P601   8 STUDIO_G22_LEFT_P709    9 FULL_G22_LEFT_P709     10 STUDIO_G22_LEFT_P2020  11 FULL_G22_LEFT_P2020
#   13 STUDIO_G2084_LEFT_P2020   15 STUDIO_G22_TOPLEFT_P2020   16 STUDIO_G2084_TOPLEFT_P2020   18 STUDIO_GHLG_TOPLEFT_P2020   23 STUDIO_G24_LEFT_P2020
. "$PSScriptRoot\..\common.ps1"

if (-not (Test-Path $script:Repro)) { Write-Error "repro.exe not found: run build.bat first"; exit 1 }
$spaces = 6, 8, 9, 10, 11, 13, 15, 16, 18, 23
$pairs = @(@('nv12', 'nv12'), @('p010', 'nv12'), @('nv12', 'p010'), @('p010', 'p010'))   # input format, output format
$exitAllZero = 2   # repro.exe's exit code for an all-zero output
$results = foreach ($pair in $pairs) { foreach ($in in $spaces) { foreach ($out in $spaces) {
    $o = (& $script:Repro --vsr 0 --hdr 0 --in $pair[0] --out $pair[1] --in-cs $in --out-cs $out --frames 3 2>&1 | Out-String)
    [pscustomobject]@{ Line = ('{0},{1},{2},{3},{4},{5}' -f $pair[0], $pair[1], $in, $out, $LASTEXITCODE, [regex]::Match($o, 'max=(\d+)').Groups[1].Value); Exit = $LASTEXITCODE }
} } }
@('infmt,outfmt,incs,outcs,exit,max') + @($results | ForEach-Object Line) | Set-Content $OutFile -Encoding ascii
$black = @($results | Where-Object { $_.Exit -eq $exitAllZero }).Count
"{0} of {1} pairs returned an all-zero frame; written to {2}" -f $black, @($results).Count, $OutFile
