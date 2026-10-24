using System.Text.Json;
using System.Text.Json.Serialization;
using Nearclip.App.Platform;

namespace Nearclip.App.Model;

/// <summary>User preferences (DESIGN.md §4.6), persisted as JSON in %LOCALAPPDATA%\Nearclip\settings.json.</summary>
internal sealed class AppSettings
{
    public bool Paused { get; set; }
    public bool AutoApply { get; set; } = true;
    public bool SyncImages { get; set; } = true;
    public bool ShowToasts { get; set; } = true;
    public bool PasteAfterChoosing { get; set; }
    public int RetentionDays { get; set; } = 30;
    public bool OnboardingDone { get; set; }
    public bool LoginItemInitialized { get; set; }
    public uint HotKeyModifiers { get; set; } = Native.MOD_WIN | Native.MOD_ALT;
    public uint HotKeyKey { get; set; } = 0x56; // V
    public List<string> IgnoredApps { get; set; } = ["1Password.exe", "Bitwarden.exe", "KeePassXC.exe", "KeePass.exe"];
    /// <summary>system | light | dark</summary>
    public string Theme { get; set; } = "system";
    /// <summary>"" (Windows setting) | en-US | ko-KR</summary>
    public string Language { get; set; } = "";
    /// <summary>Remote connection through the embedded Tailscale node (DESIGN.md §4.7).</summary>
    public bool RemoteEnabled { get; set; }

    [JsonIgnore] public string? FilePath { get; private set; }

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static AppSettings Load(string path)
    {
        AppSettings s;
        try { s = File.Exists(path) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Options) ?? new() : new(); }
        catch (Exception) { s = new(); }
        s.FilePath = path;
        return s;
    }

    public void Save()
    {
        if (FilePath is null) return;
        try
        {
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Options));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception e) { Log.Write("settings save failed: " + e.Message); }
    }
}
