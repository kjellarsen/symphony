param(
  [string]$InstallDir = (Join-Path $env:APPDATA 'npm'),
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Install-TemplateFile {
  param(
    [string]$TemplatePath,
    [string]$DestinationPath,
    [hashtable]$Replacements
  )

  $content = Get-Content -LiteralPath $TemplatePath -Raw

  foreach ($entry in $Replacements.GetEnumerator()) {
    $content = $content.Replace($entry.Key, $entry.Value)
  }

  if (Test-Path -LiteralPath $DestinationPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $DestinationPath -Destination "$DestinationPath.bak-$timestamp"
  }

  Set-Content -LiteralPath $DestinationPath -Value $content -NoNewline
}

$resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$templateDir = Join-Path $resolvedRepoRoot 'scripts\windows'

if (-not (Test-Path -LiteralPath $templateDir)) {
  throw "Launcher templates not found under $templateDir"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$replacements = @{
  '__SYMPHONY_ROOT__' = $resolvedRepoRoot
}

Install-TemplateFile `
  -TemplatePath (Join-Path $templateDir 'symphony.ps1.template') `
  -DestinationPath (Join-Path $InstallDir 'symphony.ps1') `
  -Replacements $replacements

Install-TemplateFile `
  -TemplatePath (Join-Path $templateDir 'symphony.cmd.template') `
  -DestinationPath (Join-Path $InstallDir 'symphony.cmd') `
  -Replacements $replacements

Write-Host "Installed Symphony launcher to $InstallDir" -ForegroundColor Green
Write-Host "Repo root: $resolvedRepoRoot" -ForegroundColor Cyan
