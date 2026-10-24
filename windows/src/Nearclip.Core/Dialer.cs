using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Nearclip.Core;

/// <summary>One way to reach a peer during a dial race (PROTOCOL.md §4.5, §10.3).</summary>
/// <param name="ConnectTo">TCP target: the peer itself, or the tailnet bridge proxy (127.0.0.1:proxyPort).</param>
/// <param name="Address">The peer address this candidate stands for (remembered when it wins).</param>
/// <param name="ProxyRequest">"NCTN1 &lt;token&gt; &lt;ip&gt;:&lt;port&gt;\n" when dialing through the tailnet bridge.</param>
/// <param name="Delay">Tailnet candidates start after the LAN candidates.</param>
internal sealed record DialCandidate(Endpoint ConnectTo, Endpoint Address, string? ProxyRequest = null, TimeSpan Delay = default, bool Remote = false)
{
    public static DialCandidate Direct(Endpoint e) => new(e, e);
}

internal static class Dialer
{
    static readonly TimeSpan ProxyTimeout = TimeSpan.FromSeconds(15);

    /// <summary>Connects to every endpoint in parallel and keeps the first that answers.</summary>
    public static async Task<(Socket Socket, Endpoint Endpoint)> ConnectAnyAsync(IReadOnlyList<Endpoint> targets, TimeSpan timeout, CancellationToken ct)
    {
        var (s, c) = await RaceAsync(targets.Distinct().Select(DialCandidate.Direct).ToList(), timeout, ct).ConfigureAwait(false);
        return (s, c.Address);
    }

    /// <summary>Starts every candidate (after its delay) in parallel and keeps the first connection that opens — for
    /// proxied candidates once the tailnet bridge answered 0. The others are closed.</summary>
    public static async Task<(Socket Socket, DialCandidate Candidate)> RaceAsync(IReadOnlyList<DialCandidate> candidates, TimeSpan timeout, CancellationToken ct)
    {
        if (candidates.Count == 0) throw NearclipException.Io("no address");
        var maxDelay = candidates.Max(c => c.Delay);
        var budget = timeout + maxDelay + (candidates.Any(c => c.ProxyRequest is not null) ? ProxyTimeout : TimeSpan.Zero);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(budget);
        var pending = candidates.Distinct().Select(c => AttemptAsync(c, timeout, cts.Token)).ToList();
        Exception? last = null;
        while (pending.Count > 0)
        {
            var done = await Task.WhenAny(pending).ConfigureAwait(false);
            pending.Remove(done);
            if (done.IsCompletedSuccessfully)
            {
                cts.Cancel();
                foreach (var p in pending)
                    _ = p.ContinueWith(t => { if (t.IsCompletedSuccessfully) t.Result.Socket.Dispose(); }, TaskScheduler.Default);
                return done.Result;
            }
            last = done.Exception?.GetBaseException() ?? last;
        }
        if (ct.IsCancellationRequested) throw new NearclipException(ErrorKind.Cancelled);
        if (cts.IsCancellationRequested && last is OperationCanceledException) throw NearclipException.TimedOut();
        throw NearclipException.Io(last?.Message ?? "unreachable");
    }

    static async Task<(Socket Socket, DialCandidate Candidate)> AttemptAsync(DialCandidate c, TimeSpan timeout, CancellationToken ct)
    {
        if (c.Delay > TimeSpan.Zero) await Task.Delay(c.Delay, ct).ConfigureAwait(false);
        using var one = CancellationTokenSource.CreateLinkedTokenSource(ct);
        one.CancelAfter(timeout);
        var (socket, _) = await ConnectOneAsync(c.ConnectTo, one.Token).ConfigureAwait(false);
        if (c.ProxyRequest is null) return (socket, c);
        try
        {
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(ct);
            wait.CancelAfter(ProxyTimeout);
            await socket.SendAsync(Encoding.ASCII.GetBytes(c.ProxyRequest), SocketFlags.None, wait.Token).ConfigureAwait(false);
            var status = new byte[1];
            var n = await socket.ReceiveAsync(status, SocketFlags.None, wait.Token).ConfigureAwait(false);
            if (n != 1 || status[0] != 0) throw NearclipException.Io($"tailnet dial failed ({(n == 1 ? status[0] : -1)})");
            return (socket, c);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    static async Task<(Socket Socket, Endpoint Endpoint)> ConnectOneAsync(Endpoint ep, CancellationToken ct)
    {
        Socket socket;
        if (IPAddress.TryParse(ep.H, out var ip))
        {
            socket = new Socket(ip.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
            try { await socket.ConnectAsync(new IPEndPoint(ip, ep.P), ct).ConfigureAwait(false); }
            catch { socket.Dispose(); throw; }
        }
        else
        {
            socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
            try { await socket.ConnectAsync(ep.H, ep.P, ct).ConfigureAwait(false); }
            catch { socket.Dispose(); throw; }
        }
        Configure(socket);
        return (socket, ep);
    }

    public static void Configure(Socket socket)
    {
        try { socket.NoDelay = true; } catch (Exception) { }
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 20);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 5);
        }
        catch (Exception) { /* not supported everywhere */ }
    }

    /// <summary>Remote IPv4 (IPv4-mapped IPv6 unwrapped), or null.</summary>
    public static string? RemoteHost(Socket socket)
    {
        try
        {
            if (socket.RemoteEndPoint is not IPEndPoint ep) return null;
            var a = ep.Address.IsIPv4MappedToIPv6 ? ep.Address.MapToIPv4() : ep.Address;
            a.ScopeId = 0;
            return a.ToString();
        }
        catch (Exception) { return null; }
    }
}
