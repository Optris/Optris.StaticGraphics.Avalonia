namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// Where the scene's colours are and what they are, in fractions of the scene's own box.
/// </summary>
/// <remarks>
/// Fractions, not pixels: the same numbers then hold for the offscreen render at 96 dpi and for a
/// window on a 150% display, and the readback maps them through Skia's own canvas matrix.
/// SmokeScene.axaml lays the scene out on a 4x4 star grid, so every spot below sits in the middle of
/// one cell. Changing the grid means changing these fractions.
/// </remarks>
internal static class SceneGeometry
{
    public const double Width = 480;
    public const double Height = 320;

    public const uint Background = 0xFF101A33;
    public const uint Green = 0xFF00A000;
    public const uint Red = 0xFFC00000;
    public const uint Blue = 0xFF0060FF;
    public const uint Caption = 0xFFFFFFFF;

    /// <summary>How far each channel may drift before a spot counts as the wrong colour.</summary>
    public const int ChannelTolerance = 20;

    public static readonly ProbeSpot[] Spots =
    [
        new("green square", 0.375, 0.375, Green),
        new("red square", 0.625, 0.625, Red),
        new("blue square", 0.875, 0.375, Blue),
        new("background above the squares", 0.125, 0.125, Background),
        new("background left of the squares", 0.125, 0.625, Background),
    ];

    /// <summary>
    /// The band the caption is drawn in. Text is checked as "glyph-coloured pixels are here", never
    /// pixel by pixel: glyph rasterisation differs per platform, but a missing font stack leaves the
    /// band with nothing in it at all.
    /// </summary>
    public static readonly ProbeBand TextBand = new("caption", 0.05, 0.78, 0.95, 0.98);

    /// <summary>Glyph edges are antialiased against the background, so only cores are counted.</summary>
    public const int CaptionTolerance = 32;

    /// <summary>Distinct colours the scene must contain: four fills, before any antialiasing.</summary>
    public const int MinimumDistinctColours = 4;

    /// <summary>Pixels in the caption band that must differ from the background.</summary>
    public const int MinimumTextPixels = 32;
}

internal readonly record struct ProbeSpot(string Name, double X, double Y, uint ExpectedArgb);

internal readonly record struct ProbeBand(string Name, double X0, double Y0, double X1, double Y1);
