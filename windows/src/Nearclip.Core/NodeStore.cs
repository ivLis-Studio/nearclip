using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nearclip.Core;

/// <summary>Persistent node state: <c>state.json</c>, <c>history.json</c> and <c>blobs/</c>. Owned by the node queue;
/// file writes happen on a background queue.</summary>
internal sealed class NodeStore : IDisposable
{
    internal sealed class PersistedState
    {
        public string DeviceId { get; set; } = "";
        public string DeviceName { get; set; } = "";
        public string GroupId { get; set; } = "";
        public long JoinedAt { get; set; }
        public List<MemberRecord> Members { get; set; } = [];
        public Dictionary<string, List<Endpoint>> Endpoints { get; set; } = new();
        public Dictionary<string, long> LastSeen { get; set; } = new();
        public Dictionary<string, long> Tombstones { get; set; } = new();
        public long NewestLocalTs { get; set; }
    }

    internal sealed class PersistedClip
    {
        public Clip Clip { get; set; } = null!;
        public string GroupId { get; set; } = "";
        public bool Pinned { get; set; }
        public long ReceivedAt { get; set; }
        public string? SrcName { get; set; }
        public string? SrcPlatform { get; set; }
        public bool LocalOnly { get; set; }
        public bool TextFile { get; set; }
    }

    sealed class PersistedHistory
    {
        public List<PersistedClip> Clips { get; set; } = [];
    }

    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };

    const int InlineTextLimit = 256 * 1024;

    readonly string _directory;
    readonly string _blobs;
    readonly SerialQueue _owner;
    readonly SerialQueue _io = new("nearclip-store-io");
    readonly List<StoredClip> _history = [];
    readonly Dictionary<string, StoredClip> _byId = new();
    bool _saveScheduled;
    bool _disposed;

    public PersistedState State { get; }
    public Dictionary<string, MemberRecord> Members { get; set; }
    public int RetentionDays { get; set; } = 30;
    public int MaxItems { get; set; } = 1000;
    public IReadOnlyList<StoredClip> History => _history;
    public string BlobDirectory => _blobs;

    public NodeStore(string directory, string defaultName, SerialQueue owner)
    {
        _directory = directory;
        _blobs = Path.Combine(directory, "blobs");
        _owner = owner;
        Directory.CreateDirectory(_blobs);
        State = TryRead<PersistedState>("state.json") ?? new PersistedState
        {
            DeviceId = Ids.New(),
            DeviceName = defaultName,
            GroupId = Ids.New(),
            JoinedAt = Clock.NowMs(),
        };
        State.DeviceId = Ids.Norm(State.DeviceId);
        Members = new Dictionary<string, MemberRecord>();
        foreach (var m in State.Members)
        {
            if (!Members.TryGetValue(m.Id, out var cur) || m.UpdatedAt > cur.UpdatedAt) Members[m.Id] = m;
        }
        var hist = TryRead<PersistedHistory>("history.json");
        if (hist is not null)
        {
            foreach (var pc in hist.Clips)
            {
                if (pc.Clip is null) continue;
                var clip = pc.Clip;
                if (pc.TextFile)
                {
                    try { clip = clip with { Text = File.ReadAllText(TextPath(clip.Id)) }; }
                    catch (IOException) { continue; }
                }
                var sc = new StoredClip(clip, pc.GroupId, pc.Pinned, pc.ReceivedAt, pc.SrcName, pc.SrcPlatform, pc.LocalOnly);
                if (_byId.TryAdd(sc.Id, sc)) _history.Add(sc);
            }
            _history.Sort((a, b) => b.Clip.Ts.CompareTo(a.Clip.Ts));
        }
    }

    T? TryRead<T>(string name) where T : class
    {
        try
        {
            var path = Path.Combine(_directory, name);
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), JsonOptions);
        }
        catch (Exception) { return null; }
    }

    public string BlobPath(string id) => Path.Combine(_blobs, id + ".bin");
    string TextPath(string id) => Path.Combine(_blobs, id + ".txt");

    public byte[]? ReadBlob(string id)
    {
        try { return File.ReadAllBytes(BlobPath(id)); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public bool Has(string id) => _byId.ContainsKey(id);
    public StoredClip? Get(string id) => _byId.GetValueOrDefault(id);

    public void Add(StoredClip clip, byte[]? blob)
    {
        if (_byId.ContainsKey(clip.Id)) return;
        if (blob is not null) WriteAtomic(BlobPath(clip.Id), blob);
        var idx = _history.FindIndex(c => c.Clip.Ts < clip.Clip.Ts);
        if (idx < 0) idx = _history.Count;
        _history.Insert(idx, clip);
        _byId[clip.Id] = clip;
        SaveSoon();
    }

    public bool Remove(string id)
    {
        if (!_byId.Remove(id)) return false;
        _history.RemoveAll(c => c.Id == id);
        TryDelete(BlobPath(id));
        TryDelete(TextPath(id));
        SaveSoon();
        return true;
    }

    public StoredClip? Replace(StoredClip updated)
    {
        if (!_byId.ContainsKey(updated.Id)) return null;
        var i = _history.FindIndex(c => c.Id == updated.Id);
        if (i >= 0) _history[i] = updated;
        _byId[updated.Id] = updated;
        SaveSoon();
        return updated;
    }

    /// <summary>Applies retention and the item cap to unpinned clips and expires tombstones.
    /// Returns the removed ids (local only: no tombstones).</summary>
    public List<string> Prune(long now)
    {
        var drop = new HashSet<string>();
        if (RetentionDays > 0)
        {
            var cutoff = now - RetentionDays * Wire.DayMs;
            foreach (var c in _history) if (!c.Pinned && c.Clip.Ts < cutoff) drop.Add(c.Id);
        }
        var unpinned = _history.Where(c => !c.Pinned && !drop.Contains(c.Id)).ToList();
        if (MaxItems > 0 && unpinned.Count > MaxItems)
            foreach (var c in unpinned.Skip(MaxItems)) drop.Add(c.Id);
        foreach (var id in drop) Remove(id);
        var tombCutoff = now - 30 * Wire.DayMs;
        var expired = State.Tombstones.Where(t => t.Value < tombCutoff).Select(t => t.Key).ToList();
        foreach (var id in expired) State.Tombstones.Remove(id);
        if (expired.Count > 0) SaveSoon();
        return drop.ToList();
    }

    public void SaveSoon()
    {
        if (_saveScheduled || _disposed) return;
        _saveScheduled = true;
        _owner.After(TimeSpan.FromMilliseconds(300), () =>
        {
            _saveScheduled = false;
            WriteSnapshot(sync: false);
        });
    }

    public void SaveNow() => WriteSnapshot(sync: true);

    void WriteSnapshot(bool sync)
    {
        if (_disposed) return;
        State.Members = Members.Values.OrderBy(m => m.AddedAt).ThenBy(m => m.Id, StringComparer.Ordinal).ToList();
        var clips = new List<PersistedClip>(_history.Count);
        var sideTexts = new List<(string Path, string Text)>();
        foreach (var c in _history)
        {
            var clip = c.Clip;
            var textFile = false;
            if (clip.Text is { } t && t.Length > InlineTextLimit / 4 && System.Text.Encoding.UTF8.GetByteCount(t) > InlineTextLimit)
            {
                sideTexts.Add((TextPath(c.Id), t));
                clip = clip with { Text = null };
                textFile = true;
            }
            clips.Add(new PersistedClip
            {
                Clip = clip, GroupId = c.GroupId, Pinned = c.Pinned, ReceivedAt = c.ReceivedAt, SrcName = c.SrcName,
                SrcPlatform = c.SrcPlatform, LocalOnly = c.LocalOnly, TextFile = textFile,
            });
        }
        var stateBytes = JsonSerializer.SerializeToUtf8Bytes(State, JsonOptions);
        var historyBytes = JsonSerializer.SerializeToUtf8Bytes(new PersistedHistory { Clips = clips }, JsonOptions);
        var dir = _directory;
        void Work()
        {
            foreach (var (path, text) in sideTexts)
                if (!File.Exists(path)) WriteAtomic(path, System.Text.Encoding.UTF8.GetBytes(text));
            WriteAtomic(Path.Combine(dir, "state.json"), stateBytes);
            WriteAtomic(Path.Combine(dir, "history.json"), historyBytes);
        }
        if (sync) _io.Invoke(Work); else _io.Post(Work);
    }

    static void WriteAtomic(string path, byte[] data)
    {
        try
        {
            var tmp = path + "." + Environment.ProcessId + ".tmp";
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, path, overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        if (_disposed) return;
        SaveNow();
        _disposed = true;
        _io.Dispose();
    }
}
