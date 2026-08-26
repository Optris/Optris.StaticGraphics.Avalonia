# Attribution and what this fork changes

Derived from **[greepar/StaticLink.Avalonia](https://github.com/greepar/StaticLink.Avalonia)**
(MIT), which did the hard part: building Skia, HarfBuzz and ANGLE as static archives and wiring
them into ILCompiler with `DirectPInvoke` + `NativeLibrary` so an Avalonia Native AOT publish emits
a single executable instead of one beside three native DLLs. The build scripts, the ANGLE patch and
the MSBuild integration in this repository all began as that work.

## Why the fork exists

Upstream builds Skia with `skia_use_vulkan = false`. That is not a missing feature so much as a
**silent** one, and the distinction is the whole reason this repository exists.

SkiaSharp's C API does not compile absent backends out — it stubs them. From `mono/skia`
`src/c/gr_context.cpp`:

```c
gr_direct_context_t* gr_direct_context_make_vulkan(...) {
    return SK_ONLY_VULKAN(ToGrDirectContext(...), nullptr);
}
```

With `SK_VULKAN` undefined that macro selects the second argument, so the symbol still exists and
still links — it just returns `nullptr`. An Avalonia app whose renderer list starts with Vulkan
therefore loads the system `vulkan-1.dll`, creates an instance, device and queue successfully,
commits to the Vulkan platform graphics, hands it all to Skia, and receives a null context back.
The result is a window that opens, stays responsive, logs nothing, and **paints nothing**. No
crash, no exception, no fallback to the next renderer in the list.

We lost an afternoon to that on a real application. Everything below follows from not wanting
anyone to lose another one.

## What changed

- **Vulkan is enabled** (`skia_use_vulkan = true`, which also turns on the memory allocator via
  `skia_use_vma`). This costs roughly 2.5 MB and needs no new dependency: Skia vendors the Vulkan
  headers, the allocator is already synced by `git-sync-deps`, and Skia never links a Vulkan
  library — it resolves entry points through a proc-address getter the caller supplies.
- **Three package tiers**, each a strict superset of the one below, so no tier can leave a hole in
  an Avalonia fallback chain: Vulkan → OpenGL/ANGLE → Software.
- **The tier contract is machine-checked.** Every build asserts, at the symbol level, that the
  archives contain exactly the backends the package name claims. This is the check whose absence
  produced the bug above, and it fails the build rather than a customer's window.
- **The smoke test renders a frame and asserts the pixels are not uniform.** Upstream's asserts the
  process stays alive, which is precisely what a blank window does.
- **ANGLE is no longer shipped for non-Windows targets**, where nothing referenced it.
- Packages are published under the `Optris.StaticGraphics.Avalonia.*` identity.

Upstream is not at fault for any of this; a GL-only static build is a perfectly reasonable thing to
ship, and it is clearly documented as being about single-file output rather than about backends.
Our requirements are simply narrower: the application this exists for is deliberately Vulkan-first,
because that is what it ships to customers on.
