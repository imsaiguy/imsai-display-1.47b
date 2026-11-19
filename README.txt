IMSAI display project - Waveshare ESP32-S3-LCD-1.47B
Archived 2026-11-18

What it does
  Alternates, every 5 seconds, a cleaned-up photo of the IMSAI 8080 front panel (hand removed, background
  blacked out) and an "ImsaiGuy" title scene with a gold frame, in landscape (320 x 172).

Contents
  main\hello.c        the program (ESP-IDF v5.5.2, esp_lcd ST7789 driver, no graphics library)
  main\fonts.h        generated anti-aliased fonts (Monotype Corsiva 46 px, Palatino Linotype 15 px)
  main\photo.h        generated 320x172 RGB565 picture
  assets\             original image, hand-removed full-resolution panel, screen preview
  tools\gen_fonts.ps1 regenerates fonts.h from installed Windows fonts (Microsoft fonts: check licenses before
                      distributing firmware commercially)
  tools\gen_image.ps1 regenerates photo.h from assets\imsai8080.png
  firmware\imsai_display_merged_0x0.bin   ready-to-flash image, SHA-256 F1F0A4431E29BDF34DBA04932FA9042000FB8D3FE26CDA4B418C9246D933EBF3

Flash the ready-made image (any 1.47B board; replace COM9 with your port; BOOT+RESET for download mode if needed)
  python -m esptool --chip esp32s3 -p COM9 -b 460800 write_flash 0x0 firmware\imsai_display_merged_0x0.bin

Build from source (ESP-IDF 5.5.x environment active)
  idf.py set-target esp32s3
  idf.py -p COM9 flash

Board pins (Waveshare ESP32-S3-LCD-1.47B, ST7789 172x320, no touch)
  MOSI 45, SCLK 40, CS 42, DC 41, RST 39, backlight 46 (active high); panel offset: 34 px on the short axis.
  Landscape = swap_xy + mirror(false, true), gap (0, 34).
