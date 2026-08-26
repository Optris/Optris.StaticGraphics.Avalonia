// Compiled into the referencing project by Optris.StaticGraphics.Avalonia.<Tier>.targets, so it
// has to build inside someone else's project whatever they switched on: the file is
// nullable-oblivious either way, uses nothing newer than C# 10, and no API beyond Avalonia 11.
#nullable disable

using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Logging;

namespace Optris.StaticGraphics;

/// <summary>
/// What <see cref="OptrisStaticGraphicsExtensions.WithOptrisStaticGraphics"/> does when the app
/// asks for a rendering mode the linked graphics tier does not contain.
/// </summary>
public enum OptrisBackendPolicy
{
    /// <summary>Throw at startup, naming the tier, the mode and the package that would provide it.</summary>
    Strict,

    /// <summary>Drop the unavailable modes and log, leaving a fallback chain that can actually run.</summary>
    Filter,
}

/// <summary>
/// Startup guard for apps that statically link Skia through Optris.StaticGraphics.Avalonia.
/// </summary>
public static class OptrisStaticGraphicsExtensions
{
    private const string VulkanBackend = "Vulkan";
    private const string OpenGLBackend = "OpenGL";
    private const string SoftwareBackend = "Software";

    private static readonly string[] AvailableBackends =
        OptrisStaticGraphicsTierInfo.Backends.Split(';');

    /// <summary>
    /// Checks the configured rendering modes against the graphics tier that is actually linked.
    /// Chain it after the windowing subsystem is chosen and after any
    /// <c>.With(new Win32PlatformOptions ...)</c> call, e.g.
    /// <c>AppBuilder.Configure&lt;App&gt;().UsePlatformDetect().With(options).WithOptrisStaticGraphics()</c>.
    /// </summary>
    public static AppBuilder WithOptrisStaticGraphics(
        this AppBuilder builder,
        OptrisBackendPolicy policy = OptrisBackendPolicy.Strict)
    {
        if (builder == null)
        {
            throw new ArgumentNullException(nameof(builder));
        }

        var windowingSubsystem = builder.WindowingSubsystemInitializer;
        if (windowingSubsystem == null)
        {
            throw new InvalidOperationException(
                "WithOptrisStaticGraphics() has to be chained after the windowing subsystem is " +
                "selected, for example AppBuilder.Configure<App>().UsePlatformDetect()" +
                ".WithOptrisStaticGraphics(). The rendering modes it inspects do not exist yet " +
                "before that point.");
        }

        // The rendering mode is picked while the windowing subsystem initialises, and every
        // public hook Avalonia offers (AfterPlatformServicesSetup, AfterSetup) runs after the
        // platform graphics have already been created. Wrapping the initialiser is the last
        // moment at which the options are both bound and still unread.
        return builder.UseWindowingSubsystem(
            delegate
            {
                try
                {
                    Inspect(policy);
                }
                catch (InvalidOperationException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    // A guard must never be the reason an app fails to start.
                    Log(LogEventLevel.Warning, "Optris.StaticGraphics guard did not run: " + ex.Message);
                }

                windowingSubsystem();
            },
            builder.WindowingSubsystemName);
    }

    private static void Inspect(OptrisBackendPolicy policy)
    {
        if (OperatingSystem.IsWindows())
        {
            InspectWindows(policy);
        }
        else if (OperatingSystem.IsLinux())
        {
            InspectX11(policy);
        }
        else if (OperatingSystem.IsMacOS())
        {
            InspectAvaloniaNative(policy);
        }
    }

    private static void InspectWindows(OptrisBackendPolicy policy)
    {
        var options = Resolve(typeof(Win32PlatformOptions)) as Win32PlatformOptions;
        var configured = options != null;
        var modes = configured ? options.RenderingMode : new Win32PlatformOptions().RenderingMode;

        var kept = new List<Win32RenderingMode>();
        var dropped = new List<string>();
        var droppedTopBackend = false;
        foreach (var mode in modes)
        {
            var backend = BackendOf(mode);
            if (IsAvailable(backend))
            {
                kept.Add(mode);
                continue;
            }

            dropped.Add(mode.ToString());
            droppedTopBackend |= backend == VulkanBackend;
        }

        if (dropped.Count == 0)
        {
            return;
        }

        if (Report(policy, "Win32PlatformOptions", configured, dropped, droppedTopBackend))
        {
            if (kept.Count == 0)
            {
                kept.Add(Win32RenderingMode.Software);
            }

            options.RenderingMode = kept;
        }
    }

    private static void InspectX11(OptrisBackendPolicy policy)
    {
        var options = Resolve(typeof(X11PlatformOptions)) as X11PlatformOptions;
        var configured = options != null;
        var modes = configured ? options.RenderingMode : new X11PlatformOptions().RenderingMode;

        var kept = new List<X11RenderingMode>();
        var dropped = new List<string>();
        var droppedTopBackend = false;
        foreach (var mode in modes)
        {
            var backend = BackendOf(mode);
            if (IsAvailable(backend))
            {
                kept.Add(mode);
                continue;
            }

            dropped.Add(mode.ToString());
            droppedTopBackend |= backend == VulkanBackend;
        }

        if (dropped.Count == 0)
        {
            return;
        }

        if (Report(policy, "X11PlatformOptions", configured, dropped, droppedTopBackend))
        {
            if (kept.Count == 0)
            {
                kept.Add(X11RenderingMode.Software);
            }

            options.RenderingMode = kept;
        }
    }

    private static void InspectAvaloniaNative(OptrisBackendPolicy policy)
    {
        // MacOSPlatformOptions carries no rendering mode; on macOS the renderer is chosen through
        // AvaloniaNativePlatformOptions, which is what UseAvaloniaNative() reads.
        var options = Resolve(typeof(AvaloniaNativePlatformOptions)) as AvaloniaNativePlatformOptions;
        var configured = options != null;
        var modes = configured
            ? options.RenderingMode
            : new AvaloniaNativePlatformOptions().RenderingMode;

        var kept = new List<AvaloniaNativeRenderingMode>();
        var dropped = new List<string>();
        var droppedTopBackend = false;
        foreach (var mode in modes)
        {
            var backend = BackendOf(mode);
            if (IsAvailable(backend))
            {
                kept.Add(mode);
                continue;
            }

            dropped.Add(mode.ToString());
            droppedTopBackend |= backend == VulkanBackend;
        }

        if (dropped.Count == 0)
        {
            return;
        }

        if (Report(policy, "AvaloniaNativePlatformOptions", configured, dropped, droppedTopBackend))
        {
            if (kept.Count == 0)
            {
                kept.Add(AvaloniaNativeRenderingMode.Software);
            }

            options.RenderingMode = kept;
        }
    }

    private static string BackendOf(Win32RenderingMode mode)
    {
        switch (mode)
        {
            case Win32RenderingMode.Software:
                return SoftwareBackend;
            case Win32RenderingMode.AngleEgl:
            case Win32RenderingMode.Wgl:
                return OpenGLBackend;
            case Win32RenderingMode.Vulkan:
                return VulkanBackend;
            default:
                return null;
        }
    }

    private static string BackendOf(X11RenderingMode mode)
    {
        switch (mode)
        {
            case X11RenderingMode.Software:
                return SoftwareBackend;
            case X11RenderingMode.Glx:
            case X11RenderingMode.Egl:
                return OpenGLBackend;
            case X11RenderingMode.Vulkan:
                return VulkanBackend;
            default:
                return null;
        }
    }

    private static string BackendOf(AvaloniaNativeRenderingMode mode)
    {
        switch (mode)
        {
            case AvaloniaNativeRenderingMode.Software:
                return SoftwareBackend;
            case AvaloniaNativeRenderingMode.OpenGl:
                return OpenGLBackend;
            // Skia does not vendor MoltenVK, so the top tier reaches Apple GPUs through Metal
            // instead of Vulkan. The build scripts compile Metal in for exactly that tier.
            case AvaloniaNativeRenderingMode.Metal:
                return VulkanBackend;
            default:
                return null;
        }
    }

    private static bool IsAvailable(string backend)
    {
        // A rendering mode added by a newer Avalonia than this package cannot be classified, and
        // refusing to run on it would be worse than letting Avalonia probe it as it always has.
        if (backend == null)
        {
            return true;
        }

        foreach (var available in AvailableBackends)
        {
            if (string.Equals(available, backend, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Returns true when the caller should write the filtered rendering modes back.
    /// </summary>
    private static bool Report(
        OptrisBackendPolicy policy,
        string optionsTypeName,
        bool configured,
        List<string> dropped,
        bool droppedTopBackend)
    {
        var modes = string.Join(", ", dropped.ToArray());
        var tier = OptrisStaticGraphicsTierInfo.PackageId + " links graphics tier '" +
                   OptrisStaticGraphicsTierInfo.Tier + "' (" +
                   OptrisStaticGraphicsTierInfo.Backends.Replace(";", ", ") + ")";
        var upgrade = "Optris.StaticGraphics.Avalonia." +
                      (droppedTopBackend ? VulkanBackend : OpenGLBackend);

        if (configured)
        {
            if (policy == OptrisBackendPolicy.Strict)
            {
                throw new InvalidOperationException(
                    tier + ", but " + optionsTypeName + ".RenderingMode asks for " + modes +
                    ". Skia has no such backend compiled in, so the window would stay blank " +
                    "instead of falling back. Reference " + upgrade +
                    ", drop the mode, or pass OptrisBackendPolicy.Filter to " +
                    "WithOptrisStaticGraphics() to have it removed at startup.");
            }

            Log(
                LogEventLevel.Warning,
                tier + ", so " + modes + " was removed from " + optionsTypeName +
                ".RenderingMode. Reference " + upgrade + " to render with it.");
            return true;
        }

        // Nothing was bound, so the platform will build its own default options object after this
        // point and there is no public API to reach into it. Only the top GPU backend is worth
        // failing over: Avalonia's own probe fails cleanly for the modes below it and moves on,
        // while Vulkan and Metal initialise successfully and only then hand back a null Skia
        // context - the blank window this package exists to prevent.
        var fix = "Configure " + optionsTypeName + " explicitly (AppBuilder.With(new " +
                  optionsTypeName + " { RenderingMode = ... })) before WithOptrisStaticGraphics() " +
                  "so the unavailable modes can be removed.";

        if (droppedTopBackend)
        {
            if (policy == OptrisBackendPolicy.Strict)
            {
                throw new InvalidOperationException(
                    tier + ", but the platform default for " + optionsTypeName +
                    " tries " + modes + " first. " + fix);
            }

            Log(
                LogEventLevel.Warning,
                tier + ", but the platform default for " + optionsTypeName + " tries " + modes +
                " first and cannot be rewritten from here. " + fix);
            return false;
        }

        Log(
            LogEventLevel.Information,
            tier + ", so the platform default " + modes + " for " + optionsTypeName +
            " will fail its probe and fall through to the next mode. " + fix);
        return false;
    }

    // Avalonia's reference assembly hides AvaloniaLocator's members while the implementation
    // keeps them public (checked on 11.3 and 12.1), and there is no other way to read the options
    // an app configured: With<T>() only binds them, and every callback that could read them back
    // runs after the platform graphics exist. Both lookups are typeof() plus a literal name,
    // which the trimmer and NativeAOT recognise and preserve, and anything unexpected leaves the
    // guard inert instead of breaking startup.
    private static object Resolve(Type serviceType)
    {
        var currentProperty = typeof(AvaloniaLocator).GetProperty("Current");
        if (currentProperty == null)
        {
            return null;
        }

        if (!(currentProperty.GetValue(null) is AvaloniaLocator locator))
        {
            return null;
        }

        var getService = typeof(AvaloniaLocator).GetMethod("GetService", new Type[] { typeof(Type) });
        if (getService == null)
        {
            return null;
        }

        return getService.Invoke(locator, new object[] { serviceType });
    }

    private static void Log(LogEventLevel level, string message)
    {
        var logger = Logger.TryGet(level, LogArea.Platform);
        if (logger.HasValue)
        {
            logger.Value.Log(null, message);
        }
    }
}
