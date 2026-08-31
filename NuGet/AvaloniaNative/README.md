# Optris.StaticGraphics.AvaloniaNative

Static `AvaloniaNative` libraries for macOS Avalonia NativeAOT publishing, for `osx-x64` and
`osx-arm64`.

Fork of [greepar/StaticLink.Avalonia](https://github.com/greepar/StaticLink.Avalonia) (MIT).

`libAvaloniaNative.a` carries no Skia backend, so this package is tier-independent: pair it with
whichever `Optris.StaticGraphics.Avalonia.<Tier>` package you use. Its version is the Avalonia
version plus a build revision, and it has to match the Avalonia version of the app.

```xml
<PackageReference Include="Avalonia" Version="12.1.1" />
<PackageReference Include="Optris.StaticGraphics.AvaloniaNative" Version="12.1.1.1" />
<PackageReference Include="Optris.StaticGraphics.Avalonia.Vulkan" Version="4.150.1.1" />
```
