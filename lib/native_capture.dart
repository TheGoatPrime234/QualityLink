import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:image/image.dart' as img;

class NativeScreenCapture {
  /// Nimmt den Bildschirm auf - Optimiert für Streaming
  static Uint8List? captureWindowsScreen() {
    if (!Platform.isWindows) {
      print("❌ Capture nur auf Windows möglich");
      return null;
    }

    try {
      // 1. Desktop-Handle
      final hwnd = GetDesktopWindow();
      if (hwnd == 0) {
        print("❌ GetDesktopWindow failed");
        return null;
      }

      final hdcScreen = GetDC(hwnd);
      if (hdcScreen == 0) {
        print("❌ GetDC failed");
        return null;
      }

      final hdcMem = CreateCompatibleDC(hdcScreen);
      if (hdcMem == 0) {
        ReleaseDC(hwnd, hdcScreen);
        return null;
      }

      // 2. Bildschirmgröße
      final width = GetSystemMetrics(SM_CXSCREEN);
      final height = GetSystemMetrics(SM_CYSCREEN);

      if (width <= 0 || height <= 0) {
        DeleteDC(hdcMem);
        ReleaseDC(hwnd, hdcScreen);
        return null;
      }

      // 3. Bitmap erstellen
      final hBitmap = CreateCompatibleBitmap(hdcScreen, width, height);
      if (hBitmap == 0) {
        DeleteDC(hdcMem);
        ReleaseDC(hwnd, hdcScreen);
        return null;
      }

      final hOld = SelectObject(hdcMem, hBitmap);

      // 4. Screen kopieren (BitBlt)
      final copyResult = BitBlt(
        hdcMem, 0, 0, width, height,
        hdcScreen, 0, 0,
        SRCCOPY // 0x00CC0020
      );

      if (copyResult == 0) {
        print("⚠️ BitBlt failed");
        SelectObject(hdcMem, hOld);
        DeleteObject(hBitmap);
        DeleteDC(hdcMem);
        ReleaseDC(hwnd, hdcScreen);
        return null;
      }

      // 5. Bitmap-Info vorbereiten
      final bmi = calloc<BITMAPINFO>();
      bmi.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
      bmi.ref.bmiHeader.biWidth = width;
      bmi.ref.bmiHeader.biHeight = -height; // Top-Down
      bmi.ref.bmiHeader.biPlanes = 1;
      bmi.ref.bmiHeader.biBitCount = 32;
      bmi.ref.bmiHeader.biCompression = BI_RGB;

      // 6. Pixel-Daten lesen
      final pixelDataSize = width * height * 4;
      final pPixels = calloc<Uint8>(pixelDataSize);

      final bitsResult = GetDIBits(
        hdcMem, hBitmap, 0, height,
        pPixels, bmi, DIB_RGB_COLORS
      );

      // 7. Cleanup GDI-Objekte (Wichtig!)
      SelectObject(hdcMem, hOld);
      DeleteObject(hBitmap);
      DeleteDC(hdcMem);
      ReleaseDC(hwnd, hdcScreen);
      free(bmi);

      if (bitsResult == 0) {
        free(pPixels);
        print("⚠️ GetDIBits failed");
        return null;
      }

      // 8. Image-Objekt erstellen
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: pPixels.asTypedList(pixelDataSize).buffer,
        order: img.ChannelOrder.bgra,
        numChannels: 4
      );

      free(pPixels);

      // 9. Runterskalieren für Performance (720p Breite)
      final resized = img.copyResize(image, width: 1280);

      // 10. Als JPEG encodieren (Quality 60 = guter Kompromiss)
      final encoded = img.encodeJpg(resized, quality: 60);

      return Uint8List.fromList(encoded);

    } catch (e, stack) {
      print("❌ Capture Exception: $e");
      print(stack);
      return null;
    }
  }
}