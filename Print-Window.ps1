# Print-Window.ps1 —— 用 PrintWindow 抓取被遮挡窗口的真实内容（开发/核对用）
#
# 用途：在无人值守的情况下截取资源管理器窗口，核对文件夹图标是否生效。
# 普通用户不需要这个脚本。
#
# 示例：
#   .\Print-Window.ps1 -Out .\shot.png -TitleMatch '\(E:\)' -ClassMatch '^CabinetWClass$'
param(
    [string]$Out = (Join-Path $env:TEMP 'printwin.png'),
    [string]$TitleMatch = '\([A-Z]:\)',
    [string]$ClassMatch = '^CabinetWClass$|^ExploreWClass$'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public class PW {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public const uint PW_RENDERFULLCONTENT = 0x00000002;

  public static string Title(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
  public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }

  public static List<IntPtr> TopLevel() {
    var list = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr p) { if (IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
    return list;
  }

  public static Bitmap Capture(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    int w = r.R - r.L, ht = r.B - r.T;
    var bmp = new Bitmap(w, ht, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      try { PrintWindow(h, hdc, PW_RENDERFULLCONTENT); }
      finally { g.ReleaseHdc(hdc); }
    }
    return bmp;
  }
}
'@

$target = [IntPtr]::Zero; $bestArea = 0
foreach ($h in [PW]::TopLevel()) {
    if ([PW]::Cls($h) -notmatch $ClassMatch) { continue }
    if ([PW]::Title($h) -notmatch $TitleMatch) { continue }
    $rect = New-Object PW+RECT
    [PW]::GetWindowRect($h, [ref]$rect) | Out-Null
    $area = ($rect.R - $rect.L) * ($rect.B - $rect.T)
    if ($area -gt $bestArea) { $bestArea = $area; $target = $h }
}
if ($target -eq [IntPtr]::Zero) { Write-Host '未找到窗口'; exit 1 }
Write-Host "抓取窗口: '$([PW]::Title($target))'"

$bmp = [PW]::Capture($target)
$dir = Split-Path $Out -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (Test-Path $Out) { Remove-Item $Out -Force }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "输出: $Out ($((Get-Item $Out).Length) 字节)"
