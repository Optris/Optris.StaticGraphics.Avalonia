# Optris.StaticGraphics.AvaloniaNative

Static `AvaloniaNative` libraries for macOS Avalonia NativeAOT publishing, for `osx-x64` and
`osx-arm64`.

Fork of [greepar/StaticLink.Avalonia](https://github.com/greepar/StaticLink.Avalonia) (MIT).

`libAvaloniaNative.a` carries no Skia backend, so this package is tier-independent: pair it with
whichever `Optris.StaticGraphics.Avalonia.<Tier>` package you use. Its version is the Avalonia
version plus a build revision, and it has to match the Avalonia version of the app.

> **Not published to nuget.org.** This package is built by the repository but has never been
> released. Build it from source if you need it. The snippet below shows how the three versions
> relate, not something that will restore today.

```xml
<PackageReference Include="Avalonia" Version="12.2.0" />
<PackageReference Include="Optris.StaticGraphics.AvaloniaNative" Version="12.2.0.1" />
<PackageReference Include="Optris.StaticGraphics.Avalonia.Vulkan" Version="3.119.4.3" />
```

The AvaloniaNative version tracks **Avalonia** (12.2.0 -> `12.2.0.x`), while the tier package
version tracks the **SkiaSharp** that Avalonia depends on (Avalonia 12.2.0 -> SkiaSharp 3.119.4 ->
`3.119.4.x`). The two therefore do not match each other, and that is expected.
