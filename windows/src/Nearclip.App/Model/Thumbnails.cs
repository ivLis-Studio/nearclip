using Microsoft.UI.Xaml.Media.Imaging;

namespace Nearclip.App.Model;

/// <summary>Small decoded thumbnails of image clips (UI thread).</summary>
internal static class Thumbnails
{
    static readonly Dictionary<string, BitmapImage> Cache = new();

    public static async Task<BitmapImage?> GetAsync(string id, string path, int decodeWidth = 80)
    {
        if (Cache.TryGetValue(id, out var cached)) return cached;
        try
        {
            if (!File.Exists(path)) return null;
            var bmp = new BitmapImage { DecodePixelWidth = decodeWidth, DecodePixelType = DecodePixelType.Logical };
            using var fs = File.OpenRead(path);
            await bmp.SetSourceAsync(fs.AsRandomAccessStream());
            if (Cache.Count > 300) Cache.Clear();
            Cache[id] = bmp;
            return bmp;
        }
        catch (Exception) { return null; }
    }
}
