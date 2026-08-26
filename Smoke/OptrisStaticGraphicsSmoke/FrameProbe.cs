using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Rendering.SceneGraph;
using Avalonia.Skia;
using SkiaSharp;

namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// Sits on top of the scene and reads back the pixels Skia just drew.
/// </summary>
/// <remarks>
/// Drawn last, so by the time its operation runs the surface already holds the whole scene. This is
/// the only vantage point that sees what the selected backend actually produced: the same code runs
/// inside a window's render pass on the render thread and inside a RenderTargetBitmap pass on the UI
/// thread, which is why each probe carries its own sink instead of sharing static state.
/// </remarks>
internal sealed class FrameProbe : Control
{
    private readonly FrameSink _sink;

    public FrameProbe(FrameSink sink)
    {
        _sink = sink;
        IsHitTestVisible = false;
    }

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width < 1 || bounds.Height < 1)
        {
            return;
        }

        context.Custom(new CaptureOperation(bounds, _sink));
    }
}

internal sealed class CaptureOperation(Rect bounds, FrameSink sink) : ICustomDrawOperation
{
    public Rect Bounds => bounds;

    public bool HitTest(Point p) => false;

    // Never equal to another operation: two captures must never be collapsed into one.
    public bool Equals(ICustomDrawOperation? other) => false;

    public void Dispose()
    {
    }

    public void Render(ImmediateDrawingContext context)
    {
        // Readback costs a GPU flush, so it happens only for frames someone asked for.
        if (!sink.TryBeginCapture())
        {
            return;
        }

        try
        {
            if (context.TryGetFeature(typeof(ISkiaSharpApiLeaseFeature)) is not ISkiaSharpApiLeaseFeature feature)
            {
                sink.Complete(CapturedFrame.Failed(
                    "The drawing context does not expose ISkiaSharpApiLeaseFeature, so this build is not rendering through Skia at all."));
                return;
            }

            using var lease = feature.Lease();
            sink.Complete(Capture(lease));
        }
        catch (Exception ex)
        {
            sink.Complete(CapturedFrame.Failed($"Reading back the frame threw {ex.GetType().Name}: {ex.Message}"));
        }
    }

    private CapturedFrame Capture(ISkiaSharpApiLease lease)
    {
        var observed = ObserveGraphics(lease, out var skiaBackend, out var gpuBacked);

        var surface = lease.SkSurface;
        if (surface is null)
        {
            return CapturedFrame.Failed("The Skia lease carried no SkSurface, so there is no frame to read.", observed, skiaBackend, gpuBacked);
        }

        var canvas = lease.SkCanvas;
        var matrix = canvas.TotalMatrix;
        var topLeft = matrix.MapPoint((float)bounds.X, (float)bounds.Y);
        var bottomRight = matrix.MapPoint((float)bounds.Right, (float)bounds.Bottom);

        var x0 = (int)Math.Round(Math.Min(topLeft.X, bottomRight.X));
        var y0 = (int)Math.Round(Math.Min(topLeft.Y, bottomRight.Y));
        var x1 = (int)Math.Round(Math.Max(topLeft.X, bottomRight.X));
        var y1 = (int)Math.Round(Math.Max(topLeft.Y, bottomRight.Y));
        var width = x1 - x0;
        var height = y1 - y0;

        if (x0 < 0 || y0 < 0 || width < 16 || height < 16)
        {
            return CapturedFrame.Failed(
                $"The scene maps to an unusable device rectangle {x0},{y0} {width}x{height}.", observed, skiaBackend, gpuBacked);
        }

        // A partial repaint would only refresh part of the scene; the caller asks for another frame.
        var clip = canvas.DeviceClipBounds;
        var partial = clip.Left > x0 || clip.Top > y0 || clip.Right < x1 || clip.Bottom < y1;

        var info = new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Unpremul);
        var pixels = new byte[width * height * 4];
        var pinned = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        bool read;
        try
        {
            read = surface.ReadPixels(info, pinned.AddrOfPinnedObject(), width * 4, x0, y0);
        }
        finally
        {
            pinned.Free();
        }

        if (!read)
        {
            return CapturedFrame.Failed(
                $"Skia refused to read back {width}x{height} pixels at {x0},{y0} from the render surface.", observed, skiaBackend, gpuBacked);
        }

        return new CapturedFrame
        {
            Pixels = pixels,
            Width = width,
            Height = height,
            DeviceOrigin = (x0, y0),
            PartialRepaint = partial,
            Graphics = observed,
            SkiaBackend = skiaBackend,
            GpuBacked = gpuBacked,
        };
    }

    private static ObservedGraphics ObserveGraphics(ISkiaSharpApiLease lease, out string? skiaBackend, out bool gpuBacked)
    {
        skiaBackend = null;
        gpuBacked = false;

        try
        {
            // Skia's own answer to "which backend am I": a GRContext that never came into being is
            // precisely the silent failure this app exists to catch.
            var grContext = lease.GrContext;
            if (grContext is not null)
            {
                gpuBacked = true;
                skiaBackend = grContext.Backend.ToString();
            }
        }
        catch (Exception ex)
        {
            skiaBackend = $"unreadable ({ex.GetType().Name})";
        }

        try
        {
            using var platformApi = lease.TryLeasePlatformGraphicsApi();
            return GraphicsIdentity.FromPlatformContext(platformApi?.Context);
        }
        catch (Exception ex)
        {
            return new ObservedGraphics(null, "unavailable", $"leasing the platform graphics API threw {ex.GetType().Name}: {ex.Message}");
        }
    }
}

internal sealed class CapturedFrame
{
    public string? Failure { get; init; }

    public byte[] Pixels { get; init; } = [];

    public int Width { get; init; }

    public int Height { get; init; }

    public (int X, int Y) DeviceOrigin { get; init; }

    public bool PartialRepaint { get; init; }

    public ObservedGraphics Graphics { get; init; } = new(null, "unknown", "not observed");

    /// <summary>What Skia reported as its backend, or null when it had no GPU context at all.</summary>
    public string? SkiaBackend { get; init; }

    public bool GpuBacked { get; init; }

    public static CapturedFrame Failed(string failure, ObservedGraphics? graphics = null, string? skiaBackend = null, bool gpuBacked = false) => new()
    {
        Failure = failure,
        Graphics = graphics ?? new ObservedGraphics(null, "unknown", "not observed"),
        SkiaBackend = skiaBackend,
        GpuBacked = gpuBacked,
    };
}

/// <summary>
/// Hands one captured frame from whichever thread rendered it to the thread waiting on it.
/// </summary>
internal sealed class FrameSink
{
    private readonly object _gate = new();
    private TaskCompletionSource<CapturedFrame> _pending = new(TaskCreationOptions.RunContinuationsAsynchronously);

    // Starts armed: a static scene may paint exactly once, and that first frame is the one that matters.
    private int _requested = 1;

    public bool TryBeginCapture() => Interlocked.Exchange(ref _requested, 0) == 1;

    public void Complete(CapturedFrame frame)
    {
        lock (_gate)
        {
            _pending.TrySetResult(frame);
        }
    }

    public void Rearm()
    {
        lock (_gate)
        {
            _pending = new TaskCompletionSource<CapturedFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        Volatile.Write(ref _requested, 1);
    }

    public async Task<CapturedFrame?> WaitAsync(TimeSpan timeout)
    {
        Task<CapturedFrame> pending;
        lock (_gate)
        {
            pending = _pending.Task;
        }

        try
        {
            return await pending.WaitAsync(timeout).ConfigureAwait(true);
        }
        catch (TimeoutException)
        {
            return null;
        }
    }
}
