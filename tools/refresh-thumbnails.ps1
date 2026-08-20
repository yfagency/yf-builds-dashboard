# Regenerates the dashboard's build thumbnails.
#
# Why this exists: the dashboard runs as a claude.ai Artifact under a CSP that blocks
# every external host. A remote <img> cannot load and neither can an <iframe> of the
# build, so a thumbnail has to already be inside the page as a data URI. This script
# renders each build's live GitHub Pages URL with headless Chrome, shrinks it to a
# 640x400 JPEG, and injects the whole set into yf-builds-dashboard.artifact.html.
#
# Run it after publishing a new build, or when a build changes visibly:
#   powershell -File tools/refresh-thumbnails.ps1
#
# Then republish the artifact from Claude Code so the team sees the new tiles.

param(
  [string]$Html = "yf-builds-dashboard.artifact.html",
  [string]$ShotDir = "thumbs"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$chrome = @(
  "C:\Program Files\Google\Chrome\Application\chrome.exe",
  "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
  "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw "No Chromium browser found - install Chrome or Edge." }

# Every build with a live URL. Keep this list in step with the registry's Live URL column.
$builds = @(
  "token-playground",
  "brand-spiral-work-index",
  "solution-stack-gravity",
  "construct-word-field",
  "cta-diagnostic-landing"
)

New-Item -ItemType Directory -Force $ShotDir | Out-Null

$jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
  Where-Object { $_.MimeType -eq "image/jpeg" }
$encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
  [System.Drawing.Imaging.Encoder]::Quality, 62)

$entries = New-Object System.Collections.Generic.List[string]

foreach ($name in $builds) {
  $url = "https://yfagency.github.io/$name/"
  $png = Join-Path $ShotDir "$name.png"
  $jpg = Join-Path $ShotDir "$name.jpg"

  # virtual-time-budget lets animation and WebGL settle before the frame is taken;
  # enable-unsafe-swiftshader gives headless a software GL implementation, without
  # which the canvas-heavy builds capture black.
  & $chrome --headless=new --disable-gpu --enable-unsafe-swiftshader --hide-scrollbars `
            --window-size=1280,800 --virtual-time-budget=9000 `
            --screenshot="$png" $url 2>$null | Out-Null
  if (-not (Test-Path $png)) { Write-Warning "$name did not render - skipped"; continue }

  $src = [System.Drawing.Image]::FromFile($png)
  $bmp = New-Object System.Drawing.Bitmap 640, 400
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.DrawImage($src, 0, 0, 640, 400)
  $bmp.Save($jpg, $jpegEncoder, $encParams)
  $g.Dispose(); $bmp.Dispose(); $src.Dispose()
  Remove-Item $png

  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($jpg))
  $entries.Add('"' + $url + '":"data:image/jpeg;base64,' + $b64 + '"')
  "{0,-26} {1,7:N0} bytes" -f $name, (Get-Item $jpg).Length
}

if ($entries.Count -eq 0) { throw "Nothing rendered - aborting without touching $Html" }

# Replace the whole THUMBS assignment, whatever it currently holds.
$content = Get-Content $Html -Raw
$pattern = '(?s)var THUMBS = \{.*?\};'
if ($content -notmatch $pattern) { throw "Could not find the THUMBS block in $Html" }
$js = "var THUMBS = {" + ($entries -join ",`n") + "};"
$content = [regex]::Replace($content, $pattern, { $js }, 1)
[IO.File]::WriteAllText((Resolve-Path $Html), $content)

"injected $($entries.Count) thumbnails into $Html"
