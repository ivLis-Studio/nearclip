using Xunit.Sdk;

namespace Nearclip.Core.Tests;

/// <summary>A real node on 127.0.0.1 (no DNS-SD) with an event log that tests can wait on.</summary>
internal sealed class TestPeer : IDisposable
{
    readonly object _lock = new();
    List<NodeEvent> _events = [];
    int _cursor;

    public string Name { get; }
    public string Dir { get; }
    public NearclipNode Node { get; private set; }
    public string Id => Node.DeviceId;

    public TestPeer(string name, string? dir = null)
    {
        Name = name;
        Dir = dir ?? Path.Combine(Path.GetTempPath(), "nearclip-test-" + Guid.NewGuid().ToString("N"));
        Node = Make();
        Node.Start();
    }

    NearclipNode Make()
    {
        var node = new NearclipNode(new NearclipNode.Options
        {
            StateDirectory = Dir,
            DeviceName = Name,
            Platform = "cli",
            AppVersion = "test",
            Port = 0,
            SecretStore = new FileSecretStore(Path.Combine(Dir, "secrets")),
            AddressProvider = () => ["127.0.0.1"],
        });
        node.Event += e =>
        {
            lock (_lock)
            {
                _events.Add(e);
                Monitor.PulseAll(_lock);
            }
        };
        return node;
    }

    /// <summary>Waits for an event (at or after the cursor) matching <paramref name="match"/>.</summary>
    public T Wait<T>(string what, Func<T, bool>? match = null, double seconds = 15) where T : NodeEvent
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        lock (_lock)
        {
            while (true)
            {
                for (var i = _cursor; i < _events.Count; i++)
                    if (_events[i] is T t && (match is null || match(t))) return t;
                var left = deadline - DateTime.UtcNow;
                if (left <= TimeSpan.Zero)
                {
                    var seen = string.Join("\n  ", _events.Skip(Math.Max(0, _events.Count - 20)).Select(e => e.ToString()));
                    throw new XunitException($"{Name}: timed out waiting for {what}. Last events:\n  {seen}");
                }
                Monitor.Wait(_lock, left);
            }
        }
    }

    public bool Saw<T>(Func<T, bool>? match = null) where T : NodeEvent
    {
        lock (_lock) return _events.Skip(_cursor).OfType<T>().Any(t => match is null || match(t));
    }

    public void Mark()
    {
        lock (_lock) _cursor = _events.Count;
    }

    /// <summary>The listener port (from the latest <c>Ready</c>, independent of the cursor).</summary>
    public int Port
    {
        get
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            lock (_lock)
            {
                while (true)
                {
                    if (_events.OfType<NodeEvent.Ready>().LastOrDefault() is { } r) return r.Port;
                    var left = deadline - DateTime.UtcNow;
                    if (left <= TimeSpan.Zero) throw new XunitException($"{Name}: no ready event");
                    Monitor.Wait(_lock, left);
                }
            }
        }
    }

    public void Restart()
    {
        Node.Dispose();
        lock (_lock)
        {
            _events = [];
            _cursor = 0;
        }
        Node = Make();
        Node.Start();
    }

    public void Dispose()
    {
        Node.Dispose();
        try { Directory.Delete(Dir, true); } catch (Exception) { }
    }
}
