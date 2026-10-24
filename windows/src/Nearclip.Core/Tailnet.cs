using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nearclip.Core;

/// <summary>Another Nearclip node in the user's tailnet (PROTOCOL.md §10.2).</summary>
public sealed record TailnetPeer
{
    [JsonPropertyName("host")] public string Host { get; init; } = "";
    [JsonPropertyName("idPrefix")] public string? IdPrefix { get; init; }
    [JsonPropertyName("ip")] public string Ip { get; init; } = "";
    [JsonPropertyName("online")] public bool Online { get; init; }
    [JsonPropertyName("os")] public string? Os { get; init; }
    [JsonPropertyName("direct")] public bool Direct { get; init; }
    [JsonPropertyName("relay")] public string? Relay { get; init; }
}

/// <summary>Status of the embedded Tailscale node (tailnet/README.md).</summary>
public sealed record TailnetStatus
{
    /// <summary>off, starting, needsLogin, needsApproval, running, stopped, error</summary>
    [JsonPropertyName("state")] public string State { get; init; } = "off";
    [JsonPropertyName("backend")] public string? Backend { get; init; }
    [JsonPropertyName("authURL")] public string? AuthUrl { get; init; }
    [JsonPropertyName("ip")] public string? Ip { get; init; }
    [JsonPropertyName("ip6")] public string? Ip6 { get; init; }
    [JsonPropertyName("hostname")] public string? Hostname { get; init; }
    [JsonPropertyName("dnsName")] public string? DnsName { get; init; }
    [JsonPropertyName("account")] public string? Account { get; init; }
    [JsonPropertyName("tailnet")] public string? Tailnet { get; init; }
    [JsonPropertyName("proxyPort")] public int? ProxyPort { get; init; }
    [JsonPropertyName("token")] public string? Token { get; init; }
    [JsonPropertyName("peers")] public IReadOnlyList<TailnetPeer> Peers { get; init; } = [];
    [JsonPropertyName("health")] public IReadOnlyList<string>? Health { get; init; }
    [JsonPropertyName("error")] public string? Error { get; init; }
    [JsonPropertyName("version")] public string? Version { get; init; }

    public static TailnetStatus Off { get; } = new();

    public bool IsRunning => State == "running" && Ip is not null;

    /// <summary>What the UI and the engine care about (ignores health chatter).</summary>
    public bool SameEssentials(TailnetStatus o) =>
        State == o.State && AuthUrl == o.AuthUrl && Ip == o.Ip && Account == o.Account && Error == o.Error &&
        ProxyPort == o.ProxyPort && Token == o.Token && Peers.SequenceEqual(o.Peers);
}

/// <summary>Options for the embedded node; it only runs while remote connection is enabled.</summary>
public sealed record TailnetOptions(string Directory, string? ControlUrl = null, string? LogPath = null, bool TestMode = false);

/// <summary>How a session reaches its peer (PROTOCOL.md §10.3).</summary>
public enum PeerRoute { Lan, Remote }

/// <summary>Tailnet addresses: 100.64.0.0/10 and fd7a:115c:a1e0::/48.</summary>
public static class TailnetAddress
{
    public static bool Contains(string? host)
    {
        if (string.IsNullOrEmpty(host)) return false;
        var h = host.ToLowerInvariant();
        if (h.StartsWith("fd7a:115c:a1e0:", StringComparison.Ordinal)) return true;
        var parts = h.Split('.');
        return parts.Length == 4 && int.TryParse(parts[0], out var a) && int.TryParse(parts[1], out var b) && a == 100 && b is >= 64 and <= 127;
    }
}

/// <summary>Calls into the embedded node (tailnet/capi, nctailnet.dll). All calls block: never on the node or UI thread.</summary>
public static class TailnetBridge
{
    const string Lib = "nctailnet";

    static TailnetBridge()
    {
        // Go's asynchronous preemption suspends threads and rewrites their context. In an x64 process emulated on ARM64
        // Windows that kills the process without a trace (seen in a Windows 11 ARM64 VM: the x64 build died right after
        // starting with remote connection on, and ran with it off or with asyncpreemptoff=1). The arm64 build runs
        // natively; for the x64 build on ARM64, turn it off before the Go runtime in nctailnet.dll reads GODEBUG.
        if (OperatingSystem.IsWindows() && EmulatedOnArm64())
            Environment.SetEnvironmentVariable("GODEBUG", MergeGoDebug(Environment.GetEnvironmentVariable("GODEBUG"), "asyncpreemptoff=1"));
        // Tests and the CLI on macOS load the desktop build from NEARCLIP_TAILNET_LIB; the app ships nctailnet.dll next to the exe.
        try
        {
            NativeLibrary.SetDllImportResolver(typeof(TailnetBridge).Assembly, (name, assembly, path) =>
            {
                if (name != Lib) return IntPtr.Zero;
                var custom = Environment.GetEnvironmentVariable("NEARCLIP_TAILNET_LIB");
                if (!string.IsNullOrEmpty(custom) && File.Exists(custom)) return NativeLibrary.Load(custom);
                return NativeLibrary.TryLoad(name, assembly, path, out var h) ? h : IntPtr.Zero;
            });
        }
        catch (InvalidOperationException) { /* a resolver is already set */ }
    }

    /// <summary>GODEBUG with one more "name=value" setting; an existing setting of that name wins.</summary>
    public static string MergeGoDebug(string? current, string setting)
    {
        if (string.IsNullOrWhiteSpace(current)) return setting;
        var name = setting.Split('=')[0];
        foreach (var part in current.Split(','))
            if (part.Trim().Split('=')[0] == name) return current;
        return current + "," + setting;
    }

    /// <summary>An x64 process running under emulation on an ARM64 PC.</summary>
    static bool EmulatedOnArm64()
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.X64) return false;
        try { return IsWow64Process2(GetCurrentProcess(), out _, out var native) && native == ImageFileMachineArm64; }
        catch (Exception) { return false; } // IsWow64Process2 needs Windows 10 1709
    }

    const ushort ImageFileMachineArm64 = 0xAA64;
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NCTailnetStart([MarshalAs(UnmanagedType.LPUTF8Str)] string config);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NCTailnetStatus();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NCTailnetLogin();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NCTailnetLogout();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NCTailnetStop();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void NCTailnetNetworkChanged();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void NCTailnetFree(IntPtr p);

    static string? s_loadError;
    static bool s_checked;

    /// <summary>Whether the native library can be loaded.</summary>
    public static bool Available
    {
        get
        {
            if (!s_checked)
            {
                s_checked = true;
                try { Marshal.Prelink(typeof(TailnetBridge).GetMethod(nameof(NCTailnetStatus), BindingFlags.NonPublic | BindingFlags.Static)!); }
                catch (Exception e) { s_loadError = e.Message; }
            }
            return s_loadError is null;
        }
    }

    static TailnetStatus Call(Func<IntPtr> f)
    {
        if (!Available) return new TailnetStatus { State = "error", Error = "tailnet library: " + s_loadError };
        try
        {
            var p = f();
            if (p == IntPtr.Zero) return new TailnetStatus { State = "error", Error = "no result" };
            try
            {
                var json = Marshal.PtrToStringUTF8(p) ?? "";
                return JsonSerializer.Deserialize<TailnetStatus>(json) ?? new TailnetStatus { State = "error", Error = "bad status" };
            }
            finally { NCTailnetFree(p); }
        }
        catch (Exception e) { return new TailnetStatus { State = "error", Error = e.Message }; }
    }

    public static TailnetStatus Start(string configJson) => Call(() => NCTailnetStart(configJson));
    public static TailnetStatus Status() => Call(NCTailnetStatus);
    public static TailnetStatus Login() => Call(NCTailnetLogin);
    public static TailnetStatus Logout() => Call(NCTailnetLogout);
    public static TailnetStatus Stop() => Call(NCTailnetStop);

    public static void NetworkChanged()
    {
        if (!Available) return;
        try { NCTailnetNetworkChanged(); } catch (Exception) { }
    }
}
