# Pre-publish check for yf-builds-dashboard.artifact.html.
#
# Run this before every Artifact publish. It exists because two Claude sessions publish
# the same artifact, and an artifact publish does NOT go through git — so whoever
# publishes last silently overwrites the other, and neither notices. Both of the things
# that went wrong on 2026-08-20 are checked here:
#
#   - a whole-file edit re-encoded every non-ASCII character into mojibake, corrupting
#     the error messages the team reads
#   - a publish from a stale copy dropped a thumbnail another session had just added
#
#   powershell -File tools/check-artifact.ps1
#
# Exit code 0 means safe to publish. Non-zero means do not publish.

param([string]$Html = "yf-builds-dashboard.artifact.html", [string]$ShotDir = "thumbs")

$ErrorActionPreference = "Stop"
$fail = New-Object System.Collections.Generic.List[string]
$warn = New-Object System.Collections.Generic.List[string]

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$text = $utf8NoBom.GetString([IO.File]::ReadAllBytes((Resolve-Path $Html)))
$lines = $text -split "`r?`n"

# --- 1. pure ASCII -----------------------------------------------------------------
# The file is deliberately ASCII-only: HTML entities for typography, \u escapes or plain
# words in JS strings. Any non-ASCII byte means something re-encoded the file.
$nonAscii = [regex]::Matches($text, '[^\x20-\x7E\r\n\t]')
if ($nonAscii.Count -gt 0) {
  $sample = ($nonAscii | Select-Object -First 3 | ForEach-Object { "U+{0:X4}" -f [int][char]$_.Value }) -join " "
  $fail.Add("$($nonAscii.Count) non-ASCII characters ($sample ...). Something re-encoded the file - check the reader/writer encoding in whatever last touched it.")
}

# --- 2. thumbnails in the page match thumbnails on disk ----------------------------
# Catches a publish from a stale copy: the page must carry every rendered tile.
# Two key forms are valid: the live URL (what the render tools emit) and a bare repo slug
# (the only option for a build with no live page, e.g. a supplied screenshot).
$inPage = [regex]::Matches($text, '"(?:https://yfagency\.github\.io/)?([a-z0-9][a-z0-9-]*)/?"\s*:\s*"data:image') |
          ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
# Join-Path, not "$ShotDir\*.jpg": this check also runs on the ubuntu runner in the
# Thumbnails workflow, where a backslash is a legal filename character rather than a
# separator, so the literal form silently matches nothing and check 2 stops checking.
$onDisk = Get-ChildItem (Join-Path $ShotDir "*.jpg") -ErrorAction SilentlyContinue |
          ForEach-Object { $_.BaseName } | Sort-Object -Unique
$missing = $onDisk | Where-Object { $inPage -notcontains $_ }
$extra   = $inPage | Where-Object { $onDisk -notcontains $_ }
if ($missing) { $fail.Add("thumbnails on disk but NOT in the page: $($missing -join ', '). Publishing now would drop them - pull and re-run the thumbnail tool.") }
if ($extra)   { $warn.Add("thumbnails in the page with no file in $ShotDir : $($extra -join ', ')") }

# --- 3. structure ------------------------------------------------------------------
if ($lines[0].Trim() -ne "<title>YF Bridge</title>") { $fail.Add("first line is not the <title> - a stray fragment may sit above it: '$($lines[0].Substring(0, [Math]::Min(60, $lines[0].Length)))'") }
foreach ($pair in @(@("<style>", "</style>"), @("<script>", "</script>"))) {
  # \r? before the line end: this repo is checked out with CRLF, and $ anchors before the
  # \n, leaving the \r unmatched.
  $o = ([regex]::Matches($text, "(?m)^$([regex]::Escape($pair[0]))\r?$")).Count
  $c = ([regex]::Matches($text, "(?m)^$([regex]::Escape($pair[1]))\r?$")).Count
  if ($o -ne 1 -or $c -ne 1) { $fail.Add("expected exactly one $($pair[0]) ... $($pair[1]) pair, found $o / $c") }
}
foreach ($tag in @("div", "section", "ol", "li")) {
  $o = ([regex]::Matches($text, "<$tag[ >]")).Count
  $c = ([regex]::Matches($text, "</$tag>")).Count
  if ($o -ne $c) { $fail.Add("<$tag> tags unbalanced: $o open, $c close") }
}

# --- 4. the script parses as far as brackets go ------------------------------------
$scriptBody = [regex]::Match($text, '(?ms)^<script>\r?\n(.*?)\r?\n</script>').Groups[1].Value
if (-not $scriptBody) { $fail.Add("could not isolate the <script> body") }
else {
  foreach ($b in @(@('{','}'), @('(',')'))) {
    $o = ([regex]::Matches($scriptBody, [regex]::Escape($b[0]))).Count
    $c = ([regex]::Matches($scriptBody, [regex]::Escape($b[1]))).Count
    if ($o -ne $c) { $fail.Add("script $($b[0])$($b[1]) unbalanced: $o vs $c") }
  }
}

# --- 5. the guide's contents rail matches its sections ------------------------------
$navIds = [regex]::Matches($text, 'data-goto="(g-[a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
$secIds = [regex]::Matches($text, 'id="(g-[a-z]+)"')       | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
$navOnly = $navIds | Where-Object { $secIds -notcontains $_ }
$secOnly = $secIds | Where-Object { $navIds -notcontains $_ }
if ($navOnly) { $fail.Add("guide nav links to sections that don't exist: $($navOnly -join ', ')") }
if ($secOnly) { $warn.Add("guide sections with no nav link: $($secOnly -join ', ')") }

# --- 6. am I about to publish a stale copy? ----------------------------------------
try {
  git fetch --quiet 2>$null
  # Spell the upstream ref out: PowerShell parses @{u} as a hashtable literal.
  $behind = (git rev-list --count "HEAD..origin/main" 2>$null)
  if ($behind -and [int]$behind -gt 0) {
    $fail.Add("$behind commit(s) behind the remote. Another session has pushed - run 'git pull' and re-check before publishing, or you will overwrite their work.")
  }
  if (git status --porcelain $Html) { $warn.Add("$Html has uncommitted changes - commit them so the repo matches what you publish") }
} catch { $warn.Add("could not check git state: $($_.Exception.Message)") }

# --- duplicate CSS selectors --------------------------------------------------------
#
# The same selector declared twice at the top level of a <style> block. The later one
# wins silently, which is how `.chip` - the tag AND the identity button - spent a week
# rendering every tag in the app as a 999px identity pill with the wrong font and an
# avatar's worth of padding. It was found by screenshot, and so were `.plates`,
# `.dcard .chips` and the pinned-card hover. Eleven more were sitting in the sheet when
# this check was written on 2026-08-28.
#
# Two rules for the same selector is not always a bug, but it is never necessary: merge
# them. If a later declaration is meant to override an earlier one, that is a different
# selector - add the class or the context that makes it so.
#
# Only TOP-LEVEL rules count. A repeat inside @media is the whole point of @media, so
# depth is tracked by counting braces rather than by matching a closing line.
$dupFail = @()
$inStyle = $false; $depth = 0; $seen = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
  $t = $lines[$i]
  if ($t -match '<style>')  { $inStyle = $true;  $depth = 0; continue }
  if ($t -match '</style>') { $inStyle = $false; continue }
  if (-not $inStyle) { continue }
  $noComment = $t -replace '/\*.*?\*/', ''
  $trim = $noComment.Trim()
  if ($depth -eq 0 -and $trim -match '^([^@/}][^{}]*?)\s*\{') {
    $sel = ($Matches[1] -replace '\s+', ' ').Trim()
    if ($sel -ne '') {
      if (-not $seen.ContainsKey($sel)) { $seen[$sel] = @() }
      $seen[$sel] += ($i + 1)
    }
  }
  $depth += ([regex]::Matches($noComment, '\{')).Count
  $depth -= ([regex]::Matches($noComment, '\}')).Count
  if ($depth -lt 0) { $depth = 0 }
}
foreach ($k in ($seen.Keys | Sort-Object)) {
  if ($seen[$k].Count -gt 1) {
    $dupFail += ("selector declared {0}x: {1}  (lines {2}) - merge them" -f $seen[$k].Count, $k, ($seen[$k] -join ", "))
  }
}
foreach ($d in $dupFail) { $fail.Add($d) }

# --- duplicate top-level declarations ------------------------------------------------
#
# The same bug in JavaScript. Two top-level `var`s of one name are ONE variable, and the
# later initialiser wins - silently, everywhere, including inside code written next to the
# earlier one. The reel and the Decisions page both declared Q_DL and DL_ROWS: the reel was
# running the page's 300-row query instead of its own twelve, and its ten-minute refresh
# was replacing the page's rows underneath it. Found 2026-08-28, by looking, not by
# noticing. Column-0 only, which is what "top level" means in this file.
$declSeen = @{}
$fnSeen = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^var\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=') {
    $nm = $Matches[1]
    if (-not $declSeen.ContainsKey($nm)) { $declSeen[$nm] = @() }
    $declSeen[$nm] += ($i + 1)
  }
  if ($lines[$i] -match '^function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(') {
    $nm = $Matches[1]
    if (-not $fnSeen.ContainsKey($nm)) { $fnSeen[$nm] = @() }
    $fnSeen[$nm] += ($i + 1)
  }
}
foreach ($k in ($declSeen.Keys | Sort-Object)) {
  if ($declSeen[$k].Count -gt 1) {
    $fail.Add(("var declared {0}x: {1}  (lines {2}) - one of them wins silently, rename it" -f $declSeen[$k].Count, $k, ($declSeen[$k] -join ", ")))
  }
}
foreach ($k in ($fnSeen.Keys | Sort-Object)) {
  if ($fnSeen[$k].Count -gt 1) {
    $fail.Add(("function declared {0}x: {1}  (lines {2}) - the later one wins, rename it" -f $fnSeen[$k].Count, $k, ($fnSeen[$k] -join ", ")))
  }
}

# --- report ------------------------------------------------------------------------
"thumbnails in page : $($inPage.Count)"
"thumbnails on disk : $(@($onDisk).Count)"
# THE CANONICAL STATEMENT OF THE FAVICON. Do not restate the value anywhere else - point
# at this line instead.
#
# It is the one publish input nobody can look up: platform metadata, not part of the file.
# Printing it here means every session that runs this check is told the answer, so it never
# has to be guessed or escalated. Settled by ZF 2026-08-21.
#
# It was also stated in the README, in the artifact's own header comment and in
# tools/add-thumbnail.py. One of those drifted to the wrong emoji and told people so for a
# week before anyone noticed. Four copies is four chances to be wrong; a pointer cannot go
# stale. Fixed 2026-08-28.
"favicon to publish : hammer-and-wrench  U+1F6E0 U+FE0F   (never substitute)"
""
foreach ($w in $warn) { Write-Host "WARN  $w" -ForegroundColor Yellow }
foreach ($f in $fail) { Write-Host "FAIL  $f" -ForegroundColor Red }
if ($fail.Count -eq 0) { Write-Host "OK - safe to publish" -ForegroundColor Green; exit 0 }
exit 1
