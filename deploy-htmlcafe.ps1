<#
.SYNOPSIS
  Builds a self-contained HTML file and optionally uploads it to HTML.cafe.

.DESCRIPTION
  This script inlines local asset references into one HTML file, writes that
  standalone artifact to disk, and uploads it to HTML.cafe when PageId and
  EditKey are provided. It is intended to be project-generic: pass project
  paths and verification patterns as parameters instead of editing the script.

.EXAMPLE
  .\deploy-htmlcafe.ps1 -NoUpload

.EXAMPLE
  .\deploy-htmlcafe.ps1 -PageId x12345678 -EditKey your-edit-key

.EXAMPLE
  .\deploy-htmlcafe.ps1 -ProjectRoot C:\work\site -HtmlPath public\index.html -NoUpload

.EXAMPLE
  .\deploy-htmlcafe.ps1 -OptimizeAudio -AudioMode Loop -AudioBitrateKbps 96 -AudioLoopStartMap "theme.mp3=8" -NoUpload
#>

param(
  [string]$ProjectRoot = "",
  [string]$HtmlPath = "index.html",
  [string]$OutputPath = "",

  [string]$PageId = $env:HTMLCAFE_PAGE_ID,
  [string]$EditKey = $env:HTMLCAFE_EDIT_KEY,
  [string]$SaveUrl = "https://html.cafe/_save/",
  [string]$PublicBaseUrl = "https://html.cafe",

  [string]$TitleContains = "",
  [string[]]$RequiredPattern = @(),
  [string[]]$ForbiddenPattern = @("C:\\Users\\", "ArrayArray", "\?{4,}"),

  [int]$TimeoutSec = 60,
  [double]$MaxInlineAssetMB = 0,
  [switch]$OptimizeImages,
  [string]$ImageOptimizerPython = "",
  [int]$ImageQuality = 82,
  [int]$JpegQuality = 95,
  [int]$ImageMaxWidth = 0,
  [int]$ImageMaxHeight = 0,
  [string]$AssetOptimizationManifest = "deploy-asset-optimization.json",
  [double]$RenderedAssetScale = 2.0,
  [switch]$NoOptimizeRenderedAssets,
  [switch]$WriteAssetOptimizationReport,
  [double]$RenderedSpriteScale = 2.0,
  [switch]$NoOptimizeRenderedSprites,
  [string[]]$JpegPattern = @(),
  [string[]]$KeepOriginalPattern = @(),
  [switch]$OptimizeAudio,
  [ValidateSet("Full", "Loop")]
  [string]$AudioMode = "Full",
  [int]$AudioBitrateKbps = 96,
  [int]$AudioLoopSeconds = 30,
  [double]$AudioLoopFadeSeconds = 0.75,
  [string[]]$AudioLoopStartMap = @(),
  [string]$FfmpegPath = "ffmpeg",

  [switch]$UseInlineAssetRegistry,
  [switch]$NoInlineAssets,
  [switch]$NoInlineQuotedAssets,
  [switch]$NoUpload,
  [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
$KeepOriginalPattern = @(
  "assets/ocean-snake-idle-loop-256.webp"
  $KeepOriginalPattern
) | Select-Object -Unique
$script:InlineAssetCache = @{}
$script:ResolvedImageOptimizerPython = $null
$script:ResolvedFfmpegPath = $null
$script:AudioLoopStarts = @{}
$script:AssetOptimizationRules = @{}
$script:AssetOptimizationReport = @()
$script:AssetOptimizationCacheDir = $null
$script:EffectiveRenderedAssetScale = 2.0
$script:OptimizeRenderedAssets = $true
$script:InlineAssetRegistry = [ordered]@{}

function Resolve-ProjectPath {
  param(
    [string]$Path,
    [string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return (Resolve-Path -LiteralPath $Path).Path
  }

  return (Resolve-Path -LiteralPath (Join-Path $BasePath $Path)).Path
}

function Test-IsExternalReference {
  param([string]$Reference)

  if ([string]::IsNullOrWhiteSpace($Reference)) {
    return $true
  }

  $trimmed = $Reference.Trim()
  return $trimmed -match '^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//|#)'
}

function Test-IsUnderPath {
  param(
    [string]$ChildPath,
    [string]$ParentPath
  )

  $childFull = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $parentFull = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  return $childFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $childFull.StartsWith($parentFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-MimeType {
  param([string]$Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".apng" { return "image/apng" }
    ".avif" { return "image/avif" }
    ".css" { return "text/css" }
    ".gif" { return "image/gif" }
    ".htm" { return "text/html" }
    ".html" { return "text/html" }
    ".jpg" { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".js" { return "text/javascript" }
    ".json" { return "application/json" }
    ".m4a" { return "audio/mp4" }
    ".mp3" { return "audio/mpeg" }
    ".ogg" { return "audio/ogg" }
    ".otf" { return "font/otf" }
    ".png" { return "image/png" }
    ".svg" { return "image/svg+xml" }
    ".ttf" { return "font/ttf" }
    ".wav" { return "audio/wav" }
    ".webm" { return "video/webm" }
    ".webp" { return "image/webp" }
    ".woff" { return "font/woff" }
    ".woff2" { return "font/woff2" }
    default { return "application/octet-stream" }
  }
}

function Test-IsOptimizableImage {
  param([string]$Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".jpg" { return $true }
    ".jpeg" { return $true }
    ".png" { return $true }
    ".webp" { return $true }
    default { return $false }
  }
}

function Test-IsOptimizableAudio {
  param([string]$Path)

  return [System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq ".mp3"
}

function Test-AnyPatternMatch {
  param(
    [string[]]$Pattern,
    [string[]]$Value
  )

  foreach ($patternItem in $Pattern) {
    if ([string]::IsNullOrWhiteSpace($patternItem)) {
      continue
    }

    foreach ($valueItem in $Value) {
      if (-not [string]::IsNullOrWhiteSpace($valueItem) -and $valueItem -match $patternItem) {
        return $true
      }
    }
  }

  return $false
}

function Normalize-AssetReferenceKey {
  param([string]$Value)

  $pathOnly = ($Value -split '[?#]', 2)[0]
  $decoded = [System.Uri]::UnescapeDataString($pathOnly)
  $normalized = ($decoded -replace '\\', '/').Trim()
  while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(2)
  }

  return $normalized.ToLowerInvariant()
}

function Get-OptionalPropertyValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }

  return $property.Value
}

function Get-ManifestMetadataItems {
  param([object]$Rule)

  $metadata = Get-OptionalPropertyValue -Object $Rule -Name "metadata" -Default @()
  if ($null -eq $metadata) {
    return @()
  }
  if ($metadata -is [System.Array]) {
    return @($metadata)
  }
  return @($metadata)
}

function Initialize-AssetOptimizationRules {
  param(
    [string]$ResolvedProjectRoot,
    [double]$Scale
  )

  $script:AssetOptimizationRules = @{}
  if (-not $OptimizeImages -or -not $script:OptimizeRenderedAssets -or [string]::IsNullOrWhiteSpace($AssetOptimizationManifest)) {
    return
  }

  $manifestPath = if ([System.IO.Path]::IsPathRooted($AssetOptimizationManifest)) {
    $AssetOptimizationManifest
  } else {
    Join-Path $ResolvedProjectRoot $AssetOptimizationManifest
  }

  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Warning "Asset optimization manifest not found: $manifestPath. Render-size optimization will be skipped."
    return
  }

  $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  foreach ($manifestRule in @($manifest.rules)) {
    $assetPath = [string]$manifestRule.assetPath
    if ([string]::IsNullOrWhiteSpace($assetPath)) {
      continue
    }

    $type = [string](Get-OptionalPropertyValue -Object $manifestRule -Name "type" -Default "singleImage")
    $rule = [ordered]@{
      AssetPath = $assetPath
      Key = Normalize-AssetReferenceKey -Value $assetPath
      Type = $type
      Metadata = @(Get-ManifestMetadataItems -Rule $manifestRule)
      TargetW = 0
      TargetH = 0
      ScaleX = 1.0
      ScaleY = 1.0
      Downscale = $false
    }

    if ($type -eq "spriteSheet") {
      $sourceFrameW = [int]$manifestRule.sourceFrameW
      $sourceFrameH = [int]$manifestRule.sourceFrameH
      $columns = [int]$manifestRule.columns
      $rows = [int]$manifestRule.rows
      $targetFrameRenderW = Get-OptionalPropertyValue -Object $manifestRule -Name "targetFrameRenderW"
      $targetFrameRenderH = Get-OptionalPropertyValue -Object $manifestRule -Name "targetFrameRenderH"

      if ($null -ne $targetFrameRenderW) {
        $targetFrameW = [Math]::Max(1, [int][Math]::Round([double]$targetFrameRenderW * $Scale))
        $targetFrameH = [Math]::Max(1, [int][Math]::Round($sourceFrameH * ($targetFrameW / $sourceFrameW)))
      } else {
        $targetFrameH = [Math]::Max(1, [int][Math]::Round([double]$targetFrameRenderH * $Scale))
        $targetFrameW = [Math]::Max(1, [int][Math]::Round($sourceFrameW * ($targetFrameH / $sourceFrameH)))
      }

      $sourceW = $sourceFrameW * $columns
      $sourceH = $sourceFrameH * $rows
      $targetW = $targetFrameW * $columns
      $targetH = $targetFrameH * $rows

      $rule.SourceFrameW = $sourceFrameW
      $rule.SourceFrameH = $sourceFrameH
      $rule.TargetFrameW = $targetFrameW
      $rule.TargetFrameH = $targetFrameH
      $rule.Columns = $columns
      $rule.Rows = $rows
      $rule.SourceW = $sourceW
      $rule.SourceH = $sourceH
      $rule.TargetW = $targetW
      $rule.TargetH = $targetH
      $rule.ScaleX = $targetFrameW / $sourceFrameW
      $rule.ScaleY = $targetFrameH / $sourceFrameH
      $rule.Downscale = $targetW -lt $sourceW -or $targetH -lt $sourceH
    } elseif ($type -eq "singleImage") {
      $sourceW = [int]$manifestRule.sourceW
      $sourceH = [int]$manifestRule.sourceH
      $targetRenderW = Get-OptionalPropertyValue -Object $manifestRule -Name "targetRenderW"
      $targetRenderH = Get-OptionalPropertyValue -Object $manifestRule -Name "targetRenderH"

      if ($null -ne $targetRenderW) {
        $targetW = [Math]::Max(1, [int][Math]::Round([double]$targetRenderW * $Scale))
        $targetH = [Math]::Max(1, [int][Math]::Round($sourceH * ($targetW / $sourceW)))
      } else {
        $targetH = [Math]::Max(1, [int][Math]::Round([double]$targetRenderH * $Scale))
        $targetW = [Math]::Max(1, [int][Math]::Round($sourceW * ($targetH / $sourceH)))
      }

      $rule.SourceW = $sourceW
      $rule.SourceH = $sourceH
      $rule.TargetW = $targetW
      $rule.TargetH = $targetH
      $rule.ScaleX = $targetW / $sourceW
      $rule.ScaleY = $targetH / $sourceH
      $rule.Downscale = $targetW -lt $sourceW -or $targetH -lt $sourceH
    }

    $script:AssetOptimizationRules[$rule.Key] = [pscustomobject]$rule
  }
}

function Get-RenderedAssetOptimizationRule {
  param([string]$Reference)

  if (-not $OptimizeImages -or -not $script:OptimizeRenderedAssets -or $NoInlineAssets) {
    return $null
  }

  $key = Normalize-AssetReferenceKey -Value $Reference
  if ($script:AssetOptimizationRules.ContainsKey($key)) {
    $rule = $script:AssetOptimizationRules[$key]
    if ($rule.Downscale) {
      return $rule
    }
  }

  return $null
}

function Add-AssetOptimizationReportEntry {
  param(
    [string]$Reference,
    [string]$Status,
    [string]$RuleType,
    [int64]$OriginalBytes,
    [int64]$EmbeddedBytes,
    [string]$MimeType
  )

  if (-not $WriteAssetOptimizationReport) {
    return
  }

  $script:AssetOptimizationReport += [pscustomobject]@{
    reference = $Reference
    status = $Status
    ruleType = $RuleType
    originalBytes = $OriginalBytes
    embeddedBytes = $EmbeddedBytes
    savedBytes = $OriginalBytes - $EmbeddedBytes
    mimeType = $MimeType
  }
}

function Test-PythonImageOptimizer {
  param([string]$PythonCommand)

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = & $PythonCommand -c "from PIL import Image, features; import sys; sys.exit(0 if features.check('webp') else 2)" 2>&1
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

function Resolve-ImageOptimizerPython {
  param([string]$PreferredPython)

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($PreferredPython)) {
    $candidates += $PreferredPython
  }
  if (-not [string]::IsNullOrWhiteSpace($env:PYTHON)) {
    $candidates += $env:PYTHON
  }
  $candidates += "python"
  $candidates += "py"

  foreach ($candidate in $candidates) {
    if (Test-PythonImageOptimizer -PythonCommand $candidate) {
      return $candidate
    }
  }

  throw "Image optimization requires Python with Pillow and WebP support. Install Pillow or pass -ImageOptimizerPython with a working Python executable. Use without -OptimizeImages to skip this."
}

function Format-InvariantNumber {
  param([double]$Value)

  return $Value.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Normalize-AudioMapKey {
  param([string]$Value)

  return ($Value -replace '\\', '/').Trim().ToLowerInvariant()
}

function Initialize-AudioLoopStartMap {
  param([string[]]$MapEntries)

  $script:AudioLoopStarts = @{}
  foreach ($entryGroup in $MapEntries) {
    if ([string]::IsNullOrWhiteSpace($entryGroup)) {
      continue
    }

    foreach ($entry in ($entryGroup -split ',')) {
      if ([string]::IsNullOrWhiteSpace($entry)) {
        continue
      }

      $parts = $entry -split '=', 2
      if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "Invalid AudioLoopStartMap entry '$entry'. Use the form 'filename.mp3=8'."
      }

      $seconds = 0.0
      if (-not [double]::TryParse($parts[1].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
        throw "Invalid audio loop start '$($parts[1])' in entry '$entry'. Use seconds, for example '8' or '12.5'."
      }

      if ($seconds -lt 0) {
        throw "Audio loop start must be 0 or greater in entry '$entry'."
      }

      $script:AudioLoopStarts[(Normalize-AudioMapKey -Value $parts[0])] = $seconds
    }
  }
}

function Resolve-FfmpegExecutable {
  param([string]$PreferredPath)

  $resolved = $null
  if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath -PathType Leaf)) {
    $resolved = (Resolve-Path -LiteralPath $PreferredPath).Path
  } else {
    $command = Get-Command $PreferredPath -ErrorAction SilentlyContinue
    if ($null -ne $command) {
      $resolved = $command.Source
    }
  }

  if ([string]::IsNullOrWhiteSpace($resolved)) {
    throw "Audio optimization requires ffmpeg. Install ffmpeg on PATH or pass -FfmpegPath. Use without -OptimizeAudio to embed original audio."
  }

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = & $resolved -version 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Audio optimization requires a working ffmpeg executable. '$resolved -version' failed. Output: $output"
    }
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  return $resolved
}

function Get-AudioLoopStartSeconds {
  param(
    [string]$Reference,
    [string]$PathOnly,
    [string]$ResolvedAssetPath
  )

  $candidates = @(
    $Reference,
    $PathOnly,
    [System.IO.Path]::GetFileName($PathOnly),
    $ResolvedAssetPath,
    [System.IO.Path]::GetFileName($ResolvedAssetPath)
  )

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    $key = Normalize-AudioMapKey -Value $candidate
    if ($script:AudioLoopStarts.ContainsKey($key)) {
      return [double]$script:AudioLoopStarts[$key]
    }
  }

  return 0.0
}

function Convert-AudioToOptimizedMp3 {
  param(
    [string]$Path,
    [string]$Reference,
    [string]$PathOnly
  )

  if (-not (Test-IsOptimizableAudio -Path $Path)) {
    return $null
  }

  $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + ".mp3")
  $arguments = @("-y")

  if ($AudioMode -eq "Loop") {
    $loopStart = Get-AudioLoopStartSeconds -Reference $Reference -PathOnly $PathOnly -ResolvedAssetPath $Path
    $arguments += @("-ss", (Format-InvariantNumber -Value $loopStart), "-t", $AudioLoopSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
  }

  $arguments += @("-i", $Path, "-vn", "-map_metadata", "-1", "-ac", "2", "-ar", "44100", "-b:a", "${AudioBitrateKbps}k")

  if ($AudioMode -eq "Loop" -and $AudioLoopFadeSeconds -gt 0) {
    $fadeSeconds = [Math]::Min($AudioLoopFadeSeconds, [Math]::Max(0.0, $AudioLoopSeconds / 2.0))
    $fadeOutStart = [Math]::Max(0.0, $AudioLoopSeconds - $fadeSeconds)
    $arguments += @("-af", "afade=t=in:st=0:d=$(Format-InvariantNumber -Value $fadeSeconds),afade=t=out:st=$(Format-InvariantNumber -Value $fadeOutStart):d=$(Format-InvariantNumber -Value $fadeSeconds)")
  }

  $arguments += $tempPath

  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $script:ResolvedFfmpegPath @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($exitCode -ne 0) {
      throw "ffmpeg audio optimization failed for $Reference. Output: $output"
    }

    return [System.IO.File]::ReadAllBytes($tempPath)
  } finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
      Remove-Item -LiteralPath $tempPath -Force
    }
  }
}

function Convert-ImageToOptimizedRaster {
  param(
    [string]$Path,
    [ValidateSet("WEBP", "JPEG")]
    [string]$Format,
    [int]$Quality,
    [int]$MaxWidth,
    [int]$MaxHeight
  )

  if (-not (Test-IsOptimizableImage -Path $Path)) {
    return $null
  }

  $extension = if ($Format -eq "JPEG") { ".jpg" } else { ".webp" }
  $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + $extension)
  $tempScriptPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + ".py")
  $pythonCode = @'
import os
import sys
from PIL import Image

input_path, output_path = sys.argv[1], sys.argv[2]
fmt = sys.argv[3]
quality, max_width, max_height = map(int, sys.argv[4:7])

im = Image.open(input_path)
has_alpha = im.mode in ("RGBA", "LA") or "transparency" in im.info
if fmt == "JPEG":
    if has_alpha:
        rgba = im.convert("RGBA")
        matte = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        matte.alpha_composite(rgba)
        im = matte.convert("RGB")
    else:
        im = im.convert("RGB")
else:
    im = im.convert("RGBA" if has_alpha else "RGB")

if max_width > 0 or max_height > 0:
    width, height = im.size
    scale = 1.0
    if max_width > 0:
        scale = min(scale, max_width / width)
    if max_height > 0:
        scale = min(scale, max_height / height)
    if scale < 1.0:
        im = im.resize((max(1, round(width * scale)), max(1, round(height * scale))), Image.Resampling.LANCZOS)

if fmt == "JPEG":
    im.save(output_path, "JPEG", quality=quality, optimize=True, progressive=True)
else:
    im.save(output_path, "WEBP", quality=quality, method=6)
'@

  try {
    [System.IO.File]::WriteAllText($tempScriptPath, $pythonCode, [System.Text.Encoding]::UTF8)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $script:ResolvedImageOptimizerPython $tempScriptPath $Path $tempPath $Format $Quality $MaxWidth $MaxHeight 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($exitCode -ne 0) {
      throw "Python optimizer failed for $Path. Output: $output"
    }

    return [System.IO.File]::ReadAllBytes($tempPath)
  } finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if (Test-Path -LiteralPath $tempScriptPath -PathType Leaf) {
      Remove-Item -LiteralPath $tempScriptPath -Force
    }
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
      Remove-Item -LiteralPath $tempPath -Force
    }
  }
}

function Get-AssetOptimizationCachePath {
  param(
    [string]$Path,
    [object]$Rule,
    [int]$Quality
  )

  if ([string]::IsNullOrWhiteSpace($script:AssetOptimizationCacheDir)) {
    return $null
  }

  $fileInfo = Get-Item -LiteralPath $Path
  $key = "$($fileInfo.FullName)|$($fileInfo.Length)|$($fileInfo.LastWriteTimeUtc.Ticks)|$($Rule.AssetPath)|$($Rule.Type)|$($Rule.TargetW)x$($Rule.TargetH)|q=$Quality"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }

  return Join-Path $script:AssetOptimizationCacheDir "$hash.webp"
}

function Convert-AssetToOptimizedRaster {
  param(
    [string]$Path,
    [object]$Rule,
    [int]$Quality
  )

  $cachePath = Get-AssetOptimizationCachePath -Path $Path -Rule $Rule -Quality $Quality
  if (-not [string]::IsNullOrWhiteSpace($cachePath) -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    return [System.IO.File]::ReadAllBytes($cachePath)
  }

  $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + ".webp")
  $tempScriptPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + ".py")
  $pythonCode = @'
import sys
from PIL import Image

input_path, output_path = sys.argv[1], sys.argv[2]
quality = int(sys.argv[3])
source_w, source_h = map(int, sys.argv[4:6])
target_w, target_h = map(int, sys.argv[6:8])

im = Image.open(input_path).convert("RGBA")
expected_size = (source_w, source_h)
if im.size != expected_size:
    raise SystemExit(
        f"Expected asset {expected_size[0]}x{expected_size[1]} for {input_path}, got {im.size[0]}x{im.size[1]}"
    )

target_size = (target_w, target_h)
im = im.resize(target_size, Image.Resampling.LANCZOS)
im.save(output_path, "WEBP", quality=quality, method=6)
'@

  try {
    [System.IO.File]::WriteAllText($tempScriptPath, $pythonCode, [System.Text.Encoding]::UTF8)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $script:ResolvedImageOptimizerPython `
      $tempScriptPath `
      $Path `
      $tempPath `
      $Quality `
      $Rule.SourceW `
      $Rule.SourceH `
      $Rule.TargetW `
      $Rule.TargetH 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($exitCode -ne 0) {
      throw "Python asset optimizer failed for $Path. Output: $output"
    }

    $bytes = [System.IO.File]::ReadAllBytes($tempPath)
    if (-not [string]::IsNullOrWhiteSpace($cachePath)) {
      $cacheDir = Split-Path -Parent $cachePath
      if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Path $cacheDir | Out-Null
      }
      [System.IO.File]::WriteAllBytes($cachePath, $bytes)
    }

    return $bytes
  } finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if (Test-Path -LiteralPath $tempScriptPath -PathType Leaf) {
      Remove-Item -LiteralPath $tempScriptPath -Force
    }
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
      Remove-Item -LiteralPath $tempPath -Force
    }
  }
}

function Convert-JsonValueAssetReferences {
  param(
    [object]$Value,
    [string]$JsonDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB
  )

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [string]) {
    $dataUri = Convert-AssetReferenceToDataUri -Reference $Value -ReferenceBaseDir $JsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    if (-not [string]::IsNullOrWhiteSpace($dataUri)) {
      return $dataUri
    }
    return $Value
  }

  if ($Value -is [System.Array]) {
    return @($Value | ForEach-Object {
      Convert-JsonValueAssetReferences -Value $_ -JsonDir $JsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    })
  }

  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
      $result[$property.Name] = Convert-JsonValueAssetReferences -Value $property.Value -JsonDir $JsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    }
    return [pscustomobject]$result
  }

  return $Value
}

function Register-JsonValueAssetReferences {
  param(
    [object]$Value,
    [string]$JsonDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB
  )

  if ($null -eq $Value) {
    return
  }

  if ($Value -is [string]) {
    Register-InlineAssetReference -Reference $Value -ReferenceBaseDir $JsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB | Out-Null
    return
  }

  if ($Value -is [System.Array]) {
    foreach ($item in $Value) {
      Register-JsonValueAssetReferences -Value $item -JsonDir $JsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    }
    return
  }

  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    foreach ($property in $Value.PSObject.Properties) {
      Register-JsonValueAssetReferences -Value $property.Value -JsonDir $JsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    }
  }
}

function Test-RuleHasMetadataKind {
  param(
    [object]$Rule,
    [string]$Kind
  )

  foreach ($metadata in @($Rule.Metadata)) {
    if ([string]$metadata.kind -eq $Kind) {
      return $true
    }
  }

  return $false
}

function Update-JsonAssetMetadataForDeployment {
  param([object]$Value)

  if (-not $OptimizeImages -or -not $script:OptimizeRenderedAssets) {
    return $Value
  }

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [System.Array]) {
    foreach ($item in $Value) {
      Update-JsonAssetMetadataForDeployment -Value $item | Out-Null
    }
    return $Value
  }

  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $srcProperty = $Value.PSObject.Properties["src"]
    $frameProperty = $Value.PSObject.Properties["frame"]
    if ($null -ne $srcProperty) {
      $key = Normalize-AssetReferenceKey -Value ([string]$srcProperty.Value)
      if ($script:AssetOptimizationRules.ContainsKey($key)) {
        $rule = $script:AssetOptimizationRules[$key]
        if ($rule.Downscale -and (Test-RuleHasMetadataKind -Rule $rule -Kind "stageVisualSourcePadding")) {
          $paddingProperty = $Value.PSObject.Properties["sourceBottomPadding"]
          if ($null -ne $paddingProperty) {
            $paddingProperty.Value = [Math]::Round(([double]$paddingProperty.Value) * $rule.ScaleY, 3)
          }
        }

        if ($null -ne $frameProperty -and $rule.Downscale -and (Test-RuleHasMetadataKind -Rule $rule -Kind "stageVisualFrames")) {
          $frame = $frameProperty.Value
          foreach ($name in @("x", "w")) {
            $property = $frame.PSObject.Properties[$name]
            if ($null -ne $property) {
              $property.Value = [Math]::Round(([double]$property.Value) * $rule.ScaleX, 3)
            }
          }
          foreach ($name in @("y", "h")) {
            $property = $frame.PSObject.Properties[$name]
            if ($null -ne $property) {
              $property.Value = [Math]::Round(([double]$property.Value) * $rule.ScaleY, 3)
            }
          }
        }
      }
    }

    foreach ($property in $Value.PSObject.Properties) {
      Update-JsonAssetMetadataForDeployment -Value $property.Value | Out-Null
    }
  }

  return $Value
}

function Get-JsonBytesWithInlinedReferences {
  param(
    [string]$Path,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB,
    [bool]$InlineReferences = $true
  )

  $jsonText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  try {
    $json = $jsonText | ConvertFrom-Json
  } catch {
    return [System.Text.Encoding]::UTF8.GetBytes($jsonText)
  }

  $jsonDir = Split-Path -Parent $Path
  $json = Update-JsonAssetMetadataForDeployment -Value $json
  $converted = if ($InlineReferences) {
    Convert-JsonValueAssetReferences -Value $json -JsonDir $jsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
  } else {
    Register-JsonValueAssetReferences -Value $json -JsonDir $jsonDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    $json
  }
  $convertedJson = $converted | ConvertTo-Json -Depth 100 -Compress
  return [System.Text.Encoding]::UTF8.GetBytes($convertedJson)
}

function Register-InlineAssetReference {
  param(
    [string]$Reference,
    [string]$ReferenceBaseDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB
  )

  $dataUri = Convert-AssetReferenceToDataUri -Reference $Reference -ReferenceBaseDir $ReferenceBaseDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
  if ([string]::IsNullOrWhiteSpace($dataUri)) {
    return $null
  }

  $key = Normalize-AssetReferenceKey -Value $Reference
  if (-not $script:InlineAssetRegistry.Contains($key)) {
    $script:InlineAssetRegistry[$key] = $dataUri
  }

  return $dataUri
}

function Convert-AssetReferenceToDataUri {
  param(
    [string]$Reference,
    [string]$ReferenceBaseDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB
  )

  $trimmed = $Reference.Trim()
  if (Test-IsExternalReference -Reference $trimmed) {
    return $null
  }

  $pathOnly = ($trimmed -split '[?#]', 2)[0]
  if ([string]::IsNullOrWhiteSpace($pathOnly)) {
    return $null
  }

  $decodedPath = [System.Uri]::UnescapeDataString($pathOnly)
  if ([System.IO.Path]::IsPathRooted($decodedPath)) {
    return $null
  }

  $relativePath = $decodedPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
  $candidates = @(
    (Join-Path $ReferenceBaseDir $relativePath),
    (Join-Path $ResolvedProjectRoot $relativePath)
  )
  $candidate = $null
  foreach ($candidatePath in $candidates) {
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      $candidate = $candidatePath
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    return $null
  }

  $resolvedAssetPath = (Resolve-Path -LiteralPath $candidate).Path
  if (-not (Test-IsUnderPath -ChildPath $resolvedAssetPath -ParentPath $ResolvedProjectRoot)) {
    Write-Warning "Skipping asset outside project root: $Reference"
    return $null
  }

  $patternValues = @($Reference, $pathOnly, $resolvedAssetPath)
  $keepOriginal = Test-AnyPatternMatch -Pattern $KeepOriginalPattern -Value $patternValues
  $manifestRuleKey = Normalize-AssetReferenceKey -Value $pathOnly
  $manifestRule = if ($script:AssetOptimizationRules.ContainsKey($manifestRuleKey)) {
    $script:AssetOptimizationRules[$manifestRuleKey]
  } else {
    $null
  }
  $assetRule = if (-not $keepOriginal) {
    Get-RenderedAssetOptimizationRule -Reference $pathOnly
  } else {
    $null
  }
  $useJpeg = (-not $keepOriginal) -and ($null -eq $assetRule) -and (Test-AnyPatternMatch -Pattern $JpegPattern -Value $patternValues)

  $audioMapCacheKey = $AudioLoopStartMap -join ";"
  $assetOptimizationCacheKey = if ($null -ne $assetRule) {
    "$($assetRule.Type):$($assetRule.TargetW)x$($assetRule.TargetH)"
  } else {
    "none"
  }
  $cacheKey = "$resolvedAssetPath|opt=$OptimizeImages|keep=$keepOriginal|jpg=$useJpeg|q=$ImageQuality|jq=$JpegQuality|mw=$ImageMaxWidth|mh=$ImageMaxHeight|asset=$assetOptimizationCacheKey|audio=$OptimizeAudio|am=$AudioMode|ab=$AudioBitrateKbps|als=$AudioLoopSeconds|alf=$AudioLoopFadeSeconds|alm=$audioMapCacheKey"
  if ($script:InlineAssetCache.ContainsKey($cacheKey)) {
    return $script:InlineAssetCache[$cacheKey]
  }

  $fileInfo = Get-Item -LiteralPath $resolvedAssetPath
  if ($MaxInlineAssetMB -gt 0 -and $fileInfo.Length -gt ($MaxInlineAssetMB * 1MB)) {
    $sizeMb = [Math]::Round($fileInfo.Length / 1MB, 2)
    Write-Warning "Skipping $Reference because it is $sizeMb MB, above MaxInlineAssetMB=$MaxInlineAssetMB."
    return $null
  }

  $mimeType = Get-MimeType -Path $resolvedAssetPath
  $bytes = if ([System.IO.Path]::GetExtension($resolvedAssetPath).ToLowerInvariant() -eq ".json") {
    Get-JsonBytesWithInlinedReferences -Path $resolvedAssetPath -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB -InlineReferences (-not $UseInlineAssetRegistry)
  } else {
    [System.IO.File]::ReadAllBytes($resolvedAssetPath)
  }
  $originalMimeType = $mimeType
  $originalByteCount = $bytes.Length
  $optimizationStatus = if ($keepOriginal) {
    "kept-original"
  } elseif ($null -ne $assetRule) {
    "optimized"
  } elseif ($null -ne $manifestRule -and -not $manifestRule.Downscale -and $manifestRule.Type -ne "coverImage") {
    "skipped-small-enough"
  } elseif ($OptimizeImages -and (Test-IsOptimizableImage -Path $resolvedAssetPath)) {
    "compressed-only"
  } else {
    "skipped-no-rule"
  }
  $optimizationRuleType = if ($null -ne $manifestRule) { $manifestRule.Type } else { "" }

  if ($OptimizeImages -and -not $keepOriginal) {
    if ($null -ne $assetRule) {
      $targetMimeType = "image/webp"
      $optimizedBytes = Convert-AssetToOptimizedRaster -Path $resolvedAssetPath -Rule $assetRule -Quality $ImageQuality
    } else {
      $targetFormat = if ($useJpeg) { "JPEG" } else { "WEBP" }
      $targetQuality = if ($useJpeg) { $JpegQuality } else { $ImageQuality }
      $targetMimeType = if ($useJpeg) { "image/jpeg" } else { "image/webp" }
      $optimizedBytes = Convert-ImageToOptimizedRaster -Path $resolvedAssetPath -Format $targetFormat -Quality $targetQuality -MaxWidth $ImageMaxWidth -MaxHeight $ImageMaxHeight
    }
    if ($null -ne $optimizedBytes -and ($null -ne $assetRule -or $optimizedBytes.Length -lt $bytes.Length)) {
      $bytes = $optimizedBytes
      $mimeType = $targetMimeType
    } elseif ($optimizationStatus -eq "compressed-only") {
      $optimizationStatus = "skipped-no-rule"
    }
  }

  if ($OptimizeAudio) {
    $optimizedAudioBytes = Convert-AudioToOptimizedMp3 -Path $resolvedAssetPath -Reference $Reference -PathOnly $pathOnly
    if ($null -ne $optimizedAudioBytes) {
      $bytes = $optimizedAudioBytes
      $mimeType = "audio/mpeg"
    }
  }

  Add-AssetOptimizationReportEntry `
    -Reference $Reference `
    -Status $optimizationStatus `
    -RuleType $optimizationRuleType `
    -OriginalBytes $originalByteCount `
    -EmbeddedBytes $bytes.Length `
    -MimeType $mimeType

  $base64 = [System.Convert]::ToBase64String($bytes)
  $sizeKb = [Math]::Round($bytes.Length / 1KB, 1)
  if ($mimeType -ne $originalMimeType -or $bytes.Length -ne $originalByteCount) {
    $originalSizeKb = [Math]::Round($originalByteCount / 1KB, 1)
    Write-Host "Embedded optimized asset: $Reference ($originalSizeKb KB -> $sizeKb KB, $mimeType)"
  } else {
    Write-Host "Embedded asset: $Reference ($sizeKb KB)"
  }

  $dataUri = "data:$mimeType;base64,$base64"
  $script:InlineAssetCache[$cacheKey] = $dataUri
  return $dataUri
}

function Inline-AttributeAssets {
  param(
    [string]$Html,
    [string]$HtmlDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB
  )

  $attributePattern = '(?<name>\b(?:src|href|poster)\s*=\s*)(?<quote>["''])(?<value>[^"'']+)\k<quote>'
  return [regex]::Replace($Html, $attributePattern, {
    param($match)

    $value = $match.Groups["value"].Value
    $dataUri = Convert-AssetReferenceToDataUri -Reference $value -ReferenceBaseDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    if ([string]::IsNullOrWhiteSpace($dataUri)) {
      return $match.Value
    }

    $name = $match.Groups["name"].Value
    $quote = $match.Groups["quote"].Value
    return "$name$quote$dataUri$quote"
  })
}

function Inline-CssUrlAssets {
  param(
    [string]$Html,
    [string]$HtmlDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB
  )

  $urlPattern = 'url\(\s*(?<quote>["'']?)(?<value>[^)"'']+)\k<quote>\s*\)'
  return [regex]::Replace($Html, $urlPattern, {
    param($match)

    $value = $match.Groups["value"].Value
    $dataUri = Convert-AssetReferenceToDataUri -Reference $value -ReferenceBaseDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    if ([string]::IsNullOrWhiteSpace($dataUri)) {
      return $match.Value
    }

    return "url(`"$dataUri`")"
  })
}

function Inline-QuotedAssetStrings {
  param(
    [string]$Html,
    [string]$HtmlDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB,
    [bool]$UseRegistry
  )

  $quotedPattern = '(?<quote>["''])(?<value>(?!data:)[^"'']+\.(?:apng|avif|css|gif|html?|jpe?g|js|json|m4a|mp3|ogg|otf|png|svg|ttf|wav|webm|webp|woff2?)(?:[?#][^"'']*)?)\k<quote>'
  return [regex]::Replace($Html, $quotedPattern, {
    param($match)

    $value = $match.Groups["value"].Value
    if ($UseRegistry) {
      Register-InlineAssetReference -Reference $value -ReferenceBaseDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB | Out-Null
      return $match.Value
    }

    $dataUri = Convert-AssetReferenceToDataUri -Reference $value -ReferenceBaseDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    if ([string]::IsNullOrWhiteSpace($dataUri)) {
      return $match.Value
    }

    $quote = $match.Groups["quote"].Value
    return "$quote$dataUri$quote"
  })
}

function Inline-LocalAssets {
  param(
    [string]$Html,
    [string]$HtmlDir,
    [string]$ResolvedProjectRoot,
    [double]$MaxInlineAssetMB,
    [bool]$InlineQuotedAssets
  )

  if ($InlineQuotedAssets) {
    $result = Inline-CssUrlAssets -Html $Html -HtmlDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    $result = Inline-QuotedAssetStrings -Html $result -HtmlDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB -UseRegistry $UseInlineAssetRegistry
  } else {
    $result = Inline-AttributeAssets -Html $Html -HtmlDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
    $result = Inline-CssUrlAssets -Html $result -HtmlDir $HtmlDir -ResolvedProjectRoot $ResolvedProjectRoot -MaxInlineAssetMB $MaxInlineAssetMB
  }

  return $result
}

function Add-InlineAssetRegistryScript {
  param([string]$Html)

  if (-not $UseInlineAssetRegistry -or $script:InlineAssetRegistry.Count -eq 0) {
    return $Html
  }

  $registryJson = $script:InlineAssetRegistry | ConvertTo-Json -Depth 3 -Compress
  $registryScript = "<script>window.__DEPLOY_ASSETS__=$registryJson;</script>"
  $scriptPattern = '<script\b[^>]*>'
  $match = [regex]::Match($Html, $scriptPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($match.Success) {
    return $Html.Substring(0, $match.Index) + $registryScript + "`n" + $Html.Substring($match.Index)
  }

  return $registryScript + "`n" + $Html
}

function Format-ScaledAssetNumber {
  param([double]$Value)

  return Format-InvariantNumber -Value ([Math]::Round($Value, 3))
}

function Scale-JsNumber {
  param(
    [string]$Text,
    [string]$PropertyName,
    [double]$Scale
  )

  $pattern = "($([regex]::Escape($PropertyName))\s*:\s*)(?<value>-?\d+(?:\.\d+)?)"
  return [regex]::Replace($Text, $pattern, {
    param($match)
    $value = [double]::Parse($match.Groups["value"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return $match.Groups[1].Value + (Format-ScaledAssetNumber -Value ($value * $Scale))
  })
}

function Scale-JsNumberArray {
  param(
    [string]$Text,
    [string]$PropertyName,
    [double]$Scale
  )

  $pattern = "(?<prefix>$([regex]::Escape($PropertyName))\s*:\s*\[)(?<values>[^\]]+)(?<suffix>\])"
  return [regex]::Replace($Text, $pattern, {
    param($match)
    $values = @()
    foreach ($item in ($match.Groups["values"].Value -split ",")) {
      $trimmed = $item.Trim()
      if ([string]::IsNullOrWhiteSpace($trimmed)) {
        continue
      }
      $value = [double]::Parse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture)
      $values += (Format-ScaledAssetNumber -Value ($value * $Scale))
    }
    return $match.Groups["prefix"].Value + ($values -join ", ") + $match.Groups["suffix"].Value
  })
}

function Update-JsObjectFrameMetadata {
  param(
    [string]$Html,
    [object]$Rule,
    [string]$ObjectName
  )

  $objectPattern = [regex]::Escape($ObjectName)
  $pattern = "(?s)(const\s+$objectPattern\s*=\s*\{.*?\n\s*\};)"
  $match = [regex]::Match($Html, $pattern)
  if (-not $match.Success) {
    Write-Warning "Could not update deploy frame metadata for $ObjectName."
    return $Html
  }

  $block = $match.Groups[1].Value
  $block = [regex]::Replace($block, "(?<prefix>frameW:\s*)\d+", {
    param($frameMatch)
    return $frameMatch.Groups["prefix"].Value + $Rule.TargetFrameW
  }, 1)
  $block = [regex]::Replace($block, "(?<prefix>frameH:\s*)\d+", {
    param($frameMatch)
    return $frameMatch.Groups["prefix"].Value + $Rule.TargetFrameH
  }, 1)
  $hadBottomPadding = $block -match "\bbottomPadding\s*:"
  $block = Scale-JsNumber -Text $block -PropertyName "bottomPadding" -Scale $Rule.ScaleY

  $offsetMessage = if ($hadBottomPadding) {
    ", offsets scaled by $($Rule.ScaleY.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture))x"
  } else {
    ""
  }
  Write-Host "Deploy frame metadata: $ObjectName frame $($Rule.SourceFrameW)x$($Rule.SourceFrameH) -> $($Rule.TargetFrameW)x$($Rule.TargetFrameH)$offsetMessage."
  return $Html.Substring(0, $match.Index) + $block + $Html.Substring($match.Index + $match.Length)
}

function Update-StageVisualFrameMetadata {
  param(
    [string]$Html,
    [object]$Rule
  )

  $assetPattern = [regex]::Escape($Rule.AssetPath)
  $pattern = "(?s)(?<prefix>src:\s*[""']$assetPattern[""'].*?frame:\s*\{\s*x:\s*)(?<x>-?\d+(?:\.\d+)?)(?<afterX>\s*,\s*y:\s*)(?<y>-?\d+(?:\.\d+)?)(?<afterY>\s*,\s*w:\s*)(?<w>-?\d+(?:\.\d+)?)(?<afterW>\s*,\s*h:\s*)(?<h>-?\d+(?:\.\d+)?)(?<suffix>\s*\})"
  return [regex]::Replace($Html, $pattern, {
    param($match)
    $x = [double]::Parse($match.Groups["x"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $y = [double]::Parse($match.Groups["y"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $w = [double]::Parse($match.Groups["w"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $h = [double]::Parse($match.Groups["h"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return $match.Groups["prefix"].Value +
      (Format-ScaledAssetNumber -Value ($x * $Rule.ScaleX)) +
      $match.Groups["afterX"].Value +
      (Format-ScaledAssetNumber -Value ($y * $Rule.ScaleY)) +
      $match.Groups["afterY"].Value +
      (Format-ScaledAssetNumber -Value ($w * $Rule.ScaleX)) +
      $match.Groups["afterW"].Value +
      (Format-ScaledAssetNumber -Value ($h * $Rule.ScaleY)) +
      $match.Groups["suffix"].Value
  })
}

function Update-StageVisualSourcePaddingMetadata {
  param(
    [string]$Html,
    [object]$Rule
  )

  $assetPattern = [regex]::Escape($Rule.AssetPath)
  $pattern = "(?s)(?<prefix>src:\s*[""']$assetPattern[""'].*?sourceBottomPadding:\s*)(?<padding>-?\d+(?:\.\d+)?)"
  $updated = [regex]::Replace($Html, $pattern, {
    param($match)
    $value = [double]::Parse($match.Groups["padding"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return $match.Groups["prefix"].Value + (Format-ScaledAssetNumber -Value ($value * $Rule.ScaleY))
  })

  if ($updated -ne $Html) {
    Write-Host "Deploy source-space metadata: stage visual sourceBottomPadding for $($Rule.AssetPath) scaled by $($Rule.ScaleY.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture))x."
  }

  return $updated
}

function Update-CheckpointFlagMetadata {
  param(
    [string]$Html,
    [object]$Rule
  )

  $pattern = "(?s)(const\s+checkpointFlagSprite\s*=\s*\{.*?\n\s*\};)"
  $match = [regex]::Match($Html, $pattern)
  if (-not $match.Success) {
    Write-Warning "Could not update checkpoint flag metadata."
    return $Html
  }

  $block = $match.Groups[1].Value
  $block = [regex]::Replace($block, "(?<prefix>frameW:\s*)\d+", {
    param($frameMatch)
    return $frameMatch.Groups["prefix"].Value + $Rule.TargetFrameW
  }, 1)
  $block = [regex]::Replace($block, "(?<prefix>frameH:\s*)\d+", {
    param($frameMatch)
    return $frameMatch.Groups["prefix"].Value + $Rule.TargetFrameH
  }, 1)
  $block = Scale-JsNumber -Text $block -PropertyName "sourcePoleX" -Scale $Rule.ScaleX
  $block = Scale-JsNumber -Text $block -PropertyName "sourceFootY" -Scale $Rule.ScaleY
  $block = Scale-JsNumber -Text $block -PropertyName "visibleSourceH" -Scale $Rule.ScaleY

  Write-Host "Deploy source-space metadata: checkpointFlagSprite scaled by $($Rule.ScaleX.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture))x."
  return $Html.Substring(0, $match.Index) + $block + $Html.Substring($match.Index + $match.Length)
}

function Update-BusStationMetadata {
  param(
    [string]$Html,
    [object]$Rule
  )

  $pattern = "(?s)(const\s+tanaBusStationSprite\s*=\s*\{.*?\n\s*\};)"
  $match = [regex]::Match($Html, $pattern)
  if (-not $match.Success) {
    Write-Warning "Could not update Tana bus station metadata."
    return $Html
  }

  $block = $match.Groups[1].Value
  $block = Scale-JsNumber -Text $block -PropertyName "sourceBottomPadding" -Scale $Rule.ScaleY
  $block = Scale-JsNumber -Text $block -PropertyName "x" -Scale $Rule.ScaleX
  $block = Scale-JsNumber -Text $block -PropertyName "y" -Scale $Rule.ScaleY
  $block = Scale-JsNumber -Text $block -PropertyName "w" -Scale $Rule.ScaleX
  $block = Scale-JsNumber -Text $block -PropertyName "h" -Scale $Rule.ScaleY

  Write-Host "Deploy source-space metadata: tanaBusStationSprite scaled by $($Rule.ScaleX.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture))x."
  return $Html.Substring(0, $match.Index) + $block + $Html.Substring($match.Index + $match.Length)
}

function Update-LiteralSourcePaddingMetadata {
  param(
    [string]$Html,
    [object]$Rule,
    [object]$Metadata
  )

  $functionName = [regex]::Escape([string]$Metadata.functionName)
  $imageExpression = [regex]::Escape([string]$Metadata.imageExpression)
  $pattern = "(?s)(?<prefix>$functionName\s*\(\s*$imageExpression\s*,.*?,\s*)(?<padding>-?\d+(?:\.\d+)?)(?<suffix>\s*\))"
  return [regex]::Replace($Html, $pattern, {
    param($match)
    $value = [double]::Parse($match.Groups["padding"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return $match.Groups["prefix"].Value + (Format-ScaledAssetNumber -Value ($value * $Rule.ScaleY)) + $match.Groups["suffix"].Value
  }, 1)
}

function Update-AssetMetadataForDeployment {
  param(
    [string]$Html,
    [string]$ResolvedProjectRoot
  )

  if (-not $OptimizeImages -or $NoInlineAssets -or -not $script:OptimizeRenderedAssets) {
    return $Html
  }

  $updated = $Html
  foreach ($rule in $script:AssetOptimizationRules.Values) {
    if (-not $rule.Downscale) {
      continue
    }

    $relativePath = $rule.AssetPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $resolvedAssetPath = Join-Path $ResolvedProjectRoot $relativePath
    if (Test-Path -LiteralPath $resolvedAssetPath -PathType Leaf) {
      $resolvedAssetPath = (Resolve-Path -LiteralPath $resolvedAssetPath).Path
    }

    $patternValues = @($rule.AssetPath, $resolvedAssetPath)
    if (Test-AnyPatternMatch -Pattern $KeepOriginalPattern -Value $patternValues) {
      continue
    }

    foreach ($metadata in @($rule.Metadata)) {
      $kind = [string]$metadata.kind
      if ($kind -eq "jsObjectFrame") {
        $updated = Update-JsObjectFrameMetadata -Html $updated -Rule $rule -ObjectName ([string]$metadata.objectName)
      } elseif ($kind -eq "stageVisualFrames") {
        $updated = Update-StageVisualFrameMetadata -Html $updated -Rule $rule
      } elseif ($kind -eq "stageVisualSourcePadding") {
        $updated = Update-StageVisualSourcePaddingMetadata -Html $updated -Rule $rule
      } elseif ($kind -eq "checkpointFlagSprite") {
        $updated = Update-CheckpointFlagMetadata -Html $updated -Rule $rule
      } elseif ($kind -eq "busStationSprite") {
        $updated = Update-BusStationMetadata -Html $updated -Rule $rule
      } elseif ($kind -eq "literalSourcePadding") {
        $updated = Update-LiteralSourcePaddingMetadata -Html $updated -Rule $rule -Metadata $metadata
      }
    }
  }

  return $updated
}

function Test-ContentPatterns {
  param(
    [string]$Content,
    [string]$Context,
    [string[]]$RequiredPattern,
    [string[]]$ForbiddenPattern,
    [string]$TitleContains
  )

  foreach ($pattern in $ForbiddenPattern) {
    if (-not [string]::IsNullOrWhiteSpace($pattern) -and $Content -match $pattern) {
      throw "$Context verification failed: forbidden pattern found: $pattern"
    }
  }

  foreach ($pattern in $RequiredPattern) {
    if (-not [string]::IsNullOrWhiteSpace($pattern) -and $Content -notmatch $pattern) {
      throw "$Context verification failed: required pattern was not found: $pattern"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($TitleContains) -and $Content -notmatch "<title>[^<]*$([regex]::Escape($TitleContains))") {
    Write-Warning "$Context verification did not find TitleContains='$TitleContains' in the <title> tag."
  }
}

function Convert-WebResponseToUtf8Text {
  param([object]$Response)

  if ($null -ne $Response.RawContentStream) {
    $stream = $Response.RawContentStream
    if ($stream.CanSeek) {
      $stream.Position = 0
    }

    $memory = [System.IO.MemoryStream]::new()
    try {
      $stream.CopyTo($memory)
      $bytes = $memory.ToArray()
      return [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } finally {
      $memory.Dispose()
    }
  }

  if ($Response.Content -is [byte[]]) {
    return [System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$Response.Content)
  }

  return [string]$Response.Content
}

if ($ImageQuality -lt 1 -or $ImageQuality -gt 100) {
  throw "ImageQuality must be between 1 and 100."
}

if ($JpegQuality -lt 1 -or $JpegQuality -gt 100) {
  throw "JpegQuality must be between 1 and 100."
}

if ($ImageMaxWidth -lt 0 -or $ImageMaxHeight -lt 0) {
  throw "ImageMaxWidth and ImageMaxHeight must be 0 or greater."
}

if ($RenderedAssetScale -le 0) {
  throw "RenderedAssetScale must be greater than 0."
}

if ($RenderedSpriteScale -le 0) {
  throw "RenderedSpriteScale must be greater than 0."
}

$script:EffectiveRenderedAssetScale = if ($PSBoundParameters.ContainsKey("RenderedAssetScale")) {
  $RenderedAssetScale
} elseif ($PSBoundParameters.ContainsKey("RenderedSpriteScale")) {
  $RenderedSpriteScale
} else {
  $RenderedAssetScale
}
$script:OptimizeRenderedAssets = -not ($NoOptimizeRenderedAssets -or $NoOptimizeRenderedSprites)

if ($AudioBitrateKbps -lt 16 -or $AudioBitrateKbps -gt 320) {
  throw "AudioBitrateKbps must be between 16 and 320."
}

if ($AudioLoopSeconds -lt 1) {
  throw "AudioLoopSeconds must be 1 or greater."
}

if ($AudioLoopFadeSeconds -lt 0) {
  throw "AudioLoopFadeSeconds must be 0 or greater."
}

if ($OptimizeImages -and -not $NoInlineAssets) {
  $script:ResolvedImageOptimizerPython = Resolve-ImageOptimizerPython -PreferredPython $ImageOptimizerPython
  Write-Host "Image optimization enabled: converting eligible images to WebP at quality $ImageQuality."
  if ($JpegPattern.Count -gt 0) {
    Write-Host "JPEG override enabled for matching references at quality $JpegQuality."
  }
  if ($KeepOriginalPattern.Count -gt 0) {
    Write-Host "Original-asset override enabled for matching references."
  }
  if ($ImageMaxWidth -gt 0 -or $ImageMaxHeight -gt 0) {
    Write-Host "Image resize limit: max width=$ImageMaxWidth, max height=$ImageMaxHeight."
  }
  if ($script:OptimizeRenderedAssets) {
    Write-Host "Rendered asset optimization enabled: scale=$($script:EffectiveRenderedAssetScale.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)), manifest=$AssetOptimizationManifest."
  }
}

if ($OptimizeAudio -and -not $NoInlineAssets) {
  Initialize-AudioLoopStartMap -MapEntries $AudioLoopStartMap
  $script:ResolvedFfmpegPath = Resolve-FfmpegExecutable -PreferredPath $FfmpegPath
  Write-Host "Audio optimization enabled: mode=$AudioMode, bitrate=${AudioBitrateKbps}k."
  if ($AudioMode -eq "Loop") {
    Write-Host "Audio loop settings: length=${AudioLoopSeconds}s, fade=${AudioLoopFadeSeconds}s."
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolvedProjectRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $scriptDir
} else {
  Resolve-ProjectPath -Path $ProjectRoot -BasePath $scriptDir
}
$script:AssetOptimizationCacheDir = Join-Path $resolvedProjectRoot "dist\asset-optimization-cache"
Initialize-AssetOptimizationRules -ResolvedProjectRoot $resolvedProjectRoot -Scale $script:EffectiveRenderedAssetScale
if ($OptimizeImages -and $script:OptimizeRenderedAssets -and $script:AssetOptimizationRules.Count -gt 0) {
  Write-Host "Loaded $($script:AssetOptimizationRules.Count) rendered asset optimization rules."
}

$resolvedHtmlPath = Resolve-ProjectPath -Path $HtmlPath -BasePath $resolvedProjectRoot
if (-not (Test-IsUnderPath -ChildPath $resolvedHtmlPath -ParentPath $resolvedProjectRoot)) {
  throw "HtmlPath must resolve inside ProjectRoot. HtmlPath=$resolvedHtmlPath ProjectRoot=$resolvedProjectRoot"
}

$html = [System.IO.File]::ReadAllText($resolvedHtmlPath, [System.Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($html)) {
  throw "The HTML file is empty: $resolvedHtmlPath"
}

if ($html -notmatch "<!DOCTYPE html|<!doctype html") {
  Write-Warning "The file does not appear to contain an HTML doctype."
}

$htmlDir = Split-Path -Parent $resolvedHtmlPath
if (-not $NoInlineAssets) {
  Write-Host "Preparing self-contained HTML with local assets inlined ..."
  $html = Update-AssetMetadataForDeployment `
    -Html $html `
    -ResolvedProjectRoot $resolvedProjectRoot

  $html = Inline-LocalAssets `
    -Html $html `
    -HtmlDir $htmlDir `
    -ResolvedProjectRoot $resolvedProjectRoot `
    -MaxInlineAssetMB $MaxInlineAssetMB `
    -InlineQuotedAssets (-not $NoInlineQuotedAssets)

  $html = Add-InlineAssetRegistryScript -Html $html
}

Test-ContentPatterns `
  -Content $html `
  -Context "Local build" `
  -RequiredPattern $RequiredPattern `
  -ForbiddenPattern $ForbiddenPattern `
  -TitleContains $TitleContains

$defaultOutputDir = Join-Path $resolvedProjectRoot "dist"
$defaultOutputPath = Join-Path $defaultOutputDir ([System.IO.Path]::GetFileNameWithoutExtension($resolvedHtmlPath) + ".standalone.html")
$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $defaultOutputPath
} elseif ([System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath
} else {
  Join-Path $resolvedProjectRoot $OutputPath
}

$outputDir = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outputDir | Out-Null
}

[System.IO.File]::WriteAllText($resolvedOutputPath, $html, [System.Text.Encoding]::UTF8)
$payloadSizeKb = [Math]::Round([System.Text.Encoding]::UTF8.GetByteCount($html) / 1KB, 1)
Write-Host "Wrote standalone HTML: $resolvedOutputPath"
Write-Host "Standalone HTML size: $payloadSizeKb KB"
if ($WriteAssetOptimizationReport) {
  $reportPath = [System.IO.Path]::ChangeExtension($resolvedOutputPath, ".asset-optimization-report.json")
  $report = [pscustomobject]@{
    generatedAt = [DateTime]::UtcNow.ToString("o")
    renderedAssetScale = $script:EffectiveRenderedAssetScale
    manifest = $AssetOptimizationManifest
    standaloneBytes = [System.Text.Encoding]::UTF8.GetByteCount($html)
    assets = $script:AssetOptimizationReport
  }
  [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 100), [System.Text.Encoding]::UTF8)
  Write-Host "Wrote asset optimization report: $reportPath"
}

if ($NoUpload) {
  Write-Host "NoUpload was set; skipping HTML.cafe upload."
  return
}

if ([string]::IsNullOrWhiteSpace($PageId)) {
  throw "PageId is required for upload. Pass -PageId or set HTMLCAFE_PAGE_ID. Use -NoUpload to build locally only."
}

if ([string]::IsNullOrWhiteSpace($EditKey)) {
  throw "EditKey is required for upload. Pass -EditKey or set HTMLCAFE_EDIT_KEY. Use -NoUpload to build locally only."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$payload = [ordered]@{
  id = $PageId
  key = $EditKey
  data = [string]$html
} | ConvertTo-Json -Depth 3 -Compress
$payloadBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($payload)

$publicBase = $PublicBaseUrl.TrimEnd("/")
$publicUrl = "$publicBase/$PageId"

Write-Host "Deploying $resolvedHtmlPath to $publicUrl ..."
$response = Invoke-RestMethod -Uri $SaveUrl -Method Post -Body $payloadBytes -ContentType "application/json; charset=utf-8" -TimeoutSec $TimeoutSec

if ([string]$response -ne "1") {
  throw "HTML.cafe did not accept the save. Response: $response"
}

Write-Host "Upload accepted."

if (-not $SkipVerify) {
  Write-Host "Verifying public page ..."
  $published = Invoke-WebRequest -Uri $publicUrl -UseBasicParsing -TimeoutSec $TimeoutSec
  $content = Convert-WebResponseToUtf8Text -Response $published

  Test-ContentPatterns `
    -Content $content `
    -Context "Published page" `
    -RequiredPattern $RequiredPattern `
    -ForbiddenPattern $ForbiddenPattern `
    -TitleContains $TitleContains

  Write-Host "Verification passed."
}

Write-Host "Live URL: $publicUrl"
