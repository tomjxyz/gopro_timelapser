using System.Reflection;
using System.Security.Cryptography;

namespace GoProTimelapser;

/// <summary>
/// Finds ffmpeg.exe: the copy embedded in this exe (extracted once to
/// %LOCALAPPDATA%, which needs no admin rights), or one next to the exe / on PATH.
/// </summary>
public static class FfmpegLocator
{
    private static string? _cached;

    public static string Locate()
    {
        if (_cached != null && File.Exists(_cached)) return _cached;

        var embedded = ExtractEmbedded();
        if (embedded != null) return _cached = embedded;

        var beside = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        if (File.Exists(beside)) return _cached = beside;

        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
                if (File.Exists(candidate)) return _cached = candidate;
            }
            catch { /* ignore bad PATH entries */ }
        }

        throw new FileNotFoundException(
            "ffmpeg.exe was not found. This build does not contain an embedded ffmpeg; " +
            "place ffmpeg.exe next to GoProTimelapser.exe.");
    }

    private static string? ExtractEmbedded()
    {
        var asm = Assembly.GetExecutingAssembly();
        using var res = asm.GetManifestResourceStream("ffmpeg.exe");
        if (res == null) return null;

        // Hash a prefix + length to get a stable version tag without reading 100+ MB each launch.
        string tag;
        using (var sha = SHA256.Create())
        {
            var buf = new byte[1 << 20];
            int n = res.Read(buf, 0, buf.Length);
            sha.TransformBlock(buf, 0, n, null, 0);
            var len = BitConverter.GetBytes(res.Length);
            sha.TransformFinalBlock(len, 0, len.Length);
            tag = Convert.ToHexString(sha.Hash!)[..12].ToLowerInvariant();
        }

        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "GoProTimelapser");
        Directory.CreateDirectory(dir);
        var target = Path.Combine(dir, $"ffmpeg-{tag}.exe");

        if (File.Exists(target) && new FileInfo(target).Length == res.Length) return target;

        var tmp = target + ".tmp";
        res.Position = 0;
        using (var outFs = File.Create(tmp))
            res.CopyTo(outFs);
        File.Move(tmp, target, overwrite: true);

        // Clean out older extracted versions.
        foreach (var old in Directory.GetFiles(dir, "ffmpeg-*.exe"))
        {
            if (!string.Equals(old, target, StringComparison.OrdinalIgnoreCase))
                try { File.Delete(old); } catch { }
        }
        return target;
    }
}
