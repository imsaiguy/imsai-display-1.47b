# Prepares assets\imsai8080.png for the 320x172 screen:
#   1. removes the hand in the lower-right corner of the front panel (reconstructs what is behind it)
#   2. cuts out just the front panel and blacks out everything around it
#   3. scales it to fit the screen width (letterboxed in black), then cleans it up
#      (contrast stretch, gentle sharpening, slight saturation, dithering to RGB565)
# Writes ..\main\photo.h (RGB565, byte-swapped), a screen preview and a full-resolution debug image.
$ErrorActionPreference = "Stop"

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Text;
using System.IO;

public static class ImgGen
{
    static bool InPoly(float x, float y, float[] px, float[] py)
    {
        bool inside = false;
        for (int i = 0, j = px.Length - 1; i < px.Length; j = i++)
            if (((py[i] > y) != (py[j] > y)) && (x < (px[j] - px[i]) * (y - py[i]) / (py[j] - py[i]) + px[i]))
                inside = !inside;
        return inside;
    }

    static float[] Gauss(int n)
    {
        float[] k = new float[2 * n + 1]; float s = 0; float sigma = n / 2.0f;
        for (int i = -n; i <= n; i++) { k[i + n] = (float)Math.Exp(-(i * i) / (2 * sigma * sigma)); s += k[i + n]; }
        for (int i = 0; i < k.Length; i++) k[i] /= s;
        return k;
    }

    // separable blur of a w*h image with c channels
    static float[] Blur(float[] src, int w, int h, int c, float[] k)
    {
        int n = k.Length / 2;
        float[] tmp = new float[src.Length], dst = new float[src.Length];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                for (int ch = 0; ch < c; ch++)
                {
                    float a = 0;
                    for (int d = -n; d <= n; d++) { int xx = Math.Max(0, Math.Min(w - 1, x + d)); a += k[d + n] * src[(y * w + xx) * c + ch]; }
                    tmp[(y * w + x) * c + ch] = a;
                }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                for (int ch = 0; ch < c; ch++)
                {
                    float a = 0;
                    for (int d = -n; d <= n; d++) { int yy = Math.Max(0, Math.Min(h - 1, y + d)); a += k[d + n] * tmp[(yy * w + x) * c + ch]; }
                    dst[(y * w + x) * c + ch] = a;
                }
        return dst;
    }

    static float[] ToFloat(Bitmap b)
    {
        int w = b.Width, h = b.Height;
        using (Bitmap c = new Bitmap(w, h, PixelFormat.Format24bppRgb))
        {
            using (Graphics g = Graphics.FromImage(c)) g.DrawImage(b, 0, 0, w, h);
            BitmapData bd = c.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            byte[] raw = new byte[bd.Stride * h];
            System.Runtime.InteropServices.Marshal.Copy(bd.Scan0, raw, 0, raw.Length);
            int stride = bd.Stride; c.UnlockBits(bd);
            float[] f = new float[w * h * 3];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int i = y * stride + x * 3, o = (y * w + x) * 3;
                    f[o] = raw[i + 2]; f[o + 1] = raw[i + 1]; f[o + 2] = raw[i];
                }
            return f;
        }
    }

    static Bitmap ToBitmap(float[] f, int w, int h)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int o = (y * w + x) * 3;
                b.SetPixel(x, y, Color.FromArgb((int)Math.Max(0, Math.Min(255, f[o] + 0.5f)), (int)Math.Max(0, Math.Min(255, f[o + 1] + 0.5f)), (int)Math.Max(0, Math.Min(255, f[o + 2] + 0.5f))));
            }
        return b;
    }

    public static string Run(string src, string headerOut, string previewOut, string debugOut, string sitesCsv, int W, int H)
    {
        float[] img; int sw, sh;
        using (Bitmap orig = new Bitmap(src)) { sw = orig.Width; sh = orig.Height; img = ToFloat(orig); }
        StringBuilder info = new StringBuilder();

        // ---------- 1) Remove the hand (source coordinates measured from the photo) ----------
        float[] hx = { 529, 573, 573, 483, 485, 490, 500, 509, 518, 526 };
        float[] hy = { 213, 213, 276, 276, 266, 255, 244, 236, 226, 218 };
        bool[] hand = new bool[sw * sh];
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++)
                hand[y * sw + x] = InPoly(x + 0.5f, y + 0.5f, hx, hy);
        // grow the mask by 3 px so no skin-colored fringe is left
        bool[] grown = new bool[hand.Length];
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++)
            {
                bool v = false;
                for (int dy = -3; dy <= 3 && !v; dy++)
                    for (int dx = -3; dx <= 3; dx++)
                    {
                        int xx = x + dx, yy = y + dy;
                        if (xx >= 0 && yy >= 0 && xx < sw && yy < sh && hand[yy * sw + xx]) { v = true; break; }
                    }
                grown[y * sw + x] = v;
            }
        int[] yTop = new int[sw];
        for (int x = 0; x < sw; x++) { yTop[x] = -1; for (int y = 0; y < sh; y++) if (grown[y * sw + x]) { yTop[x] = y; break; } }
        // average color of the right blue side just above the hand, per column
        float[] cheek = new float[sw * 3];
        for (int x = 549; x < 572; x++)
            for (int c = 0; c < 3; c++)
            {
                float a = 0; int n = 0;
                for (int y = 195; y <= 208; y++) { a += img[(y * sw + x) * 3 + c]; n++; }
                cheek[x * 3 + c] = a / n;
            }
        // low-frequency version of the photo: used to borrow only the fine texture, not the brightness, from other places
        float[] low = Blur(img, sw, sh, 3, Gauss(6));
        // for each row of the black strip: brightness just left of the hand and its trend, to continue it smoothly
        int[] xb = new int[sh];
        float[] m2 = new float[sh * 3], slope = new float[sh * 3];
        for (int y = 0; y < sh; y++)
        {
            xb[y] = -1;
            for (int x = 470; x < 549; x++) if (grown[y * sw + x]) { xb[y] = x; break; }
            if (xb[y] < 60) continue;
            for (int c = 0; c < 3; c++)
            {
                float a = 0, b = 0;
                for (int i = 1; i <= 12; i++) a += img[(y * sw + xb[y] - i) * 3 + c];
                for (int i = 28; i <= 40; i++) b += img[(y * sw + xb[y] - i) * 3 + c];
                m2[y * 3 + c] = a / 12.0f;
                slope[y * 3 + c] = (a / 12.0f - b / 13.0f) / 27.0f;
            }
        }
        float[] fill = (float[])img.Clone();
        int filled = 0;
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++)
            {
                if (!grown[y * sw + x]) continue;
                int o = (y * sw + x) * 3;
                if (x >= 549 && x < 572 && y >= 211)
                {   // right blue side: extend its color down
                    for (int c = 0; c < 3; c++) fill[o + c] = cheek[x * 3 + c];
                }
                else if (y >= 230)
                {   // black lower strip: continue the brightness trend from the left of the hand,
                    // and borrow only the fine texture (photo minus its blur) from 100 px further left
                    int sx = Math.Max(0, x - 100);
                    for (int c = 0; c < 3; c++)
                    {
                        float baseV = img[(y * sw + sx) * 3 + c];
                        if (xb[y] >= 60)
                        {
                            float e = m2[y * 3 + c] + slope[y * 3 + c] * (x - (xb[y] - 6.5f));
                            e = Math.Max(m2[y * 3 + c] - 10, Math.Min(m2[y * 3 + c] + 10, e));
                            baseV = e + (img[(y * sw + sx) * 3 + c] - low[(y * sw + sx) * 3 + c]);
                        }
                        fill[o + c] = baseV;
                    }
                }
                else
                {   // switch area: extend the last visible row above the hand straight down
                    int top = yTop[x] < 0 ? y : yTop[x];
                    int sy = Math.Max(0, top - 3);
                    for (int c = 0; c < 3; c++) fill[o + c] = img[(sy * sw + x) * 3 + c];
                }
                filled++;
            }
        float[] soft = new float[sw * sh];
        for (int i = 0; i < soft.Length; i++) soft[i] = grown[i] ? 1.0f : 0.0f;
        soft = Blur(soft, sw, sh, 1, Gauss(3));
        for (int i = 0; i < sw * sh; i++)
            for (int c = 0; c < 3; c++)
                img[i * 3 + c] = img[i * 3 + c] * (1 - soft[i]) + fill[i * 3 + c] * soft[i];
        info.AppendFormat("hand removed ({0} px reconstructed); ", filled);

        // ---------- 1b) Switch the lit LEDs off (the firmware draws them again, animated) ----------
        // Each lit LED is covered by a copy of the nearest dark LED of the same row (soft-edged disc).
        {
            string[] ln = File.ReadAllLines(sitesCsv);
            var rowName = new System.Collections.Generic.List<string>();
            var lx = new System.Collections.Generic.List<float>();
            var ly = new System.Collections.Generic.List<float>();
            var lit = new System.Collections.Generic.List<bool>();
            foreach (string l in ln)
            {
                if (l.Length == 0 || l[0] == '#') continue;
                string[] p = l.Split(',');
                rowName.Add(p[0]);
                lx.Add(float.Parse(p[2], System.Globalization.CultureInfo.InvariantCulture) + 29f);   // panel crop origin X0
                ly.Add(float.Parse(p[3], System.Globalization.CultureInfo.InvariantCulture) + 73f);   // panel crop origin Y0
                lit.Add(p[4] == "1");
            }
            float[] orig = (float[])img.Clone();
            const float R0 = 9f, R1 = 12f;
            int patched = 0;
            for (int i = 0; i < lx.Count; i++)
            {
                if (!lit[i]) continue;
                int best = -1; float bd = 1e9f;
                for (int j = 0; j < lx.Count; j++)
                    if (!lit[j] && rowName[j] == rowName[i] && Math.Abs(lx[j] - lx[i]) < bd) { bd = Math.Abs(lx[j] - lx[i]); best = j; }
                if (best < 0) continue;
                float dx = lx[best] - lx[i], dy = ly[best] - ly[i];
                for (int y = (int)(ly[i] - R1) - 1; y <= (int)(ly[i] + R1) + 1; y++)
                    for (int x = (int)(lx[i] - R1) - 1; x <= (int)(lx[i] + R1) + 1; x++)
                    {
                        float d = (float)Math.Sqrt((x + 0.5f - lx[i]) * (x + 0.5f - lx[i]) + (y + 0.5f - ly[i]) * (y + 0.5f - ly[i]));
                        if (d >= R1) continue;
                        float w = d <= R0 ? 1f : 1f - (d - R0) / (R1 - R0);
                        w = w * w * (3f - 2f * w);
                        // bilinear sample of the donor
                        float sx = x + dx, sy = y + dy;
                        int x0 = (int)Math.Floor(sx - 0.5f), y0 = (int)Math.Floor(sy - 0.5f);
                        float fx = sx - 0.5f - x0, fy = sy - 0.5f - y0;
                        for (int c = 0; c < 3; c++)
                        {
                            float v = orig[(y0 * sw + x0) * 3 + c] * (1 - fx) * (1 - fy) + orig[(y0 * sw + x0 + 1) * 3 + c] * fx * (1 - fy)
                                    + orig[((y0 + 1) * sw + x0) * 3 + c] * (1 - fx) * fy + orig[((y0 + 1) * sw + x0 + 1) * 3 + c] * fx * fy;
                            img[(y * sw + x) * 3 + c] = img[(y * sw + x) * 3 + c] * (1 - w) + v * w;
                        }
                    }
                patched++;
            }
            info.AppendFormat("{0} lit LEDs switched off; ", patched);
        }

        // ---------- 2) Cut out just the front panel; everything outside becomes black ----------
        const float X0 = 29f, X1 = 568.2f, Y0 = 73f, Y1 = 273f, R = 6f;
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++)
            {
                float px = x + 0.5f, py = y + 0.5f;
                float xl = X0 + 0.0448f * (py - Y0);                    // the left edge leans slightly outward
                float d = Math.Min(Math.Min(px - xl, X1 - px), Math.Min(py - Y0, Y1 - py));
                // rounded top corners
                if (py < Y0 + R && px < xl + R) d = Math.Min(d, R - (float)Math.Sqrt((px - xl - R) * (px - xl - R) + (py - Y0 - R) * (py - Y0 - R)));
                if (py < Y0 + R && px > X1 - R) d = Math.Min(d, R - (float)Math.Sqrt((px - X1 + R) * (px - X1 + R) + (py - Y0 - R) * (py - Y0 - R)));
                float cov = Math.Max(0, Math.Min(1, d + 0.5f));
                for (int c = 0; c < 3; c++) img[(y * sw + x) * 3 + c] *= cov;
            }
        int cw = (int)(X1 - X0), ch = (int)(Y1 - Y0);
        float[] crop = new float[cw * ch * 3];
        for (int y = 0; y < ch; y++)
            for (int x = 0; x < cw; x++)
                for (int c = 0; c < 3; c++)
                    crop[(y * cw + x) * 3 + c] = img[((int)Y0 + y) * sw * 3 + ((int)X0 + x) * 3 + c];
        using (Bitmap dbg = ToBitmap(crop, cw, ch)) dbg.Save(debugOut, ImageFormat.Png);

        // ---------- 3) Scale to the screen width (letterboxed in black) ----------
        int tw = W, th = (int)Math.Round((double)ch * W / cw);
        float[] canvas = new float[W * H * 3];
        int oy = (H - th) / 2;
        using (Bitmap cb = ToBitmap(crop, cw, ch))
        using (Bitmap sc = new Bitmap(tw, th, PixelFormat.Format24bppRgb))
        {
            using (Graphics g = Graphics.FromImage(sc))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.DrawImage(cb, new Rectangle(0, 0, tw, th), 0, 0, cw, ch, GraphicsUnit.Pixel);
            }
            float[] sf = ToFloat(sc);
            for (int y = 0; y < th; y++)
                for (int x = 0; x < tw; x++)
                    for (int c = 0; c < 3; c++)
                        canvas[((y + oy) * W + x) * 3 + c] = sf[(y * tw + x) * 3 + c];
        }
        info.AppendFormat("panel {0}x{1} scaled to {2}x{3} at y={4}; ", cw, ch, tw, th, oy);

        // ---------- 4) Clean up: contrast stretch (panel pixels only), gamma, sharpen, saturate ----------
        int[] hist = new int[256]; int cnt = 0;
        for (int y = oy; y < oy + th; y++)
            for (int x = 0; x < W; x++)
            {
                int o = (y * W + x) * 3;
                float l = 0.299f * canvas[o] + 0.587f * canvas[o + 1] + 0.114f * canvas[o + 2];
                hist[(int)Math.Max(0, Math.Min(255, l))]++; cnt++;
            }
        int acc = 0, lo = 0, hi = 255;
        for (int v = 0; v < 256; v++) { acc += hist[v]; if (acc >= cnt * 0.01) { lo = v; break; } }
        acc = 0;
        for (int v = 0; v < 256; v++) { acc += hist[v]; if (acc >= cnt * 0.997) { hi = v; break; } }
        if (hi - lo < 64) { lo = 0; hi = 255; }
        // With the LEDs switched off the bright end of the histogram is lower; keep the levels the picture had
        // with the LEDs on (6..238) so the panel looks exactly as before.
        lo = 6; hi = 238;
        info.AppendFormat("levels {0}..{1}; ", lo, hi);
        for (int i = 0; i < canvas.Length; i++)
        {
            float v = Math.Max(0, Math.Min(1, (canvas[i] - lo) / (hi - lo)));
            canvas[i] = 255.0f * (float)Math.Pow(v, 0.9);      // gentle shadow lift for the small screen
        }
        float[] blur = Blur(canvas, W, H, 3, Gauss(3));
        for (int i = 0; i < canvas.Length; i++) canvas[i] = Math.Max(0, Math.Min(255, canvas[i] + 0.8f * (canvas[i] - blur[i])));
        for (int i = 0; i < W * H; i++)
        {
            float r = canvas[i * 3], g = canvas[i * 3 + 1], b = canvas[i * 3 + 2];
            float l = 0.299f * r + 0.587f * g + 0.114f * b;
            canvas[i * 3] = Math.Max(0, Math.Min(255, l + (r - l) * 1.12f));
            canvas[i * 3 + 1] = Math.Max(0, Math.Min(255, l + (g - l) * 1.12f));
            canvas[i * 3 + 2] = Math.Max(0, Math.Min(255, l + (b - l) * 1.12f));
        }

        // ---------- 5) Floyd-Steinberg dither to RGB565 ----------
        ushort[] outv = new ushort[W * H];
        using (Bitmap prev = new Bitmap(W, H, PixelFormat.Format24bppRgb))
        {
            int[] bits = { 5, 6, 5 };
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                {
                    int o = (y * W + x) * 3; int[] q = new int[3];
                    for (int c = 0; c < 3; c++)
                    {
                        int maxq = (1 << bits[c]) - 1;
                        float v = Math.Max(0, Math.Min(255, canvas[o + c]));
                        q[c] = (int)Math.Round(v / 255.0f * maxq);
                        float err = v - q[c] * 255.0f / maxq;
                        if (x + 1 < W) canvas[o + 3 + c] += err * 7 / 16.0f;
                        if (y + 1 < H)
                        {
                            if (x > 0) canvas[o + W * 3 - 3 + c] += err * 3 / 16.0f;
                            canvas[o + W * 3 + c] += err * 5 / 16.0f;
                            if (x + 1 < W) canvas[o + W * 3 + 3 + c] += err * 1 / 16.0f;
                        }
                    }
                    ushort c565 = (ushort)((q[0] << 11) | (q[1] << 5) | q[2]);
                    outv[y * W + x] = (ushort)((c565 >> 8) | (c565 << 8));
                    prev.SetPixel(x, y, Color.FromArgb((int)Math.Round(q[0] * 255.0 / 31), (int)Math.Round(q[1] * 255.0 / 63), (int)Math.Round(q[2] * 255.0 / 31)));
                }
            prev.Save(previewOut, ImageFormat.Png);
        }

        StringBuilder sb = new StringBuilder();
        sb.Append("// Generated by tools/gen_image.ps1 from assets/imsai8080.png. Do not edit by hand.\n");
        sb.AppendFormat("// {0}\n#pragma once\n#include <stdint.h>\n\n", info.ToString());
        sb.AppendFormat("#define PHOTO_W {0}\n#define PHOTO_H {1}\n", W, H);
        sb.Append("// RGB565, already byte-swapped for the SPI bus\n");
        sb.AppendFormat("static const uint16_t photo_rgb565[{0}] = {{\n", W * H);
        for (int i = 0; i < outv.Length; i++)
        {
            if (i % 16 == 0) sb.Append("    ");
            sb.AppendFormat("0x{0:X4},", outv[i]);
            sb.Append(i % 16 == 15 ? "\n" : " ");
        }
        sb.Append("\n};\n");
        File.WriteAllText(headerOut, sb.ToString(), new UTF8Encoding(false));
        return info.ToString();
    }
}
"@

$root = Split-Path $PSScriptRoot -Parent
$info = [ImgGen]::Run((Join-Path $root "assets\imsai8080.png"), (Join-Path $root "main\photo.h"), (Join-Path $root "assets\imsai8080_preview_320x172.png"), (Join-Path $root "assets\imsai8080_panel_handremoved.png"), (Join-Path $root "tools\led_sites.csv"), 320, 172)
"Done: $info"
