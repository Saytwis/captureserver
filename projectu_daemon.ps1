# ============================================================
# Project U — PowerShell Capture Daemon
# ============================================================
# Usage (user pastes into Win+R or PowerShell):
#   powershell -W Hidden -EP Bypass -C "irm projectu.com/s/USERCODE|iex"
#
# What it does:
#   1. Registers Right Ctrl as a global hotkey
#   2. On press: takes a screenshot, uploads to server as JPEG
#   3. Server processes with LLM, pushes answer to user's phone
#   4. Runs completely hidden — no window, no tray icon, no traces
# ============================================================

# --- CONFIG (injected by server per-user) ---
$ServerURL = "{{SERVER_URL}}"
$UserCode  = "{{USER_CODE}}"

# --- Get unique machine ID (hardware UUID, can't be faked easily) ---
$MachineID = (Get-WmiObject Win32_ComputerSystemProduct).UUID

# --- Load required assemblies (built into Windows) ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Add C# code for global hotkey + screenshot ---
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Threading;

public class ProjectU
{
    // --- Windows API for global hotkey ---
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    // --- BitBlt APIs (lower-level screen capture) ---
    [DllImport("gdi32.dll")]
    static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest,
        int width, int height, IntPtr hdcSrc, int xSrc, int ySrc, int rop);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);

    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);

    [DllImport("gdi32.dll")]
    static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr obj);

    [DllImport("user32.dll")]
    static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    static extern IntPtr GetWindowDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    private const int SRCCOPY = 0x00CC0020;
    private const uint VK_RCONTROL = 0xA3;
    private const int HOTKEY_ID = 9001;
    private const int WM_HOTKEY = 0x0312;

    private static string serverUrl;
    private static string userCode;
    private static string machineId;
    private static bool isProcessing = false;

    public static void Run(string url, string code, string machine)
    {
        serverUrl = url;
        userCode = code;
        machineId = machine;
        Application.Run(new HotkeyForm());
    }

    private class HotkeyForm : Form
    {
        public HotkeyForm()
        {
            // Make form completely invisible
            this.ShowInTaskbar = false;
            this.WindowState = FormWindowState.Minimized;
            this.FormBorderStyle = FormBorderStyle.None;
            this.Opacity = 0;
            this.Size = new Size(0, 0);

            // Register the hotkey on form load
            this.Load += (s, e) =>
            {
                // Register Right Ctrl (no modifier flags)
                bool registered = RegisterHotKey(this.Handle, HOTKEY_ID, 0x0000, VK_RCONTROL);
                if (!registered)
                {
                    // Hotkey might already be in use, try alternate approach
                    // Use Ctrl+F12 as fallback (MOD_CONTROL=0x0002, VK_F12=0x7B)
                    RegisterHotKey(this.Handle, HOTKEY_ID, 0x0002, 0x7B);
                }
            };

            this.FormClosing += (s, e) =>
            {
                UnregisterHotKey(this.Handle, HOTKEY_ID);
            };
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID)
            {
                // Fire screenshot in background thread
                if (!isProcessing)
                {
                    ThreadPool.QueueUserWorkItem(_ => CaptureAndUpload());
                }
            }
            base.WndProc(ref m);
        }
    }

    private static void CaptureAndUpload()
    {
        if (isProcessing) return;
        isProcessing = true;

        try
        {
            // --- BitBlt screen capture (lower level than CopyFromScreen) ---
            // Goes: BitBlt -> GDI32.dll -> Display driver -> GPU
            // Fewer interception points than CopyFromScreen
            IntPtr desktopWnd = GetDesktopWindow();
            IntPtr desktopDC = GetWindowDC(desktopWnd);

            RECT rect;
            GetWindowRect(desktopWnd, out rect);
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;

            IntPtr memDC = CreateCompatibleDC(desktopDC);
            IntPtr memBmp = CreateCompatibleBitmap(desktopDC, width, height);
            IntPtr oldBmp = SelectObject(memDC, memBmp);

            // BitBlt: direct pixel copy from screen to memory
            BitBlt(memDC, 0, 0, width, height, desktopDC, 0, 0, SRCCOPY);

            // Convert to managed Bitmap
            Bitmap bmp = Image.FromHbitmap(memBmp);

            // Cleanup GDI objects immediately
            SelectObject(memDC, oldBmp);
            DeleteObject(memBmp);
            DeleteDC(memDC);
            ReleaseDC(desktopWnd, desktopDC);

            // --- Convert to JPEG in memory ---
            using (MemoryStream ms = new MemoryStream())
            {
                ImageCodecInfo jpegCodec = null;
                foreach (ImageCodecInfo codec in ImageCodecInfo.GetImageEncoders())
                {
                    if (codec.MimeType == "image/jpeg") { jpegCodec = codec; break; }
                }

                EncoderParameters encoderParams = new EncoderParameters(1);
                encoderParams.Param[0] = new EncoderParameter(
                    System.Drawing.Imaging.Encoder.Quality, 70L);

                bmp.Save(ms, jpegCodec, encoderParams);
                bmp.Dispose();
                byte[] imageBytes = ms.ToArray();

                // --- Upload via multipart form POST ---
                string boundary = "----ProjectU" + DateTime.Now.Ticks.ToString("x");
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(serverUrl);
                req.Method = "POST";
                req.ContentType = "multipart/form-data; boundary=" + boundary;
                req.Timeout = 30000;
                req.Headers.Add("X-User-Code", userCode);
                    req.Headers.Add("X-Machine-ID", machineId);

                using (Stream reqStream = req.GetRequestStream())
                {
                    byte[] header = System.Text.Encoding.ASCII.GetBytes(
                        "--" + boundary + "\r\n" +
                        "Content-Disposition: form-data; name=\"file\"; filename=\"screenshot.jpg\"\r\n" +
                        "Content-Type: image/jpeg\r\n\r\n");
                    reqStream.Write(header, 0, header.Length);
                    reqStream.Write(imageBytes, 0, imageBytes.Length);
                    byte[] footer = System.Text.Encoding.ASCII.GetBytes(
                        "\r\n--" + boundary + "--\r\n");
                    reqStream.Write(footer, 0, footer.Length);
                }

                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    // Success — server handles LLM + push notification
                }
            }
        }
        catch
        {
            // Silent fail — no logs, no traces
        }
        finally
        {
            isProcessing = false;
        }
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

# --- Run the daemon ---
[ProjectU]::Run($ServerURL, $UserCode, $MachineID)
