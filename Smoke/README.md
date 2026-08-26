# Smoke test

`OptrisStaticGraphicsSmoke` is a normal Avalonia application that a tier package is added to at
publish time. It forces one rendering backend, draws a known picture, reads the pixels back out of
the surface Skia actually rendered into, and exits non-zero with a report naming the tier, the
backend and what it saw.

It exists because the failure this repository was forked over does not crash. A Skia built without
Vulkan still exports `gr_direct_context_make_vulkan`; it returns `nullptr`. Avalonia creates a
Vulkan instance, device and queue, hands them over, gets nothing back, and the window stays empty
with no exception and no log line. A smoke test that asserts the process is still alive after
fifteen seconds passes that run, which is how the defect shipped in the first place.

## What each run checks

| Check | Catches |
| --- | --- |
| Avalonia starts with exactly one rendering mode | a fallback quietly rendering with another backend |
| the offscreen `RenderTargetBitmap` pass draws the scene | Skia, HarfBuzz or the font stack being broken outright |
| a frame reaches the probe at all | a window that never paints |
| the frame is not one flat colour | the blank window, in its usual form |
| four fills sit at their expected coordinates in their expected colours | a partially drawn or mistransformed frame |
| the caption band contains white glyph pixels | fontconfig, DirectWrite or CoreText being unreachable |
| the platform graphics context is the backend that was asked for | Vulkan silently becoming GL, or GL becoming software |
| `GRContext` is non-null and reports the expected backend | **the `SK_ONLY_VULKAN` stub**: a GPU device accepted and a null context handed back |

The last two run against the context Skia was handed for that frame, taken through Avalonia's
`ISkiaSharpApiLeaseFeature` inside the render pass, so they describe what drew the frame rather than
what was requested.

Both passes render the same scene: `RenderTargetBitmap` first, through Skia's raster path, then the
window through the selected backend. When the offscreen pass draws correctly and the window comes
back blank, the report says so, and the fault is in the backend rather than in Skia.

## Running it

```bash
OPTRIS_SMOKE_TIER=Vulkan OPTRIS_SMOKE_BACKEND=Vulkan ./OptrisStaticGraphicsSmoke
```

On Linux there must be a display: `xvfb-run -a ./OptrisStaticGraphicsSmoke`.

| Variable | Meaning |
| --- | --- |
| `OPTRIS_SMOKE_TIER` | `Vulkan`, `OpenGL` or `Software`. Defaults to the tier baked in by the package reference; if both are present and disagree, the run fails with exit 3. |
| `OPTRIS_SMOKE_BACKEND` | The backend to force for this run. Defaults to the richest backend the tier promises. |
| `OPTRIS_SMOKE_TIMEOUT_SECONDS` | Watchdog for the whole run, default 30. It kills the process from a background thread, because a wedged GPU driver is one of the outcomes under test. |
| `OPTRIS_SMOKE_REQUIRE_TEXT` | `0` to accept a frame whose caption never rasterised. On by default. |
| `OPTRIS_SMOKE_FRAME` | Path to write the captured frame to, as a BMP. Worth uploading as a CI artifact. |
| `OPTRIS_SMOKE_REPORT` | Path to write the report to. |
| `OPTRIS_SMOKE_SELFTEST` | `blank` or `uniform`. See below. |

| Exit code | Meaning |
| --- | --- |
| 0 | every check passed |
| 1 | the run completed and something was wrong |
| 2 | no frame arrived, or the watchdog fired |
| 3 | the run was configured in a way that cannot prove anything |
| 4 | Avalonia could not start with the requested backend |

Because each tier is a superset of the one below it, a tier has to be run once per backend it
promises. A `Vulkan` package should be exercised with `OPTRIS_SMOKE_BACKEND` set to `Vulkan`, then
`OpenGL`, then `Software`; asking for a backend the tier does not carry is exit 3 rather than a
failure. Avalonia has no Vulkan backend on macOS, so macOS runs are `OpenGL` and `Software` only.

## Negative controls

`OPTRIS_SMOKE_SELFTEST=blank` renders nothing, and `uniform` renders one flat colour. Both are what
a broken backend produces, and both **must** fail:

```bash
OPTRIS_SMOKE_SELFTEST=blank ./OptrisStaticGraphicsSmoke && echo "the checks have stopped checking"
```

Running one of these in CI keeps the assertions honest. A drawn window and a blank window have to
produce different verdicts; that is the entire point of the app, and this is how it is proven.

## In CI

`scripts/run-smoke.sh` is what the workflows call, on Windows, Linux, macOS and inside the Alpine
container alike, so one implementation decides all four. It runs the app once per backend in
`SMOKE_BACKENDS` and fails if any of them returns anything but 0 - there is no branch anywhere that
reads liveness as success. `SMOKE_SELFTEST=1` runs the negative control instead, through the
cheapest backend the tier carries, and fails if the app comes back green.

| Variable | Meaning |
| --- | --- |
| `SMOKE_TIER` | the tier under test |
| `SMOKE_BACKENDS` | space separated backends to force, richest first |
| `SMOKE_DIR` | directory holding the published app |
| `SMOKE_LOG_DIR` | where the frame BMPs and the reports are written, and what CI uploads |
| `SMOKE_LAUNCHER` | command prefix, `xvfb-run -a` where there is no display |
| `SMOKE_LABEL` | what to call the run in the log |
| `SMOKE_TIMEOUT` | watchdog seconds handed to the app, default 60 |
| `SMOKE_SELFTEST` | `1` to run the negative control instead |

The frames and reports upload on every run, including failures: a blank frame is the evidence, and a
red build without the picture it read back is an assertion nobody else can check.

## Building it

`scripts/create-avalonia-smoke.ps1` copies this project next to a local package feed and writes the
`SmokeVersions.props` and `NuGet.config` that point it at one tier:

```powershell
pwsh ./scripts/create-avalonia-smoke.ps1 `
  -ProjectDir artifacts/avalonia-smoke-src `
  -NuGetSource (Resolve-Path artifacts/nuget) `
  -Tier Vulkan `
  -PackageVersion 3.119.4.12 `
  -AvaloniaVersion 11.3.14
```

The copy sets `OptrisStaticGraphicsRequiredBackends` to everything the tier promises, so a publish
that succeeds is also a passing run of the consumer guard. Point `-Tier` at a lesser tier while
leaving `-RequiredBackends` alone to check the other direction: the build must fail with OSG0001.

The project also builds on its own, without any tier package, which is what
`static-graphics-preflight.yml` uses:

```bash
dotnet build Smoke/OptrisStaticGraphicsSmoke/OptrisStaticGraphicsSmoke.csproj -c Release -p:PublishAot=false
```

Without a package reference no tier is baked in, so a run then needs `OPTRIS_SMOKE_TIER`.

## What it cannot see

It reads the surface Skia rendered into, from inside the render pass. That covers everything between
Avalonia's backend selection and Skia's output, which is where the silent failure lives. It does not
photograph the screen, so a fault entirely in presentation - a correct frame that never reaches the
compositor or the display - would still pass. Catching that needs a screenshot from outside the
process, which is a different tool.
