// 8-bit parallel (8080) ST7789 driver for the Pimoroni Tufty 2350.
//
// A standalone port of the Tufty firmware's PIO + DMA parallel driver (no
// MicroPython). Pin map comes from pimoroni_tufty2350.h (BW_LCD_*). The panel
// GRAM is 240x320 portrait; update() transposes a 320x240 landscape framebuffer
// into it column-by-column (which also matches the scan direction and avoids
// diagonal tearing), exactly as the stock driver does.
//
// update() takes the PicoVector framebuffer as packed RGBA8888 words (byte 0 =
// R, 1 = G, 2 = B, 3 = A) and emits big-endian RGB565 over the parallel bus.

#ifndef ST7789_HPP
#define ST7789_HPP

#include <cstdint>

namespace st7789 {

  // Claim a PIO state machine + DMA channel, reset and configure the panel.
  void init();

  // Select resolution: true = full 320x240, false = LORES 160x120 (each pixel
  // doubled to a 2x2 block on the panel). Default full-res.
  void set_mode(bool fullres);

  // Push one frame. Full-res reads a 320x240 framebuffer; LORES reads 160x120
  // and pixel-doubles it onto the 320x240 panel.
  void update(const uint32_t *framebuffer);

  // Gamma-corrected backlight, 0..255.
  void backlight(uint8_t brightness);

  // Wait for the TE/vsync line before each update (off by default; tearing is
  // harmless for the demo and this avoids any stall if TE is not wired).
  void set_vsync(bool enabled);

}

#endif // ST7789_HPP
