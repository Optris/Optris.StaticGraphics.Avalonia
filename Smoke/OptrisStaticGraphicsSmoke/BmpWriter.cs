namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// Writes the captured frame as a 32-bit BMP.
/// </summary>
/// <remarks>
/// BMP and not PNG on purpose: the frame dump is a debugging aid for a failed run, and it must not
/// depend on the very encoder whose library is under test. Forty bytes of header and the pixels the
/// probe already holds cannot fail in an interesting way.
/// </remarks>
internal static class BmpWriter
{
    public static void Write(string path, CapturedFrame frame)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var stride = frame.Width * 4;
        var pixelBytes = stride * frame.Height;

        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write);
        using var writer = new BinaryWriter(stream);

        writer.Write((byte)'B');
        writer.Write((byte)'M');
        writer.Write(14 + 40 + pixelBytes);
        writer.Write(0);
        writer.Write(14 + 40);

        writer.Write(40);
        writer.Write(frame.Width);
        writer.Write(frame.Height);
        writer.Write((short)1);
        writer.Write((short)32);
        writer.Write(0);
        writer.Write(pixelBytes);
        writer.Write(2835);
        writer.Write(2835);
        writer.Write(0);
        writer.Write(0);

        // BMP rows run bottom-up; the readback is top-down and already BGRA.
        for (var y = frame.Height - 1; y >= 0; y--)
        {
            writer.Write(frame.Pixels, y * stride, stride);
        }
    }
}
