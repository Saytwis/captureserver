# ============================================================
# Project U — PowerShell Capture Daemon (v2 - Polling)
# ============================================================
# Uses GetAsyncKeyState polling instead of RegisterHotKey
# More compatible across different Windows configurations
# ============================================================

$ServerURL = "{{SERVER_URL}}"
$UserCode  = "{{USER_CODE}}"
$MachineID = (Get-WmiObject Win32_ComputerSystemProduct).UUID

# --- Kill any previous Project U daemons ---
$currentPID = $PID
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -like '*captureserver*' -and $_.ProcessId -ne $currentPID
} | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

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

# --- Buzz Mode Selection ---
Write-Host ""
Write-Host "Notification mode:" -ForegroundColor Yellow
Write-Host "  [1] Normal — answer text on your phone" -ForegroundColor Gray
Write-Host "  [2] Stealth — vibrations only (1 buzz = A, 2 = B, 3 = C, 4 = D)" -ForegroundColor Gray
Write-Host ""
$modeInput = Read-Host "Pick 1 or 2"
$buzzMode = if ($modeInput -eq "2") { "true" } else { "false" }
$modeName = if ($buzzMode -eq "true") { "Stealth (buzz)" } else { "Normal (text)" }

Write-Host ""
Write-Host "Confirmed! Press $keyName anytime to capture." -ForegroundColor Green
Write-Host "Mode: $modeName" -ForegroundColor Green
Write-Host "Going invisible now..." -ForegroundColor Gray
Start-Sleep -Seconds 2

# --- Spawn hidden background process with selected key ---
# This creates a new hidden PowerShell that runs the capture loop
# The current visible window closes automatically

$loopScript = @"
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.IO;
using System.Net;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class PU
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

    public static bool IsKeyPressed(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    public static byte[] CaptureScreen()
    {
        IntPtr dw = GetDesktopWindow();
        IntPtr dc = GetWindowDC(dw);
        RECT r; GetWindowRect(dw, out r);
        int w = r.Right - r.Left; int h = r.Bottom - r.Top;
        IntPtr mdc = CreateCompatibleDC(dc);
        IntPtr mb = CreateCompatibleBitmap(dc, w, h);
        IntPtr ob = SelectObject(mdc, mb);
        BitBlt(mdc, 0, 0, w, h, dc, 0, 0, 0x00CC0020);
        Bitmap bmp = Image.FromHbitmap(mb);
        SelectObject(mdc, ob); DeleteObject(mb); DeleteDC(mdc); ReleaseDC(dw, dc);
        using (MemoryStream ms = new MemoryStream())
        {
            ImageCodecInfo jc = null;
            foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders())
            { if (c.MimeType == "image/jpeg") { jc = c; break; } }
            EncoderParameters ep = new EncoderParameters(1);
            ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 70L);
            bmp.Save(ms, jc, ep); bmp.Dispose(); return ms.ToArray();
        }
    }

    public static string Upload(byte[] img, string url, string code, string mid)
    {
        try
        {
            string b = "----PU" + DateTime.Now.Ticks.ToString("x");
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "POST";
            req.ContentType = "multipart/form-data; boundary=" + b;
            req.Timeout = 30000;
            req.Headers.Add("X-User-Code", code);
            req.Headers.Add("X-Machine-ID", mid);
            req.Headers.Add("X-Buzz-Mode", "$buzzMode");
            using (Stream s = req.GetRequestStream())
            {
                byte[] hd = System.Text.Encoding.ASCII.GetBytes("--" + b + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"s.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n");
                s.Write(hd, 0, hd.Length); s.Write(img, 0, img.Length);
                byte[] ft = System.Text.Encoding.ASCII.GetBytes("\r\n--" + b + "--\r\n");
                s.Write(ft, 0, ft.Length);
            }
            using (HttpWebResponse rsp = (HttpWebResponse)req.GetResponse())
            using (StreamReader sr = new StreamReader(rsp.GetResponseStream()))
            { return sr.ReadToEnd(); }
        }
        catch (Exception ex) { return "ERROR: " + ex.Message; }
    }
}
'@ -ReferencedAssemblies System.Drawing

`$vk = $selectedKey
`$url = '$ServerURL'
`$code = '$UserCode'
`$mid = (Get-WmiObject Win32_ComputerSystemProduct).UUID
`$p = `$false

while (`$true) {
    if ([PU]::IsKeyPressed(`$vk) -and -not `$p) {
        `$p = `$true
        try { `$b = [PU]::CaptureScreen(); [PU]::Upload(`$b, `$url, `$code, `$mid) } catch {}
        while ([PU]::IsKeyPressed(`$vk)) { Start-Sleep -Milliseconds 50 }
        Start-Sleep -Milliseconds 500
        `$p = `$false
    }
    Start-Sleep -Milliseconds 50
}
"@

# Replace the selected key value and buzz mode into the script
$loopScript = $loopScript.Replace('$selectedKey', "$selectedKey")
$loopScript = $loopScript.Replace('$buzzMode', "$buzzMode")

# Encode the daemon script as Base64 so it's not readable in process list
$encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($loopScript))

# Spawn as hidden background process running the encoded script
Start-Process powershell -WindowStyle Hidden -ArgumentList "-EP Bypass -C `"iex([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedScript')))`""

Write-Host ""
Write-Host "Project U is running in the background." -ForegroundColor Green
Write-Host "Press $keyName to capture. Close this window anytime." -ForegroundColor Gray
Start-Sleep -Seconds 3
exit
