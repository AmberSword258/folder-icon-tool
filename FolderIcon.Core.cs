// FolderIcon.Core.cs
// 文件夹图标工具 —— 核心引擎
// 功能：解析 PE 判断 GUI/控制台、提取 exe 内嵌图标、重建多尺寸 .ico、
//       通过 desktop.ini 设置/恢复文件夹图标、通知资源管理器刷新。
// 目标框架：.NET Framework 4.x（由 PowerShell 5.1 的 Add-Type 编译）

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace FolderIconTool
{
    #region 原生互操作

    internal static class Native
    {
        public const uint SHGFI_ICON = 0x000000100;
        public const uint SHGFI_LARGEICON = 0x000000000;
        public const uint SHGFI_SMALLICON = 0x000000001;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct SHFILEINFO
        {
            public IntPtr hIcon;
            public int iIcon;
            public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes,
            ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SHDefExtractIcon(string pszIconFile, int iIndex, uint uFlags,
            ref IntPtr phiconLarge, ref IntPtr phiconSmall, uint nIconSize);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern uint ExtractIconEx(string lpszFile, int nIconIndex,
            IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam,
            string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetFileAttributes(string lpFileName, uint dwFileAttributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetFileAttributes(string lpFileName);

        public const uint FILE_ATTRIBUTE_READONLY = 0x1;
        public const uint FILE_ATTRIBUTE_HIDDEN = 0x2;
        public const uint FILE_ATTRIBUTE_SYSTEM = 0x4;
        public const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
        public const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;

        public const int SHCNE_UPDATEDIR = 0x00001000;
        public const int SHCNE_UPDATEITEM = 0x00002000;
        public const int SHCNE_ASSOCCHANGED = 0x08000000;
        public const uint SHCNF_PATHW = 0x0005;
        public const uint SHCNF_FLUSH = 0x1000;

        public const uint WM_COMMAND = 0x0111;
        public const uint SMTO_ABORTIFHUNG = 0x0002;
    }

    #endregion

    #region PE 解析：判断 exe 是图形程序还是控制台程序

    /// <summary>轻量 PE 头解析，仅用于读取子系统（GUI / 控制台）与机器类型。</summary>
    public static class PeInspector
    {
        public enum SubsystemKind
        {
            Unknown = 0,
            Native = 1,
            WindowsGui = 2,
            WindowsConsole = 3,
            Other = 99
        }

        public sealed class Info
        {
            public SubsystemKind Subsystem = SubsystemKind.Unknown;
            public bool Is64Bit;
            public bool IsDotNet;
            public bool IsValidPe;
            public string Description = "";
        }

        public static Info Inspect(string exePath)
        {
            var info = new Info();
            try
            {
                using (var fs = new FileStream(exePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var br = new BinaryReader(fs))
                {
                    if (fs.Length < 0x100) { info.Description = "文件过小"; return info; }
                    if (br.ReadUInt16() != 0x5A4D) { info.Description = "非 MZ 头"; return info; } // 'MZ'
                    fs.Position = 0x3C;
                    int peOffset = br.ReadInt32();
                    if (peOffset <= 0 || peOffset + 24 > fs.Length) { info.Description = "PE 偏移无效"; return info; }
                    fs.Position = peOffset;
                    if (br.ReadUInt32() != 0x00004550) { info.Description = "非 PE 签名"; return info; } // 'PE\0\0'

                    ushort machine = br.ReadUInt16();
                    info.Is64Bit = (machine == 0x8664 || machine == 0xAA64);
                    int numberOfSections = br.ReadUInt16();
                    br.ReadUInt32(); // TimeDateStamp
                    br.ReadUInt32(); // PointerToSymbolTable
                    br.ReadUInt32(); // NumberOfSymbols
                    int sizeOfOptionalHeader = br.ReadUInt16();
                    br.ReadUInt16(); // Characteristics

                    if (sizeOfOptionalHeader < 70) { info.Description = "可选头过小"; return info; }
                    long optStart = fs.Position;
                    ushort magic = br.ReadUInt16();
                    bool pe32Plus = (magic == 0x20B);
                    // Subsystem 位于可选头偏移 68（PE32 与 PE32+ 相同）
                    fs.Position = optStart + 68;
                    ushort subsystem = br.ReadUInt16();
                    switch (subsystem)
                    {
                        case 1: info.Subsystem = SubsystemKind.Native; break;
                        case 2: info.Subsystem = SubsystemKind.WindowsGui; break;
                        case 3: info.Subsystem = SubsystemKind.WindowsConsole; break;
                        default: info.Subsystem = SubsystemKind.Other; break;
                    }

                    // 判断是否为 .NET 程序集：查 COM 描述符目录（可选头偏移 208 for PE32+，208/224 视版本而定）
                    try
                    {
                        long comOffset = optStart + (pe32Plus ? 112 + 14 * 8 : 96 + 14 * 8);
                        if (comOffset + 8 <= fs.Length)
                        {
                            fs.Position = comOffset;
                            uint comRva = br.ReadUInt32();
                            uint comSize = br.ReadUInt32();
                            if (comRva != 0 && comSize != 0) info.IsDotNet = true;
                        }
                    }
                    catch { /* 忽略：.NET 检测失败不影响主流程 */ }

                    info.IsValidPe = true;
                    info.Description = info.Subsystem.ToString() + (info.Is64Bit ? " x64" : " x86") + (info.IsDotNet ? " .NET" : "");
                }
            }
            catch (Exception ex)
            {
                info.Description = "读取失败: " + ex.Message;
            }
            return info;
        }
    }

    #endregion

    #region 图标提取

    /// <summary>从可执行文件中提取图标，优先使用系统外壳以获得最佳多尺寸质量。</summary>
    public static class IconExtractor
    {
        /// <summary>标准图标尺寸梯度。</summary>
        public static readonly int[] StandardSizes = new[] { 16, 24, 32, 48, 64, 128, 256 };

        /// <summary>按需获取指定尺寸的位图；系统无该尺寸时返回 null。</summary>
        public static Bitmap GetSize(string exePath, int size)
        {
            // SHDefExtractIcon: 低 16 位为小图标尺寸，高 16 位为大图标尺寸
            uint packed = (uint)((size & 0xFFFF) | ((size & 0xFFFF) << 16));
            IntPtr hLarge = IntPtr.Zero, hSmall = IntPtr.Zero;
            try
            {
                int hr = Native.SHDefExtractIcon(exePath, 0, 0, ref hLarge, ref hSmall, packed);
                IntPtr h = hLarge != IntPtr.Zero ? hLarge : hSmall;
                if (hr == 0 && h != IntPtr.Zero)
                {
                    using (var ico = Icon.FromHandle(h))
                    {
                        var bmp = CloneViaDraw(ico, size);
                        if (bmp != null) return bmp;
                    }
                }
            }
            catch { /* 回退到 ExtractIconEx */ }
            finally
            {
                if (hLarge != IntPtr.Zero) Native.DestroyIcon(hLarge);
                if (hSmall != IntPtr.Zero && hSmall != hLarge) Native.DestroyIcon(hSmall);
            }
            return null;
        }

        private static Bitmap CloneViaDraw(Icon ico, int size)
        {
            try
            {
                var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Transparent);
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    g.DrawIcon(ico, new Rectangle(0, 0, size, size));
                }
                return bmp;
            }
            catch { return null; }
        }

        /// <summary>回退方案：ExtractIconEx，通常只有 32x32。</summary>
        public static Bitmap FallbackExtract(string exePath, int size)
        {
            var large = new IntPtr[1];
            var small = new IntPtr[1];
            try
            {
                uint got = Native.ExtractIconEx(exePath, 0, large, small, 1);
                IntPtr h = large[0] != IntPtr.Zero ? large[0] : small[0];
                if (got == 0 || h == IntPtr.Zero) return null;
                using (var ico = Icon.FromHandle(h))
                {
                    return CloneViaDraw(ico, size);
                }
            }
            catch { return null; }
            finally
            {
                if (large[0] != IntPtr.Zero) Native.DestroyIcon(large[0]);
                if (small[0] != IntPtr.Zero) Native.DestroyIcon(small[0]);
            }
        }

        /// <summary>
        /// 提取多尺寸图标集合，键为标准尺寸，值为位图。
        /// 策略：优先原生尺寸；缺失的尺寸由更大尺寸高质量缩小补齐（不做上采样放大）。
        /// </summary>
        public static SortedDictionary<int, Bitmap> ExtractMultiSize(string exePath, bool allowSmallPlaceholder = true)
        {
            var native = new SortedDictionary<int, Bitmap>();
            foreach (int s in StandardSizes)
            {
                Bitmap bmp = GetSize(exePath, s);
                if (bmp == null) bmp = FallbackExtract(exePath, s);
                if (bmp != null && !IsBlank(bmp)) native[s] = bmp;
            }

            // 全部失败：使用系统默认应用程序图标
            if (native.Count == 0 && allowSmallPlaceholder)
            {
                var def = SystemIcons.Application;
                foreach (int s in new[] { 16, 32, 48 })
                    native[s] = CloneViaDraw(def, s);
            }

            int maxNative = native.Count > 0 ? native.Keys.Max() : 0;
            var result = new SortedDictionary<int, Bitmap>();

            // 由大到小依次补全：每个尺寸要么用原生，要么由最近的更大尺寸缩小
            foreach (int s in StandardSizes.Where(x => x <= Math.Max(maxNative, 32)).OrderByDescending(x => x))
            {
                if (native.ContainsKey(s)) { result[s] = native[s]; continue; }
                int src = native.Keys.Where(k => k > s).OrderBy(k => k).FirstOrDefault();
                if (src == 0) continue;
                var scaled = ResizeWithAlpha(native[src], s);
                if (scaled != null) result[s] = scaled;
            }

            // 补齐最小尺寸组合，保证图标在任意视图下都有内容
            foreach (int s in new[] { 16, 32, 48 })
            {
                if (result.ContainsKey(s)) continue;
                int src = result.Keys.Where(k => k > s).OrderBy(k => k).FirstOrDefault();
                if (src != 0) result[s] = ResizeWithAlpha(result[src], s);
            }
            return result;
        }

        /// <summary>判断位图是否完全透明（某些 exe 会返回空白图标）。</summary>
        public static bool IsBlank(Bitmap bmp)
        {
            if (bmp == null) return true;
            try
            {
                var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
                var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    int stride = data.Stride;
                    var buf = new byte[stride * bmp.Height];
                    Marshal.Copy(data.Scan0, buf, 0, buf.Length);
                    for (int i = 3; i < buf.Length; i += 4)
                        if (buf[i] != 0) return false;
                    return true;
                }
                finally { bmp.UnlockBits(data); }
            }
            catch { return false; }
        }

        /// <summary>按标准尺寸梯度，由已有位图生成完整的多尺寸集合（只缩小，不放大）。</summary>
        public static SortedDictionary<int, Bitmap> BuildSizeSet(IEnumerable<KeyValuePair<int, Bitmap>> native)
        {
            var have = new SortedDictionary<int, Bitmap>();
            if (native != null)
                foreach (var kv in native)
                    if (kv.Value != null && kv.Key >= 1 && kv.Key <= 256 && !have.ContainsKey(kv.Key))
                        have[kv.Key] = kv.Value;

            var result = new SortedDictionary<int, Bitmap>();
            if (have.Count == 0) return result;

            int maxNative = have.Keys.Max();
            foreach (int s in StandardSizes.Where(x => x <= maxNative).OrderByDescending(x => x))
            {
                if (have.ContainsKey(s)) { result[s] = have[s]; continue; }
                int src = have.Keys.Where(k => k > s).OrderBy(k => k).FirstOrDefault();
                if (src == 0) continue;
                var scaled = ResizeWithAlpha(have[src], s);
                if (scaled != null) result[s] = scaled;
            }

            // 补齐最小尺寸组合，保证图标在任意视图下都有内容
            foreach (int s in new[] { 16, 32, 48 })
            {
                if (result.ContainsKey(s)) continue;
                int src = result.Keys.Where(k => k > s).OrderBy(k => k).FirstOrDefault();
                if (src == 0) continue;
                var scaled = ResizeWithAlpha(result[src], s);
                if (scaled != null) result[s] = scaled;
            }
            return result;
        }

        /// <summary>读取 .ico 文件，返回其中每个尺寸的位图。</summary>
        public static SortedDictionary<int, Bitmap> LoadFromIcoFile(string icoPath)
        {
            var dict = new SortedDictionary<int, Bitmap>();
            foreach (int size in StandardSizes)
            {
                try
                {
                    using (var ico = new Icon(icoPath, size, size))
                    {
                        // 仅当该尺寸确实是图标内的原生尺寸时才采用，
                        // 否则 Icon 会拿别的尺寸缩放后返回，导致重复且模糊
                        int native = ico.Width;
                        if (native != size) continue;
                        var bmp = CloneViaDraw(ico, size);
                        if (bmp != null && !IsBlank(bmp)) dict[size] = bmp;
                    }
                }
                catch { }
            }

            // 某些 ico 的尺寸不在标准梯度里（如 20/40/96），用最大尺寸兜底
            if (dict.Count == 0)
            {
                try
                {
                    using (var src = LoadLargestFrame(icoPath))
                    {
                        if (src != null)
                        {
                            int s = Math.Min(256, Math.Max(src.Width, src.Height));
                            dict[s] = ResizeWithAlpha(src, s);
                        }
                    }
                }
                catch { }
            }
            return dict;
        }

        /// <summary>取 ICO / 图片文件中尺寸最大的一帧，作为缩放母版。</summary>
        public static Bitmap LoadLargestFrame(string path)
        {
            string ext = Path.GetExtension(path).ToLowerInvariant();
            if (ext == ".ico")
            {
                Bitmap best = null;
                foreach (int size in new[] { 256, 128, 96, 64, 48, 40, 32, 24, 20, 16 })
                {
                    try
                    {
                        using (var ico = new Icon(path, size, size))
                        {
                            if (ico.Width != size) continue;
                            var bmp = CloneViaDraw(ico, size);
                            if (bmp == null) continue;
                            if (best == null || bmp.Width > best.Width)
                            {
                                if (best != null) best.Dispose();
                                best = bmp;
                            }
                        }
                    }
                    catch { }
                }
                return best;
            }

            // 普通图片：用流方式打开，避免锁定源文件
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var img = Image.FromStream(fs, true, true))
                {
                    int side = Math.Min(256, Math.Max(img.Width, img.Height));
                    var bmp = new Bitmap(side, side, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.Clear(Color.Transparent);
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.SmoothingMode = SmoothingMode.HighQuality;
                        // 按最长边等比缩放，非正方形居中，保持透明
                        double scale = Math.Min((double)side / img.Width, (double)side / img.Height);
                        int w = Math.Max(1, (int)Math.Round(img.Width * scale));
                        int h = Math.Max(1, (int)Math.Round(img.Height * scale));
                        var attrs = new ImageAttributes();
                        attrs.SetWrapMode(WrapMode.TileFlipXY);
                        g.DrawImage(img, new Rectangle((side - w) / 2, (side - h) / 2, w, h),
                            0, 0, img.Width, img.Height, GraphicsUnit.Pixel, attrs);
                    }
                    return bmp;
                }
            }
            catch { return null; }
        }

        /// <summary>判断扩展名是否可作为图标来源（可执行文件 / 图标 / 普通图片）。</summary>
        public static bool IsSupportedIconSource(string path)
        {
            string ext = Path.GetExtension(path).ToLowerInvariant();
            switch (ext)
            {
                case ".exe": case ".dll": case ".ocx": case ".cpl": case ".scr": case ".msi":
                case ".ico": case ".png": case ".jpg": case ".jpeg": case ".bmp": case ".gif":
                case ".tif": case ".tiff": case ".webp":
                    return true;
                default:
                    return false;
            }
        }

        /// <summary>
        /// 统一入口：从任意支持的来源取得多尺寸图标集合。
        /// 可执行文件走外壳提取，.ico 直接解析，普通图片整体缩放。
        /// </summary>
        public static SortedDictionary<int, Bitmap> GetFrames(string sourcePath)
        {
            if (string.IsNullOrEmpty(sourcePath) || !File.Exists(sourcePath))
                throw new FileNotFoundException("图标来源文件不存在：" + sourcePath);

            string ext = Path.GetExtension(sourcePath).ToLowerInvariant();
            if (ext == ".ico") return LoadFromIcoFile(sourcePath);
            if (ext == ".exe" || ext == ".dll" || ext == ".ocx" || ext == ".cpl" ||
                ext == ".scr" || ext == ".msi")
                return ExtractMultiSize(sourcePath);

            // 普通图片
            var result = new SortedDictionary<int, Bitmap>();
            var frame = LoadLargestFrame(sourcePath);
            if (frame == null) throw new InvalidOperationException("无法读取图片文件：" + sourcePath);
            var set = BuildSizeSet(new[] { new KeyValuePair<int, Bitmap>(frame.Width, frame) });
            foreach (var kv in set) result[kv.Key] = kv.Value;
            return result;
        }

        /// <summary>高质量缩放，保留 alpha（先转预乘再插值，避免边缘发黑）。</summary>
        public static Bitmap ResizeWithAlpha(Bitmap src, int size)
        {
            if (src == null) return null;
            try
            {
                var dst = new Bitmap(size, size, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(dst))
                {
                    g.Clear(Color.Transparent);
                    g.CompositingMode = CompositingMode.SourceOver;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    var attrs = new ImageAttributes();
                    attrs.SetWrapMode(WrapMode.TileFlipXY);
                    g.DrawImage(src, new Rectangle(0, 0, size, size),
                        0, 0, src.Width, src.Height, GraphicsUnit.Pixel, attrs);
                }
                return dst;
            }
            catch { return null; }
        }
    }

    #endregion

    #region ICO 写入

    /// <summary>把多张位图写成标准的 32bpp BGRA 多尺寸 .ico 文件。</summary>
    public static class IcoWriter
    {
        public static void Write(string icoPath, IEnumerable<KeyValuePair<int, Bitmap>> images)
        {
            var list = images.Where(kv => kv.Value != null && kv.Key >= 1 && kv.Key <= 256)
                             .OrderBy(kv => kv.Key)
                             .ToList();
            if (list.Count == 0) throw new InvalidOperationException("没有可写入的图标图像。");

            var dir = Path.GetDirectoryName(icoPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var temp = icoPath + ".tmp";
            using (var fs = new FileStream(temp, FileMode.Create, FileAccess.Write))
            using (var bw = new BinaryWriter(fs))
            {
                // ICONDIR
                bw.Write((ushort)0);            // reserved
                bw.Write((ushort)1);            // type = icon
                bw.Write((ushort)list.Count);   // image count

                var imageData = new List<byte[]>();
                foreach (var kv in list)
                    imageData.Add(BuildIconImage(kv.Value, kv.Key));

                int offset = 6 + 16 * list.Count;
                for (int i = 0; i < list.Count; i++)
                {
                    int size = list[i].Key;
                    byte[] data = imageData[i];
                    bw.Write((byte)(size >= 256 ? 0 : size)); // width
                    bw.Write((byte)(size >= 256 ? 0 : size)); // height
                    bw.Write((byte)0);                        // 调色板颜色数（32bpp 为 0）
                    bw.Write((byte)0);                        // reserved
                    bw.Write((ushort)1);                      // color planes
                    bw.Write((ushort)32);                     // bits per pixel
                    bw.Write((uint)data.Length);              // 图像数据字节数
                    bw.Write((uint)offset);                   // 数据偏移
                    offset += data.Length;
                }
                foreach (var data in imageData) bw.Write(data);
            }
            if (File.Exists(icoPath)) File.Delete(icoPath);
            File.Move(temp, icoPath);
        }

        /// <summary>构造 ICO 内嵌的图标图像：BITMAPINFOHEADER + BGRA 像素（自下而上）+ AND 掩码。</summary>
        private static byte[] BuildIconImage(Bitmap source, int size)
        {
            using (var bmp = IconExtractor.ResizeWithAlpha(source, size) ?? new Bitmap(source, size, size))
            {
                int stride = size * 4;
                int maskStride = ((size + 31) / 32) * 4;
                int pixelBytes = stride * size;
                int maskBytes = maskStride * size;
                var buffer = new byte[40 + pixelBytes + maskBytes];

                // BITMAPINFOHEADER
                BitConverter.GetBytes(40).CopyTo(buffer, 0);                    // biSize
                BitConverter.GetBytes(size).CopyTo(buffer, 4);                  // biWidth
                BitConverter.GetBytes(size * 2).CopyTo(buffer, 8);              // biHeight（XOR + AND）
                BitConverter.GetBytes((ushort)1).CopyTo(buffer, 12);            // biPlanes
                BitConverter.GetBytes((ushort)32).CopyTo(buffer, 14);           // biBitCount
                BitConverter.GetBytes(0).CopyTo(buffer, 16);                    // biCompression = BI_RGB
                BitConverter.GetBytes(pixelBytes).CopyTo(buffer, 20);           // biSizeImage

                var rect = new Rectangle(0, 0, size, size);
                var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var row = new byte[stride];
                    for (int y = 0; y < size; y++)
                    {
                        // 源数据自上而下，ICO 要求自下而上
                        Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, stride);
                        Buffer.BlockCopy(row, 0, buffer, 40 + (size - 1 - y) * stride, stride);
                    }
                }
                finally { bmp.UnlockBits(data); }

                // AND 掩码：全部置 1（不透明），透明度交给 32bpp 的 alpha 通道
                byte[] maskRow = new byte[maskStride];
                for (int i = 0; i < maskRow.Length; i++) maskRow[i] = 0xFF;
                for (int y = 0; y < size; y++)
                    Buffer.BlockCopy(maskRow, 0, buffer, 40 + pixelBytes + y * maskStride, maskStride);

                return buffer;
            }
        }
    }

    #endregion

    #region 候选可执行文件发现与打分

    public sealed class ExeCandidate
    {
        public string Path;
        public string FileName;
        public long Size;
        public PeInspector.Info Pe;
        public int Score;
        public string Reason = "";

        /// <summary>相对于目标文件夹的层级：0 = 文件夹内，1 = 一级子文件夹，以此类推。</summary>
        public int Depth;

        /// <summary>相对于目标文件夹的路径，用于界面展示。</summary>
        public string RelativePath = "";

        /// <summary>是否为卸载/安装/更新等辅助程序。</summary>
        public bool IsHelper;

        /// <summary>文件名与文件夹名是否高度吻合（强信号，可豁免部分降权）。</summary>
        public bool NameMatched;

        public string SizeText
        {
            get
            {
                double mb = Size / 1048576.0;
                if (mb >= 1) return mb.ToString("0.##") + " MB";
                return (Size / 1024.0).ToString("0.#") + " KB";
            }
        }
    }

    /// <summary>在文件夹中寻找可作为“应用本体”的 exe，并按可信度打分。</summary>
    public static class CandidateFinder
    {
        /// <summary>明确的辅助程序关键字：卸载器、安装器、更新器、运行库等。</summary>
        private static readonly string[] HelperKeywords = new[]
        {
            "unins", "uninstall", "uninst", "setup", "install", "instal",
            "update", "updater", "upgrade", "patcher", "patch",
            "crashpad", "crashreport", "crashhandler", "crashsender", "reporter", "werfault",
            "service", "daemon", "watchdog", "scheduler", "elevate", "createdump",
            "register", "unregister", "regsvr", "reset", "repair", "diagnose", "bugreport",
            "vc_redist", "vcredist", "dxsetup", "dxwebsetup", "dotnetfx", "ndp48",
            "unpack", "extract", "7za", "7zr", "busybox", "nircmd", "wget", "curl",
            "ffmpeg", "ffplay", "ffprobe", "yt-dlp", "youtube-dl", "aria2c", "adb", "fastboot",
            "python", "pythonw", "pip", "conda", "npm", "node", "git", "java", "javaw",
            "helper", "bridge", "proxy", "agent", "client_service", "botservice",
            "bmdpanel", "kakaoutil", "util64", "tool64", "healthd", "webengine",
            "subprocess", "renderer", "kiosk", "webrtc"
        };

        /// <summary>可能但不确定的关键字（轻微降权）。</summary>
        private static readonly string[] WeakKeywords = new[]
        {
            "launcher", "launch", "start", "starter", "boot", "config", "settings",
            "tool", "util", "utility", "test", "demo", "sample", "debug", "preview",
            "cli", "cmd", "console", "terminal", "server", "remote", "panel", "tray"
        };

        /// <summary>
        /// 明显不是主界面程序的名称（较强制降权）：
        /// 欢迎页、引导页、教程、迁移向导等，它们通常也带厂商 logo，
        /// 但真正的应用本体才是用户想看到的图标。
        /// </summary>
        private static readonly string[] NonMainKeywords = new[]
        {
            "welcome", "onboarding", "tour", "tutorial", "intro", "gettingstarted",
            "firstrun", "migrate", "migration", "importer", "import", "activate",
            "activation", "license", "readme", "about", "help", "manual", "docs",
            "benchmark", "bench", "probe", "scanner", "monitor", "tray", "hook",
            "subprocess", "renderer", "gpu", "worker", "sync", "backup", "restore"
        };

        /// <summary>这些文件名即使与文件夹同名，也绝不应作为图标来源。</summary>
        private static readonly string[] ForbiddenNames = new[]
        {
            "setup", "install", "installer", "unins000", "uninstall", "update", "updater"
        };

        /// <summary>跳过这些子目录名（不参与深层搜索）。</summary>
        private static readonly string[] SkipDirNames = new[]
        {
            "node_modules", "redist", "redistributables", "thirdparty", "third_party",
            "crashpad", "locales", "resources", "resource", "swiftshader", "squirrelsetup"
        };

        /// <summary>
        /// 在文件夹内查找可执行文件。
        /// 策略：先看文件夹本身；若最优候选是辅助程序（卸载器/安装器），
        /// 则自动向下多搜一层，因为应用本体常常放在 bin、app 之类的子目录里。
        /// </summary>
        public static List<ExeCandidate> Find(string folder, int maxDepth = 2)
        {
            string leafName = Path.GetFileName(folder.TrimEnd('\\', '/'));
            string normalizedFolder = Normalize(leafName);

            var topLevel = new List<ExeCandidate>();
            Collect(topLevel, folder, folder, 0, SkipDirNames);

            // 顶层候选是否全部为辅助程序（决定要不要向下深入搜索）
            foreach (var c in topLevel)
                c.IsHelper = IsHelperName(Path.GetFileNameWithoutExtension(c.FileName));
            bool topBestIsHelper = topLevel.Count == 0 || topLevel.All(c => c.IsHelper);

            var pool = new List<ExeCandidate>(topLevel);
            if (topBestIsHelper && maxDepth > 1)
            {
                // 深入一层寻找真正的应用主体
                try
                {
                    foreach (var sub in Directory.EnumerateDirectories(folder))
                    {
                        string subLeaf = Path.GetFileName(sub);
                        if (subLeaf.StartsWith(".")) continue;
                        if (SkipDirNames.Any(s => subLeaf.Equals(s, StringComparison.OrdinalIgnoreCase))) continue;
                        Collect(pool, sub, folder, 1, SkipDirNames);
                    }
                }
                catch { }
            }

            foreach (var c in pool)
            {
                c.IsHelper = IsHelperName(Path.GetFileNameWithoutExtension(c.FileName));
                c.Pe = PeInspector.Inspect(c.Path);
                Score(c, normalizedFolder);
            }

            var ordered = pool
                .Where(c => !ForbiddenNames.Contains(
                    Path.GetFileNameWithoutExtension(c.FileName).ToLowerInvariant()))
                .OrderByDescending(c => c.Score)
                .ThenByDescending(c => c.Size)
                .ToList();

            // 若过滤后为空，至少把原始集合返回，供用户手动挑选
            return ordered.Count > 0 ? ordered : pool.OrderByDescending(c => c.Score).ToList();
        }

        private static void Collect(List<ExeCandidate> sink, string dir, string rootFolder, int depth, string[] skipDirs)
        {
            try
            {
                foreach (var f in Directory.EnumerateFiles(dir, "*.exe", SearchOption.TopDirectoryOnly))
                {
                    string name = Path.GetFileName(f);
                    // 跳过明显的调试符号与临时文件
                    if (name.EndsWith(".pdb", StringComparison.OrdinalIgnoreCase)) continue;

                    long size = 0;
                    try { size = new FileInfo(f).Length; } catch { }
                    if (size == 0) continue;

                    string rel = f.Substring(rootFolder.TrimEnd('\\').Length).TrimStart('\\');
                    sink.Add(new ExeCandidate
                    {
                        Path = f,
                        FileName = name,
                        Size = size,
                        Depth = depth,
                        RelativePath = rel
                    });
                }
            }
            catch { }
        }

        /// <summary>判断文件名是否为卸载器、安装器、更新器等辅助程序。</summary>
        public static bool IsHelperName(string baseNameNoExt)
        {
            string n = baseNameNoExt.ToLowerInvariant().Replace(" ", "").Replace("-", "").Replace("_", "");
            return HelperKeywords.Any(k => n.Contains(k.Replace("_", "")));
        }

        private static void Score(ExeCandidate c, string normalizedFolder)
        {
            int score = 50;
            var reasons = new List<string>();
            string rawBase = Path.GetFileNameWithoutExtension(c.FileName);
            string baseName = Normalize(rawBase);

            // ---------- 1) 名称与文件夹名的吻合程度 ----------
            int nameBonus = 0;
            if (normalizedFolder.Length >= 2 && baseName.Length >= 2)
            {
                if (baseName == normalizedFolder)
                {
                    nameBonus = 55; reasons.Add("名称与文件夹完全一致"); c.NameMatched = true;
                }
                else if (baseName.StartsWith(normalizedFolder, StringComparison.Ordinal) ||
                         normalizedFolder.StartsWith(baseName, StringComparison.Ordinal))
                {
                    nameBonus = 38; reasons.Add("名称与文件夹高度相似"); c.NameMatched = true;
                }
                else if (baseName.Contains(normalizedFolder) || normalizedFolder.Contains(baseName))
                {
                    // 双向包含：能覆盖 "Davinci resolve" 与 "Resolve.exe"、
                    // "Playnite" 与 "Playnite.DesktopApp.exe" 这类情况
                    nameBonus = 24; reasons.Add("名称包含文件夹名"); c.NameMatched = true;
                }
            }
            // 名称匹配的加分上限为 40，确保无法压过“卸载器”这类强降权
            score += Math.Min(nameBonus, 40);

            // ---------- 2) 子系统类型 ----------
            if (c.Pe != null && c.Pe.IsValidPe)
            {
                if (c.Pe.Subsystem == PeInspector.SubsystemKind.WindowsGui)
                {
                    score += 30; reasons.Add("图形界面程序");
                }
                else if (c.Pe.Subsystem == PeInspector.SubsystemKind.WindowsConsole)
                {
                    score -= 20; reasons.Add("控制台程序");
                }
            }

            // ---------- 3) 体积 ----------
            double mb = c.Size / 1048576.0;
            if (mb >= 20) { score += 18; reasons.Add("体积较大"); }
            else if (mb >= 5) { score += 14; }
            else if (mb >= 1) { score += 9; }
            else if (mb >= 0.2) { score += 3; }
            else if (mb < 0.05) { score -= 14; reasons.Add("体积极小"); }

            // ---------- 4) 辅助程序判定（强降权） ----------
            if (c.IsHelper)
            {
                // 名称完全吻合时减轻处罚（例如 Python 文件夹里的 python.exe）
                int penalty = c.NameMatched ? 30 : 60;
                score -= penalty;
                reasons.Add(c.NameMatched ? "疑似辅助程序（但名称吻合）" : "疑似辅助程序");
            }
            else
            {
                string lower = baseName;
                if (WeakKeywords.Any(k => lower.Contains(k))) { score -= 26; reasons.Add("名称偏工具类"); }
            }

            // ---------- 5) 所在层级 ----------
            if (c.Depth == 0)
            {
                score += 8;
            }
            else
            {
                score -= 6 * c.Depth;
                reasons.Add("位于子文件夹");
                // 子文件夹名与文件夹名相关时给予补偿（如 ImageGlass\App\...）
                try
                {
                    string sub = Path.GetFileName(Path.GetDirectoryName(c.Path));
                    if (!string.IsNullOrEmpty(sub) && normalizedFolder.Length >= 2)
                    {
                        string subN = Normalize(sub);
                        if (subN.Length >= 2 &&
                            (subN.Contains(normalizedFolder) || normalizedFolder.Contains(subN)))
                        {
                            score += 10; reasons.Add("子文件夹名与目标一致");
                        }
                    }
                }
                catch { }
            }

            // ---------- 6) 明显的非主程序 ----------
            string low = rawBase.ToLowerInvariant();
            if (low.EndsWith("_debug") || low.EndsWith("_test") || low.EndsWith("_d"))
            {
                score -= 20; reasons.Add("疑似调试版本");
            }
            // 欢迎页、引导页、教程等不是主界面程序
            // 名称与文件夹完全一致时豁免（例如 Welcome.exe 装在一个叫 Welcome 的文件夹里）
            bool exactName = c.NameMatched && Normalize(low) == normalizedFolder;
            if (!exactName)
            {
                string flat = low.Replace(" ", "").Replace("-", "").Replace("_", "").Replace(".", "");
                string hit = NonMainKeywords.FirstOrDefault(k => flat.Contains(k));
                if (hit != null)
                {
                    score -= 38; reasons.Add("疑似非主界面程序（" + hit + "）");
                }
            }

            c.Score = Math.Max(0, Math.Min(200, score));
            c.Reason = string.Join("、", reasons);
        }

        private static string Normalize(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new StringBuilder();
            foreach (char ch in s.ToLowerInvariant())
                if (char.IsLetterOrDigit(ch)) sb.Append(ch);
            return sb.ToString();
        }

        /// <summary>自动判定是否足够可信。不可信时通过 explanation 说明原因。</summary>
        /// <remarks>
        /// 参数声明为 object 是有意为之：PowerShell 调用 .NET 方法时，
        /// 其数组类型为 Object[]，无法隐式绑定到 IEnumerable&lt;ExeCandidate&gt;，
        /// 这里在方法内部完成元素转换，脚本侧调用更简单。
        /// </remarks>
        public static bool IsConfident(object candidates, out string explanation)
        {
            explanation = "";
            var list = ToCandidateList(candidates);
            if (list.Count == 0)
            {
                explanation = "文件夹内没有可用的 .exe";
                return false;
            }

            // 最优候选是纯辅助程序（且名称不吻合）：不是应用本体
            var top = list[0];
            if (top.IsHelper && !top.NameMatched)
            {
                explanation = "最优候选 " + top.FileName + " 疑似卸载或安装程序，不是应用本体";
                return false;
            }

            // 只有一个候选，而且它本身就是安装/卸载程序
            if (list.Count == 1)
            {
                var only = list[0];
                string onlyBase = Path.GetFileNameWithoutExtension(only.FileName).ToLowerInvariant();
                if (ForbiddenNames.Contains(onlyBase))
                {
                    explanation = "文件夹内只有安装程序 " + only.FileName + "，它不是应用本体（应用可能在子文件夹中）";
                    return false;
                }
                if (only.IsHelper)
                {
                    explanation = "文件夹内只有一个辅助程序（" + only.FileName + "），它很可能不是应用本体";
                    return false;
                }
                explanation = "唯一候选：" + only.FileName;
                return true;
            }

            // 是否存在非安装程序候选：若存在，则安装程序不参与自动判定
            var nonInstaller = list.Where(c => !ForbiddenNames.Contains(
                Path.GetFileNameWithoutExtension(c.FileName).ToLowerInvariant())).ToList();
            if (nonInstaller.Count > 0) list = nonInstaller;
            if (list.Count == 1)
            {
                explanation = "唯一可用候选：" + list[0].FileName;
                return true;
            }
            top = list[0];
            var second = list[1];

            // 绝对分数过低：不可信
            if (top.Score < 55)
            {
                explanation = "最优候选 " + top.FileName + " 的特征不明显（评分 " + top.Score + "）";
                return false;
            }
            // 与第二名差距不足：不可信
            if (top.Score - second.Score < 20)
            {
                explanation = "存在多个特征接近的候选程序（" + top.FileName + " 与 " + second.FileName + "）";
                return false;
            }

            explanation = "自动判定：" + top.FileName +
                          (string.IsNullOrEmpty(top.Reason) ? "" : "（" + top.Reason + "）");
            return true;
        }

        /// <summary>需要用户选择时返回 true。</summary>
        public static bool NeedsUserChoice(object candidates, out string explanation)
        {
            return !IsConfident(candidates, out explanation);
        }

        /// <summary>把 PowerShell 传入的各种集合形态统一转成候选列表。</summary>
        private static List<ExeCandidate> ToCandidateList(object candidates)
        {
            var list = new List<ExeCandidate>();
            if (candidates == null) return list;

            var direct = candidates as ExeCandidate;
            if (direct != null) { list.Add(direct); return list; }

            var enumerable = candidates as System.Collections.IEnumerable;
            if (enumerable == null) return list;

            foreach (var item in enumerable)
            {
                var c = item as ExeCandidate;
                if (c != null) list.Add(c);
            }
            return list;
        }
    }

    #endregion

    #region 文件夹图标设置

    /// <summary>管理 desktop.ini，实现文件夹图标设置与恢复。</summary>
    public static class FolderIconManager
    {
        public const string DesktopIniName = "desktop.ini";

        /// <summary>
        /// 把图标写入 .ico 文件并设置到目标文件夹。
        /// </summary>
        /// <param name="folder">目标文件夹</param>
        /// <param name="iconSource">图标来源：可执行文件 / .ico / 普通图片 均可</param>
        /// <param name="iconOutputPath">生成的 .ico 路径</param>
        /// <param name="keepNameFile">是否同时固定文件夹显示名（写入 LocalizedResourceName）</param>
        /// <remarks>
        /// 关键点：资源管理器只有在文件夹本身带 READONLY 或 SYSTEM 属性时，
        /// 才会去读取该文件夹下的 desktop.ini。缺少这一步图标不会生效，
        /// 这是本工具最容易踩的坑。
        /// </remarks>
        public static void Apply(string folder, string iconSource, string iconOutputPath, bool keepNameFile)
        {
            if (!Directory.Exists(folder)) throw new DirectoryNotFoundException("文件夹不存在：" + folder);
            if (!File.Exists(iconSource)) throw new FileNotFoundException("图标来源文件不存在：" + iconSource);

            // 1) 取图标（exe/dll 走外壳提取，ico 直接解析，图片整体缩放）并写出多尺寸 .ico
            var images = IconExtractor.GetFrames(iconSource);
            if (images.Count == 0) throw new InvalidOperationException("无法从该文件取得图标：" + iconSource);
            IcoWriter.Write(iconOutputPath, images);

            // 2) 写 desktop.ini 并设置 隐藏 + 系统 属性
            string iniPath = Path.Combine(folder, DesktopIniName);
            WriteDesktopIni(iniPath, iconOutputPath, keepNameFile ? Path.GetFileName(folder.TrimEnd('\\', '/')) : null);
            if (!Native.SetFileAttributes(iniPath, Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM))
            {
                int err = Marshal.GetLastWin32Error();
                throw new UnauthorizedAccessException(
                    "无法设置 " + iniPath + " 的属性（错误码 " + err + "），请以管理员身份运行本工具");
            }

            // 3) 给文件夹加 READONLY 属性 —— 资源管理器据此决定是否读取 desktop.ini
            uint dirAttr = Native.GetFileAttributes(folder);
            if (dirAttr != Native.INVALID_FILE_ATTRIBUTES &&
                (dirAttr & Native.FILE_ATTRIBUTE_READONLY) == 0)
            {
                Native.SetFileAttributes(folder, dirAttr | Native.FILE_ATTRIBUTE_READONLY);
            }

            // 4) 更新文件夹修改时间，促使资源管理器重新评估该目录
            try { Directory.SetLastWriteTime(folder, DateTime.Now); } catch { }

            NotifyFolderChanged(folder);
        }

        /// <summary>写入 desktop.ini 内容（UTF-16LE，资源管理器可正确解析中文路径）。</summary>
        /// <remarks>
        /// 写入前必须先清掉 隐藏/系统/只读 属性：若 desktop.ini 已存在且带这些属性，
        /// 以 FileMode.Create 打开会被系统拒绝（UnauthorizedAccessException）。
        /// </remarks>
        public static void WriteDesktopIni(string iniPath, string iconPath, string localizedName)
        {
            var sb = new StringBuilder();
            sb.AppendLine("[.ShellClassInfo]");
            // IconResource 的路径必须是绝对路径；含空格时用引号包裹，兼容性最好
            string value = iconPath.IndexOf(' ') >= 0 ? "\"" + iconPath + "\"" : iconPath;
            sb.AppendLine("IconResource=" + value + ",0");
            if (!string.IsNullOrEmpty(localizedName))
            {
                sb.AppendLine("[{F29F85E0-4FF9-1068-AB91-08002B27B3D9}]");
                sb.AppendLine("Prop3=31," + localizedName);
            }

            if (File.Exists(iniPath)) ClearAttributes(iniPath);

            // 以 UTF-16LE 写入（Explorer 原生支持）
            File.WriteAllText(iniPath, sb.ToString(), new UnicodeEncoding(false, true));
        }

        /// <summary>恢复文件夹原始图标：移除 desktop.ini 中的 IconResource，或整文件删除。</summary>
        public static void Revert(string folder, bool deleteIni)
        {
            string iniPath = Path.Combine(folder, DesktopIniName);
            if (File.Exists(iniPath))
            {
                if (deleteIni)
                {
                    ClearAttributes(iniPath);
                    try { File.Delete(iniPath); }
                    catch (UnauthorizedAccessException)
                    {
                        throw new UnauthorizedAccessException(
                            "无法删除 " + iniPath + "，请以管理员身份运行本工具");
                    }
                }
                else
                {
                    var lines = ReadDesktopIniLines(iniPath)
                        .Where(l => !l.TrimStart().StartsWith("IconResource=", StringComparison.OrdinalIgnoreCase))
                        .ToList();
                    var sb = new StringBuilder();
                    foreach (var l in lines) sb.AppendLine(l);
                    ClearAttributes(iniPath);
                    File.WriteAllText(iniPath, sb.ToString(), new UnicodeEncoding(false, true));
                    Native.SetFileAttributes(iniPath, Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM);
                }
            }

            // 撤销 Apply 时给文件夹加的 READONLY 属性（若当前未设置图标则不再需要）
            uint dirAttr = Native.GetFileAttributes(folder);
            if (dirAttr != Native.INVALID_FILE_ATTRIBUTES && (dirAttr & Native.FILE_ATTRIBUTE_READONLY) != 0)
            {
                Native.SetFileAttributes(folder, dirAttr & ~Native.FILE_ATTRIBUTE_READONLY);
            }
            // 更新修改时间，促使资源管理器重新评估该目录
            try { Directory.SetLastWriteTime(folder, DateTime.Now); } catch { }

            NotifyFolderChanged(folder);
        }

        /// <summary>读取文件夹当前的图标资源设置，未设置时返回 null。</summary>
        public static string GetCurrentIconResource(string folder)
        {
            string iniPath = Path.Combine(folder, DesktopIniName);
            if (!File.Exists(iniPath)) return null;
            foreach (var line in ReadDesktopIniLines(iniPath))
            {
                string t = line.Trim();
                if (t.StartsWith("IconResource=", StringComparison.OrdinalIgnoreCase))
                    return t.Substring("IconResource=".Length).Trim().Trim('"');
            }
            return null;
        }

        private static IEnumerable<string> ReadDesktopIniLines(string iniPath)
        {
            try
            {
                // 兼容 UTF-16 与 ANSI 两种编码
                byte[] head = new byte[2];
                using (var fs = File.OpenRead(iniPath)) { if (fs.Length >= 2) fs.Read(head, 0, 2); }
                bool utf16 = head[0] == 0xFF && head[1] == 0xFE;
                return File.ReadAllLines(iniPath, utf16 ? (Encoding)new UnicodeEncoding(false, true) : Encoding.Default);
            }
            catch { return new string[0]; }
        }

        private static void ClearAttributes(string path)
        {
            uint attr = Native.GetFileAttributes(path);
            if (attr != Native.INVALID_FILE_ATTRIBUTES)
                Native.SetFileAttributes(path, attr & ~(Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM | Native.FILE_ATTRIBUTE_READONLY));
        }

        /// <summary>通知资源管理器该文件夹已变化，使其重新读取 desktop.ini。</summary>
        public static void NotifyFolderChanged(string folder)
        {
            IntPtr p = Marshal.StringToHGlobalUni(folder);
            try
            {
                Native.SHChangeNotify(Native.SHCNE_UPDATEDIR, Native.SHCNF_PATHW | Native.SHCNF_FLUSH, p, IntPtr.Zero);
                Native.SHChangeNotify(Native.SHCNE_UPDATEITEM, Native.SHCNF_PATHW | Native.SHCNF_FLUSH, p, IntPtr.Zero);
            }
            finally { Marshal.FreeHGlobal(p); }
        }

        /// <summary>
        /// 强制刷新图标缓存：通知所有资源管理器窗口（含桌面）重新加载系统映像列表。
        /// 这是让新文件夹图标立即生效的关键步骤。
        /// </summary>
        public static void RefreshShellIconCache()
        {
            try
            {
                Native.SHChangeNotify(Native.SHCNE_ASSOCCHANGED, 0, IntPtr.Zero, IntPtr.Zero);
            }
            catch { }

            // 通知所有顶层窗口刷新（隐藏的 Progman / WorkerW 承载桌面图标）
            try
            {
                var procs = Process.GetProcessesByName("explorer");
                foreach (var p in procs)
                {
                    IntPtr result;
                    Native.SendMessageTimeout(p.MainWindowHandle, Native.WM_COMMAND,
                        IntPtr.Zero, "UpdateIcons", Native.SMTO_ABORTIFHUNG, 3000, out result);
                }
            }
            catch { }
        }

        /// <summary>
        /// 删除图标缓存数据库。删除后资源管理器会重建缓存，新图标随即生效。
        /// 返回实际删除的文件数，并说明失败数量，便于界面如实反馈。
        /// </summary>
        public static string DeleteIconCache(out int deleted, out int failed)
        {
            deleted = 0; failed = 0;
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string explorerDir = Path.Combine(local, "Microsoft", "Windows", "Explorer");
            var targets = new List<string> { Path.Combine(local, "IconCache.db") };
            try
            {
                if (Directory.Exists(explorerDir))
                    targets.AddRange(Directory.GetFiles(explorerDir, "iconcache*"));
            }
            catch { }

            foreach (var t in targets)
            {
                try
                {
                    if (File.Exists(t)) { File.Delete(t); deleted++; }
                }
                catch { failed++; }
            }

            // 通知系统重建图标缓存（会重写 iconcache 数据库）
            try
            {
                var psi = new ProcessStartInfo("ie4uinit.exe", "-show")
                { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden };
                Process.Start(psi);
            }
            catch { }

            if (failed == 0) return "已清除 " + deleted + " 个图标缓存文件，资源管理器将自动重建缓存。";
            return "已清除 " + deleted + " 个图标缓存文件，" + failed + " 个被占用未能删除（通常是资源管理器正在使用，可稍后重试）。";
        }
    }

    #endregion
}
