param(
    [ValidateSet("skia", "angle", "angle-preflight", "all")]
    [string]$Target = "all",

    [string]$Tier = $(if ($env:TIER) { $env:TIER } else { "Vulkan" })
)

$ErrorActionPreference = "Stop"

# Each tier is a strict superset of the one below it, so no package can leave a hole in an
# Avalonia render-backend fallback chain: whatever a tier claims, it also claims everything
# under it. The names are part of the cross-repo contract - they become the payload
# directory, the PackageId suffix and the OptrisStaticGraphicsBackends property.
$KnownTiers = @("Vulkan", "OpenGL", "Software")
$TierBackends = @{
    "Vulkan"   = @("Vulkan", "OpenGL", "Software")
    "OpenGL"   = @("OpenGL", "Software")
    "Software" = @("Software")
}

# A default taken from $env:TIER never passes through [ValidateSet], and the tier spelling
# ends up in a package id, so reject anything that is not an exact match.
if ($KnownTiers -cnotcontains $Tier) {
    throw "Unknown tier '$Tier'. Expected one of: $($KnownTiers -join ', ') (case-sensitive)."
}
$Backends = $TierBackends[$Tier]

$RootDir = Split-Path -Parent $PSScriptRoot
$WorkDir = if ($env:WORK_DIR) { $env:WORK_DIR } else { Join-Path $RootDir "External\NativeStatic\.work" }
$SkiaSharpVersion = if ($env:SKIASHARP_VERSION) { $env:SKIASHARP_VERSION } else { "4.150.1" }
$AngleBranch = if ($env:ANGLE_BRANCH) { $env:ANGLE_BRANCH } else { "7922" }
$TargetCpu = if ($env:TARGET_CPU) { $env:TARGET_CPU } else { "x64" }
$Rid = if ($env:RID) { $env:RID } else { "win-$TargetCpu" }
# Tiers differ only in what is compiled in, so they share $WorkDir - the multi-GB
# depot_tools/SkiaSharp/ANGLE checkout is cloned once and reused by every tier - while the
# payload is kept apart per tier so one tier can never overwrite another's archives.
$OutputDir = if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { Join-Path $RootDir "External\NativeStatic\static-$Tier\$Rid\native" }
$BuildJobs = if ($env:BUILD_JOBS) { $env:BUILD_JOBS } else { [Environment]::ProcessorCount }
$AnglePatchDir = if ($env:ANGLE_PATCH_DIR) { $env:ANGLE_PATCH_DIR } else { Join-Path $RootDir "External\NativeStatic\patches" }
$SkiaDepsRetries = if ($env:SKIA_DEPS_RETRIES) { [int]$env:SKIA_DEPS_RETRIES } else { 3 }

# The one place the MSVC location is decided, so the GYP environment below and Skia's own win_vc
# GN arg can never disagree about which compiler is being used.
# VSINSTALLDIR is deliberately NOT consulted: it is ambient, any developer prompt or installer can
# have set it, and a wrong value here is a build that fails deep inside GN on a path with no
# compiler under it. Asking vswhere for the x64 C++ component is the only question whose answer is
# necessarily a usable toolchain.
function Get-MsvcInstallationPath {
    if ($script:MsvcInstallationPath) { return $script:MsvcInstallationPath }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found at '$vswhere'. Install the Visual Studio Build Tools with the 'Desktop development with C++' workload."
    }
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $path) {
        throw "No Visual Studio installation carries the x64 MSVC tools (Microsoft.VisualStudio.Component.VC.Tools.x86.x64). Install the 'Desktop development with C++' workload."
    }
    $script:MsvcInstallationPath = $path.TrimEnd("\", "/")
    return $script:MsvcInstallationPath
}

if (-not $env:DEPOT_TOOLS_WIN_TOOLCHAIN) {
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
}
if ($env:DEPOT_TOOLS_WIN_TOOLCHAIN -eq "0") {
    if (-not $env:GYP_MSVS_VERSION) {
        $env:GYP_MSVS_VERSION = "17.0"
    }
    if (-not $env:GYP_MSVS_OVERRIDE_PATH) {
        $env:GYP_MSVS_OVERRIDE_PATH = Get-MsvcInstallationPath
    }
}

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Ensure-Tools {
    Require-Command git
    Require-Command python
    Require-Command ninja
    git config --global core.longpaths true
}

function Ensure-DepotTools {
    $depotDir = Join-Path $WorkDir "depot_tools"
    if (-not (Test-Path (Join-Path $depotDir ".git"))) {
        $null = git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $depotDir
    } else {
        $null = git -C $depotDir pull --ff-only
    }
    $env:PATH = "$depotDir;$env:PATH"
}

function Resolve-LlvmNm {
    if ($script:LlvmNmPath) {
        return $script:LlvmNmPath
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:LLVM_NM) {
        $candidates.Add($env:LLVM_NM)
    }
    # Prefer the clang that produced the archives: the Chromium toolchain that Skia and
    # ANGLE sync into their own checkouts. Falling back to a PATH llvm-nm is fine too - the
    # archive formats it has to read are stable - but a mismatched, much older llvm-nm can
    # choke on newer LLVM bitcode.
    if ($script:SkiaCheckoutDir) {
        $candidates.Add((Join-Path $script:SkiaCheckoutDir "third_party\externals\llvm-build\Release+Asserts\bin\llvm-nm.exe"))
        $candidates.Add((Join-Path $script:SkiaCheckoutDir "third_party\llvm-build\Release+Asserts\bin\llvm-nm.exe"))
        $candidates.Add((Join-Path $script:SkiaCheckoutDir "bin\llvm-nm.exe"))
    }
    $candidates.Add((Join-Path $WorkDir "ANGLE-$AngleBranch\third_party\llvm-build\Release+Asserts\bin\llvm-nm.exe"))
    $candidates.Add((Join-Path $WorkDir "depot_tools\llvm-build\Release+Asserts\bin\llvm-nm.exe"))

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $script:LlvmNmPath = (Resolve-Path $candidate).Path
            return $script:LlvmNmPath
        }
    }

    foreach ($name in @("llvm-nm.exe", "llvm-nm")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            $script:LlvmNmPath = $command.Source
            return $script:LlvmNmPath
        }
    }

    return $null
}

# dumpbin is the reason this stage cannot fail for want of a tool: building Skia on Windows
# REQUIRES the MSVC toolchain, so the symbol reader ships with the compiler that produced the
# archive. llvm-nm is preferred when present only because its output is the same on all three
# platforms; it is genuinely optional here. (An early run on a developer machine with MSVC and no
# LLVM failed the assertion step after a completely successful build - the archives were correct
# and unverified, which is the one outcome this whole mechanism exists to prevent.)
function Resolve-Dumpbin {
    if ($script:DumpbinPath) { return $script:DumpbinPath }
    $vcRoot = Get-MsvcInstallationPath
    $msvcDir = Join-Path $vcRoot "VC\Tools\MSVC"
    if (-not (Test-Path $msvcDir)) {
        throw "No MSVC tools under '$msvcDir'."
    }
    # Newest toolset, matching how Skia's own highest_version_dir.py picks one.
    $version = Get-ChildItem $msvcDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $dumpbin = Join-Path $version.FullName "bin\Hostx64\x64\dumpbin.exe"
    if (-not (Test-Path $dumpbin)) {
        throw "dumpbin.exe not found at '$dumpbin'."
    }
    $script:DumpbinPath = $dumpbin
    return $script:DumpbinPath
}

# Every name the tier contract cares about. One llvm-nm pass over a multi-hundred-MB archive
# is expensive, so the output is filtered down to these once and then queried in memory.
# SkCanvas/SkSurface/SkImage are not part of the contract; they are the reader's own proof of
# life, and they have to survive this filter for Assert-TierSymbols to be able to check it.
$script:TierSymbolPattern = 'GrVkGpu|GrVkCaps|GrVkBackendContext|AMDMemoryAllocator|GrGLGpu|GrGLInterface|vkCreateInstance|SkCanvas|SkSurface|SkImage'
$script:ReaderSanitySymbols = @("SkCanvas", "SkSurface", "SkImage")

function Get-TierSymbolLines($Library) {
    $llvmNm = Resolve-LlvmNm
    if ($llvmNm) {
        $lines = & $llvmNm $Library 2>$null | Select-String -Pattern $script:TierSymbolPattern | ForEach-Object { $_.Line }
        if ($LASTEXITCODE -ne 0) {
            throw "llvm-nm could not read $Library (exit code $LASTEXITCODE)."
        }
        return @($lines)
    }

    # dumpbin /SYMBOLS prints one record per symbol; the ones that matter look like
    #   008 00000000 SECT4  notype ()    External     | ?foo@GrVkGpu@@...
    # where "UNDEF" in the section column is dumpbin's spelling of nm's U. Normalising to
    # "<addr> <type> <name>" lets Test-DefinedSymbol/Test-MentionedSymbol stay one implementation
    # for both readers, which matters because those two are what encode the contract.
    $dumpbin = Resolve-Dumpbin
    $lines = & $dumpbin /SYMBOLS $Library 2>$null |
        Select-String -Pattern $script:TierSymbolPattern |
        ForEach-Object {
            $text = $_.Line
            $type = if ($text -match '\bUNDEF\b') { 'U' } else { 'T' }
            "0000000000000000 $type $text"
        }
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin could not read $Library (exit code $LASTEXITCODE)."
    }
    return @($lines)
}

function Test-DefinedSymbol($Lines, $Name) {
    foreach ($line in $Lines) {
        if ($line -notmatch [regex]::Escape($Name)) {
            continue
        }
        # llvm-nm prints "<address> <type> <name>" for a defined symbol and leaves the
        # address blank with type U for an undefined one. Only a defined symbol proves the
        # code is really compiled into the archive rather than merely referenced by it.
        if ($line -match '^\s*[0-9a-fA-F]+\s+([A-Za-z?])\s' -and $Matches[1] -cne 'U') {
            return $true
        }
    }
    return $false
}

function Test-MentionedSymbol($Lines, $Name) {
    foreach ($line in $Lines) {
        if ($line -match [regex]::Escape($Name)) {
            return $true
        }
    }
    return $false
}

function Assert-TierSymbols($Library) {
    # This is the whole reason the fork exists. Upstream shipped a package that advertised
    # Vulkan while SkiaSharp had only stubbed it out (gr_direct_context_make_vulkan returns
    # nullptr when skia_use_vulkan is false), so an app that asked for Vulkan rendered a
    # blank window with no crash, no log and no fallback. Presence alone is not enough:
    # a reduced tier that quietly contains a backend is just as wrong, because the consumer
    # guard and the published backend list would then be lying in the other direction.
    $lines = Get-TierSymbolLines $Library
    $failures = [System.Collections.Generic.List[string]]::new()

    # Every "is not defined" verdict below is only as good as the reader that produced it, and a
    # reader that cannot parse the archive reports every backend missing - which reads exactly
    # like a real build gap. That false verdict has already cost this repository a dropped RID on
    # musl, where the build log showed GrVkGpu.cpp and GrGLGpu.cpp compiling while this check
    # said they were absent. Windows has two readers (llvm-nm and the dumpbin fallback), so it has
    # two chances to be silently wrong; a build that went "unverified" through the fallback is the
    # exact outcome this function exists to prevent.
    # SkCanvas/SkSurface/SkImage are in every Skia build ever configured. Proving one of them is
    # *defined* - through the same Test-DefinedSymbol the contract uses, so the whole pipeline is
    # exercised and not merely "the tool emitted bytes" - is what makes the rest of this evidence.
    $readerProved = $null
    foreach ($probe in $script:ReaderSanitySymbols) {
        if (Test-DefinedSymbol $lines $probe) {
            $readerProved = $probe
            break
        }
    }
    if (-not $readerProved) {
        throw @"
Symbol reader cannot be trusted for $Library.
It returned $($lines.Count) line(s), but none of $($script:ReaderSanitySymbols -join ', ') came
back as a defined symbol. Every Skia build contains all of them, so this is a reader that cannot
parse this archive - not a verdict about which backends the archive holds.
Check which reader was selected (llvm-nm, else the dumpbin fallback) and that it can read a
static archive built by this toolchain.
"@
    }

    if ($Backends -contains "Vulkan") {
        # GrVkAMDMemoryAllocator/skgpu::VulkanAMDMemoryAllocator is not optional: Skia's
        # Vulkan backend without VMA fails exactly like a stubbed one, silently.
        foreach ($required in @("GrVkGpu", "AMDMemoryAllocator")) {
            if (-not (Test-DefinedSymbol $lines $required)) {
                $failures.Add("tier '$Tier' claims Vulkan but '$required' is not defined in $Library")
            }
        }
    } else {
        foreach ($forbidden in @("GrVkGpu", "GrVkCaps", "GrVkBackendContext", "AMDMemoryAllocator", "vkCreateInstance")) {
            if (Test-MentionedSymbol $lines $forbidden) {
                $failures.Add("tier '$Tier' must not contain Vulkan but '$forbidden' appears in $Library")
            }
        }
    }

    if ($Backends -contains "OpenGL") {
        foreach ($required in @("GrGLGpu", "GrGLInterface")) {
            if (-not (Test-DefinedSymbol $lines $required)) {
                $failures.Add("tier '$Tier' claims OpenGL but '$required' is not defined in $Library")
            }
        }
    } else {
        foreach ($forbidden in @("GrGLGpu", "GrGLInterface")) {
            if (Test-MentionedSymbol $lines $forbidden) {
                $failures.Add("tier '$Tier' must not contain OpenGL but '$forbidden' appears in $Library")
            }
        }
    }

    if ($failures.Count) {
        throw "Tier contract violated (tier '$Tier', backends $($Backends -join ', ')):`n  " + ($failures -join "`n  ")
    }

    Write-Host "Tier '$Tier' symbol contract verified in ${Library}: backends $($Backends -join ', ')."
}

function Assert-AngleSymbols($Library) {
    $lines = & (Resolve-LlvmNm) $Library 2>$null | Select-String -Pattern 'DrawArrays' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) {
        throw "llvm-nm could not read $Library (exit code $LASTEXITCODE)."
    }
    if (-not (Test-DefinedSymbol @($lines) "DrawArrays")) {
        throw "Tier contract violated (tier '$Tier'): 'glDrawArrays' is not defined in $Library, so the archive is not a usable GLES implementation."
    }
    Write-Host "ANGLE payload verified in $Library."
}

function Copy-FirstExisting($Destination, [string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if (Test-Path $candidate) {
            Copy-Item $candidate $Destination -Force
            Write-Host "Wrote $Destination"
            return
        }
    }
    throw "None of the expected files exist for ${Destination}: $($Candidates -join ', ')"
}

function Split-ParameterList($Parameters) {
    if ([string]::IsNullOrWhiteSpace($Parameters)) {
        return @()
    }

    $items = [System.Collections.Generic.List[string]]::new()
    $start = 0
    $depth = 0
    for ($i = 0; $i -lt $Parameters.Length; $i++) {
        $ch = $Parameters[$i]
        if ($ch -eq '[' -or $ch -eq '(' -or $ch -eq '<') {
            $depth++
        } elseif ($ch -eq ']' -or $ch -eq ')' -or $ch -eq '>') {
            if ($depth -gt 0) { $depth-- }
        } elseif ($ch -eq ',' -and $depth -eq 0) {
            $items.Add($Parameters.Substring($start, $i - $start).Trim())
            $start = $i + 1
        }
    }
    $items.Add($Parameters.Substring($start).Trim())
    return $items | Where-Object { $_ }
}

function Get-X86NativeParameterSize($Parameter) {
    $parameter = [regex]::Replace($Parameter, '/\*.*?\*/', '').Trim()
    $parameter = [regex]::Replace($parameter, '\[[^\]]+\]\s*', '').Trim()
    $parameter = [regex]::Replace($parameter, '\b(ref|out|in)\b\s*', '').Trim()
    if (-not $parameter) { return 0 }

    $parts = $parameter -split '\s+'
    if ($parts.Length -gt 1) {
        $type = ($parts[0..($parts.Length - 2)] -join ' ')
    } else {
        $type = $parts[0]
    }
    $type = $type.Trim()

    if ($script:X86GeneratedStructSizes -and $script:X86GeneratedStructSizes.ContainsKey($type)) {
        return $script:X86GeneratedStructSizes[$type]
    }

    if ($type.Contains('*') -or $type.EndsWith('[]') -or $type -eq 'String' -or $type -eq 'string' -or $type.EndsWith('Delegate')) {
        return 4
    }

    switch -Regex ($type) {
        '^(Int64|UInt64|long|ulong|Double|double)$' { return 8 }
        default { return 4 }
    }
}

function Align-X86Size($Size, $Alignment) {
    if ($Alignment -le 1) { return $Size }
    return [int]([Math]::Ceiling($Size / [double]$Alignment) * $Alignment)
}

function Get-X86ManagedTypeLayout($Type, $KnownSizes) {
    if ($Type.Contains('*') -or $Type.Contains('delegate*') -or $Type.EndsWith('[]') -or $Type.EndsWith('Delegate')) {
        return @{ Size = 4; Alignment = 4 }
    }

    switch -Regex ($Type) {
        '^(Byte|SByte|bool)$' { return @{ Size = 1; Alignment = 1 } }
        '^(Int16|UInt16|short|ushort|Char)$' { return @{ Size = 2; Alignment = 2 } }
        '^(Int64|UInt64|long|ulong|Double|double)$' { return @{ Size = 8; Alignment = 4 } }
        default {
            if ($KnownSizes.ContainsKey($Type)) {
                return @{ Size = $KnownSizes[$Type]; Alignment = 4 }
            }
            return @{ Size = 4; Alignment = 4 }
        }
    }
}

function Get-X86GeneratedStructSizes($BindingFiles) {
    $structFields = @{}

    foreach ($bindingFile in $BindingFiles) {
        $lines = Get-Content -Path $bindingFile
        $current = $null
        $depth = 0
        $includeStack = @($true)
        foreach ($line in $lines) {
            if ($line -match '^\s*#if\s+USE_LIBRARY_IMPORT\b') {
                $includeStack += $includeStack[-1]
                continue
            }
            if ($line -match '^\s*#else\b') {
                if ($includeStack.Count -gt 1) {
                    $parentActive = $includeStack[-2]
                    $includeStack[-1] = $parentActive -and (-not $includeStack[-1])
                }
                continue
            }
            if ($line -match '^\s*#endif\b') {
                if ($includeStack.Count -gt 1) {
                    $includeStack = @($includeStack[0..($includeStack.Count - 2)])
                }
                continue
            }
            if (-not $includeStack[-1]) {
                continue
            }

            if (-not $current -and $line -match '\bstruct\s+([A-Za-z0-9_]+)\b') {
                $current = $Matches[1]
                $structFields[$current] = [System.Collections.Generic.List[string]]::new()
                $depth = ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
                continue
            }

            if ($current) {
                if ($depth -eq 1 -and $line -match '^\s*public\s+(.+?)\s+[A-Za-z0-9_]+;\s*$') {
                    $fieldType = ([regex]::Replace($Matches[1].Trim(), '#if.*$', '')).Trim()
                    $structFields[$current].Add($fieldType)
                }

                $depth += ([regex]::Matches($line, '\{')).Count
                $depth -= ([regex]::Matches($line, '\}')).Count
                if ($depth -le 0) {
                    $current = $null
                }
            }
        }
    }

    $sizes = @{}
    $pending = @($structFields.Keys)
    while ($pending.Count -gt 0) {
        $next = @()
        $progress = $false
        foreach ($name in $pending) {
            $offset = 0
            $maxAlign = 1
            $resolved = $true
            foreach ($fieldType in $structFields[$name]) {
                if ($structFields.ContainsKey($fieldType) -and -not $sizes.ContainsKey($fieldType)) {
                    $resolved = $false
                    break
                }
                $layout = Get-X86ManagedTypeLayout $fieldType $sizes
                $maxAlign = [Math]::Max($maxAlign, [Math]::Min($layout.Alignment, 4))
                $offset = Align-X86Size $offset ([Math]::Min($layout.Alignment, 4))
                $offset += $layout.Size
            }
            if ($resolved) {
                $sizes[$name] = Align-X86Size $offset $maxAlign
                $progress = $true
            } else {
                $next += $name
            }
        }
        if (-not $progress) { break }
        $pending = $next
    }

    return $sizes
}

function Get-X86PInvokeThunks($BindingFiles, $DefinedSymbols) {
    $thunks = @{}
    $signaturePattern = 'internal static (?:extern|partial)\s+.+?\s+((?:sk|gr|hb)_[A-Za-z0-9_]+)\s*\((.*?)\);'
    $script:X86GeneratedStructSizes = Get-X86GeneratedStructSizes $BindingFiles

    foreach ($bindingFile in $BindingFiles) {
        if (-not (Test-Path $bindingFile)) {
            throw "Missing binding file for win-x86 thunk generation: $bindingFile"
        }

        $content = Get-Content -Raw -Path $bindingFile
        foreach ($match in [regex]::Matches($content, $signaturePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            $symbol = "_$($match.Groups[1].Value)"
            if (-not $DefinedSymbols.ContainsKey($symbol)) {
                continue
            }

            $bytes = 0
            foreach ($parameter in Split-ParameterList $match.Groups[2].Value) {
                $bytes += Get-X86NativeParameterSize $parameter
            }

            $decorated = "${symbol}@${bytes}"
            $thunks[$decorated] = [pscustomobject]@{
                Symbol = $symbol
                Bytes = $bytes
                Decorated = $decorated
            }
        }
    }

    return $thunks.Values | Sort-Object Symbol, Bytes
}

function New-WinX86SkiaStdcallThunks([string[]]$InputLibraries, [string[]]$BindingFiles, $Destination) {
    if ($TargetCpu -ne "x86") {
        return
    }

    $llvmNm = Resolve-LlvmNm
    Require-Command ml.exe
    Require-Command lib.exe

    $thunkDir = Join-Path $WorkDir "win-x86-skia-stdcall-thunks"
    New-Item -ItemType Directory -Path $thunkDir -Force | Out-Null
    $asmPath = Join-Path $thunkDir "skia_x86_stdcall_thunks.asm"
    $objPath = Join-Path $thunkDir "skia_x86_stdcall_thunks.obj"

    $definedSymbols = @{}
    foreach ($library in $InputLibraries) {
        & $llvmNm --defined-only $library |
            ForEach-Object {
                if ($_ -match '\sT\s(_(?:sk|gr|hb)_[A-Za-z0-9_]+)$') {
                    $definedSymbols[$Matches[1]] = $true
                }
            }
    }

    if (-not $definedSymbols.Count) {
        throw "No SkiaSharp/HarfBuzzSharp C API symbols found in $($InputLibraries -join ', ')"
    }

    $thunks = @(Get-X86PInvokeThunks $BindingFiles $definedSymbols)
    if (-not $thunks) {
        throw "No win-x86 stdcall thunks generated from $($BindingFiles -join ', ')"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("OPTION CASEMAP:NONE")
    $lines.Add(".386")
    $lines.Add(".model flat")
    foreach ($symbol in ($thunks | Select-Object -ExpandProperty Symbol -Unique)) {
        $lines.Add("EXTERN ${symbol}:PROC")
    }
    $lines.Add("_TEXT SEGMENT")
    foreach ($thunk in $thunks) {
        $lines.Add("PUBLIC $($thunk.Decorated)")
        $lines.Add("$($thunk.Decorated) PROC")
        for ($offset = 0; $offset -lt $thunk.Bytes; $offset += 4) {
            $lines.Add("    push DWORD PTR [esp+$($thunk.Bytes)]")
        }
        $lines.Add("    call $($thunk.Symbol)")
        if ($thunk.Bytes -gt 0) {
            $lines.Add("    add esp, $($thunk.Bytes)")
        }
        $lines.Add("    ret $($thunk.Bytes)")
        $lines.Add("$($thunk.Decorated) ENDP")
    }
    $lines.Add("_TEXT ENDS")
    $lines.Add("END")
    Set-Content -Path $asmPath -Value $lines -Encoding ASCII

    & ml.exe /nologo /c /coff /safeseh /Fo$objPath $asmPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to assemble win-x86 Skia stdcall thunks."
    }

    & lib.exe /nologo /out:$Destination $objPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to archive win-x86 Skia stdcall thunks."
    }
    Write-Host "Wrote $Destination"
}

function Sync-SkiaSharp {
    $src = Join-Path $WorkDir "SkiaSharp-$SkiaSharpVersion"
    if (-not (Test-Path (Join-Path $src ".git"))) {
        $null = git -c core.longpaths=true clone --depth 1 --branch "release/$SkiaSharpVersion" https://github.com/mono/SkiaSharp.git $src
    } else {
        $null = git -C $src fetch --depth 1 origin "release/$SkiaSharpVersion"
        $null = git -C $src checkout -q FETCH_HEAD
    }
    $null = git -C $src submodule update --init --depth 1 externals/skia
    return $src
}

function Patch-WinX86SkiaLinker($SkiaDir) {
    if ($TargetCpu -ne "x86") {
        return
    }

    $linkerPath = Join-Path $SkiaDir "src\c\sk_linker.cpp"
    $text = Get-Content -Path $linkerPath -Raw
    $pattern = '(?m)^    skjson::ObjectValue\* a = nullptr;\r?\n    auto r = \(\*a\)\["tmp"\]\.getType\(\);\r?$'
    $patched = [regex]::Replace($text, $pattern, '    int r = 0;')
    if ($patched -eq $text) {
        if ($text -match '(?m)^    int r = 0;\r?$') {
            return
        }
        throw "Unable to patch win-x86 sk_linker JSON keep-alive references."
    }
    Set-Content -Path $linkerPath -Value $patched -NoNewline -Encoding UTF8
}

function Prepare-SkiaGitSyncDeps($SkiaDir) {
    $syncDeps = Join-Path $SkiaDir "tools\git-sync-deps"
    $text = Get-Content -Path $syncDeps -Raw
    $depsPath = Join-Path $SkiaDir "DEPS"
    if (Test-Path $depsPath) {
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText = [regex]::Replace($depsText, '(?m)^\s*"third_party/externals/dng_sdk"\s*:\s*"[^"]+",\s*\r?\n', '')
        Set-Content -Path $depsPath -Value $depsText -NoNewline -Encoding UTF8
    }
    $old = "  multithread(git_checkout_to_directory, list_of_arg_lists)"
    $new = "  for args in list_of_arg_lists:`n    git_checkout_to_directory(*args)"
    if ($text.Contains($old)) {
        Set-Content -Path $syncDeps -Value $text.Replace($old, $new) -NoNewline -Encoding UTF8
    }
}

function Invoke-SkiaGitSyncDeps($SkiaDir) {
    Prepare-SkiaGitSyncDeps $SkiaDir

    for ($attempt = 1; $attempt -le $SkiaDepsRetries; $attempt++) {
        python (Join-Path $SkiaDir "tools\git-sync-deps")
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -eq $SkiaDepsRetries) {
            throw "git-sync-deps failed after $SkiaDepsRetries attempts"
        }
        Write-Warning "git-sync-deps failed; retrying ($attempt/$SkiaDepsRetries)..."
        Start-Sleep -Seconds 10
    }
}

function Build-Skia {
    Ensure-Tools
    Ensure-DepotTools
    $src = Sync-SkiaSharp
    $skiaDir = Join-Path $src "externals\skia"
    $script:SkiaCheckoutDir = $skiaDir
    Patch-WinX86SkiaLinker $skiaDir
    if (-not (Test-Path (Join-Path $skiaDir "bin\gn.exe"))) {
        Invoke-SkiaGitSyncDeps $skiaDir
    }

    # Ganesh stays ON for every tier, including Software, and skia_use_gl is what actually
    # distinguishes them.
    # This was skia_enable_ganesh = false for Software, which is the tidier expression of
    # "no GPU pipeline at all" and does not compile: SkiaSharp's C API is written assuming
    # Ganesh exists, and the Software build failed with
    #   src/c/gr_context.cpp:46: error: non-void function
    #   'gr_recording_context_get_direct_context' should return a value
    # because SK_ONLY_GPU collapses to nothing and leaves the function with no return. The
    # C API stubs absent BACKENDS but not an absent pipeline.
    # Turning GL off instead keeps the API compiling, still drops ANGLE - the bulk of the
    # size win - and still satisfies Assert-TierSymbols, because GrGLGpu and GrGLInterface
    # are compiled only when skia_use_gl is true. The Software tier therefore carries
    # Ganesh's raster path and no GPU backend, which is exactly what it promises.
    $skiaEnableGanesh = "true"
    $skiaUseGl = if ($Backends -contains "OpenGL") { "true" } else { "false" }
    # Skia vendors the Vulkan headers and gn/skia.gni derives skia_use_vma from
    # skia_use_vulkan, so no new dependency is needed here. Skia never links a Vulkan
    # library either - it resolves entry points through a caller-supplied proc-address
    # getter that Avalonia provides - which is why nothing below adds vulkan-1.
    $skiaUseVulkan = if ($Backends -contains "Vulkan") { "true" } else { "false" }

    # Per-tier build directory inside the shared checkout: switching tiers must not force a
    # full re-sync, and two tiers building concurrently must not fight over one ninja dir.
    $outDir = Join-Path $skiaDir "out\win-static-$Tier-$TargetCpu"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    # Pin the toolchain rather than let Skia guess. gn/find_msvc.py looks only for VS 2019/2017
    # under "Program Files (x86)", then falls back to `vswhere -prerelease -legacy -products *`
    # and takes the FIRST line — which is whatever product happens to sort first, not necessarily
    # a C++ compiler. On a clean CI image that is always Visual Studio, so upstream never sees it;
    # on a real workstation it picked "Microsoft SQL Server Management Studio 22\Release\VC" (SSMS
    # ships a VS shell) and the build died in highest_version_dir.py on a path with no
    # Tools\MSVC under it. Asking vswhere for the component we actually need cannot pick that up.
    $vcRoot = Get-MsvcInstallationPath
    $winVc = ($vcRoot.TrimEnd('\', '/') + '\VC').Replace('\', '/')
    Write-Host "Skia toolchain (win_vc): $winVc"
    @"
target_os = "win"
target_cpu = "$TargetCpu"
win_vc = "$winVc"
is_official_build = true
is_static_skiasharp = true
is_clang = true
skia_enable_tools = false
skia_enable_ganesh = $skiaEnableGanesh
skia_use_gl = $skiaUseGl
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = false
skia_use_freetype = false
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_sfntly = false
skia_use_system_expat = false
skia_use_system_freetype2 = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = $skiaUseVulkan
skia_use_xps = true
extra_cflags = [ "-DSKIA_C_DLL" ]
extra_cflags_cc = [ "/GR" ]
"@ | Set-Content -Path (Join-Path $outDir "args.gn") -Encoding ASCII

    Push-Location $skiaDir
    try {
        & (Join-Path $skiaDir "bin\gn.exe") gen $outDir
        ninja -C $outDir -j $BuildJobs skia SkiaSharp HarfBuzzSharp
    } finally {
        Pop-Location
    }

    $skiaLib = Join-Path $OutputDir "skia.lib"
    $skiaSharpLib = Join-Path $OutputDir "SkiaSharp.lib"
    $harfbuzzLib = Join-Path $OutputDir "libHarfBuzzSharp.lib"
    Copy-FirstExisting $skiaLib @((Join-Path $outDir "skia.lib"), (Join-Path $outDir "obj\skia.lib"))
    Copy-FirstExisting $skiaSharpLib @((Join-Path $outDir "SkiaSharp.lib"), (Join-Path $outDir "obj\SkiaSharp.lib"))
    Copy-FirstExisting $harfbuzzLib @(
        (Join-Path $outDir "libHarfBuzzSharp.lib"),
        (Join-Path $outDir "HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\HarfBuzzSharp.lib")
    )
    New-WinX86SkiaStdcallThunks `
        -InputLibraries @($skiaLib, $skiaSharpLib, $harfbuzzLib) `
        -BindingFiles @((Join-Path $src "binding\SkiaSharp\SkiaApi.generated.cs"), (Join-Path $src "binding\HarfBuzzSharp\HarfBuzzApi.generated.cs")) `
        -Destination (Join-Path $OutputDir "skia_x86_stdcall_thunks.lib")

    Assert-TierSymbols $skiaLib
}

function Sync-Angle {
    $src = Join-Path $WorkDir "ANGLE-$AngleBranch"
    if (-not (Test-Path (Join-Path $src ".git"))) {
        $null = git -c core.longpaths=true clone --depth 1 --branch "chromium/$AngleBranch" https://github.com/google/angle.git $src
    } else {
        $null = git -C $src fetch --depth 1 origin "chromium/$AngleBranch"
        $null = git -C $src checkout -q FETCH_HEAD
    }
    return $src
}

function Apply-AnglePatches($Src) {
    $buildFile = Join-Path $Src "BUILD.gn"
    $buildText = Get-Content -Path $buildFile -Raw
    if (-not $buildText.Contains('angle_static_library("libANGLE_static")')) {
        $libAngleTargets = @'
angle_static_library("libANGLE_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE" ]
}

angle_static_library("libANGLE_with_capture_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE_with_capture" ]
}

angle_static_library("libGLESv2_static") {
'@
        $buildText = [regex]::Replace($buildText, '(?m)^angle_static_library\("libGLESv2_static"\) \{', $libAngleTargets)
        $buildText = [regex]::Replace($buildText, '(?m)^angle_static_library\("libGLESv2_static"\) \{\r?\n  sources = libglesv2_sources', "angle_static_library(`"libGLESv2_static`") {`n  complete_static_lib = true`n  sources = libglesv2_sources")
        Set-Content -Path $buildFile -Value $buildText -NoNewline -Encoding UTF8
    }

    $patch = Join-Path $AnglePatchDir "angle-chromium-$AngleBranch.patch"
    $depsFile = Join-Path $Src "DEPS"
    if ((Test-Path $patch) -and (Select-String -Path $depsFile -Pattern "'third_party/catapult'" -Quiet)) {
        $null = git -C $Src apply $patch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to apply ANGLE patch: $patch"
        }
    }
}

function Assert-AngleVisualStudioVersion {
    if ($env:VisualStudioVersion -and -not ($env:VisualStudioVersion -in @("17.0", "16.0", "15.0"))) {
        throw "ANGLE $AngleBranch requires Visual Studio 2022/2019/2017, but VisualStudioVersion is $env:VisualStudioVersion. Use windows-2022 or a VS 2022 developer prompt."
    }
    if ($env:GYP_MSVS_OVERRIDE_PATH -and ($env:GYP_MSVS_OVERRIDE_PATH -match '\\Microsoft Visual Studio\\18\\')) {
        throw "ANGLE $AngleBranch requires Visual Studio 2022/2019/2017, but GYP_MSVS_OVERRIDE_PATH points to $env:GYP_MSVS_OVERRIDE_PATH. Use windows-2022 or a VS 2022 developer prompt."
    }
}

# ANGLE is Skia's GL implementation on Windows and is byte-for-byte the same for every tier
# that claims GL, so it is not part of the per-tier matrix - only of the per-tier payload.
function Test-TierNeedsAngle {
    if ($Backends -contains "OpenGL") {
        return $true
    }
    Write-Host "Tier '$Tier' does not claim OpenGL; skipping ANGLE."
    return $false
}

function Test-AnglePatch {
    if (-not (Test-TierNeedsAngle)) {
        return
    }
    Require-Command git
    Assert-AngleVisualStudioVersion

    $src = Sync-Angle
    Apply-AnglePatches $src
    if (-not (Select-String -Path (Join-Path $src "BUILD.gn") -Pattern 'angle_static_library\("libANGLE_static"\)' -Quiet)) {
        throw "ANGLE BUILD.gn preflight failed."
    }
    Write-Host "ANGLE preflight passed."
}

function Build-Angle {
    if (-not (Test-TierNeedsAngle)) {
        return
    }
    Ensure-Tools
    Assert-AngleVisualStudioVersion
    Ensure-DepotTools
    $src = Sync-Angle
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Apply-AnglePatches $src
    Push-Location $src
    try {
        python scripts/bootstrap.py
        gclient sync -f -D -R
        $outDir = Join-Path $src "out\win-static-$TargetCpu"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        @"
target_os = "win"
target_cpu = "$TargetCpu"
is_debug = false
is_component_build = false
is_clang = true
use_lld = false
use_custom_libcxx = false
use_thin_lto = false
symbol_level = 0
angle_build_tests = false
build_angle_deqp_tests = false
angle_enable_swiftshader = false
angle_enable_vulkan = false
angle_enable_wgpu = false
"@ | Set-Content -Path (Join-Path $outDir "args.gn") -Encoding ASCII
        gn gen $outDir
        ninja -C $outDir -j $BuildJobs libANGLE_static libGLESv2_static
        Copy-FirstExisting (Join-Path $OutputDir "libANGLE_static.lib") @((Join-Path $outDir "libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static\libANGLE_static.lib"))
        Copy-FirstExisting (Join-Path $OutputDir "libGLESv2_static.lib") @((Join-Path $outDir "libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static\libGLESv2_static.lib"))
        Assert-AngleSymbols (Join-Path $OutputDir "libGLESv2_static.lib")
        foreach ($libcxxName in @("libc++.lib", "libc++abi.lib")) {
            $libcxxPath = Join-Path $src "third_party\llvm-build\Release+Asserts\lib\$libcxxName"
            if (Test-Path $libcxxPath) {
                Copy-Item $libcxxPath (Join-Path $OutputDir $libcxxName) -Force
                Write-Host "Wrote $(Join-Path $OutputDir $libcxxName)"
            }
        }
    } finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Write-Host "Building tier '$Tier' (backends $($Backends -join ', ')) for $Rid into $OutputDir"
switch ($Target) {
    "skia" { Build-Skia }
    "angle-preflight" { Test-AnglePatch }
    "angle" { Build-Angle }
    "all" { Build-Skia; Build-Angle }
}
