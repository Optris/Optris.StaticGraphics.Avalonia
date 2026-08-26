param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [Parameter(Mandatory = $true)]
    [string]$NuGetSource,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Vulkan", "OpenGL", "Software")]
    [string]$Tier,

    [Alias("StaticGraphicsVersion")]
    [string]$PackageVersion = "",

    [string]$AvaloniaNativeVersion = "",

    [string]$AvaloniaVersion = "11.3.14",

    [string]$SkiaSharpVersion = "",

    # Defaults to everything the tier promises, so a passing publish is also a passing guard check.
    [string]$RequiredBackends = "",

    [switch]$AcknowledgeReducedTier
)

$ErrorActionPreference = "Stop"

# Must match Backend in Smoke/OptrisStaticGraphicsSmoke/SmokeOptions.cs: each tier is a strict
# superset of the one below it.
$tierBackends = @{
    "Vulkan"   = "Vulkan;OpenGL;Software"
    "OpenGL"   = "OpenGL;Software"
    "Software" = "Software"
}

$templateDir = Join-Path (Split-Path -Parent $PSScriptRoot) "Smoke/OptrisStaticGraphicsSmoke"
if (-not (Test-Path (Join-Path $templateDir "OptrisStaticGraphicsSmoke.csproj"))) {
    throw "Smoke project template was not found: $templateDir"
}

if (-not $RequiredBackends) {
    $RequiredBackends = $tierBackends[$Tier]
}

New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null

# bin and obj are excluded: a developer's local build would otherwise travel with the template and the
# copy would start out holding another tier's generated LinkedPackage.g.cs.
Get-ChildItem -Path $templateDir -Force |
    Where-Object { $_.Name -notin @("bin", "obj") } |
    Copy-Item -Destination $ProjectDir -Recurse -Force

function Format-XmlValue([string]$value) {
    [System.Security.SecurityElement]::Escape($value)
}

$escapedNuGetSource = Format-XmlValue $NuGetSource
$escapedAvaloniaVersion = Format-XmlValue $AvaloniaVersion
$escapedTier = Format-XmlValue $Tier
$escapedPackageVersion = Format-XmlValue $PackageVersion
$escapedAvaloniaNativeVersion = Format-XmlValue $AvaloniaNativeVersion
$escapedSkiaSharpVersion = Format-XmlValue $SkiaSharpVersion
$escapedRequiredBackends = Format-XmlValue $RequiredBackends
$escapedAcknowledge = if ($AcknowledgeReducedTier) { "true" } else { "" }

@"
<Project>
  <PropertyGroup>
    <AvaloniaVersion>$escapedAvaloniaVersion</AvaloniaVersion>
    <SmokeTier>$escapedTier</SmokeTier>
    <SmokeStaticGraphicsVersion>$escapedPackageVersion</SmokeStaticGraphicsVersion>
    <SmokeAvaloniaNativeVersion>$escapedAvaloniaNativeVersion</SmokeAvaloniaNativeVersion>
    <SmokeSkiaSharpVersion>$escapedSkiaSharpVersion</SmokeSkiaSharpVersion>
    <SmokeRequiredBackends>$escapedRequiredBackends</SmokeRequiredBackends>
    <SmokeAcknowledgeReducedTier>$escapedAcknowledge</SmokeAcknowledgeReducedTier>
  </PropertyGroup>
</Project>
"@ | Set-Content -Path (Join-Path $ProjectDir "SmokeVersions.props") -Encoding UTF8

@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local-optris-staticgraphics" value="$escapedNuGetSource" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@ | Set-Content -Path (Join-Path $ProjectDir "NuGet.config") -Encoding UTF8

Write-Host "Smoke project for the $Tier tier written to $ProjectDir"
Write-Host "  package        : Optris.StaticGraphics.Avalonia.$Tier $PackageVersion"
Write-Host "  guard requires : $RequiredBackends"
Write-Host "  run it once per backend: $($tierBackends[$Tier] -replace ';', ', ')"
