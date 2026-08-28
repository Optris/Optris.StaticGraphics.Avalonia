namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// The backends a run can be forced onto: the three tier names of the package contract, richest
/// first, and then Metal.
/// </summary>
/// <remarks>
/// The three tier names are ordered so that a tier supports every backend whose value is greater
/// than or equal to its own: each tier is a strict superset of the one below it.
/// Metal sits outside that order on purpose and is ranked by <see cref="SmokeOptions.TierOf"/>
/// instead, because it is not a fourth tier - see its own note below.
/// </remarks>
internal enum Backend
{
    Vulkan = 0,
    OpenGL = 1,
    Software = 2,

    /// <summary>
    /// The Vulkan tier's GPU backend on macOS.
    /// </summary>
    /// <remarks>
    /// Vulkan only reaches Apple hardware through MoltenVK, which Skia does not vendor, so the top
    /// tier is built with skia_use_metal and its frames come out of GrMtlGpu. The tier is still
    /// spelled "Vulkan" in package ids and in what the payload advertises - Metal is what that name
    /// is made of here, which is why it is a backend and never a tier.
    /// </remarks>
    Metal = 3,
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

    /// <summary>
    /// The tier that carries a backend, which is the rank the superset ordering is compared on.
    /// </summary>
    /// <remarks>
    /// Every backend names its own tier except Metal, which has no tier of its own: it ships inside
    /// the Vulkan payload, so the Vulkan tier carries it and the two below it do not. Ranking it
    /// here rather than by its enum value is what keeps "Software tier, Metal backend" a refusal.
    /// </remarks>
    public static Backend TierOf(Backend backend) => backend == Backend.Metal ? Backend.Vulkan : backend;

    public static IReadOnlyList<Backend> BackendsOf(Backend tier) =>
        Enum.GetValues<Backend>().Where(backend => TierOf(backend) >= tier).ToArray();

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

        // Metal parses as a backend but is not a tier and never names a package: the payload that
        // renders with it is the Vulkan one, so accepting it here would invent a fourth tier.
        if (!TryParseBackend(tierText, out var tier) || tier == Backend.Metal)
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
            error = $"OPTRIS_SMOKE_BACKEND='{backendText}' is not one of Vulkan, OpenGL, Software, Metal.";
            return null;
        }

        if (TierOf(backend) < tier)
        {
            error = $"The {tier} tier does not carry a {backend} backend. It supports {Describe(BackendsOf(tier))}.";
            return null;
        }

        // A backend is advertised under the name of the tier that carries it, so Metal is looked up
        // as Vulkan: the payload built with skia_use_metal is the Vulkan payload, and "Metal" never
        // appears in the list the package writes.
        var advertisedAs = TierOf(backend);
        if (linkedBackends is not null &&
            !linkedBackends.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Any(entry => entry.Equals(advertisedAs.ToString(), StringComparison.OrdinalIgnoreCase)))
        {
            var missing = advertisedAs == backend ? backend.ToString() : $"{advertisedAs}, which is what carries {backend}";
            error = $"The linked package advertises backends '{linkedBackends}', which does not include {missing}.";
            return null;
        }

        // A backend the platform cannot have is refused outright. Letting the run continue would mean
        // rendering with something else and reporting on the name that was asked for, which is the
        // exact substitution this app exists to catch.
        if (backend == Backend.Vulkan && OperatingSystem.IsMacOS())
        {
            error = "Avalonia has no Vulkan backend on macOS, so a Vulkan run here would prove nothing. " +
                    "Metal is what the Vulkan tier is made of on this platform - Skia does not vendor " +
                    "MoltenVK, so the tier is built with skia_use_metal and draws through GrMtlGpu. " +
                    "Run OPTRIS_SMOKE_BACKEND=Metal for the top backend, then OpenGL and Software.";
            return null;
        }

        if (backend == Backend.Metal && !OperatingSystem.IsMacOS())
        {
            error = "Metal exists only on Apple platforms, so a Metal run here would prove nothing. " +
                    "Metal is how the Vulkan tier renders on macOS; everywhere else that tier renders " +
                    "with Vulkan itself. Run OPTRIS_SMOKE_BACKEND=Vulkan for the top backend here.";
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
