param([Parameter(Mandatory)][string[]]$Logs)
# Counts what a trace_objs.ps1 log contains. The cdb log puts several "OBJ <function> access=<mask> name=<name>" entries
# on one line, so entries are found by pattern over the whole text, not line by line.
#   opens(<module>)   entries naming the module file (NtCreateFile / NtOpenFile)
#   loaded(<module>)  "ModLoad:" lines from the debugger: the module really was mapped into the process

function Get-TraceEntries([string]$Text) {
    [regex]::Matches($Text, 'OBJ (\w+) access=([0-9a-f]+) name=(.*?)(?=OBJ |\r|\n|$)') | ForEach-Object {
        [pscustomobject]@{ Function = $_.Groups[1].Value; Name = ($_.Groups[3].Value -replace '\s+ModLoad:.*$', '').Trim() } }
}

function Get-OpenCount($Entries, [string]$Module) {
    @($Entries | Where-Object { $_.Function -match 'File$' -and $_.Name -match [regex]::Escape($Module) + '$' }).Count
}

function Get-LoadedCount([string]$Text, [string]$Module) {
    [regex]::Matches($Text, 'ModLoad:[^\r\n]*\\' + [regex]::Escape($Module)).Count
}

foreach ($log in $Logs) {
    if (-not (Test-Path $log)) { throw "log not found: $log" }
    $text = Get-Content $log -Raw
    $entries = @(Get-TraceEntries $text)
    Split-Path $log -Leaf
    '  objects logged: {0}' -f $entries.Count
    foreach ($module in 'nvdlppx.dll', 'nvAIHDRx.dll') {
        '  opens({0}) {1,3}   loaded({0}) {2}' -f $module, (Get-OpenCount $entries $module), (Get-LoadedCount $text $module)
    }
    '  loaded(nvppex.dll) {0}   loaded(nvwgf2umx.dll) {1}' -f (Get-LoadedCount $text 'nvppex.dll'), (Get-LoadedCount $text 'nvwgf2umx.dll')
    '  CatRoot2\dberr.txt opened: {0}' -f @($entries | Where-Object { $_.Name -match 'CatRoot2\\dberr\.txt$' }).Count
    '  SystemCertificates\CA\... key opens/creates: {0}' -f @($entries | Where-Object { $_.Function -match 'Key' -and $_.Name -match 'SystemCertificates\\CA' }).Count
}
