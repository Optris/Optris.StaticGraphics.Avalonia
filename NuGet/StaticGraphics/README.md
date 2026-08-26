# Optris.StaticGraphics.Avalonia

Static native libraries for Avalonia single-file NativeAOT publishing: SkiaSharp, HarfBuzzSharp and
(on Windows) ANGLE, linked into the executable so nothing has to be shipped beside it.

Fork of [greepar/StaticLink.Avalonia](https://github.com/greepar/StaticLink.Avalonia) (MIT).

## Pick a tier

The package ships in three tiers. Each is a strict superset of the one below it, so no tier can
leave a hole in an Avalonia render-backend fallback chain.

| Package | Backends compiled into Skia | Approximate cost |
| --- | --- | --- |
| `Optris.StaticGraphics.Avalonia.Vulkan` | Vulkan (Metal on macOS), OpenGL/ANGLE, Software | largest |
| `Optris.StaticGraphics.Avalonia.OpenGL` | OpenGL/ANGLE, Software | no Vulkan |
| `Optris.StaticGraphics.Avalonia.Software` | Software | smallest, no GPU |

Reference exactly one of them. Referencing two fails the build (`OSG0001`): both ship the same
static libraries and the same `DirectPInvoke` names, so the linker would pick one and the app would
silently ship the other tier's capabilities.

On macOS the Vulkan tier is delivered by Metal. Skia does not vendor MoltenVK, so Vulkan cannot
reach Apple GPUs; Metal is what Avalonia asks for there anyway.

```xml
<PackageReference Include="Optris.StaticGraphics.Avalonia.Vulkan" Version="4.150.1.1" />
```

For macOS also reference `Optris.StaticGraphics.AvaloniaNative`, which is tier-independent but must
match your Avalonia version because it contains `libAvaloniaNative.a`.

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

Use the RID you need: `win-x64`, `win-x86`, `win-arm64`, `linux-x64`, `linux-arm64`,
`linux-musl-x64`, `linux-musl-arm64`, `osx-x64` or `osx-arm64`.

## What the package tells you

The tier is published as MSBuild properties, generated when the package was packed:

| Property | Example |
| --- | --- |
| `OptrisStaticGraphicsTier` | `Vulkan` |
| `OptrisStaticGraphicsBackends` | `Vulkan;OpenGL;Software` |
| `OptrisStaticGraphicsHasVulkan` | `true` |
| `OptrisStaticGraphicsHasAngle` | `true` |
| `OptrisStaticGraphicsAngleBranch` | `7922` (empty when the tier has no ANGLE) |

## Build-time guards

Set what your app cannot run without, and a wrong tier fails the build instead of the window:

```xml
<PropertyGroup>
  <OptrisStaticGraphicsRequiredBackends>Vulkan</OptrisStaticGraphicsRequiredBackends>
</PropertyGroup>
```

| Code | Meaning |
| --- | --- |
| `OSG0001` (error) | Two tier packages referenced, or the linked tier lacks a required backend. |
| `OSG0002` (warning) | A reduced tier (anything below Vulkan) is linked. Set `OptrisStaticGraphicsAcknowledgeReducedTier=true` once that is deliberate. |
| `OSG0003` (warning) | `PublishAot` with a RID this package carries no payload for: nothing is linked statically. |

## Runtime guard

Skia does not fail when a backend is missing. `gr_direct_context_make_vulkan` is compiled in
whatever the build flags say and simply returns null when Vulkan was not enabled, so an app that
asks for Vulkan creates a Vulkan instance, a device and a queue, hands them to Skia, gets nothing
back, and renders a **blank window** with no crash, no log and no fallback. Metal behaves the same
way on macOS.

`WithOptrisStaticGraphics()` compares the rendering modes the app configured against the tier that
is actually linked:

```csharp
using Optris.StaticGraphics;

public static AppBuilder BuildAvaloniaApp() =>
    AppBuilder.Configure<App>()
        .UsePlatformDetect()
        .With(new Win32PlatformOptions
        {
            RenderingMode = [Win32RenderingMode.Vulkan, Win32RenderingMode.AngleEgl, Win32RenderingMode.Software],
        })
        .WithOptrisStaticGraphics()   // OptrisBackendPolicy.Strict by default
        .LogToTrace();
```

- `OptrisBackendPolicy.Strict` throws at startup, naming the tier, the mode and the package that
  would provide it.
- `OptrisBackendPolicy.Filter` removes the unavailable modes and logs to `LogArea.Platform`, which
  repairs the fallback chain: a tier-OpenGL app that asks for Vulkan first gets a working ANGLE
  window instead of a blank one.

Chain it **after** the windowing subsystem is selected and **after** the `.With(...)` call that
configures the platform options, because it inspects those options in place. Avalonia builds its
own default options when an app configures none, and there is no supported way to reach into that
default, so the guard can only report it: configure the options explicitly if you want them
repaired.

The guard is compiled into your project by the package. It is injected when `Avalonia.Desktop` is
referenced, because it inspects `Win32PlatformOptions`, `X11PlatformOptions` and
`AvaloniaNativePlatformOptions`. Set `OptrisStaticGraphicsInjectRuntimeGuard` to `true` or `false`
to override that, for example when those packages arrive transitively.
