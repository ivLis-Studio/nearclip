namespace Nearclip.App.Platform;

/// <summary>Small rolling diagnostics log in %LOCALAPPDATA%\Nearclip\logs (no clip contents are written).</summary>
internal static class Log
{
    static readonly object Gate = new();
    static string? s_path;

    public static void Init(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            s_path = Path.Combine(directory, "nearclip.log");
            if (File.Exists(s_path) && new FileInfo(s_path).Length > 1_000_000)
                File.Move(s_path, Path.Combine(directory, "nearclip.old.log"), overwrite: true);
        }
        catch (Exception) { s_path = null; }
    }

    public static void Write(string message)
    {
        var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + message;
        System.Diagnostics.Debug.WriteLine(line);
        if (s_path is null) return;
        lock (Gate)
        {
            try { File.AppendAllText(s_path, line + Environment.NewLine); } catch (Exception) { }
        }
    }
}
