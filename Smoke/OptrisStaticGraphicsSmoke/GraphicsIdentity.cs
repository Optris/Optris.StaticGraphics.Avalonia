using Avalonia.Metal;
using Avalonia.OpenGL;
using Avalonia.Platform;
using Avalonia.Vulkan;

namespace Optris.StaticGraphics.Smoke;

/// <summary>What the frame was actually drawn with, as opposed to what was asked for.</summary>
internal readonly record struct ObservedGraphics(Backend? Backend, string Name, string Detail);

internal static class GraphicsIdentity
{
    /// <summary>
    /// Identifies the context Skia was handed for this frame.
    /// </summary>
    /// <remarks>
    /// Cast to Avalonia's public backend interfaces rather than matching type names: those interfaces
    /// are the contract, the concrete types are not, and a wrong answer here would let a run that
    /// quietly fell back to something else report success.
    /// </remarks>
    public static ObservedGraphics FromPlatformContext(IPlatformGraphicsContext? context)
    {
        switch (context)
        {
            case null:
                return new ObservedGraphics(Backend.Software, "Software", "no platform graphics context; Skia drew into a raster surface");

            case IVulkanPlatformGraphicsContext vulkan:
            {
                var detail = "Vulkan context";
                try
                {
                    detail = $"instance 0x{vulkan.Instance.Handle:X}, physical device 0x{vulkan.Device.PhysicalDeviceHandle:X}, " +
                             $"graphics queue family {vulkan.Device.GraphicsQueueFamilyIndex}";
                }
                catch (Exception ex)
                {
                    detail = $"Vulkan context, details unreadable ({ex.GetType().Name})";
                }

                return new ObservedGraphics(Backend.Vulkan, "Vulkan", detail);
            }

            case IGlContext gl:
            {
                var detail = "OpenGL context";
                try
                {
                    var version = gl.Version;
                    var profile = version.Type == GlProfileType.OpenGLES ? "OpenGL ES" : "OpenGL";
                    detail = $"{profile} {version.Major}.{version.Minor}, vendor '{gl.GlInterface.Vendor}', renderer '{gl.GlInterface.Renderer}'";
                }
                catch (Exception ex)
                {
                    detail = $"OpenGL context, details unreadable ({ex.GetType().Name})";
                }

                return new ObservedGraphics(Backend.OpenGL, "OpenGL", detail);
            }

            case IMetalDevice:
                return new ObservedGraphics(null, "Metal", "Metal device; the tiers do not cover Metal");

            default:
                return new ObservedGraphics(null, context.GetType().Name, $"unrecognised platform graphics context {context.GetType().FullName}");
        }
    }

}
