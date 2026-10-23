using System.Diagnostics;

namespace Nearclip.App.Platform;

/// <summary>Reads Windows Defender Firewall rules (HNetCfg.FwPolicy2) to tell whether other devices can reach this PC.</summary>
internal static class Firewall
{
    public enum State { Allowed, Blocked, NotAllowedYet, Off, Unknown }

    public sealed record Status(State State, bool PublicNetwork);

    /// <summary>Card description for the current state (onboarding and Settings › Devices).</summary>
    public static string Describe(Status s) => s.State switch
    {
        State.Allowed or State.Off => Nearclip.App.Model.Loc.S("Firewall_AllowedBody"),
        State.Blocked => Nearclip.App.Model.Loc.S("Firewall_BlockedBody"),
        State.NotAllowedYet when s.PublicNetwork => Nearclip.App.Model.Loc.S("Firewall_PublicBody"),
        _ => Nearclip.App.Model.Loc.S("Firewall_Body"),
    };

    public static Status Check(string exePath)
    {
        try
        {
            var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            if (type is null) return new(State.Unknown, false);
            dynamic policy = Activator.CreateInstance(type)!;
            int profiles = policy.CurrentProfileTypes;
            var isPublic = (profiles & 4) != 0;
            var enabled = false;
            foreach (var p in new[] { 1, 2, 4 })
                if ((profiles & p) != 0 && (bool)policy.FirewallEnabled[p]) enabled = true;
            if (!enabled) return new(State.Off, isPublic);
            bool allow = false, block = false;
            foreach (dynamic rule in policy.Rules)
            {
                string? app = rule.ApplicationName;
                if (app is null || !string.Equals(Path.GetFullPath(app), Path.GetFullPath(exePath), StringComparison.OrdinalIgnoreCase)) continue;
                if (!(bool)rule.Enabled || (int)rule.Direction != 1 || ((int)rule.Profiles & profiles) == 0) continue;
                if ((int)rule.Action == 1) allow = true; else block = true;
            }
            return new(block ? State.Blocked : allow ? State.Allowed : State.NotAllowedYet, isPublic);
        }
        catch (Exception e)
        {
            Log.Write("firewall check failed: " + e.Message);
            return new(State.Unknown, false);
        }
    }

    /// <summary>Asks for elevation (UAC) and adds an inbound allow rule for this program on every network profile,
    /// replacing block rules Windows created when the firewall prompt was dismissed.</summary>
    public static bool RequestAllow(string exePath)
    {
        try
        {
            var quoted = "\"" + exePath + "\"";
            var args = $"/c netsh advfirewall firewall delete rule name=all program={quoted} >nul & " +
                       $"netsh advfirewall firewall add rule name=\"Nearclip\" dir=in action=allow program={quoted} enable=yes profile=any protocol=tcp";
            var p = Process.Start(new ProcessStartInfo("cmd.exe", args) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden });
            p?.WaitForExit(20000);
            return p?.ExitCode == 0;
        }
        catch (Exception e)
        {
            Log.Write("firewall allow cancelled: " + e.Message);
            return false;
        }
    }
}
