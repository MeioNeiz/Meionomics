#Requires -Version 7.0
<#
LocalMods manager: keeps local WoW addon changes in place across addon updates.

  pwsh -File mods.ps1            apply: install overlay addons, apply every patch
  pwsh -File mods.ps1 status     check only, change nothing
  pwsh -File mods.ps1 revert <patch-name>   undo one patch (its NEW back to OLD)

-AddOns <path> points any of them at another install. Without it: _forever_\Interface\AddOns
beside this folder when it sits in the WoW folder, else the standard install
C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns.
Exit code: 0 all fine, 1 a patch is BROKEN, 2 AddOns folder not found.


Layout (next to this script):
  addons\<Name>\       overlay addons we own. Copied into the game's AddOns folder; this copy is the source.
  patches\*.patch      edits inside other people's addons (format: see README.md). Applied in name order.
  backups\<time>\      each file as it was before this tool changed it (this and below: not in git)
  state.json           addon versions seen last run (to report updates)
  last-run.md          the last run's report; BROKEN patches listed with what to do
#>
param(
    [ValidateSet('apply', 'status', 'revert')][string]$Command = 'apply',
    [string]$Name,
    [string]$AddOns = (Join-Path $PSScriptRoot '..\_forever_\Interface\AddOns'),
    [switch]$Coordinator
)
$ErrorActionPreference = 'Stop'
$lockPath = Join-Path $PSScriptRoot 'deploy.lock'
if ($Command -ne 'status' -and -not $Coordinator -and (Test-Path $lockPath)) {
    Write-Host "LOCKED: $((Get-Content -Raw $lockPath).Trim())"
    exit 3
}
# not given and not beside us (the repo cloned elsewhere): the standard install
if (-not $PSBoundParameters.ContainsKey('AddOns') -and -not (Test-Path $AddOns)) {
    $AddOns = 'C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns'
}
if (-not (Test-Path $AddOns)) {
    Write-Host "AddOns folder not found: $AddOns"
    Write-Host "Run again with -AddOns '<your WoW folder>\_forever_\Interface\AddOns'"
    exit 2
}
$AddOns = (Resolve-Path $AddOns).Path
$Root = $PSScriptRoot
$checkOnly = $Command -eq 'status'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $Root "backups\$stamp"
$backedUp = @{}
$report = [System.Collections.Generic.List[string]]::new()
$problems = 0

function Say([string]$line) { Write-Host $line; $report.Add($line) }

# ---------------------------------------------------------------- file io (keeps BOM and line endings)
function Read-Text([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes, ($bom ? 3 : 0), $bytes.Length - ($bom ? 3 : 0))
    [pscustomobject]@{ Text = $text; Bom = $bom; Crlf = $text.Contains("`r`n") }
}
function Write-Text([string]$path, $file, [string]$text) {
    if (-not $backedUp[$path]) {
        $rel = [IO.Path]::GetRelativePath($AddOns, $path)
        $dest = Join-Path $backupDir $rel
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $path $dest
        $backedUp[$path] = $true
    }
    $enc = [Text.UTF8Encoding]::new($file.Bom)
    [IO.File]::WriteAllText($path, $text, $enc)
}
function Count-Of([string]$hay, [string]$needle) {
    if ($needle.Length -eq 0) { return 0 }
    $n = 0; $i = 0
    while (($i = $hay.IndexOf($needle, $i, [StringComparison]::Ordinal)) -ge 0) { $n++; $i += $needle.Length }
    $n
}

# ---------------------------------------------------------------- patch file parsing
function Read-Patch([string]$path) {
    $lines = (Get-Content -LiteralPath $path -Raw -Encoding utf8) -replace "`r`n", "`n" -split "`n"
    $p = [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($path); Title = ''; Why = ''; Hunks = @() }
    $hunk = $null; $mode = $null; $buf = $null
    foreach ($l in $lines) {
        if ($l -match '^=== FILE (.+)$') {
            $hunk = [ordered]@{ File = $Matches[1].Trim(); Count = '1'; Inline = $false; Old = $null; New = $null }
            $mode = $null; continue
        }
        if ($hunk -and $l -match '^=== COUNT (\S+)') { $hunk.Count = $Matches[1]; continue }
        if ($hunk -and $l -eq '=== INLINE') { $hunk.Inline = $true; continue }
        if ($hunk -and $l -eq '--- OLD') { $mode = 'Old'; $buf = [Collections.Generic.List[string]]::new(); continue }
        if ($hunk -and $l -eq '--- NEW') { $hunk.Old = $buf; $mode = 'New'; $buf = [Collections.Generic.List[string]]::new(); continue }
        if ($hunk -and $l -eq '=== END') {
            $hunk.New = $buf
            $tail = $hunk.Inline ? '' : "`n"
            $hunk.Old = ($hunk.Old -join "`n") + $tail
            $hunk.New = ($hunk.New -join "`n") + $tail
            $p.Hunks += [pscustomobject]$hunk
            $hunk = $null; $mode = $null; continue
        }
        if ($mode) { $buf.Add($l); continue }
        if (-not $hunk) {
            if ($l -match '^Title:\s*(.*)$') { $p.Title = $Matches[1] }
            elseif ($l -match '^Why:\s*(.*)$') { $p.Why = $Matches[1] }
        }
    }
    if ($hunk) { throw "$path : hunk for $($hunk.File) has no === END" }
    $p
}

# ---------------------------------------------------------------- matching
# Whole-line match ignoring leading/trailing whitespace, for when an update only re-indented code.
# Returns the start/end line index of the single match, or $null when there are 0 or several.
function Find-Loose([string[]]$fileLines, [string[]]$oldLines) {
    $want = @($oldLines | ForEach-Object { $_.Trim() })
    if (($want | Where-Object { $_ -ne '' }).Count -eq 0) { return $null }
    $hits = @()
    for ($i = 0; $i -le $fileLines.Count - $want.Count; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $want.Count; $j++) { if ($fileLines[$i + $j].Trim() -ne $want[$j]) { $ok = $false; break } }
        if ($ok) { $hits += $i }
    }
    if ($hits.Count -ne 1) { return $null }
    $hits[0]
}

# One hunk against the text: returns @{ State; Text; Note }
#   applied  NEW is there and OLD is not      ready  OLD found as expected (Text = patched)
#   moved    OLD found only by loose matching (Text = patched, re-indented)
#   broken   neither
function Test-Hunk($hunk, [string]$text, [bool]$crlf, [bool]$reverse) {
    $nl = $crlf ? "`r`n" : "`n"
    $old = $hunk.Old.Replace("`n", $nl); $new = $hunk.New.Replace("`n", $nl)
    if ($reverse) { $old, $new = $new, $old }
    $nOld = Count-Of $text $old
    $nNew = Count-Of $text $new
    # OLD occurrences that are not just part of a NEW block (NEW often contains OLD plus added lines)
    $oldOutsideNew = $nOld - $nNew * (Count-Of $new $old)
    if ($nNew -gt 0 -and $oldOutsideNew -le 0) { return @{ State = 'applied' } }
    $want = $hunk.Count
    if ($nOld -gt 0 -and ($want -eq 'all' -or [int]$want -eq $nOld)) {
        return @{ State = 'ready'; Text = $text.Replace($old, $new) }
    }
    if ($nOld -gt 0) { return @{ State = 'broken'; Note = "expected $want match(es) of the old code, found $nOld" } }
    if ($hunk.Inline -or $want -ne '1') { return @{ State = 'broken'; Note = 'old code not found' } }
    # loose: whole lines, any indentation
    $fileLines = @($text -split "`r?`n")
    $oldLines = @($old -split "`r?`n"); $oldLines = @($oldLines[0..($oldLines.Count - 2)])   # drop the empty after the last newline
    $newLines = @($new -split "`r?`n"); $newLines = @($newLines[0..($newLines.Count - 2)])
    $at = Find-Loose $fileLines $oldLines
    $newAt = Find-Loose $fileLines $newLines
    # already applied, only re-indented by an update: NEW is there, and OLD is absent or just part of it
    if ($null -ne $newAt -and ($null -eq $at -or ($at -ge $newAt -and $at + $oldLines.Count -le $newAt + $newLines.Count))) {
        return @{ State = 'applied' }
    }
    if ($null -eq $at) { return @{ State = 'broken'; Note = 'old code not found (not even with different indentation)' } }
    $fileIndent = [regex]::Match($fileLines[$at], '^\s*').Value
    $patchIndent = [regex]::Match($oldLines[0], '^\s*').Value
    $shifted = foreach ($l in $newLines) {
        if ($l.StartsWith($patchIndent)) { $fileIndent + $l.Substring($patchIndent.Length) } else { $l }
    }
    $out = @()
    if ($at -gt 0) { $out += $fileLines[0..($at - 1)] }
    $out += $shifted
    $rest = $at + $oldLines.Count
    if ($rest -lt $fileLines.Count) { $out += $fileLines[$rest..($fileLines.Count - 1)] }
    return @{ State = 'moved'; Text = ($out -join $nl); Note = "re-anchored at line $($at + 1) (indentation changed)" }
}

# ---------------------------------------------------------------- addon versions
$statePath = Join-Path $Root 'state.json'
$state = (Test-Path $statePath) ? (Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable) : @{}
if (-not $state.versions) { $state.versions = @{} }
function Get-AddonVersion([string]$addon) {
    $dir = Join-Path $AddOns $addon
    if (-not (Test-Path $dir)) { return $null }
    $toc = Get-ChildItem $dir -Filter *.toc | Sort-Object { $_.BaseName -ne $addon } | Select-Object -First 1
    if (-not $toc) { return '?' }
    $m = Select-String -LiteralPath $toc.FullName -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1
    $m ? $m.Matches[0].Groups[1].Value.Trim() : '?'
}

# ---------------------------------------------------------------- overlay addons
Say "# LocalMods $Command - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Say ''
Say '## Overlay addons'
$newAddon = $false
foreach ($src in Get-ChildItem (Join-Path $Root 'addons') -Directory -ErrorAction SilentlyContinue) {
    $dest = Join-Path $AddOns $src.Name
    $changed = @()
    foreach ($f in Get-ChildItem $src.FullName -Recurse -File) {
        $rel = [IO.Path]::GetRelativePath($src.FullName, $f.FullName)
        $d = Join-Path $dest $rel
        if (-not (Test-Path $d) -or (Get-FileHash $d).Hash -ne (Get-FileHash $f.FullName).Hash) { $changed += $rel }
    }
    $missing = -not (Test-Path $dest)
    if ($changed.Count -eq 0) { Say "- $($src.Name): installed, up to date"; continue }
    if ($checkOnly) { Say "- $($src.Name): $($missing ? 'NOT INSTALLED' : "out of date ($($changed -join ', '))")"; continue }
    foreach ($rel in $changed) {
        $d = Join-Path $dest $rel
        New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null
        Copy-Item -LiteralPath (Join-Path $src.FullName $rel) $d -Force
    }
    if ($missing) { $newAddon = $true }
    Say "- $($src.Name): $($missing ? 'INSTALLED (new)' : "updated ($($changed -join ', '))")"
}

# ---------------------------------------------------------------- patches
Say ''
Say '## Patches'
$patchFiles = Get-ChildItem (Join-Path $Root 'patches') -Filter *.patch | Sort-Object Name
if ($Command -eq 'revert') {
    if (-not $Name) { throw 'revert needs a patch name' }
    $patchFiles = $patchFiles | Where-Object { $_.BaseName -eq $Name }
    if (-not $patchFiles) { throw "no patch named $Name" }
    [array]::Reverse([object[]]$patchFiles)
}
$addonsSeen = @{}
$broken = [Collections.Generic.List[string]]::new()
foreach ($pf in $patchFiles) {
    $p = Read-Patch $pf.FullName
    $target = ($p.Hunks[0].File -split '[\\/]')[0]
    if (-not (Test-Path -LiteralPath (Join-Path $AddOns $target))) {
        Say "- skipped $($p.Name) - $target not installed"
        continue
    }
    $texts = @{}; $files = @{}; $notes = @(); $states = @(); $bad = $null
    $hunks = $p.Hunks
    if ($Command -eq 'revert') { $hunks = @($hunks); [array]::Reverse($hunks) }
    foreach ($h in $hunks) {
        $addon = ($h.File -split '[\\/]')[0]
        $addonsSeen[$addon] = $true
        $path = Join-Path $AddOns $h.File
        if (-not $texts.ContainsKey($path)) {
            if (-not (Test-Path -LiteralPath $path)) { $bad = "file missing: $($h.File)"; break }
            $files[$path] = Read-Text $path
            $texts[$path] = $files[$path].Text
        }
        $r = Test-Hunk $h $texts[$path] $files[$path].Crlf ($Command -eq 'revert')
        $states += $r.State
        if ($r.State -eq 'broken') { $bad = "$($h.File): $($r.Note)"; break }
        if ($r.Text) { $texts[$path] = $r.Text }
        if ($r.Note) { $notes += "$($h.File): $($r.Note)" }
    }
    $label = $p.Title ? "$($p.Name) - $($p.Title)" : $p.Name
    if ($bad) {
        $problems++
        $broken.Add($p.Name)
        $addon = ($p.Hunks[0].File -split '[\\/]')[0]
        $was = $state.versions[$addon]; $now = Get-AddonVersion $addon
        $ver = ($was -and $was -ne $now) ? " (addon updated $was -> $now)" : " (addon version $now)"
        Say "- **BROKEN** $label${ver}: $bad. Nothing in this patch was changed."
        continue
    }
    $todo = @($states | Where-Object { $_ -ne 'applied' }).Count
    if ($todo -eq 0) { Say "- ok $label$(($Command -eq 'revert') ? ' (already reverted)' : '')"; continue }
    if ($checkOnly) { Say "- NEEDS APPLYING $label$($notes ? " ($($notes -join '; '))" : '')"; continue }
    foreach ($path in $texts.Keys) {
        if ($texts[$path] -ne $files[$path].Text) { Write-Text $path $files[$path] $texts[$path] }
    }
    $verb = ($Command -eq 'revert') ? 'REVERTED' : (($todo -lt $states.Count) ? 'COMPLETED' : 'APPLIED')
    Say "- $verb $label$($notes ? " - $($notes -join '; ')" : '')"
}

# ---------------------------------------------------------------- versions + summary
Say ''
Say '## Addon versions'
foreach ($addon in $addonsSeen.Keys | Sort-Object) {
    $now = Get-AddonVersion $addon
    $was = $state.versions[$addon]
    if ($was -and $was -ne $now) { Say "- $addon updated: $was -> $now" } else { Say "- $addon $now" }
    if (-not $checkOnly) { $state.versions[$addon] = $now }
}
if (-not $checkOnly) { $state | ConvertTo-Json -Depth 5 | Set-Content $statePath -Encoding utf8 }

Say ''
if ($broken.Count) {
    Say "## To do: $($broken.Count) broken patch(es): $($broken -join ', ')"
    Say 'An update changed the code these patches edit. For each one: open the patch file and the addon file,'
    Say 'check whether the update already fixed the problem (then delete the patch), otherwise rewrite the'
    Say "patch's OLD/NEW against the new code and run this again."
} else {
    Say 'All patches in place.'
}
if ($backedUp.Count) { Say "Backups of changed files: $backupDir" }
if ($newAddon) { Say 'A NEW addon was installed: restart WoW fully (a /reload does not find new addons).' }
elseif (-not $checkOnly) { Say 'Type /reload in game to load the changes.' }

$report -join "`n" | Set-Content (Join-Path $Root 'last-run.md') -Encoding utf8
exit ($problems -gt 0 ? 1 : 0)
