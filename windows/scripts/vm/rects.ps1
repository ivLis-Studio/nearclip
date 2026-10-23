<# Prints "title|x,y,w,h" (physical pixels) for every visible top-level window of the Nearclip process. #>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -Namespace Nc -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
'@
[Nc.Win]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$proc = Get-Process Nearclip -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { return }
$list = New-Object System.Collections.Generic.List[string]
$cb = [Nc.Win+EnumProc] {
    param($h, $l)
    $p = 0
    [void][Nc.Win]::GetWindowThreadProcessId($h, [ref]$p)
    if ($p -eq $proc.Id -and [Nc.Win]::IsWindowVisible($h)) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][Nc.Win]::GetWindowText($h, $sb, 256)
        $r = New-Object Nc.Win+RECT
        [void][Nc.Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16)
        if (($r.R - $r.L) -gt 1) { $list.Add(('{0}|{1},{2},{3},{4}' -f $sb.ToString(), $r.L, $r.T, ($r.R - $r.L), ($r.B - $r.T))) }
    }
    return $true
}
[void][Nc.Win]::EnumWindows($cb, [IntPtr]::Zero)
$list
