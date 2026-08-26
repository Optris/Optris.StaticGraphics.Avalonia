using System.Text;

namespace Optris.StaticGraphics.Smoke;

/// <summary>
/// Accumulates everything the run observed and prints it once, whatever the outcome.
/// </summary>
/// <remarks>
/// A passing run prints as much as a failing one on purpose: the log of a green build is the only
/// record anyone has of which backend the machine really used.
/// </remarks>
internal sealed class SmokeReport
{
    private readonly StringBuilder _body = new();
    private readonly List<string> _failures = [];
    private readonly object _gate = new();
    private string? _section;
    private int _emitted;

    public string Tier { get; set; } = "unknown";

    public string RequestedBackend { get; set; } = "unknown";

    public string ObservedBackend { get; set; } = "nothing observed";

    public IReadOnlyList<string> Failures => _failures;

    public void Line(string text)
    {
        lock (_gate)
        {
            _body.AppendLine(text);
        }
    }

    public void Section(string title)
    {
        lock (_gate)
        {
            _section = title;
            _body.AppendLine();
            _body.AppendLine($"-- {title}");
        }
    }

    public void Check(CheckResult result)
    {
        Line($"   [{(result.Passed ? "ok" : "FAIL")}] {result.Name}: {result.Detail}");
        if (!result.Passed)
        {
            lock (_gate)
            {
                // Prefixed with the section: the same check runs in the offscreen and the window pass,
                // and the summary at the bottom is where someone reading a CI log starts.
                _failures.Add(Prefixed($"{result.Name}: {result.Detail}"));
            }
        }
    }

    public void Fail(string text)
    {
        Line($"   [FAIL] {text}");
        lock (_gate)
        {
            _failures.Add(Prefixed(text));
        }
    }

    private string Prefixed(string text) => _section is null ? text : $"[{_section}] {text}";

    /// <summary>
    /// Prints the report and returns the exit code, at most once per process.
    /// </summary>
    public int Emit(int exitCode, string? reportPath)
    {
        if (Interlocked.Exchange(ref _emitted, 1) == 1)
        {
            return exitCode;
        }

        var text = new StringBuilder();
        text.AppendLine("Optris static graphics smoke");
        lock (_gate)
        {
            text.Append(_body);
        }

        text.AppendLine();
        var outcome = exitCode == ExitCodes.Pass ? "PASS" : "FAIL";
        text.AppendLine($"{outcome} tier={Tier} requested-backend={RequestedBackend} observed={ObservedBackend} exit={exitCode}");

        lock (_gate)
        {
            foreach (var failure in _failures)
            {
                text.AppendLine($"  - {failure}");
            }
        }

        var rendered = text.ToString();
        Console.Out.Write(rendered);
        Console.Out.Flush();

        if (exitCode != ExitCodes.Pass)
        {
            Console.Error.WriteLine($"{outcome} tier={Tier} requested-backend={RequestedBackend} observed={ObservedBackend} exit={exitCode}");
            Console.Error.Flush();
        }

        if (!string.IsNullOrEmpty(reportPath))
        {
            try
            {
                var directory = Path.GetDirectoryName(Path.GetFullPath(reportPath));
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                File.WriteAllText(reportPath, rendered);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Could not write the report to '{reportPath}': {ex.Message}");
            }
        }

        return exitCode;
    }
}
