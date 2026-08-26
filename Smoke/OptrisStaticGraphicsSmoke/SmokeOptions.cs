namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// The three tier names of the package contract, richest first.
/// </summary>
/// <remarks>
/// Ordered so that a tier supports every backend whose value is greater than or equal to its own:
/// each tier is a strict superset of the one below it.
/// </remarks>
internal enum Backend
{
    Vulkan = 0,
    OpenGL = 1,
    Software = 2,
}

internal enum SelfTest
{
    None,
    Blank,
    Uniform,
}

internal static class ExitCodes
{
    public const int Pass = 0;
    public const int Failed = 1;
    public const int NoFrame = 2;
    public const int Configuration = 3;
    public const int Startup = 4;
}

internal sealed class SmokeOptions
{
    public required Backend Tier { get; init; }

    /// <summary>Where the tier came from, so a mix-up is traceable in the log.</summary>
    public required string TierSource { get; init; }

    public required Backend RequestedBackend { get; init; }

    public required TimeSpan Timeout { get; init; }

    public required bool RequireText { get; init; }

    public required SelfTest SelfTest { get; init; }

    public required int FrameAttempts { get; init; }

    public string? FramePath { get; init; }

    public string? ReportPath { get; init; }

    public string? LinkedTier { get; init; }

    public string? LinkedBackends { get; init; }

    public static IReadOnlyList<Backend> BackendsOf(Backend tier) =>
        Enum.GetValues<Backend>().Where(backend => backend >= tier).ToArray();

    public static string Describe(IEnumerable<Backend> backends) => string.Join(";", backends);

    /// <summary>
    /// Reads the run's configuration from the environment, or explains why it cannot.
    /// </summary>
    public static SmokeOptions? FromEnvironment(out string? error)
    {
        error = null;

        var linkedTier = Nullify(LinkedPackage.Tier);
        var linkedBackends = Nullify(LinkedPackage.Backends);
        var tierText = Nullify(Environment.GetEnvironmentVariable("OPTRIS_SMOKE_TIER"));
        var tierSource = tierText is null ? "the linked package" : "OPTRIS_SMOKE_TIER";
        tierText ??= linkedTier;

        if (tierText is null)
        {
            error = "The tier under test is unknown: no OPTRIS_SMOKE_TIER in the environment and no tier " +
                    "baked in by an Optris.StaticGraphics.Avalonia.* package reference. Refusing to guess - " +
                    "a smoke run that cannot name its tier cannot check it.";
            return null;
        }

        if (!TryParseBackend(tierText, out var tier))
        {
            error = $"OPTRIS_SMOKE_TIER='{tierText}' is not one of Vulkan, OpenGL, Software.";
            return null;
        }

        // The env var says what CI meant to test; the package says what the linker actually pulled in.
        if (linkedTier is not null && tierSource == "OPTRIS_SMOKE_TIER" &&
            !linkedTier.Equals(tier.ToString(), StringComparison.OrdinalIgnoreCase))
        {
            error = $"OPTRIS_SMOKE_TIER says '{tier}' but the linked package says '{linkedTier}'. " +
                    "The wrong tier package is referenced, or the wrong tier is being tested.";
            return null;
        }

        var backendText = Nullify(Environment.GetEnvironmentVariable("OPTRIS_SMOKE_BACKEND"));
        var backend = tier;
        if (backendText is not null && !TryParseBackend(backendText, out backend))
        {
            error = $"OPTRIS_SMOKE_BACKEND='{backendText}' is not one of Vulkan, OpenGL, Software.";
            return null;
        }

        if (backend < tier)
        {
            error = $"The {tier} tier does not carry a {backend} backend. It supports {Describe(BackendsOf(tier))}.";
            return null;
        }

        if (linkedBackends is not null &&
            !linkedBackends.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Any(entry => entry.Equals(backend.ToString(), StringComparison.OrdinalIgnoreCase)))
        {
            error = $"The linked package advertises backends '{linkedBackends}', which does not include {backend}.";
            return null;
        }

        if (backend == Backend.Vulkan && OperatingSystem.IsMacOS())
        {
            error = "Avalonia has no Vulkan backend on macOS, so a Vulkan run here would prove nothing. " +
                    "Run OPTRIS_SMOKE_BACKEND=OpenGL and OPTRIS_SMOKE_BACKEND=Software on macOS.";
            return null;
        }

        if (!TryParseSelfTest(Environment.GetEnvironmentVariable("OPTRIS_SMOKE_SELFTEST"), out var selfTest))
        {
            error = "OPTRIS_SMOKE_SELFTEST must be unset, 'blank' or 'uniform'.";
            return null;
        }

        var timeout = TimeSpan.FromSeconds(30);
        var timeoutText = Nullify(Environment.GetEnvironmentVariable("OPTRIS_SMOKE_TIMEOUT_SECONDS"));
        if (timeoutText is not null)
        {
            if (!double.TryParse(timeoutText, System.Globalization.CultureInfo.InvariantCulture, out var seconds) || seconds <= 0)
            {
                error = $"OPTRIS_SMOKE_TIMEOUT_SECONDS='{timeoutText}' is not a positive number of seconds.";
                return null;
            }

            timeout = TimeSpan.FromSeconds(seconds);
        }

        return new SmokeOptions
        {
            Tier = tier,
            TierSource = tierSource,
            RequestedBackend = backend,
            Timeout = timeout,
            RequireText = ReadFlag("OPTRIS_SMOKE_REQUIRE_TEXT", true),
            SelfTest = selfTest,
            FrameAttempts = 3,
            FramePath = Nullify(Environment.GetEnvironmentVariable("OPTRIS_SMOKE_FRAME")),
            ReportPath = Nullify(Environment.GetEnvironmentVariable("OPTRIS_SMOKE_REPORT")),
            LinkedTier = linkedTier,
            LinkedBackends = linkedBackends,
        };
    }

    private static bool TryParseBackend(string text, out Backend backend)
    {
        backend = default;
        text = text.Trim();

        // Enum.TryParse would also accept "0", and a tier that came out of a typo as Vulkan is
        // exactly the kind of quiet wrong answer this app is against.
        return !char.IsDigit(text.FirstOrDefault()) &&
               Enum.TryParse(text, ignoreCase: true, out backend) &&
               Enum.IsDefined(backend);
    }

    private static bool TryParseSelfTest(string? text, out SelfTest selfTest)
    {
        selfTest = SelfTest.None;
        text = Nullify(text);
        return text is null || (Enum.TryParse(text, ignoreCase: true, out selfTest) && Enum.IsDefined(selfTest));
    }

    private static bool ReadFlag(string name, bool fallback)
    {
        var text = Nullify(Environment.GetEnvironmentVariable(name));
        return text is null ? fallback : text is "1" or "true" or "True" or "TRUE" or "yes";
    }

    private static string? Nullify(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}
