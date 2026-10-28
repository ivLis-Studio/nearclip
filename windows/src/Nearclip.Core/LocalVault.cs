using System.Security.Cryptography;
using System.Text;

namespace Nearclip.Core;

internal sealed class LocalVault
{
    readonly byte[] _key;
    public LocalVault(ISecretStore secrets) {
        _key = secrets.Load("local-history-v1") ?? RandomNumberGenerator.GetBytes(32);
        if (_key.Length != 32) throw new CryptographicException("Invalid local history key");
        secrets.Save(_key, "local-history-v1");
    }
    public byte[] Read(string path) {
        var data = File.ReadAllBytes(path);
        if (data.AsSpan().StartsWith("NCV1"u8)) {
            if (data.Length < 32) throw new CryptographicException("Truncated history file");
            var plain = new byte[data.Length - 32];
            using var aes = new AesGcm(_key, 16);
            aes.Decrypt(data.AsSpan(4,12), data.AsSpan(16,plain.Length), data.AsSpan(data.Length-16), plain, Encoding.UTF8.GetBytes(Path.GetFileName(path)));
            return plain;
        }
        Write(path, data);
        return data;
    }
    public void Write(string path, byte[] plain) {
        var output = new byte[plain.Length + 32];
        "NCV1"u8.CopyTo(output);
        RandomNumberGenerator.Fill(output.AsSpan(4,12));
        using var aes = new AesGcm(_key, 16);
        aes.Encrypt(output.AsSpan(4,12), plain, output.AsSpan(16,plain.Length), output.AsSpan(output.Length-16), Encoding.UTF8.GetBytes(Path.GetFileName(path)));
        var tmp = path + ".vault.tmp";
        File.WriteAllBytes(tmp, output);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.Move(tmp, path, true);
    }
}
