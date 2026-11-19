IMSAI display project - Waveshare ESP32-S3-LCD-1.47B
Archived 2026-11-18, LED animation added 2026-11-19

What it does
  Alternates, every 5 seconds, an "ImsaiGuy" title scene (shown first after reset) and a cleaned-up photo of the IMSAI 8080
  front panel (hand removed, background blacked out) with a gold frame, in landscape (320 x 172).
  The 44 front-panel LEDs in the photo are animated (30 fps, looping) from a recording of a real IMSAI 8080.
  (The recording itself is not in this repo; main\leds.h holds the measured brightness of every LED per frame.
  tools\extract_leds.py regenerates leds.h from a recording; tools\led_sites.csv gives the LED positions in the photo.
  Needs: pip install --user imageio-ffmpeg numpy. Run gen_image.ps1 afterwards if led_sites.csv changed.)

Contents
  main\hello.c        the program (ESP-IDF v5.5.2, esp_lcd ST7789 driver, no graphics library)
  main\fonts.h        generated anti-aliased fonts (Monotype Corsiva 46 px, Palatino Linotype 15 px)
  main\photo.h        generated 320x172 RGB565 picture
  assets\             original image, hand-removed full-resolution panel, screen preview
  tools\gen_fonts.ps1 regenerates fonts.h from installed Windows fonts (Microsoft fonts: check licenses before
                      distributing firmware commercially)
  tools\gen_image.ps1 regenerates photo.h from assets\imsai8080.png
  firmware\imsai_display_merged_0x0.bin   ready-to-flash image, SHA-256 7102D60DF638B5EB048748983163E7863299330018D93E6C811739FA5DC1620C

Flash the ready-made image (any 1.47B board; replace COM9 with your port; BOOT+RESET for download mode if needed)
  python -m esptool --chip esp32s3 -p COM9 -b 460800 write_flash 0x0 firmware\imsai_display_merged_0x0.bin

Build from source (ESP-IDF 5.5.x environment active)
  idf.py set-target esp32s3
  idf.py -p COM9 flash

Board pins (Waveshare ESP32-S3-LCD-1.47B, ST7789 172x320, no touch)
  MOSI 45, SCLK 40, CS 42, DC 41, RST 39, backlight 46 (active high); panel offset: 34 px on the short axis.
  Landscape = swap_xy + mirror(false, true), gap (0, 34).
