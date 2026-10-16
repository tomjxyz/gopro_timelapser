using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace GoProTimelapser;

public enum EncoderChoice
{
    Auto,
    QuickSync,
    Software,
}

public sealed class TimelapseSettings
{
    public required IReadOnlyList<string> Inputs { get; init; }
    public required string OutputPath { get; init; }
    public required int Speed { get; init; }
    /// <summary>Target height in pixels, or null to keep the source resolution.</summary>
    public int? Height { get; init; }
    /// <summary>CRF / ICQ value, lower = better quality (18-40).</summary>
    public required int Quality { get; init; }
    public required int Fps { get; init; }
    public required EncoderChoice Encoder { get; init; }
    /// <summary>Total input duration, for progress reporting.</summary>
    public TimeSpan TotalDuration { get; init; }
}

/// <summary>
/// One way of driving ffmpeg. Auto mode tries these in order until one succeeds.
/// </summary>
public enum Strategy
{
    /// <summary>QuickSync decode + scale + encode, all on the GPU.</summary>
    QsvFull,
    /// <summary>Software decode/scale, QuickSync encode (for clips the iGPU can't decode).</summary>
    QsvEncodeOnly,
    /// <summary>libx264 on the CPU.</summary>
    Software,
}

public sealed class TimelapseJob
{
    private readonly TimelapseSettings _s;
    private Process? _proc;
    private volatile bool _cancelled;

    public event Action<string>? Log;
    /// <summary>Progress 0..1 and the current encoding speed reported by ffmpeg (e.g. "3.2x").</summary>
    public event Action<double, string>? Progress;

    public TimelapseJob(TimelapseSettings settings) => _s = settings;

    public static IReadOnlyList<Strategy> StrategiesFor(EncoderChoice choice) => choice switch
    {
        EncoderChoice.QuickSync => [Strategy.QsvFull, Strategy.QsvEncodeOnly],
        EncoderChoice.Software => [Strategy.Software],
        _ => [Strategy.QsvFull, Strategy.QsvEncodeOnly, Strategy.Software],
    };

    public void Cancel()
    {
        _cancelled = true;
        try { _proc?.Kill(entireProcessTree: true); } catch { }
    }

    /// <summary>Runs the job; returns the strategy that succeeded.</summary>
    public async Task<Strategy> RunAsync()
    {
        var ffmpeg = FfmpegLocator.Locate();
        var listFile = Path.Combine(Path.GetTempPath(), $"gopro_timelapser_{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(listFile, BuildConcatList(_s.Inputs), new UTF8Encoding(false));

        try
        {
            var strategies = StrategiesFor(_s.Encoder);
            for (int i = 0; i < strategies.Count; i++)
            {
                var strat = strategies[i];
                var args = BuildArguments(_s, listFile, strat);
                Log?.Invoke($"--- Trying {Describe(strat)} ---");
                Log?.Invoke("ffmpeg " + string.Join(' ', args.Select(Quote)));

                int code = await RunFfmpegAsync(ffmpeg, args);
                if (_cancelled) throw new OperationCanceledException();
                if (code == 0) return strat;

                Log?.Invoke($"ffmpeg exited with code {code} using {Describe(strat)}.");
                if (i < strategies.Count - 1) Log?.Invoke("Falling back...");
            }
            throw new InvalidOperationException("All encoding methods failed. See the log for details.");
        }
        catch
        {
            TryDelete(_s.OutputPath);
            throw;
        }
        finally
        {
            TryDelete(listFile);
        }
    }

    public static string Describe(Strategy s) => s switch
    {
        Strategy.QsvFull => "Intel QuickSync (GPU decode + encode)",
        Strategy.QsvEncodeOnly => "Intel QuickSync (CPU decode, GPU encode)",
        _ => "Software x264 (CPU)",
    };

    public static string BuildConcatList(IEnumerable<string> inputs)
    {
        var sb = new StringBuilder("ffconcat version 1.0\n");
        foreach (var f in inputs)
        {
            // ffconcat quoting: wrap in single quotes, escape embedded ' as '\''
            var full = Path.GetFullPath(f).Replace("\\", "/");
            sb.Append("file '").Append(full.Replace("'", "'\\''")).Append("'\n");
        }
        return sb.ToString();
    }

    public static List<string> BuildArguments(TimelapseSettings s, string listFile, Strategy strat)
    {
        var a = new List<string> { "-hide_banner", "-nostdin", "-y" };
        var speed = s.Speed.ToString(CultureInfo.InvariantCulture);
        var fps = s.Fps.ToString(CultureInfo.InvariantCulture);
        var q = s.Quality.ToString(CultureInfo.InvariantCulture);

        if (strat == Strategy.QsvFull)
            a.AddRange(["-hwaccel", "qsv", "-hwaccel_output_format", "qsv"]);

        a.AddRange(["-f", "concat", "-safe", "0", "-i", listFile]);
        a.AddRange(["-map", "0:v:0", "-an", "-sn", "-dn"]);

        var filters = new List<string> { $"setpts=PTS/{speed}", $"fps={fps}" };
        switch (strat)
        {
            case Strategy.QsvFull:
                if (s.Height is int h1)
                    filters.Add($"scale_qsv=w=-1:h='min({h1},ih)'");
                break;
            case Strategy.QsvEncodeOnly:
                if (s.Height is int h2)
                    filters.Add($"scale=-2:'min({h2},ih)'");
                filters.Add("format=nv12");
                break;
            default:
                if (s.Height is int h3)
                    filters.Add($"scale=-2:'min({h3},ih)'");
                filters.Add("format=yuv420p");
                break;
        }
        a.AddRange(["-vf", string.Join(',', filters)]);

        if (strat == Strategy.Software)
            a.AddRange(["-c:v", "libx264", "-preset", "veryfast", "-crf", q]);
        else
            a.AddRange(["-c:v", "h264_qsv", "-preset", "medium", "-global_quality", q]);

        a.AddRange(["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", s.OutputPath]);
        return a;
    }

    private async Task<int> RunFfmpegAsync(string ffmpeg, List<string> args)
    {
        var psi = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in args) psi.ArgumentList.Add(arg);

        var expectedOutUs = _s.TotalDuration.TotalMicroseconds / Math.Max(1, _s.Speed);
        using var proc = new Process { StartInfo = psi };
        _proc = proc;
        proc.Start();

        var outTask = Task.Run(async () =>
        {
            string currentSpeed = "";
            string? line;
            while ((line = await proc.StandardOutput.ReadLineAsync()) != null)
            {
                if (line.StartsWith("speed=")) currentSpeed = line[6..].Trim();
                else if (line.StartsWith("out_time_us=") &&
                         long.TryParse(line[12..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var us) &&
                         expectedOutUs > 0)
                {
                    Progress?.Invoke(Math.Clamp(us / expectedOutUs, 0, 1), currentSpeed);
                }
                else if (line == "progress=end") Progress?.Invoke(1, currentSpeed);
            }
        });
        var errTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await proc.StandardError.ReadLineAsync()) != null)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                Log?.Invoke(line);
            }
        });

        await proc.WaitForExitAsync();
        await Task.WhenAll(outTask, errTask);
        _proc = null;
        return proc.ExitCode;
    }

    private static string Quote(string s) =>
        s.Length > 0 && s.IndexOfAny([' ', '\'', '"', ',', '(']) < 0 ? s : "\"" + s.Replace("\"", "\\\"") + "\"";

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
