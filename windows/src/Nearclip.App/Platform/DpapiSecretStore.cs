using System.Security.Cryptography;
using Nearclip.Core;

namespace Nearclip.App.Platform;

/// <summary>Group key storage protected with DPAPI (current user).</summary>
internal sealed class DpapiSecretStore : ISecretStore
{
    static readonly byte[] Entropy = "Nearclip group key v1"u8.ToArray();
    readonly string _directory;

    public DpapiSecretStore(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(directory);
    }

    string PathFor(string account) => Path.Combine(_directory, account + ".dpapi");

    public byte[]? Load(string account)
    {
        try
        {
            var path = PathFor(account);
            return File.Exists(path) ? ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser) : null;
        }
        catch (Exception e)
        {
            Log.Write("dpapi load failed: " + e.Message);
            return null;
        }
    }

    public void Save(byte[] data, string account)
    {
        var path = PathFor(account);
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, ProtectedData.Protect(data, Entropy, DataProtectionScope.CurrentUser));
        File.Move(tmp, path, overwrite: true);
    }

    public void Delete(string account)
    {
        try { File.Delete(PathFor(account)); } catch (Exception) { }
    }
}
