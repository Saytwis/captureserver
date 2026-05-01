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

    public static bool IsLeftCtrlPressed()
    {
        return (GetAsyncKeyState(0xA2) & 0x8000) != 0;
    }

    public static bool IsKeyPressed(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    public static int DetectAnyKey()
    {
        // Scan all virtual key codes (1-254)
        for (int vk = 1; vk <= 254; vk++)
        {
            if ((GetAsyncKeyState(vk) & 0x8000) != 0)
            {
                return vk;
            }
        }
        return 0;
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

# --- Keybind Selection ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "  Project U — Capture Daemon" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "Choose your capture key." -ForegroundColor Yellow
Write-Host "Press the key you want to use as your trigger..." -ForegroundColor Gray
Write-Host ""

# Wait for any current keys to be released
Start-Sleep -Milliseconds 500

# Detect the key they press
$selectedKey = 0
while ($selectedKey -eq 0) {
    $selectedKey = [ProjectU]::DetectAnyKey()
    Start-Sleep -Milliseconds 50
}

# Wait for release
while ([ProjectU]::IsKeyPressed($selectedKey)) {
    Start-Sleep -Milliseconds 50
}

# Map common key codes to friendly names
$keyNames = @{
    0xA0 = "Left Shift"; 0xA1 = "Right Shift"
    0xA2 = "Left Ctrl"; 0xA3 = "Right Ctrl"
    0xA4 = "Left Alt"; 0xA5 = "Right Alt"
    0x70 = "F1"; 0x71 = "F2"; 0x72 = "F3"; 0x73 = "F4"
    0x74 = "F5"; 0x75 = "F6"; 0x76 = "F7"; 0x77 = "F8"
    0x78 = "F9"; 0x79 = "F10"; 0x7A = "F11"; 0x7B = "F12"
    0x14 = "Caps Lock"; 0x91 = "Scroll Lock"
    0x2C = "Print Screen"; 0x13 = "Pause"
    0xDC = "Backslash"; 0xC0 = "Tilde"
}

$keyName = if ($keyNames.ContainsKey($selectedKey)) { $keyNames[$selectedKey] } else { "Key code 0x$($selectedKey.ToString('X2'))" }

Write-Host "You selected: $keyName" -ForegroundColor Green
Write-Host ""
Write-Host "Press $keyName again to confirm, or close this window to cancel..." -ForegroundColor Yellow

# Wait for confirmation press
$confirmed = $false
$timeout = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $timeout) {
    if ([ProjectU]::IsKeyPressed($selectedKey)) {
        $confirmed = $true
        break
    }
    Start-Sleep -Milliseconds 50
}

if (-not $confirmed) {
    Write-Host "Timed out. Exiting." -ForegroundColor Red
    exit
}

# Wait for release
while ([ProjectU]::IsKeyPressed($selectedKey)) {
    Start-Sleep -Milliseconds 50
}

Write-Host ""
Write-Host "Confirmed! Press $keyName anytime to capture." -ForegroundColor Green
Write-Host "Minimizing in 3 seconds..." -ForegroundColor Gray
Start-Sleep -Seconds 3

# --- Main loop: poll for selected key ---
$processing = $false

while ($true) {
    if ([ProjectU]::IsKeyPressed($selectedKey) -and -not $processing) {
        $processing = $true

        try {
            $bytes = [ProjectU]::CaptureScreen()
            $result = [ProjectU]::Upload($bytes, $ServerURL, $UserCode, $MachineID)
        }
        catch {
            # Silent fail
        }

        # Wait for key release
        while ([ProjectU]::IsKeyPressed($selectedKey)) {
            Start-Sleep -Milliseconds 50
        }

        # Cooldown
        Start-Sleep -Milliseconds 500
        $processing = $false
    }

    Start-Sleep -Milliseconds 50
}
