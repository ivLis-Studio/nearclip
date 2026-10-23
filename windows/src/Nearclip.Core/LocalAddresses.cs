using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Nearclip.Core;

public static class LocalAddresses
{
    /// <summary>Non-loopback, non-link-local IPv4 addresses of interfaces that are up; LAN adapters first,
    /// virtual/VPN adapters last.</summary>
    public static IReadOnlyList<string> Ipv4()
    {
        var found = new List<(int Rank, int Order, string Address)>();
        NetworkInterface[] interfaces;
        try { interfaces = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { return []; }
        var order = 0;
        foreach (var ni in interfaces)
        {
            try
            {
                if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var props = ni.GetIPProperties();
                foreach (var ua in props.UnicastAddresses)
                {
                    var a = ua.Address;
                    if (a.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(a)) continue;
                    var s = a.ToString();
                    if (s.StartsWith("169.254.", StringComparison.Ordinal)) continue;
                    found.Add((Rank(ni, props), order++, s));
                }
            }
            catch (Exception) { /* interface vanished or unsupported property */ }
        }
        return found.OrderBy(x => x.Rank).ThenBy(x => x.Order).Select(x => x.Address).Distinct().ToList();
    }

    static int Rank(NetworkInterface ni, IPInterfaceProperties props)
    {
        var text = (ni.Name + " " + ni.Description).ToLowerInvariant();
        if (ni.NetworkInterfaceType is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp) return 5;
        string[] vpn = ["tailscale", "zerotier", "wireguard", "vpn", "utun", "ipsec", "tun", "tap-"];
        if (vpn.Any(text.Contains)) return 4;
        string[] virt = ["vethernet", "hyper-v", "virtual", "vmware", "virtualbox", "vbox", "bridge", "vnic", "docker", "wsl"];
        if (virt.Any(text.Contains)) return 3;
        var hasGateway = false;
        try
        {
            hasGateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
        }
        catch (Exception) { /* not supported on this OS */ }
        if (text.StartsWith("en0", StringComparison.Ordinal)) return 0;
        if (ni.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet)
            return hasGateway ? 0 : 1;
        return hasGateway ? 1 : 2;
    }
}
