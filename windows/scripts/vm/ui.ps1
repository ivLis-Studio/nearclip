<#
  Drives the Nearclip UI inside the test VM with real input: finds elements with UI Automation and clicks / types
  with SendInput (so the app sees the same events as from a person). Used for screenshots and flow checks.
    ui.ps1 -List                              # Nearclip windows and their screen rectangles
    ui.ps1 -Window 'Nearclip' -Tree           # named elements of a window
    ui.ps1 -Window 'Nearclip' -Click NextButton
    ui.ps1 -Click LinkBox -Type 'nearclip://pair?...'
    ui.ps1 -Keys 'win+alt+v'
#>
param(
    [string]$Window = '*',
    [string]$Click,
    [string]$Type,
    [string]$Keys,
    [switch]$List,
    [switch]$Tree
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace Nc -Name Input -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
[StructLayout(LayoutKind.Sequential)] public struct KI { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
[StructLayout(LayoutKind.Explicit)] public struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KI ki; [FieldOffset(32)] public long pad; }
[DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int size);
public static void Click(int x, int y) { SetCursorPos(x, y); System.Threading.Thread.Sleep(90); mouse_event(2, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(50); mouse_event(4, 0, 0, 0, IntPtr.Zero); }
public static void Type(string s) { foreach (char c in s) { IN[] a = new IN[2]; a[0].type = 1; a[0].ki.wScan = c; a[0].ki.dwFlags = 4; a[1].type = 1; a[1].ki.wScan = c; a[1].ki.dwFlags = 6; SendInput(2, a, Marshal.SizeOf(typeof(IN))); System.Threading.Thread.Sleep(3); } }
public static void Down(byte vk) { keybd_event(vk, 0, 0, IntPtr.Zero); }
public static void Up(byte vk) { keybd_event(vk, 0, 2, IntPtr.Zero); }
'@
[Nc.Input]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$AE = [Windows.Automation.AutomationElement]

function Get-NearclipWindows {
    $proc = Get-Process Nearclip -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { throw 'Nearclip is not running' }
    $cond = New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
    $AE::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $cond)
}

function Rect($el) {
    $r = $el.Current.BoundingRectangle
    '{0},{1},{2},{3}' -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height
}

$windows = @(Get-NearclipWindows | Where-Object { $_.Current.Name -like $Window })
if ($List) {
    foreach ($w in (Get-NearclipWindows)) { "{0} @ {1}" -f $w.Current.Name, (Rect $w) }
    return
}
if ($windows.Count -eq 0 -and ($Click -or $Tree)) { throw "no Nearclip window matches '$Window'" }
$win = $windows | Select-Object -First 1

if ($Tree) {
    $all = $win.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        if ($e.Current.AutomationId -or $e.Current.Name) {
            "{0} [{1}] '{2}' @ {3}" -f $e.Current.ControlType.ProgrammaticName, $e.Current.AutomationId, $e.Current.Name, (Rect $e)
        }
    }
    return
}

if ($Click) {
    $el = $win.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Click)))
    if (-not $el) { $el = $win.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Click))) }
    if (-not $el) { throw "element '$Click' not found in '$($win.Current.Name)'" }
    $r = $el.Current.BoundingRectangle
    [Nc.Input]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    "clicked $Click"
    Start-Sleep -Milliseconds 150
}

if ($Type) {
    [Nc.Input]::Type($Type)
    "typed $($Type.Length) chars"
}

if ($Keys) {
    $map = @{ ctrl = 0x11; alt = 0x12; shift = 0x10; win = 0x5B; enter = 0x0D; esc = 0x1B; tab = 0x09; down = 0x28; up = 0x26; left = 0x25; right = 0x27; delete = 0x2E; back = 0x08; space = 0x20 }
    foreach ($chord in $Keys.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) {
        $codes = foreach ($k in $chord.ToLower().Split('+')) {
            if ($map.ContainsKey($k)) { [byte]$map[$k] } elseif ($k.Length -eq 1) { [byte][char]$k.ToUpper() } else { throw "unknown key $k" }
        }
        foreach ($c in $codes) { [Nc.Input]::Down($c); Start-Sleep -Milliseconds 20 }
        Start-Sleep -Milliseconds 40
        [array]::Reverse($codes)
        foreach ($c in $codes) { [Nc.Input]::Up($c); Start-Sleep -Milliseconds 20 }
        Start-Sleep -Milliseconds 120
    }
    "keys $Keys"
}
