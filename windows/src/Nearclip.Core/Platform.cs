namespace Nearclip.Core;

/// <summary>DNS-SD advertisement of this device (PROTOCOL.md §2).</summary>
public sealed record ServiceAdvertisement(string InstanceName, int Port, IReadOnlyDictionary<string, string> Txt);

/// <summary>A resolved <c>_nearclip._tcp</c> service.</summary>
public sealed record DiscoveredService(string InstanceName, IReadOnlyDictionary<string, string> Txt, IReadOnlyList<Endpoint> Endpoints);

/// <summary>Platform DNS-SD. The engine calls it from its own thread; implementations raise <see cref="Changed"/>
/// with the full current list from any thread.</summary>
public interface IDiscovery : IDisposable
{
    void Start(ServiceAdvertisement advertisement);
    void Update(ServiceAdvertisement advertisement);
    void Stop();
    event Action<IReadOnlyList<DiscoveredService>>? Changed;
}

/// <summary>Where the group key lives: DPAPI on Windows, a plain file for the CLI.</summary>
public interface ISecretStore
{
    byte[]? Load(string account);
    void Save(byte[] data, string account);
    void Delete(string account);
}

public sealed class FileSecretStore : ISecretStore
{
    readonly string _directory;

    public FileSecretStore(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(directory);
    }

    string PathFor(string account) => Path.Combine(_directory, account + ".secret");

    public byte[]? Load(string account)
    {
        try { return File.ReadAllBytes(PathFor(account)); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public void Save(byte[] data, string account)
    {
        var path = PathFor(account);
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        if (!OperatingSystem.IsWindows())
        {
            try { File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch (Exception) { }
        }
        File.Move(tmp, path, overwrite: true);
    }

    public void Delete(string account)
    {
        try { File.Delete(PathFor(account)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
