using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TwoNote.App.SelfTest;

/// <summary>Counts assertions and writes the pass/fail log of a self-test run.</summary>
internal sealed class Checks
{
    private readonly List<string> _failed = [];

    public int Count { get; private set; }

    public int Failures { get; private set; }

    public string Scenario { get; set; } = "";

    /// <summary>Also log every assertion that held (<c>--verbose</c>).</summary>
    public bool Verbose { get; set; }

    public void Check(string what, bool ok, string? detail = null)
    {
        Count++;
        if (ok)
        {
            if (Verbose)
            {
                AppLog.Line($"  ok   [{Scenario}] {what}");
            }

            return;
        }

        Failures++;
        var line = $"  FAIL [{Scenario}] {what}{(detail == null ? "" : ": " + detail)}";
        if (_failed.Count < 80)
        {
            _failed.Add(line);
        }

        AppLog.Line(line);
    }

    public void Eq(string what, string? expected, string? actual) =>
        Check(what, expected == actual, $"expected «{Show(expected)}» got «{Show(actual)}»");

    public void Pass() => Count++;

    public static string Show(string? s) => s is null ? "(null)" : (s.Length > 200 ? s[..200] + "…" : s).Replace("\n", "⏎");

    public static void Note(string s) => AppLog.Line("  note: " + s);
}

/// <summary>Screenshots of the real window.</summary>
internal static class Capture
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, BitCount;
        public uint Compression, SizeImage;
        public int XPelsPerMeter, YPelsPerMeter;
        public uint ClrUsed, ClrImportant;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(nint hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(nint hwnd, nint hdc, uint flags);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out Rect value, int size);

    [DllImport("gdi32.dll")]
    private static extern nint CreateCompatibleDC(nint hdc);

    [DllImport("gdi32.dll")]
    private static extern nint CreateDIBSection(nint hdc, ref BitmapInfoHeader info, uint usage, out nint bits, nint section, uint offset);

    [DllImport("gdi32.dll")]
    private static extern nint SelectObject(nint hdc, nint obj);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint obj);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(nint hdc);

    /// <summary>
    /// Saves what the window shows - title bar, backdrop and all - as a PNG, through PrintWindow, which also works
    /// when the window is not in front. Falls back to rendering the XAML content if that gives nothing.
    /// </summary>
    public static async Task WindowAsync(nint hwnd, FrameworkElement root, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await Task.Delay(350); // let animations and the last layout pass finish
        var ok = false;
        try
        {
            ok = await PrintAsync(hwnd, path);
        }
        catch (Exception e)
        {
            AppLog.Line($"  note: PrintWindow capture failed ({e.GetType().Name}); using the XAML renderer");
        }

        if (!ok)
        {
            await ElementAsync(root, path);
        }
    }

    private static async Task<bool> PrintAsync(nint hwnd, string path)
    {
        if (!GetWindowRect(hwnd, out var window))
        {
            return false;
        }

        var width = window.Right - window.Left;
        var height = window.Bottom - window.Top;
        if (width <= 0 || height <= 0)
        {
            return false;
        }

        var header = new BitmapInfoHeader { Size = (uint)Marshal.SizeOf<BitmapInfoHeader>(), Width = width, Height = -height, Planes = 1, BitCount = 32 };
        var dc = CreateCompatibleDC(0);
        var bitmap = CreateDIBSection(dc, ref header, 0, out var bits, 0, 0);
        var old = SelectObject(dc, bitmap);
        byte[] pixels;
        try
        {
            if (!PrintWindow(hwnd, dc, 2 /* PW_RENDERFULLCONTENT */))
            {
                return false;
            }

            pixels = new byte[width * height * 4];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
        }
        finally
        {
            SelectObject(dc, old);
            DeleteObject(bitmap);
            DeleteDC(dc);
        }

        // The window rectangle includes the invisible resize border; crop to what is drawn.
        var (x, y, w, h) = (0, 0, width, height);
        if (DwmGetWindowAttribute(hwnd, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, out var frame, Marshal.SizeOf<Rect>()) == 0)
        {
            x = Math.Clamp(frame.Left - window.Left, 0, width - 1);
            y = Math.Clamp(frame.Top - window.Top, 0, height - 1);
            w = Math.Clamp(frame.Right - frame.Left, 1, width - x);
            h = Math.Clamp(frame.Bottom - frame.Top, 1, height - y);
        }

        var cropped = new byte[w * h * 4];
        var first = pixels[(y * width + x) * 4];
        var uniform = true;
        for (var row = 0; row < h; row++)
        {
            System.Buffer.BlockCopy(pixels, ((y + row) * width + x) * 4, cropped, row * w * 4, w * 4);
        }

        for (var i = 0; i < cropped.Length; i += 4)
        {
            cropped[i + 3] = 255;
            if (uniform && (cropped[i] != first || cropped[i + 1] != first || cropped[i + 2] != first))
            {
                uniform = false;
            }
        }

        if (uniform)
        {
            return false; // nothing was drawn (no desktop composition for this session)
        }

        await SavePngAsync(cropped, w, h, path);
        return true;
    }

    /// <summary>Renders one element (no title bar, no backdrop) to a PNG.</summary>
    public static async Task ElementAsync(UIElement root, string path)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(root);
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        await SavePngAsync(pixels, bitmap.PixelWidth, bitmap.PixelHeight, path);
    }

    private static async Task SavePngAsync(byte[] bgra, int width, int height, string path)
    {
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, bgra);
        await encoder.FlushAsync();
        var bytes = new byte[stream.Size];
        stream.Seek(0);
        await stream.ReadAsync(bytes.AsBuffer(), (uint)stream.Size, InputStreamOptions.None);
        File.WriteAllBytes(path, bytes);
    }
}
