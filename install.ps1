# dsh-approval-hud installer for a DSH profile.
#
# Adds the plugin to <profile>/package.json and its bundle list, then runs the
# bundled pnpm. It never edits DSH itself. Quit DSH before running against the
# live profile so Windows does not lock files during the install.
#
# Examples:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Profile web
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#
# For a disposable test profile:
#   .\install.ps1 -ProfileDir C:\tmp\profile -SkipProcessCheck

param(
  [string]$Profile = 'desktop',
  [string]$DshHome = '',
  [string]$ProfileDir = '',
  [string]$InstallDir = '',
  [string]$PnpmPath = '',
  [string]$NodePath = '',
  [switch]$NoCopy,
  [switch]$Uninstall,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$SkipProcessCheck
)

$ErrorActionPreference = 'Stop'
$pluginName = 'dsh-approval-hud'
$pluginVersion = '0.3.3'
$packageRoot = $PSScriptRoot

function Write-Step([string]$Message) {
  Write-Host "==> $Message"
}

function Write-Note([string]$Message) {
  Write-Host "    $Message"
}

function Fail([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

if ([string]::IsNullOrWhiteSpace($DshHome)) {
  if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    $DshHome = $env:DSH_HOME
  } else {
    $DshHome = Join-Path $HOME '.dsh'
  }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)

if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
  $ProfileDir = Join-Path (Join-Path $DshHome 'profiles') $Profile
}
$ProfileDir = [IO.Path]::GetFullPath($ProfileDir)
$profilePackage = Join-Path $ProfileDir 'package.json'

if (-not (Test-Path -LiteralPath $profilePackage)) {
  Fail "profile package.json not found: $profilePackage"
}

$isCustomProfileDir = -not $ProfileDir.StartsWith((Join-Path $DshHome 'profiles'), [StringComparison]::OrdinalIgnoreCase)
$checkProcess = -not ($SkipProcessCheck -or $isCustomProfileDir -or $DryRun)
if ($checkProcess -and -not $Force) {
  $running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
  if ($null -ne $running) {
    Fail 'DSH is running. Quit it completely from the tray, then rerun. Use -Force to override.'
  }
}

$pnpm = Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
if (-not [string]::IsNullOrWhiteSpace($PnpmPath)) {
  $pnpm = [IO.Path]::GetFullPath($PnpmPath)
}
if (-not (Test-Path -LiteralPath $pnpm)) {
  $candidate = Get-ChildItem -Path (Join-Path $DshHome 'dsh-runtimes') -Filter 'pnpm.mjs' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -ne $candidate) { $pnpm = $candidate.FullName }
}
if (-not (Test-Path -LiteralPath $pnpm)) {
  Fail "bundled pnpm not found. Expected: $pnpm"
}

$node = $null
if (-not [string]::IsNullOrWhiteSpace($NodePath)) {
  $node = [IO.Path]::GetFullPath($NodePath)
}
$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($node) -and $null -ne $nodeCommand) {
  $node = $nodeCommand.Source
}
if ([string]::IsNullOrWhiteSpace($node)) {
  $bundledNode = Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
  if (Test-Path -LiteralPath $bundledNode) { $node = $bundledNode }
}
if ([string]::IsNullOrWhiteSpace($node)) {
  Fail 'Node.js not found. Install Node 22+ or use the DSH plugin manager.'
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Join-Path (Join-Path $DshHome 'plugins') ("$pluginName-$pluginVersion")
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)

$raw = [IO.File]::ReadAllText($profilePackage, [Text.Encoding]::UTF8)
try {
  $package = $raw | ConvertFrom-Json
} catch {
  Fail "cannot parse $profilePackage : $($_.Exception.Message)"
}
if ($null -eq $package.dsh -or $null -eq $package.dsh.profile) {
  Fail "package.json has no dsh.profile section: $profilePackage"
}

$dependencies = [ordered]@{}
if ($null -ne $package.dependencies) {
  foreach ($property in $package.dependencies.PSObject.Properties) {
    $dependencies[$property.Name] = $property.Value
  }
}
$bundles = @($package.dsh.profile.bundles)

if ($Uninstall) {
  Write-Step "Uninstalling $pluginName from $ProfileDir"
  if ($dependencies.Contains($pluginName)) {
    $dependencies.Remove($pluginName)
  } else {
    Write-Note 'dependency was not present'
  }
  $bundles = @($bundles | Where-Object { $_ -ne $pluginName })

  if ($DryRun) {
    Write-Note "would remove dependency '$pluginName'"
    Write-Note "would remove bundle '$pluginName'"
    Write-Note "would run: node `"$pnpm`" install --dir `"$ProfileDir`""
    exit 0
  }

  $package.dependencies = [pscustomobject]$dependencies
  $package.dsh.profile.bundles = $bundles
  $json = $package | ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($profilePackage, $json, (New-Object Text.UTF8Encoding($false)))

  Push-Location $ProfileDir
  try {
    & $node $pnpm install --dir $ProfileDir
    if ($LASTEXITCODE -ne 0) { Fail "pnpm install failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }

  $pluginsRoot = [IO.Path]::GetFullPath((Join-Path $DshHome 'plugins'))
  if ($InstallDir.StartsWith($pluginsRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $InstallDir)) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Note "removed $InstallDir"
  }
  Write-Step 'Uninstalled. Restart DSH to unload the plugin.'
  exit 0
}

Write-Step "Installing $pluginName $pluginVersion"
Write-Note "profile: $ProfileDir"
Write-Note "package: $packageRoot"

if ($NoCopy) {
  $InstallDir = [IO.Path]::GetFullPath($packageRoot)
  Write-Note 'copy: disabled (linking the source directory)'
} elseif (-not $DryRun) {
  $pluginsRoot = [IO.Path]::GetFullPath((Join-Path $DshHome 'plugins'))
  if (-not $InstallDir.StartsWith($pluginsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "install directory must stay under $pluginsRoot"
  }
  if (Test-Path -LiteralPath $InstallDir) {
    Write-Note "replacing existing $InstallDir"
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  $items = @('lib', 'ui', 'locale', 'docs', 'cordis.patch.yml', 'package.json', 'icon.svg', 'README.md', 'README.zh.md', 'LICENSE')
  foreach ($item in $items) {
    $source = Join-Path $packageRoot $item
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination $InstallDir -Recurse -Force
    }
  }
  Write-Note "copied plugin to $InstallDir"
}

$dependencySpec = 'file:' + ($InstallDir -replace '\\', '/')
$dependencies[$pluginName] = $dependencySpec
if ($bundles -notcontains $pluginName) {
  $bundles += $pluginName
}

Write-Note "dependency: $pluginName -> $dependencySpec"
Write-Note "bundles: $($bundles -join ', ')"

if ($DryRun) {
  Write-Note "would run: node `"$pnpm`" install --dir `"$ProfileDir`""
  Write-Step 'Dry run only; nothing changed.'
  exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item -LiteralPath $profilePackage -Destination "$profilePackage.bak-$stamp" -Force
$lockPath = Join-Path $ProfileDir 'pnpm-lock.yaml'
if (Test-Path -LiteralPath $lockPath) {
  Copy-Item -LiteralPath $lockPath -Destination "$lockPath.bak-$stamp" -Force
}

$package.dependencies = [pscustomobject]$dependencies
$package.dsh.profile.bundles = $bundles
$json = $package | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($profilePackage, $json, (New-Object Text.UTF8Encoding($false)))

Write-Step 'Running pnpm install'
Push-Location $ProfileDir
try {
  & $node $pnpm install --dir $ProfileDir
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($code -ne 0) {
  Copy-Item -LiteralPath "$profilePackage.bak-$stamp" -Destination $profilePackage -Force
  if (Test-Path -LiteralPath "$lockPath.bak-$stamp") {
    Copy-Item -LiteralPath "$lockPath.bak-$stamp" -Destination $lockPath -Force
  }
  Fail "pnpm install failed with exit code $code; package.json and pnpm-lock.yaml were restored."
}

Write-Step 'Installed.'
Write-Note 'Restart DSH completely to load the host plugin.'
Write-Note 'A shield icon should appear in the Windows tray.'
Write-Note "Diagnostics: set debug: true and inspect $env:LOCALAPPDATA\dsh-approval-hud\"
