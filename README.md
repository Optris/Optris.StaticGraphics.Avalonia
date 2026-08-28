# Optris.StaticGraphics.Avalonia

Static Skia, HarfBuzz and ANGLE archives for Avalonia, so a Native AOT publish produces one
executable instead of one beside three native libraries.

Forked from [greepar/StaticLink.Avalonia](https://github.com/greepar/StaticLink.Avalonia) (MIT),
which did the hard part. What this fork adds is Vulkan, three package tiers that say out loud which
backends they contain, and checks - at pack time, at build time and at run time - that a package
cannot quietly contain less than its name claims.

## Why the fork exists

Upstream builds Skia with `skia_use_vulkan = false`. SkiaSharp's C API does not compile absent
backends out, it stubs them:

```c
gr_direct_context_t* gr_direct_context_make_vulkan(...) {
    return SK_ONLY_VULKAN(ToGrDirectContext(...), nullptr);
}
```

The symbol still exists, still links, and returns `nullptr`. An Avalonia application whose renderer
list starts with Vulkan therefore loads `vulkan-1.dll`, creates an instance, a device and a queue,
commits to the Vulkan platform graphics, hands it all to Skia, and receives a null context back. The
window opens, stays responsive, logs nothing and paints nothing. No crash, no exception, no fallback
to the next renderer in the list.

That cost us an afternoon on a real application. [NOTICE.md](NOTICE.md) has the full account and the
list of what changed.

## Tiers

Three packages. Each is a strict superset of the one below it, so no tier can leave a hole in an
Avalonia fallback chain.

| Package | Backends | Choose it when |
| --- | --- | --- |
| `Optris.StaticGraphics.Avalonia.Vulkan` | Vulkan, OpenGL/ANGLE, Software | the default. Anything Vulkan-first, and anything that might become Vulkan-first later |
| `Optris.StaticGraphics.Avalonia.OpenGL` | OpenGL/ANGLE, Software | the renderer list never mentions Vulkan, and the roughly 2.5 MB Vulkan costs in `skia.lib` matters |
| `Optris.StaticGraphics.Avalonia.Software` | Software | no GPU is in play at all: headless, RDP-only, container workloads |

ANGLE is built for Windows only. Nothing else ever referenced it - the macOS targets never mention
it and the Linux `DirectPInvoke` list omits `av_libglesv2` - so the other platforms were carrying
about 23 MB of archive and six ninja builds a release for nothing.

Enabling Vulkan needs no new dependency and no new link input. Skia vendors the Vulkan headers, the
memory allocator is already synced by `git-sync-deps`, and Skia never links a Vulkan library: it
resolves entry points through a proc-address getter that Avalonia supplies. Nothing here adds a hard
dependency on `vulkan-1`, so a machine with no ICD still falls back the way Avalonia intends.

macOS is OpenGL or Software. Avalonia has no Vulkan backend there.

### Known gap: Metal on macOS

**The Metal backend is compiled into the macOS payload and cannot currently be used.** The Vulkan
tier on macOS is meant to be delivered by Metal - Vulkan only reaches Apple hardware through
MoltenVK, which Skia does not vendor - so `build-macos-static-graphics.sh` sets `skia_use_metal` and
asserts `GrMtlGpu`. That assertion passes. Metal still cannot render.

Avalonia's Metal support does not go through SkiaSharp's managed bindings, because SkiaSharp exposes
no managed Metal `GRContext` API. `Avalonia.Skia.Metal.SkiaMetalApi` instead **loads a dynamic
`libSkiaSharp` at runtime** and resolves `gr_direct_context_make_metal_with_options` and
`gr_backendrendertarget_new_metal` out of it by name. A statically linked build has no
`libSkiaSharp.dylib` - this package deletes it on publish, and CI asserts it is gone - so the
constructor throws `DllNotFoundException` before Metal is ever reached.

Measured on an M4 Pro against `Optris.StaticGraphics.Avalonia.Vulkan` 3.119.4.1:

| | |
|---|---|
| `libskia.a` | 152 `GrMtlGpu` symbols, both Metal entry points present |
| published binary | exports **zero** of them, so no self-`dlopen` fallback could reach them either |
| `OPTRIS_SMOKE_BACKEND=Metal` | `DllNotFoundException: Unable to load shared library 'libSkiaSharp'`, exit 134 |
| `=OpenGL`, `=Software` | both render and pass on the same binary |

So the macOS Vulkan tier proves OpenGL and Software, and its top backend is dropped from what CI
smoke asserts. **`verify-tier-payload`'s `GrMtlGpu` check is therefore necessary but not
sufficient** - it proves Metal was compiled in, not that it can run. That is an uncomfortable state
for a repository founded on refusing exactly that gap, which is why it is written down here instead
of left to be rediscovered.

What would close it: export those two entry points from the AOT binary and register a
`DllImportResolver` mapping `libSkiaSharp` to the main program handle, so Avalonia's lookup resolves
against the statically linked Skia. Plausible - the package already uses `DirectPInvoke` for
`libSkiaSharp` - but unproven.

The smoke app already understands `OPTRIS_SMOKE_BACKEND=Metal` and refuses it on non-macOS, so the
failure above reproduces in one command. Note that GitHub's macOS runners cannot host this test at
all: they give Avalonia no usable GPU context, and even the Software backend fails there in a
background session. Real hardware, in a GUI session, is required.

## Install

```xml
<ItemGroup>
  <PackageReference Include="Avalonia" Version="11.3.14" />
  <PackageReference Include="Avalonia.Desktop" Version="11.3.14" />
  <PackageReference Include="Avalonia.Themes.Fluent" Version="11.3.14" />
  <PackageReference Include="Optris.StaticGraphics.Avalonia.Vulkan" Version="3.119.4.12" />
</ItemGroup>
```

The first three parts of the package version are the SkiaSharp version it was built against; the
fourth is the build revision. It is a release version, not a prerelease - upstream's `3.119.4-7922.1`
makes every consumer opt into prereleases forever, and every consumer of theirs after that.

Pick the version whose SkiaSharp matches the one your Avalonia version uses:

| Avalonia | SkiaSharp | package version |
| --- | --- | --- |
| 11.3.14 | 2.88.9 | `2.88.9.*` |
| 11.3.14 | 3.119.4 | `3.119.4.*` |
| 12.1.0 | 3.119.4 | `3.119.4.*` |
| 12.1.0 | 4.150.1 | `4.150.1.*` |

On macOS also reference `Optris.StaticGraphics.AvaloniaNative`, which carries
`libAvaloniaNative.a`. It is tier-independent, but it contains Avalonia's own native library, so its
version has to match the Avalonia version the application uses:

```xml
<PackageReference Include="Optris.StaticGraphics.AvaloniaNative" Version="11.3.14.1" />
```

## Publish

```bash
dotnet publish -c Release -r win-x64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true
```

Any of `win-x64`, `win-x86`, `win-arm64`, `linux-x64`, `linux-arm64`, `linux-musl-x64`,
`linux-musl-arm64`, `osx-x64`, `osx-arm64`.

## Saying which backends you need

The whole point of the tiers is that a project can state its requirement and have the build enforce
it, instead of discovering the answer as an empty window on a customer's machine.

```xml
<PropertyGroup>
  <OptrisStaticGraphicsRequiredBackends>Vulkan;OpenGL;Software</OptrisStaticGraphicsRequiredBackends>
</PropertyGroup>
```

- **OSG0001** is an error: the referenced tier does not contain one of the backends you asked for.
- **OSG0002** is a warning: a reduced tier is in use and nothing said that was intended. Set
  `OptrisStaticGraphicsAcknowledgeReducedTier` to `true` to accept it.

Every package also publishes what it contains to the consuming build, through `buildTransitive`:

| Property | Value |
| --- | --- |
| `OptrisStaticGraphicsTier` | `Vulkan`, `OpenGL` or `Software` |
| `OptrisStaticGraphicsBackends` | semicolon list of the backends in the archive |
| `OptrisStaticGraphicsHasVulkan` | `true` or `false` |
| `OptrisStaticGraphicsHasAngle` | `true` or `false` |
| `OptrisStaticGraphicsAngleBranch` | the chromium branch ANGLE was built from |

The runtime counterpart checks the backends Avalonia is actually configured with against the tier
that was linked, and fails loudly rather than letting a null GPU context paint nothing:

```csharp
using Optris.StaticGraphics;

AppBuilder.Configure<App>()
    .UsePlatformDetect()
    .WithOptrisStaticGraphics();   // OptrisBackendPolicy.Strict by default
```

## Smoke test

`Smoke/OptrisStaticGraphicsSmoke` forces one backend per run, renders a known picture, reads the
pixels back out of the surface Skia drew into, and asserts that what came back is the picture rather
than one flat colour. It also asserts that Skia's `GRContext` exists and reports the backend that was
asked for, which is the null-context stub caught directly.

Upstream's smoke test asserts that the process is still alive after fifteen seconds. So does a blank
window. CI judges every run by the app's exit code instead, and runs the app's own negative control
alongside it so that a harness which has stopped asserting fails the build rather than passing it.
`scripts/run-smoke.sh` is the one entry point all four platforms use. See
[Smoke/README.md](Smoke/README.md).

## Building the archives

`scripts/build-windows-static-graphics.ps1` takes `-Tier`; the Linux, musl and macOS shell scripts
read `TIER` from the environment and default to `Vulkan`. Each tier builds into its own directory, so
the multi-gigabyte depot_tools and Skia checkout is shared rather than re-cloned, and the payload
lands in `External/NativeStatic/static-$Tier/<rid>/native/`. Packing is
`dotnet pack -p:Tier=<tier>`.

Building Skia needs depot_tools, per-OS toolchains and hours; in practice it happens in CI.
`.github/workflows/release.yml` runs the preflight, then the platform workflows, packs
each tier, runs the smoke tests, and only then publishes. The platform workflows
(`static-graphics-windows.yml`, `-linux`, `-musl`, `-macos`) can be dispatched on their own when
diagnosing one platform.

## Credit

The build scripts, the ANGLE patch and the MSBuild integration began as
[greepar/StaticLink.Avalonia](https://github.com/greepar/StaticLink.Avalonia). A GL-only static
build is a perfectly reasonable thing to ship, and that project is clear that it is about single-file
output rather than about backends; our requirements are simply narrower. MIT, as upstream is.
