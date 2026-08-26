using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout;
using Avalonia.Media.Imaging;

namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// The scene with the frame probe laid over it, at a fixed size so the offscreen render and the
/// window render describe the same picture.
/// </summary>
internal sealed class SceneHost
{
    private readonly FrameProbe _probe;

    public SceneHost(FrameSink sink, SelfTest selfTest)
    {
        _probe = new FrameProbe(sink);
        Root = new Panel
        {
            Width = SceneGeometry.Width,
            Height = SceneGeometry.Height,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new SmokeScene(selfTest),
                _probe,
            },
        };
    }

    public Panel Root { get; }

    /// <summary>
    /// Asks for another frame. Invalidating the probe alone is enough: it covers the whole scene, so
    /// the dirty region it produces is the whole scene, and everything under it is redrawn with it.
    /// </summary>
    public void Redraw() => _probe.InvalidateVisual();
}

internal sealed class SmokeRunner(SmokeOptions options, SmokeReport report, ClassicDesktopStyleApplicationLifetime lifetime)
{
    public async Task RunAsync()
    {
        int exitCode;
        try
        {
            exitCode = await ExecuteAsync().ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            report.Fail($"The smoke run threw {ex.GetType().Name}: {ex.Message}");
            exitCode = ExitCodes.Failed;
        }

        lifetime.Shutdown(report.Emit(exitCode, options.ReportPath));
    }

    private async Task<int> ExecuteAsync()
    {
        DescribeRun();

        var offscreenDrew = await RenderOffscreenAsync().ConfigureAwait(true);
        var frame = await RenderWindowAsync().ConfigureAwait(true);

        if (frame is null)
        {
            report.ObservedBackend = "no frame";
            report.Line(offscreenDrew
                ? "   Skia drew the same scene offscreen, so Skia itself works and the window's backend is what never delivered."
                : "   The offscreen render did not produce a good frame either, so the fault is not specific to the window backend.");
            return ExitCodes.NoFrame;
        }

        CheckBackend(frame);
        DumpFrame(frame);

        return report.Failures.Count == 0 ? ExitCodes.Pass : ExitCodes.Failed;
    }

    private void DescribeRun()
    {
        report.Line($"tier                : {options.Tier} (from {options.TierSource}), covers {SmokeOptions.Describe(SmokeOptions.BackendsOf(options.Tier))}");
        report.Line($"linked package      : tier='{LinkedPackage.Tier}' backends='{LinkedPackage.Backends}' " +
                    $"vulkan='{LinkedPackage.HasVulkan}' angle='{LinkedPackage.HasAngle}' angle-branch='{LinkedPackage.AngleBranch}'");
        report.Line($"forced backend      : {options.RequestedBackend} (a single rendering mode, so nothing can fall back)");
        report.Line($"platform            : {RuntimeInformation.OSDescription.Trim()} {RuntimeInformation.ProcessArchitecture}");
        report.Line($"avalonia            : {typeof(Application).Assembly.GetName().Version}");
        report.Line($"scene               : {SceneGeometry.Width}x{SceneGeometry.Height} logical pixels");

        if (options.SelfTest != SelfTest.None)
        {
            report.Line($"self-test           : {options.SelfTest} - the scene draws nothing and this run MUST fail. " +
                        "A pass here means the checks below have stopped testing anything.");
        }
    }

    /// <summary>
    /// Draws the scene through Skia's raster path, before the window exists.
    /// </summary>
    /// <remarks>
    /// This is what separates "the GPU backend is broken" from "Skia is broken": a window that comes
    /// back blank while this pass draws the correct picture points squarely at the backend.
    /// </remarks>
    private async Task<bool> RenderOffscreenAsync()
    {
        report.Section("offscreen render, RenderTargetBitmap");

        var sink = new FrameSink();
        try
        {
            var host = new SceneHost(sink, options.SelfTest);
            var size = new Size(SceneGeometry.Width, SceneGeometry.Height);
            host.Root.Measure(size);
            host.Root.Arrange(new Rect(size));

            using var bitmap = new RenderTargetBitmap(
                new PixelSize((int)SceneGeometry.Width, (int)SceneGeometry.Height),
                new Vector(96, 96));
            bitmap.Render(host.Root);
        }
        catch (Exception ex)
        {
            report.Fail($"the offscreen render threw {ex.GetType().Name}: {ex.Message}");
            return false;
        }

        // RenderTargetBitmap.Render is synchronous, so the probe has already run by now.
        var frame = await sink.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(true);
        if (frame is null)
        {
            report.Fail("the offscreen render finished without the probe ever being drawn");
            return false;
        }

        if (frame.Failure is not null)
        {
            report.Fail($"offscreen: {frame.Failure}");
            return false;
        }

        report.Line($"   read back {frame.Width}x{frame.Height} pixels");
        var results = FrameAnalysis.Inspect(frame, options.RequireText);
        foreach (var result in results)
        {
            report.Check(result);
        }

        return results.All(result => result.Passed);
    }

    private async Task<CapturedFrame?> RenderWindowAsync()
    {
        report.Section($"window render, {options.RequestedBackend} backend");

        var sink = new FrameSink();
        var host = new SceneHost(sink, options.SelfTest);
        var window = new SmokeWindow();
        window.Attach(host);
        lifetime.MainWindow = window;
        window.Show();
        report.Line($"   window shown at {window.RenderScaling:0.##}x scaling");

        var perAttempt = TimeSpan.FromSeconds(Math.Max(3, options.Timeout.TotalSeconds / (options.FrameAttempts + 1)));
        CapturedFrame? last = null;

        for (var attempt = 1; attempt <= options.FrameAttempts; attempt++)
        {
            var frame = await sink.WaitAsync(perAttempt).ConfigureAwait(true);
            if (frame is null)
            {
                report.Fail($"attempt {attempt}: no frame reached the probe within {perAttempt.TotalSeconds:0} seconds. " +
                            "A window that never paints is the failure this app exists to catch.");
                return null;
            }

            if (frame.Failure is not null)
            {
                report.Fail($"attempt {attempt}: {frame.Failure}");
                return frame;
            }

            last = frame;
            var lastAttempt = attempt == options.FrameAttempts;

            // A partial repaint only refreshed part of the scene, so ask for a full one - but never at
            // the cost of returning a frame nothing was checked against.
            if (frame.PartialRepaint && !lastAttempt)
            {
                report.Line($"   attempt {attempt}: partial repaint, asking for a full frame");
            }
            else
            {
                if (frame.PartialRepaint)
                {
                    report.Line($"   attempt {attempt}: still a partial repaint, checking it anyway");
                }

                report.Line($"   attempt {attempt}: read back {frame.Width}x{frame.Height} pixels at {frame.DeviceOrigin.X},{frame.DeviceOrigin.Y}");
                var results = FrameAnalysis.Inspect(frame, options.RequireText);
                if (results.All(result => result.Passed) || lastAttempt)
                {
                    foreach (var result in results)
                    {
                        report.Check(result);
                    }

                    return frame;
                }

                report.Line($"   attempt {attempt}: {results.Count(result => !result.Passed)} checks failed, redrawing");
            }

            sink.Rearm();
            host.Redraw();
        }

        return last;
    }

    private void CheckBackend(CapturedFrame frame)
    {
        report.Section("backend in use");

        var observed = frame.Graphics;
        report.ObservedBackend = observed.Name;
        report.Line($"   platform graphics : {observed.Name} - {observed.Detail}");
        report.Line($"   skia gpu context  : {frame.SkiaBackend ?? "none, Skia drew into a raster surface"}");

        var matches = observed.Backend == options.RequestedBackend;
        report.Check(new CheckResult(
            $"the frame was drawn with the {options.RequestedBackend} backend",
            matches,
            matches
                ? $"{observed.Name} as requested"
                : $"asked for {options.RequestedBackend} but the frame was drawn with {observed.Name}"));

        if (options.RequestedBackend == Backend.Software)
        {
            report.Check(new CheckResult(
                "Skia has no GPU context",
                !frame.GpuBacked,
                frame.GpuBacked
                    ? $"the software backend was requested yet Skia reports a {frame.SkiaBackend} GPU context"
                    : "none, as expected"));
            return;
        }

        report.Check(new CheckResult(
            "Skia has a GPU context",
            frame.GpuBacked,
            frame.GpuBacked
                ? $"GRContext backend {frame.SkiaBackend}"
                : $"GrContext is null: Avalonia created a {options.RequestedBackend} device and Skia handed back nothing. " +
                  "That is the SK_ONLY_VULKAN stub, and it is what paints an empty window without an error"));

        var expected = options.RequestedBackend.ToString();
        report.Check(new CheckResult(
            $"Skia's own backend is {expected}",
            string.Equals(frame.SkiaBackend, expected, StringComparison.OrdinalIgnoreCase),
            $"Skia reports '{frame.SkiaBackend ?? "none"}'"));
    }

    private void DumpFrame(CapturedFrame frame)
    {
        if (options.FramePath is null || frame.Pixels.Length == 0)
        {
            return;
        }

        try
        {
            BmpWriter.Write(options.FramePath, frame);
            report.Line($"   frame written to {Path.GetFullPath(options.FramePath)}");
        }
        catch (Exception ex)
        {
            report.Line($"   could not write the frame to '{options.FramePath}': {ex.Message}");
        }
    }
}
