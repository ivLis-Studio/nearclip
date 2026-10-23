using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using Nearclip.Core;
using Windows.Devices.Enumeration;

namespace Nearclip.App.Platform;

/// <summary>DNS-SD for <c>_nearclip._tcp</c>: advertises through DnsServiceRegister (mDNS) and browses with the
/// Windows association-endpoint watcher, which resolves SRV, TXT and addresses (PROTOCOL.md §2).</summary>
/// <remarks>
/// Advertising keeps at most one DnsServiceRegister / DnsServiceDeRegister call in flight. Deregistering a
/// registration that has not completed yet fails (9701) and leaves it registered for the life of the process, which
/// then shows up as a second instance ("Name (1)"), so TXT updates wait for the previous call to complete.
/// </remarks>
internal sealed class DnsSdDiscovery : IDiscovery
{
    const string DnsSdProtocol = "{4526e8c1-8aac-4153-9b16-55e86ada0e54}";
    const uint DnsRequestPending = 9506;

    static readonly string[] Properties =
    [
        "System.Devices.Dnssd.HostName", "System.Devices.Dnssd.ServiceName", "System.Devices.Dnssd.InstanceName",
        "System.Devices.IpAddress", "System.Devices.Dnssd.PortNumber", "System.Devices.Dnssd.TextAttributes",
    ];

    [StructLayout(LayoutKind.Sequential)]
    struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern IntPtr DnsServiceConstructInstance(string pServiceName, string pHostName, IntPtr pIp4, IntPtr pIp6, ushort wPort,
        ushort wPriority, ushort wWeight, uint dwPropertiesCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);

    [DllImport("dnsapi.dll", ExactSpelling = true)] static extern uint DnsServiceRegister(IntPtr pRequest, IntPtr pCancel);
    [DllImport("dnsapi.dll", ExactSpelling = true)] static extern uint DnsServiceDeRegister(IntPtr pRequest, IntPtr pCancel);
    [DllImport("dnsapi.dll", ExactSpelling = true)] static extern void DnsServiceFreeInstance(IntPtr pInstance);

    static readonly RegisterComplete s_complete = OnRegisterComplete;
    static DnsSdDiscovery? s_current;

    sealed class Registration(ServiceAdvertisement ad, string serviceName)
    {
        public ServiceAdvertisement Ad { get; } = ad;
        public string ServiceName { get; } = serviceName;
        public IntPtr Request, Instance, Ip4;
    }

    enum Op { None, Registering, Deregistering }

    readonly object _gate = new();
    readonly Dictionary<string, DeviceInformation> _found = new();
    DeviceWatcher? _watcher;
    bool _watching;

    readonly object _adGate = new();
    ServiceAdvertisement? _wanted;
    Registration? _current;
    Op _op;
    DateTime _opStarted;

    public DnsSdDiscovery() => s_current = this;

    public event Action<IReadOnlyList<DiscoveredService>>? Changed;
    public bool IsAdvertising { get; private set; }
    public int Visible { get { lock (_gate) return _found.Count; } }

    public void Start(ServiceAdvertisement advertisement)
    {
        SetWanted(advertisement);
        _watching = true;
        StartWatcher();
    }

    public void Update(ServiceAdvertisement advertisement) => SetWanted(advertisement);

    public void Stop()
    {
        _watching = false;
        SetWanted(null);
        var w = _watcher;
        _watcher = null;
        try { if (w is { Status: DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted }) w.Stop(); }
        catch (Exception e) { Log.Write("dns-sd watcher stop: " + e.Message); }
        lock (_gate) _found.Clear();
        Changed?.Invoke([]);
    }

    /// <summary>At exit: withdraws the advertisement and waits briefly for Windows to confirm it.</summary>
    public void Dispose()
    {
        Stop();
        var until = DateTime.UtcNow.AddSeconds(2);
        while (DateTime.UtcNow < until)
        {
            lock (_adGate) if (_op == Op.None && _current is null) return;
            Thread.Sleep(40);
        }
    }

    void StartWatcher()
    {
        if (_watcher is not null) return;
        try
        {
            var aqs = $"System.Devices.AepService.ProtocolId:=\"{DnsSdProtocol}\" AND System.Devices.Dnssd.Domain:=\"local\" AND System.Devices.Dnssd.ServiceName:=\"{Wire.ServiceType}\"";
            var w = DeviceInformation.CreateWatcher(aqs, Properties, DeviceInformationKind.AssociationEndpointService);
            w.Added += (_, info) =>
            {
                lock (_gate) _found[info.Id] = info;
                Publish();
            };
            w.Updated += (_, update) =>
            {
                lock (_gate) if (_found.TryGetValue(update.Id, out var info)) info.Update(update);
                Publish();
            };
            w.Removed += (_, update) =>
            {
                lock (_gate) _found.Remove(update.Id);
                Publish();
            };
            w.Stopped += (sender, _) =>
            {
                if (!_watching || sender != _watcher) return;
                // The watcher stops on network changes; browse again shortly.
                _watcher = null;
                _ = Task.Delay(3000).ContinueWith(_ => { if (_watching) StartWatcher(); });
            };
            _watcher = w;
            w.Start();
        }
        catch (Exception e)
        {
            Log.Write("dns-sd browse unavailable: " + e.Message);
        }
    }

    void Publish()
    {
        List<DiscoveredService> list;
        lock (_gate) list = _found.Values.Select(ToService).OfType<DiscoveredService>().ToList();
        Changed?.Invoke(list);
    }

    static DiscoveredService? ToService(DeviceInformation info)
    {
        var p = info.Properties;
        var txt = new Dictionary<string, string>();
        if (p.TryGetValue("System.Devices.Dnssd.TextAttributes", out var t) && t is string[] attrs)
        {
            foreach (var a in attrs)
            {
                var i = a.IndexOf('=');
                if (i > 0) txt[a[..i]] = a[(i + 1)..];
            }
        }
        var port = 0;
        if (p.TryGetValue("System.Devices.Dnssd.PortNumber", out var pn) && pn is not null)
        {
            try { port = Convert.ToInt32(pn); } catch (Exception) { }
        }
        if (port <= 0) return null;
        var eps = new List<Endpoint>();
        if (p.TryGetValue("System.Devices.IpAddress", out var ip) && ip is string[] ips)
        {
            foreach (var a in ips)
                if (IPAddress.TryParse(a, out var addr) && addr.AddressFamily == AddressFamily.InterNetwork && !a.StartsWith("169.254.", StringComparison.Ordinal))
                    eps.Add(new Endpoint(a, port));
        }
        if (eps.Count == 0 && p.TryGetValue("System.Devices.Dnssd.HostName", out var hn) && hn is string host && host.Length > 0)
            eps.Add(new Endpoint(host.TrimEnd('.'), port));
        var instance = p.TryGetValue("System.Devices.Dnssd.InstanceName", out var inst) && inst is string s ? s : info.Name;
        return new DiscoveredService(instance, txt, eps);
    }

    static string EscapeInstance(string name) => name.Replace("\\", "\\\\").Replace(".", "\\.");

    void SetWanted(ServiceAdvertisement? ad)
    {
        lock (_adGate)
        {
            _wanted = ad;
            Pump();
        }
    }

    static bool Same(ServiceAdvertisement a, ServiceAdvertisement b) =>
        a.InstanceName == b.InstanceName && a.Port == b.Port && a.Txt.Count == b.Txt.Count &&
        a.Txt.All(kv => b.Txt.TryGetValue(kv.Key, out var v) && v == kv.Value);

    /// <summary>Moves the advertisement one step towards <see cref="_wanted"/>. Called with <see cref="_adGate"/> held.</summary>
    void Pump()
    {
        if (_op != Op.None)
        {
            if (DateTime.UtcNow - _opStarted < TimeSpan.FromSeconds(15)) return;
            Log.Write($"dns-sd: no completion for {_op}; continuing");
            if (_op == Op.Deregistering) _current = null;
            _op = Op.None;
        }
        try
        {
            if (_current is { } cur && (_wanted is null || !Same(cur.Ad, _wanted)))
            {
                _op = Op.Deregistering;
                _opStarted = DateTime.UtcNow;
                IsAdvertising = false;
                var rc = DnsServiceDeRegister(cur.Request, IntPtr.Zero);
                if (rc == DnsRequestPending) return;
                Log.Write($"dns-sd: deregister failed ({rc})");
                _op = Op.None;
                _current = null;
                Release(cur);
            }
            if (_current is null && _wanted is { } ad && Build(ad) is { } reg)
            {
                _current = reg;
                _op = Op.Registering;
                _opStarted = DateTime.UtcNow;
                var rc = DnsServiceRegister(reg.Request, IntPtr.Zero);
                if (rc == DnsRequestPending) return;
                Log.Write($"dns-sd: register failed ({rc})");
                _op = Op.None;
                _current = null;
                _wanted = null;
                Release(reg);
            }
        }
        catch (Exception e)
        {
            _op = Op.None;
            IsAdvertising = false;
            Log.Write("dns-sd advertising unavailable: " + e.Message);
        }
    }

    static Registration? Build(ServiceAdvertisement ad)
    {
        var reg = new Registration(ad, $"{EscapeInstance(ad.InstanceName)}.{Wire.ServiceType}.local");
        if (LocalAddresses.Ipv4().FirstOrDefault() is { } a && IPAddress.TryParse(a, out var ip))
        {
            reg.Ip4 = Marshal.AllocHGlobal(4);
            Marshal.Copy(ip.GetAddressBytes(), 0, reg.Ip4, 4);
        }
        var keys = ad.Txt.Keys.ToArray();
        var values = keys.Select(k => ad.Txt[k]).ToArray();
        reg.Instance = DnsServiceConstructInstance(reg.ServiceName, Dns.GetHostName() + ".local", reg.Ip4, IntPtr.Zero,
            (ushort)ad.Port, 0, 0, (uint)keys.Length, keys, values);
        if (reg.Instance == IntPtr.Zero)
        {
            Log.Write("dns-sd: could not build the service instance");
            Release(reg);
            return null;
        }
        var request = new DnsServiceRegisterRequest
        {
            Version = 1,
            pServiceInstance = reg.Instance,
            pRegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(s_complete),
            unicastEnabled = 0,
        };
        reg.Request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceRegisterRequest>());
        Marshal.StructureToPtr(request, reg.Request, false);
        return reg;
    }

    /// <summary>Frees a registration's memory a little later: dnsapi may still read it right after completing.</summary>
    static void Release(Registration reg)
    {
        var (request, instance, ip4) = (reg.Request, reg.Instance, reg.Ip4);
        reg.Request = reg.Instance = reg.Ip4 = IntPtr.Zero;
        _ = Task.Delay(5_000).ContinueWith(_ =>
        {
            if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
            if (request != IntPtr.Zero) Marshal.FreeHGlobal(request);
            if (ip4 != IntPtr.Zero) Marshal.FreeHGlobal(ip4);
        });
    }

    static void OnRegisterComplete(uint status, IntPtr context, IntPtr instance)
    {
        if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
        s_current?.Completed(status);
    }

    void Completed(uint status)
    {
        lock (_adGate)
        {
            var op = _op;
            _op = Op.None;
            if (op == Op.Registering && _current is { } reg)
            {
                IsAdvertising = status == 0;
                if (status == 0) Log.Write($"dns-sd: advertising {reg.ServiceName} on port {reg.Ad.Port}");
                else
                {
                    Log.Write($"dns-sd: registration failed ({status})");
                    _current = null;
                    if (_wanted is not null && Same(_wanted, reg.Ad)) _wanted = null; // no retry loop for the same ad
                    Release(reg);
                }
            }
            else if (op == Op.Deregistering && _current is { } old)
            {
                if (status != 0) Log.Write($"dns-sd: deregistration completed with {status}");
                _current = null;
                Release(old);
            }
            Pump();
        }
    }
}
