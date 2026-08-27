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

# $ErrorActionPreference = "Stop" does NOT cover native commands: PowerShell 7 leaves
# $PSNativeCommandUseErrorActionPreference at $false, so gn, ninja, git, gclient and python can
# exit non-zero and this script sails straight past it. That is not academic here. $WorkDir is
# restored from actions/cache with version-agnostic restore-keys, and every gn/ninja output tree
# lives inside it, so a failed build falls through to Copy-FirstExisting - which asks only whether
# a file EXISTS, never whether THIS run wrote it - and hands the previous run's archives to the
# tier assertion. The assertion then verifies the wrong file truthfully and prints "contract
# verified"; worse, running the symbol reader resets $LASTEXITCODE to 0, so even GitHub's
# `exit $LASTEXITCODE` epilogue reports the step green. build-linux-static-graphics.sh and
# build-macos-static-graphics.sh get this for free from `set -euo pipefail`; on Windows it has to
# be said out loud after every native command whose failure would leave a stale artifact reachable.
function Assert-LastExitCode($What) {
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
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
        Assert-LastExitCode "git clone depot_tools into $depotDir"
    } else {
        # A half-cloned or un-updatable depot_tools is not a warning: gclient and ninja are taken
        # from it below, so continuing here means building with whatever the cache happened to hold.
        $null = git -C $depotDir pull --ff-only
        Assert-LastExitCode "git pull --ff-only in $depotDir"
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

# Everything above is about Skia's own backend implementation - GrVkGpu, GrGLGpu - which is
# necessary and not sufficient. The defect this fork exists for lives one layer up, in SkiaSharp's
# C API, and none of the checks above can see it: gr_direct_context_make_vulkan keeps its symbol
# and returns nullptr when the backend was not compiled into that translation unit (SK_ONLY_VULKAN
# in src/c/sk_types_priv.h collapses to SK_SKIP_ARG), so "the entry point is defined" is precisely
# the evidence a stub produces too. Avalonia then creates a Vulkan device, hands it to Skia, gets
# nothing back, and the window opens, stays responsive, logs nothing and never paints. That
# returns-null stub is the defect this repository was created to refuse, and until this function
# existed nothing on Windows read it - not this script, not verify-tier-payload, not the smoke,
# which strips Vulkan on win-arm64 because there is no arm64 lavapipe to render with.
#
# What tells a wired entry point from a stub is what its own object file references:
#     return SK_ONLY_VULKAN(ToGrDirectContext(GrDirectContexts::MakeVulkan(ctx).release()), nullptr);
# with ctx from AsGrVkBackendContext(&vkBackendContext) leaves mangled references carrying
# MakeVulkan and GrVkBackendContext; SK_SKIP_ARG collapses that same body to `return nullptr`, and
# then the object references neither.
#
# Measured on this repo's own Windows payload rather than assumed. dumpbin /SYMBOLS over
# External/NativeStatic/static-Vulkan/win-x64/native/skia.lib prints 1086 per-member symbol tables,
# and in exactly one of them - the src/c gr_context object - gr_direct_context_make_vulkan,
# gr_direct_context_make_gl and gr_direct_context_make_metal are all three defined External. That
# same member references MakeVulkan x2, GrVkBackendContext x5, MakeGL x4, GrGLInterface x9 - and
# MakeMetal x0, GrMtlBackendContext x0. One archive, one object file, opposite verdicts: GL and
# Vulkan wired, Metal a stub because Metal is not built on Windows.
#
# Because the discriminator is per object file, this needs per-member symbol output, and neither
# Assert-TierSymbols above nor the payload byte scan in .github/actions/verify-tier-payload can
# stand in for it: GrDirectContext::MakeVulkan and GrVkBackendContext are in skia.lib whether or
# not gr_context.cpp ever calls them, so an archive-wide search answers a different question and
# answers it wrongly - green, on a package that paints nothing.
#
# Both payload archives are read. src/c compiles into the skia target today - that member is inside
# skia.lib, and SkiaSharp.lib carries only src/xamarin - but that is SkiaSharp's layout, not a
# contract we control. Searching both means a version that relocates the C API comes out as a loud
# "cannot certify" here instead of an archive that ships with nobody having looked inside it.
#
# This is the Windows port of assert_c_api_entry_points in build-linux-static-graphics.sh. The two
# must stay in step; the table below is the same contract, spelled for PowerShell.
#
#   Backend: the entry point the managed side P/Invokes; the names its real body must reference
$script:CApiContract = @(
    [pscustomobject]@{ Backend = "Vulkan"; Entry = "gr_direct_context_make_vulkan"; Tokens = @("MakeVulkan", "GrVkBackendContext") }
    [pscustomobject]@{ Backend = "OpenGL"; Entry = "gr_direct_context_make_gl";     Tokens = @("MakeGL", "GrGLInterface") }
)

# Per-member symbol facts for one archive, from whichever of this script's two readers is present.
# Returns the contract-relevant symbols only, each tagged with the member it came from and whether
# it is a definition or a mere reference, plus what the caller needs to decide whether the reader
# was able to answer at all.
#
# llvm-nm -A prefixes every symbol line with the archive and the member: "<archive>:<member>: <addr>
# <type> <name>" (GNU nm glues the address straight onto the prefix, Apple's spells it
# "<archive>(<member>):"). The bash siblings recover the member by whitespace-splitting column 1 and
# dropping its last colon-separated field. That is exactly wrong here: a Windows archive path
# carries a colon after the drive letter, and if it also carries a space - "C:\Program Files\...",
# or any checkout under a user name with a space in it - column 1 is a fragment of the path,
# identical for every member. Every symbol then collapses onto one key, the discriminator becomes
# "is this name somewhere in the archive", and the check silently turns back into the archive-wide
# search it exists to replace. So the line is matched whole with a greedy prefix instead: the path
# may contain colons and spaces, the mangled symbol name may not.
#
# dumpbin has no per-member switch at all, but /SYMBOLS over a .lib emits one "COFF SYMBOL TABLE"
# block per member, in archive order, so the block ordinal IS the attribution (measured: 1086
# blocks for skia.lib, whose 1089 members include three the librarian adds that carry no symbol
# table). It cannot name the member, so a failure names the block - which is enough to tell a wired
# entry point from a stub, the only question asked here. A dumpbin that emitted no block header has
# attributed nothing, and the caller refuses to answer rather than guess.
function Get-CApiMemberFacts($Library, [string[]]$Entries, [string[]]$Tokens) {
    $relevant = ((@($Entries) + @($Tokens)) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $records = [System.Collections.Generic.List[psobject]]::new()
    $unattributed = [System.Collections.Generic.List[string]]::new()

    $llvmNm = Resolve-LlvmNm
    if ($llvmNm) {
        # Filtered as it streams. These archives run to hundreds of megabytes and millions of
        # symbols; the bash version's answer to that is a full nm -A dump to $TMPDIR, which buys a
        # disk-exhaustion failure mode for nothing. Select-String keeps only the contract's names.
        $lines = & $llvmNm -A $Library 2>$null |
            Select-String -CaseSensitive -Pattern $relevant |
            ForEach-Object { $_.Line }
        if ($LASTEXITCODE -ne 0) {
            throw @"
Symbol reader could not list $Library per member (llvm-nm -A, exit code $LASTEXITCODE).
Without per-member output a wired entry point and a stub are indistinguishable, so this is a
reader failure and not a verdict about the archive. Reader was: $llvmNm
"@
        }

        $shape = [regex]::new('^(?<key>.+):[ \t]*(?<addr>[0-9a-fA-F]*)[ \t]+(?<type>[A-Za-z?])[ \t]+(?<name>\S+)\s*$')
        $archive = ($Library -replace '/', '\')
        foreach ($line in @($lines)) {
            $matched = $shape.Match($line)
            if (-not $matched.Success) {
                $unattributed.Add($line)
                continue
            }
            $key = $matched.Groups['key'].Value
            # A key that is just the archive means the reader ignored -A. There is then no member
            # to attribute the symbol to, and it has to be reported as "could not check". The bash
            # test for this - "column 1 holds no colon" - cannot be reused: on Windows the drive
            # letter supplies one.
            if (($key -replace '/', '\') -ieq $archive) {
                $unattributed.Add($line)
                continue
            }
            $type = $matched.Groups['type'].Value
            $records.Add([pscustomobject]@{
                Member  = $key
                Name    = $matched.Groups['name'].Value
                # U/u are undefined and w/v weak-undefined: a reference, not a definition.
                # SkiaSharp's SkiaKeeper references every C entry point to keep it linked in, so
                # accepting a reference as a definition would certify the very stub this catches.
                Defined = @('U', 'u', 'w', 'v') -cnotcontains $type
            })
        }
        return @{ Reader = "llvm-nm -A ($llvmNm)"; Records = $records; Members = $null; Unattributed = $unattributed }
    }

    $dumpbin = Resolve-Dumpbin
    $lines = & $dumpbin /SYMBOLS $Library 2>$null |
        Select-String -CaseSensitive -Pattern "^COFF SYMBOL TABLE|$relevant" |
        ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) {
        throw @"
Symbol reader could not list $Library per member (dumpbin /SYMBOLS, exit code $LASTEXITCODE).
Without per-member output a wired entry point and a stub are indistinguishable, so this is a
reader failure and not a verdict about the archive. Reader was: $dumpbin
"@
    }

    # "0D7 00000000 SECT43 notype ()    External     | gr_direct_context_make_vulkan", and the same
    # shape with UNDEF in the section column for a reference. The name is the first field after the
    # bar; dumpbin appends the demangled signature after it, which is deliberately ignored - a
    # token has to be in the symbol itself, not in prose about it.
    $shape = [regex]::new('^\s*[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(?<sect>\S+)\s.*?\|\s*(?<name>\S+)')
    $member = 0
    foreach ($line in @($lines)) {
        if ($line -cmatch '^COFF SYMBOL TABLE') {
            $member++
            continue
        }
        $matched = $shape.Match($line)
        if ((-not $matched.Success) -or $member -eq 0) {
            $unattributed.Add($line)
            continue
        }
        $records.Add([pscustomobject]@{
            Member  = "${Library}(member #$member)"
            Name    = $matched.Groups['name'].Value
            Defined = $matched.Groups['sect'].Value -cne 'UNDEF'
        })
    }
    return @{ Reader = "dumpbin /SYMBOLS ($dumpbin)"; Records = $records; Members = $member; Unattributed = $unattributed }
}

function Assert-CApiEntryPoints([string[]]$Libraries) {
    $applicable = @($script:CApiContract | Where-Object { $Backends -contains $_.Backend })
    if (-not $applicable) {
        # Short-circuited before the readers run, and said out loud: "nothing to certify" and
        # "certified" are different claims and the log has to be able to tell them apart.
        Write-Host "Tier '$Tier' claims no GPU backend, so it has no C entry point to certify."
        return
    }

    $entries = @($applicable | ForEach-Object { $_.Entry })
    $tokens = @($applicable | ForEach-Object { $_.Tokens } | Select-Object -Unique)

    $records = [System.Collections.Generic.List[psobject]]::new()
    $readers = [System.Collections.Generic.List[string]]::new()
    $unattributed = [System.Collections.Generic.List[string]]::new()
    $memberCensus = $null
    foreach ($library in $Libraries) {
        $facts = Get-CApiMemberFacts $library $entries $tokens
        $readers.Add("$library read by $($facts.Reader)")
        foreach ($record in $facts.Records) { $records.Add($record) }
        foreach ($line in $facts.Unattributed) { $unattributed.Add($line) }
        if ($null -ne $facts.Members) { $memberCensus += $facts.Members }
    }

    $context = "Archives read:`n  " + ($readers -join "`n  ")
    if ($unattributed.Count) {
        $context += "`n$($unattributed.Count) contract-relevant line(s) could not be attributed to a member, e.g.:`n  $($unattributed[0])"
    }

    # Which member defines each entry point. Every defining member is kept, not just the first, so
    # a second copy of the entry point cannot hide behind a good one. Exact names only: the same
    # member also holds $unwind$gr_direct_context_make_vulkan and $pdata$gr_direct_context_make_vulkan,
    # both defined and both Static, which a substring test would accept as the definition.
    $definers = @{}
    foreach ($spec in $applicable) {
        $found = @($records |
            Where-Object { $_.Defined -and ($_.Name -ceq $spec.Entry -or $_.Name -ceq "_$($spec.Entry)") } |
            ForEach-Object { $_.Member } |
            Select-Object -Unique)
        if (-not $found) {
            throw @"
Cannot certify the $($spec.Backend) backend of tier '$Tier': nothing in the payload came back as
a definition of $($spec.Entry), the entry point the managed side P/Invokes. Either no archive
defines it, or the reader could not say which member a symbol came from and there is nothing to
attribute it to. Either way this is 'could not check' and not 'checked and fine', and must not be
reported as the latter.
$context
If a SkiaSharp version moved src/c into another target, add that archive here - do not drop the
check.
"@
        }
        $definers[$spec.Entry] = $found
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $verified = [System.Collections.Generic.List[string]]::new()
    foreach ($spec in $applicable) {
        $wanted = ($spec.Tokens | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $wired = $true
        foreach ($member in $definers[$spec.Entry]) {
            $mentions = @($records | Where-Object { $_.Member -ceq $member -and $_.Name -cmatch $wanted })
            if (-not $mentions) {
                $failures.Add("tier '$Tier' claims $($spec.Backend) but $($spec.Entry) is a stub - its object ($member) references none of $($spec.Tokens -join ', ')")
                $wired = $false
            }
        }
        if ($wired) { $verified.Add($spec.Entry) }
    }

    if ($failures.Count) {
        throw @"
C API entry points contradict tier '$Tier' (backends $($Backends -join ', ')):
  $($failures -join "`n  ")
A stub keeps its symbol and returns nullptr, which is exactly how a package comes to advertise a
backend and paint nothing. Get the backend's macro into SkiaSharp's C compile, or stop claiming
the backend - do not relax this.
$context
"@
    }

    # The one way this check could fail OPEN rather than closed, hence this guard - and it is
    # deliberately the LAST thing asked, after the verdict above. The discriminator is "the entry
    # point and the names its real body references share an object file, and a stub's object holds
    # neither". Collapse the archive to one member - complete_static_lib, a full-LTO merged object,
    # a lib.exe repack over a single .obj - and the first half is true by construction:
    # GrDirectContext::MakeVulkan is defined in the archive either way, so it lands in the one
    # member beside the stub and every tier certifies itself. Alone among the failure modes here,
    # that one would print the success line. Today's GN config is nowhere near it (skia.lib: 1086
    # members), which is exactly why a change would go unnoticed.
    # Asking it EARLIER is wrong, and not theoretically: run this function over the real win-x64
    # payload with a Metal row in the contract and the answer is one attributed member - because
    # MakeMetal and GrMtlBackendContext are genuinely nowhere in skia.lib, which is what being
    # stubbed means. A caught stub concentrates the contract's names in one member exactly as a
    # merged archive does, so this question can only be asked once the verdict is "wired"; before
    # that it reports a real catch as a reader failure.
    $attributed = @($records | ForEach-Object { $_.Member } | Select-Object -Unique)
    if ($attributed.Count -le 1 -or ($null -ne $memberCensus -and $memberCensus -le 1)) {
        throw @"
Cannot certify tier '$Tier': every C API symbol the contract names came back attributed to one
archive member, so "the entry point and the names its body references share an object file" holds
by construction and this check has degraded into the archive-wide search it replaces.
That is what a single-member archive looks like (complete_static_lib, a full-LTO merged object, a
lib.exe repack) and equally what a reader that is not attributing symbols to members looks like.
Both are 'could not check', not 'checked and fine' - and this one would otherwise have printed
'wired, not stubbed'.
$context
"@
    }

    # Deliberately a separate line from Assert-TierSymbols' verdict: "the backend's code is in the
    # archive" and "the entry point a consumer calls reaches that code" are different claims, and a
    # log that blurs them is how the stub shipped in the first place.
    Write-Host "C API entry points wired, not stubbed, for tier '$Tier': $($verified -join ', ')."
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

# libGLESv2_static holds the GLES entry points; libANGLE_static is the complete_static_lib over
# :libANGLE that Apply-AnglePatches adds - the implementation behind them - and until this existed
# nothing anywhere read a single byte of it. verify-tier-payload and verify-tier-package both stop
# at "a file with that name is present", the collect step in static-graphics-windows.yml checks the
# filename too, and the consumer targets link it under an Exists() condition. Not even a green GL
# smoke covers it: Apply-AnglePatches gives libGLESv2_static complete_static_lib as well, so that
# archive is self-contained and an app links and renders exactly the same with an empty
# libANGLE_static.lib beside it. Presence was the entire gate on half the ANGLE payload.
# This deliberately does not name ANGLE-internal classes: their spelling is upstream's to change,
# and a probe list that rots turns into the "reader says everything is missing" false verdict that
# already cost this repository a dropped RID. What holds for any complete_static_lib whatever the
# branch is that it contains compiled objects - and a static library with public_deps and no
# sources, which is what libANGLE_static degrades to the moment complete_static_lib stops taking
# effect, contains none. Call this after Assert-AngleSymbols: that one has just proven the same
# reader can parse an archive from this build, which is what makes silence here a verdict about
# the file rather than about the tool.
function Assert-AngleImplementationArchive($Library) {
    $llvmNm = Resolve-LlvmNm
    if (-not $llvmNm) {
        throw "No llvm-nm was found, so nothing has inspected $Library. Set LLVM_NM or install LLVM - an unread archive is not a verified one."
    }

    # Counted as it streams rather than collected: this is a complete static library and its
    # symbol table runs to hundreds of thousands of names.
    $emitted = 0
    $defined = 0
    & $llvmNm --defined-only $Library 2>$null | ForEach-Object {
        $emitted++
        # The same "<address> <type> <name>" shape Test-DefinedSymbol keys on.
        if ($_ -match '^\s*[0-9a-fA-F]+\s+[A-Za-z?]\s') { $defined++ }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "llvm-nm could not read $Library (exit code $LASTEXITCODE)."
    }
    if ($emitted -eq 0) {
        throw @"
$Library contains no objects: llvm-nm --defined-only printed nothing at all for it.
That is exactly what libANGLE_static looks like when complete_static_lib stops taking effect -
a static library with public_deps and no sources - so check that Apply-AnglePatches still
matched the current BUILD.gn.
"@
    }
    if ($defined -eq 0) {
        throw @"
Cannot verify $Library. llvm-nm --defined-only printed $emitted line(s) for it, none in the
'<address> <type> <name>' form this script parses. Either the archive holds no compiled code or
this reader's output cannot be read here; neither is a pass, and nothing has checked this archive.
"@
    }
    Write-Host "ANGLE implementation archive verified in ${Library}: $defined defined symbol(s)."
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
        Assert-LastExitCode "git clone SkiaSharp release/$SkiaSharpVersion"
    } else {
        $null = git -C $src fetch --depth 1 origin "release/$SkiaSharpVersion"
        Assert-LastExitCode "git fetch release/$SkiaSharpVersion in $src"
        $null = git -C $src checkout -q FETCH_HEAD
        Assert-LastExitCode "git checkout FETCH_HEAD in $src"
    }
    # This is the line most likely to fail on a warm cache, and it used to fail invisibly. The
    # cached externals/skia is dirty by construction - patch-skia-gl-stubs.py,
    # Prepare-SkiaGitSyncDeps and, on x86, Patch-WinX86SkiaLinker all rewrite tracked files inside
    # it, and actions/cache saves that tree - so as soon as the submodule pin moves onto a file one
    # of them touched, git refuses with "your local changes would be overwritten" and leaves the OLD
    # revision checked out. `$null =` discards only stdout; the exit code went nowhere either, since
    # $ErrorActionPreference does not cover git. The result was a rebuild issued to pick up an
    # upstream fix that silently did not contain it, published under a bumped BuildRev while every
    # downstream check verified the wrong revision perfectly truthfully.
    $null = git -C $src submodule update --init --depth 1 externals/skia
    Assert-LastExitCode "git submodule update externals/skia in $src"
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

    # SkiaSharp's C API has no SK_ONLY_GL, so skia_use_gl=false does not stub the GL entry
    # points and they fail to compile against declarations that are gone. This adds the
    # missing macro. It runs for every tier because it is a no-op wherever SK_GL is defined,
    # and the tiers share this checkout. See the header of the script for the full story.
    python (Join-Path $PSScriptRoot "patch-skia-gl-stubs.py") $skiaDir
    if ($LASTEXITCODE -ne 0) {
        throw "patch-skia-gl-stubs.py failed for $skiaDir."
    }

    # Ganesh stays ON for every tier, and skia_use_gl is what separates them.
    # The tidier expression of "no GPU pipeline at all" would be skia_enable_ganesh = false,
    # and it does not compile: SK_ONLY_GPU collapses to nothing, so the single-argument use
    # at src/c/gr_context.cpp:46 leaves 'gr_recording_context_get_direct_context' with no
    # return. It would also strip SkSurfaces::WrapBackendRenderTarget and
    # SkImages::BorrowTextureFrom out from under src/c/sk_surface.cpp and src/c/sk_image.cpp,
    # which use them with no guard at all - and that break surfaces at the CONSUMER's link,
    # not here, which is the worst place to find it.
    # Keeping Ganesh and dropping GL leaves only the raster path, drops ANGLE - much the
    # larger part of the size win - and satisfies Assert-TierSymbols, because GrGLGpu and
    # GrGLInterface are compiled only when skia_use_gl is true. The Software tier therefore
    # carries Ganesh's raster path and no GPU backend, which is exactly what it promises.
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

    # Every place Copy-FirstExisting will look, named once so the same list can be emptied first.
    # $outDir is inside $WorkDir, which CI restores from actions/cache, so the previous run's
    # archives are already lying in exactly these paths - and Copy-FirstExisting only asks whether
    # a path exists, never whether this run wrote it. Clearing them is what turns "ninja exited 0"
    # into "these files are ninja's output": otherwise an upstream rename of a ninja output leaves
    # the stale file at the old path and Assert-TierSymbols certifies the previous build's tier
    # contract against the new args.gn. Costs one re-archive on a warm cache; worth it.
    $skiaCandidates = @((Join-Path $outDir "skia.lib"), (Join-Path $outDir "obj\skia.lib"))
    $skiaSharpCandidates = @((Join-Path $outDir "SkiaSharp.lib"), (Join-Path $outDir "obj\SkiaSharp.lib"))
    $harfbuzzCandidates = @(
        (Join-Path $outDir "libHarfBuzzSharp.lib"),
        (Join-Path $outDir "HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\HarfBuzzSharp.lib")
    )
    foreach ($candidate in ($skiaCandidates + $skiaSharpCandidates + $harfbuzzCandidates)) {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    }

    Push-Location $skiaDir
    try {
        & (Join-Path $skiaDir "bin\gn.exe") gen $outDir
        Assert-LastExitCode "gn gen $outDir"
        ninja -C $outDir -j $BuildJobs skia SkiaSharp HarfBuzzSharp
        Assert-LastExitCode "ninja skia SkiaSharp HarfBuzzSharp in $outDir"
    } finally {
        Pop-Location
    }

    $skiaLib = Join-Path $OutputDir "skia.lib"
    $skiaSharpLib = Join-Path $OutputDir "SkiaSharp.lib"
    $harfbuzzLib = Join-Path $OutputDir "libHarfBuzzSharp.lib"
    Copy-FirstExisting $skiaLib $skiaCandidates
    Copy-FirstExisting $skiaSharpLib $skiaSharpCandidates
    Copy-FirstExisting $harfbuzzLib $harfbuzzCandidates
    New-WinX86SkiaStdcallThunks `
        -InputLibraries @($skiaLib, $skiaSharpLib, $harfbuzzLib) `
        -BindingFiles @((Join-Path $src "binding\SkiaSharp\SkiaApi.generated.cs"), (Join-Path $src "binding\HarfBuzzSharp\HarfBuzzApi.generated.cs")) `
        -Destination (Join-Path $OutputDir "skia_x86_stdcall_thunks.lib")

    Assert-TierSymbols $skiaLib
    # Both shipped archives, and immediately after the copies above - the same place and the same
    # order as build_skia's last two statements in build-linux-static-graphics.sh. Assert-TierSymbols
    # has just proven the backend's own code is in skia.lib; this proves the entry point a consumer
    # actually calls reaches that code instead of returning nullptr.
    Assert-CApiEntryPoints @($skiaLib, $skiaSharpLib)
}

function Sync-Angle {
    $src = Join-Path $WorkDir "ANGLE-$AngleBranch"
    if (-not (Test-Path (Join-Path $src ".git"))) {
        $null = git -c core.longpaths=true clone --depth 1 --branch "chromium/$AngleBranch" https://github.com/google/angle.git $src
        Assert-LastExitCode "git clone ANGLE chromium/$AngleBranch"
    } else {
        # Same dirty-cache trap as Sync-SkiaSharp, and here the rewritten files are in this repo
        # itself: Apply-AnglePatches edits BUILD.gn and the branch patch edits DEPS, in a tree
        # actions/cache then saves. If chromium/$AngleBranch has moved onto either of them, this
        # checkout exits non-zero and leaves the old revision in place. Failing is the point - the
        # alternative is building a revision nobody asked for and shipping it as $AngleBranch.
        $null = git -C $src fetch --depth 1 origin "chromium/$AngleBranch"
        Assert-LastExitCode "git fetch chromium/$AngleBranch in $src"
        $null = git -C $src checkout -q FETCH_HEAD
        Assert-LastExitCode "git checkout FETCH_HEAD in $src"
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
        Assert-LastExitCode "python scripts/bootstrap.py in $src"
        # The ANGLE DEPS churn this repo already patches around makes this the likeliest step to
        # fail, and it is the step whose failure is least visible: the checkout it leaves behind is
        # the previous run's, restored from cache, and everything after it happily builds that.
        gclient sync -f -D -R
        Assert-LastExitCode "gclient sync in $src"
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
        # Same reason as Build-Skia: $outDir lives in the cached .work tree, so unless the paths
        # Copy-FirstExisting searches are emptied first, "the file is there" says nothing about
        # which run produced it.
        $angleCandidates = @((Join-Path $outDir "libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static\libANGLE_static.lib"))
        $glesv2Candidates = @((Join-Path $outDir "libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static\libGLESv2_static.lib"))
        foreach ($candidate in ($angleCandidates + $glesv2Candidates)) {
            Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        }

        gn gen $outDir
        Assert-LastExitCode "gn gen $outDir"
        ninja -C $outDir -j $BuildJobs libANGLE_static libGLESv2_static
        Assert-LastExitCode "ninja libANGLE_static libGLESv2_static in $outDir"
        Copy-FirstExisting (Join-Path $OutputDir "libANGLE_static.lib") $angleCandidates
        Copy-FirstExisting (Join-Path $OutputDir "libGLESv2_static.lib") $glesv2Candidates
        Assert-AngleSymbols (Join-Path $OutputDir "libGLESv2_static.lib")
        Assert-AngleImplementationArchive (Join-Path $OutputDir "libANGLE_static.lib")

        # Written by the code that actually cloned chromium/$AngleBranch, so that packing has
        # something independent to check its claim against. Without it verify-tier-package compares
        # the branch in the generated props against the property that generated those props - a
        # tautology that passes whatever the archives really are. The commit is logged beside it so
        # a human can tie a shipped package back to an exact ANGLE revision.
        $branchRecord = Join-Path $OutputDir "angle-branch.txt"
        Set-Content -Path $branchRecord -Value $AngleBranch -Encoding ascii -NoNewline
        $angleCommit = & git -C $src rev-parse HEAD
        Assert-LastExitCode "git rev-parse HEAD in $src"
        Write-Host "ANGLE branch record: $branchRecord (chromium/$AngleBranch at $angleCommit)"
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
