using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;

namespace Optris.StaticGraphics.Smoke;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var report = new SmokeReport();
        var options = SmokeOptions.FromEnvironment(out var configurationError);
        if (options is null)
        {
            report.Fail(configurationError!);
            report.Line(Usage);
            return report.Emit(ExitCodes.Configuration, Environment.GetEnvironmentVariable("OPTRIS_SMOKE_REPORT"));
        }

        report.Tier = options.Tier.ToString();
        report.RequestedBackend = options.RequestedBackend.ToString();
        Watchdog.Arm(options, report);

        var lifetime = new ClassicDesktopStyleApplicationLifetime
        {
            // The run decides when it is over; nothing about a window closing may end it early.
            ShutdownMode = ShutdownMode.OnExplicitShutdown,
        };

        try
        {
            BuildAvaloniaApp(options).SetupWithLifetime(lifetime);
        }
        catch (Exception ex)
        {
            report.Fail($"Avalonia could not start with the {options.RequestedBackend} backend: {ex.GetType().Name}: {ex.Message}");
            report.Line("   Only that one rendering mode was offered, on purpose. A run that quietly renders with " +
                        "another backend tells you nothing about the one you asked for.");
            return report.Emit(ExitCodes.Startup, options.ReportPath);
        }

        var runner = new SmokeRunner(options, report, lifetime);
        Dispatcher.UIThread.Post(() => _ = runner.RunAsync());
        return lifetime.Start(args);
    }

    /// <summary>
    /// Configures Avalonia with exactly one rendering mode.
    /// </summary>
    /// <remarks>
    /// Avalonia walks its rendering mode list until something works, which is the right behaviour for
    /// an application and useless for a test: a Vulkan tier that silently rendered with GL would pass
    /// every check below. One entry means the run either uses the backend under test or fails to start.
    /// </remarks>
    public static AppBuilder BuildAvaloniaApp(SmokeOptions options)
    {
        var builder = AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();

        if (OperatingSystem.IsWindows())
        {
            builder = builder.With(new Win32PlatformOptions
            {
                RenderingMode = [options.RequestedBackend switch
                {
                    Backend.Vulkan => Win32RenderingMode.Vulkan,
                    // ANGLE is the GL implementation these packages ship on Windows.
                    Backend.OpenGL => Win32RenderingMode.AngleEgl,
                    _ => Win32RenderingMode.Software,
                }],
            });
        }

        if (OperatingSystem.IsLinux())
        {
            builder = builder.With(new X11PlatformOptions
            {
                RenderingMode = [options.RequestedBackend switch
                {
                    Backend.Vulkan => X11RenderingMode.Vulkan,
                    Backend.OpenGL => X11RenderingMode.Glx,
                    _ => X11RenderingMode.Software,
                }],
            });
        }

        if (OperatingSystem.IsMacOS())
        {
            builder = builder.With(new AvaloniaNativePlatformOptions
            {
                RenderingMode = [options.RequestedBackend switch
                {
                    Backend.OpenGL => AvaloniaNativeRenderingMode.OpenGl,
                    _ => AvaloniaNativeRenderingMode.Software,
                }],
            });
        }

        return builder;
    }

    private const string Usage = """
           OPTRIS_SMOKE_TIER             Vulkan | OpenGL | Software. Defaults to the tier baked in by the
                                         Optris.StaticGraphics.Avalonia.* package reference.
           OPTRIS_SMOKE_BACKEND          Vulkan | OpenGL | Software. The backend to force for this run.
                                         Defaults to the richest backend the tier promises.
           OPTRIS_SMOKE_TIMEOUT_SECONDS  Watchdog for the whole run. Default 30.
           OPTRIS_SMOKE_REQUIRE_TEXT     0 to accept a frame whose caption never rasterised. Default on.
           OPTRIS_SMOKE_FRAME            Path to write the captured frame to, as a BMP.
           OPTRIS_SMOKE_REPORT           Path to write this report to.
           OPTRIS_SMOKE_SELFTEST         blank | uniform. Draws nothing, so the run must fail.
       """;
}

/// <summary>
/// Kills the process if the run stops making progress.
/// </summary>
/// <remarks>
/// A background thread rather than a dispatcher timer: a GPU driver that wedges the UI thread is one
/// of the outcomes under test, and the report has to come out anyway.
/// </remarks>
internal static class Watchdog
{
    public static void Arm(SmokeOptions options, SmokeReport report)
    {
        var thread = new Thread(() =>
        {
            Thread.Sleep(options.Timeout);
            report.Fail($"The run did not finish within {options.Timeout.TotalSeconds:0} seconds and was killed.");
            Environment.Exit(report.Emit(ExitCodes.NoFrame, options.ReportPath));
        })
        {
            IsBackground = true,
            Name = "optris-smoke-watchdog",
        };

        thread.Start();
    }
}
