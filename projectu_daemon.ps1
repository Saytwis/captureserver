# ============================================================
# Project U — PowerShell Capture Daemon (v2 - Polling)
# ============================================================
# Uses GetAsyncKeyState polling instead of RegisterHotKey
# More compatible across different Windows configurations
# ============================================================

$ServerURL = "{{SERVER_URL}}"
$UserCode  = "{{USER_CODE}}"
$MachineID = (Get-WmiObject Win32_ComputerSystemProduct).UUID

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.IO;
using System.Net;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class ProjectU
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("gdi32.dll")]
    static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest,
        int w, int h, IntPtr hdcSrc, int xSrc, int ySrc, int rop);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);

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

    public static bool IsRightAltPressed()
    {
        return (GetAsyncKeyState(0xA5) & 0x8000) != 0;
    }

    public static byte[] CaptureScreen()
    {
        IntPtr desktopWnd = GetDesktopWindow();
        IntPtr desktopDC = GetWindowDC(desktopWnd);

        RECT rect;
        GetWindowRect(desktopWnd, out rect);
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;

        IntPtr memDC = CreateCompatibleDC(desktopDC);
        IntPtr memBmp = CreateCompatibleBitmap(desktopDC, w, h);
        IntPtr oldBmp = SelectObject(memDC, memBmp);

        BitBlt(memDC, 0, 0, w, h, desktopDC, 0, 0, 0x00CC0020);

        Bitmap bmp = Image.FromHbitmap(memBmp);

        SelectObject(memDC, oldBmp);
        DeleteObject(memBmp);
        DeleteDC(memDC);
        ReleaseDC(desktopWnd, desktopDC);

        using (MemoryStream ms = new MemoryStream())
        {
            ImageCodecInfo jpegCodec = null;
            foreach (ImageCodecInfo codec in ImageCodecInfo.GetImageEncoders())
            {
                if (codec.MimeType == "image/jpeg") { jpegCodec = codec; break; }
            }
            EncoderParameters ep = new EncoderParameters(1);
            ep.Param[0] = new EncoderParameter(
                System.Drawing.Imaging.Encoder.Quality, 70L);
            bmp.Save(ms, jpegCodec, ep);
            bmp.Dispose();
            return ms.ToArray();
        }
    }

    public static string Upload(byte[] imageBytes, string serverUrl, string userCode, string machineId)
    {
        try
        {
            string boundary = "----ProjectU" + DateTime.Now.Ticks.ToString("x");
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(serverUrl);
            req.Method = "POST";
            req.ContentType = "multipart/form-data; boundary=" + boundary;
            req.Timeout = 30000;
            req.Headers.Add("X-User-Code", userCode);
            req.Headers.Add("X-Machine-ID", machineId);

            using (Stream s = req.GetRequestStream())
            {
                byte[] header = System.Text.Encoding.ASCII.GetBytes(
                    "--" + boundary + "\r\n" +
                    "Content-Disposition: form-data; name=\"file\"; filename=\"s.jpg\"\r\n" +
                    "Content-Type: image/jpeg\r\n\r\n");
                s.Write(header, 0, header.Length);
                s.Write(imageBytes, 0, imageBytes.Length);
                byte[] footer = System.Text.Encoding.ASCII.GetBytes(
                    "\r\n--" + boundary + "--\r\n");
                s.Write(footer, 0, footer.Length);
            }

            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
            {
                return sr.ReadToEnd();
            }
        }
        catch (Exception ex)
        {
            return "ERROR: " + ex.Message;
        }
    }
}
"@ -ReferencedAssemblies System.Drawing

# --- Main loop: poll for Right Ctrl ---
$processing = $false

while ($true) {
    if ([ProjectU]::IsRightAltPressed() -and -not $processing) {
        $processing = $true

        try {
            $bytes = [ProjectU]::CaptureScreen()
            $result = [ProjectU]::Upload($bytes, $ServerURL, $UserCode, $MachineID)
            Write-Host "Captured and uploaded. Server: $result" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: $_" -ForegroundColor Red
        }

        # Wait for key release so it doesn't fire repeatedly
        while ([ProjectU]::IsRightAltPressed()) {
            Start-Sleep -Milliseconds 50
        }

        # Cooldown
        Start-Sleep -Milliseconds 500
        $processing = $false
    }

    Start-Sleep -Milliseconds 50
}
