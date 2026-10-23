using System.Net;
using System.Net.Sockets;

namespace Nearclip.Core;

internal static class Dialer
{
    /// <summary>Connects to every endpoint in parallel and keeps the first that answers.</summary>
    public static async Task<(Socket Socket, Endpoint Endpoint)> ConnectAnyAsync(IReadOnlyList<Endpoint> targets, TimeSpan timeout, CancellationToken ct)
    {
        if (targets.Count == 0) throw NearclipException.Io("no address");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        var pending = targets.Distinct().Select(t => ConnectOneAsync(t, cts.Token)).ToList();
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
