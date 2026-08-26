namespace Optris.StaticGraphics.Smoke;

internal sealed record CheckResult(string Name, bool Passed, string Detail);

/// <summary>
/// Turns a captured frame into a verdict. Nothing here knows about backends: it only answers
/// "is this the picture the scene describes, or is it the picture a broken backend produces".
/// </summary>
internal static class FrameAnalysis
{
    public static List<CheckResult> Inspect(CapturedFrame frame, bool requireText)
    {
        var results = new List<CheckResult>();
        var (distinct, dominant, dominantShare) = Histogram(frame);

        results.Add(new CheckResult(
            "frame is not one flat colour",
            distinct > 1,
            distinct > 1
                ? $"{distinct} distinct colours, most common {Hex(dominant)} covering {dominantShare:P1} of {frame.Width}x{frame.Height} pixels"
                : $"every one of the {frame.Width}x{frame.Height} pixels is {Hex(dominant)} - this is what a window that never painted looks like"));

        results.Add(new CheckResult(
            $"frame has at least {SceneGeometry.MinimumDistinctColours} distinct colours",
            distinct >= SceneGeometry.MinimumDistinctColours,
            $"{distinct} distinct colours"));

        foreach (var spot in SceneGeometry.Spots)
        {
            var x = ToPixel(spot.X, frame.Width);
            var y = ToPixel(spot.Y, frame.Height);
            var actual = PixelAt(frame, x, y);
            var matches = Close(actual, spot.ExpectedArgb, SceneGeometry.ChannelTolerance);
            results.Add(new CheckResult(
                $"{spot.Name} is {Hex(spot.ExpectedArgb)}",
                matches,
                matches
                    ? $"{Hex(actual)} at {x},{y}"
                    : $"expected {Hex(spot.ExpectedArgb)} at {x},{y} but read {Hex(actual)}"));
        }

        var band = SceneGeometry.TextBand;
        var textPixels = CountMatchingPixels(frame, band, SceneGeometry.Caption, SceneGeometry.CaptionTolerance);
        var textPassed = textPixels >= SceneGeometry.MinimumTextPixels;
        results.Add(new CheckResult(
            $"{band.Name} band contains glyphs",
            textPassed || !requireText,
            textPassed
                ? $"{textPixels} pixels of {Hex(SceneGeometry.Caption)} glyph"
                : $"only {textPixels} pixels of {Hex(SceneGeometry.Caption)} in the band; the fills drew but the text did not, " +
                  $"which usually means the font stack is unreachable{(requireText ? string.Empty : " (not required, OPTRIS_SMOKE_REQUIRE_TEXT is off)")}"));

        return results;
    }

    private static (int Distinct, uint Dominant, double DominantShare) Histogram(CapturedFrame frame)
    {
        // Capped: past a few thousand colours the only question left ("is this frame uniform") is
        // already answered, and an unbounded dictionary over a 4K surface is not worth the memory.
        const int cap = 4096;
        var counts = new Dictionary<uint, int>(capacity: 64);
        var total = frame.Width * frame.Height;
        var overflow = false;

        for (var y = 0; y < frame.Height; y++)
        {
            for (var x = 0; x < frame.Width; x++)
            {
                var colour = PixelAt(frame, x, y);
                if (counts.TryGetValue(colour, out var count))
                {
                    counts[colour] = count + 1;
                }
                else if (counts.Count < cap)
                {
                    counts[colour] = 1;
                }
                else
                {
                    overflow = true;
                }
            }
        }

        var dominant = 0u;
        var dominantCount = 0;
        foreach (var (colour, count) in counts)
        {
            if (count > dominantCount)
            {
                dominant = colour;
                dominantCount = count;
            }
        }

        var distinct = overflow ? cap : counts.Count;
        return (distinct, dominant, total == 0 ? 0 : (double)dominantCount / total);
    }

    private static int CountMatchingPixels(CapturedFrame frame, ProbeBand band, uint reference, int tolerance)
    {
        var x0 = ToPixel(band.X0, frame.Width);
        var x1 = ToPixel(band.X1, frame.Width);
        var y0 = ToPixel(band.Y0, frame.Height);
        var y1 = ToPixel(band.Y1, frame.Height);
        var matching = 0;

        for (var y = y0; y <= y1; y++)
        {
            for (var x = x0; x <= x1; x++)
            {
                if (Close(PixelAt(frame, x, y), reference, tolerance))
                {
                    matching++;
                }
            }
        }

        return matching;
    }

    private static int ToPixel(double fraction, int size) =>
        Math.Clamp((int)Math.Round(fraction * (size - 1)), 0, size - 1);

    private static uint PixelAt(CapturedFrame frame, int x, int y)
    {
        var offset = ((y * frame.Width) + x) * 4;
        var b = frame.Pixels[offset];
        var g = frame.Pixels[offset + 1];
        var r = frame.Pixels[offset + 2];
        var a = frame.Pixels[offset + 3];
        return ((uint)a << 24) | ((uint)r << 16) | ((uint)g << 8) | b;
    }

    private static bool Close(uint actual, uint expected, int tolerance) =>
        Math.Abs((int)((actual >> 16) & 0xFF) - (int)((expected >> 16) & 0xFF)) <= tolerance &&
        Math.Abs((int)((actual >> 8) & 0xFF) - (int)((expected >> 8) & 0xFF)) <= tolerance &&
        Math.Abs((int)(actual & 0xFF) - (int)(expected & 0xFF)) <= tolerance &&
        Math.Abs((int)((actual >> 24) & 0xFF) - (int)((expected >> 24) & 0xFF)) <= tolerance;

    public static string Hex(uint argb) => $"#{argb:X8}";
}
