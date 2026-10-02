// Tufty 2350 board glue — implements the uniform board:: interface consumed by
// lib/badge.cpp. Display is a 320x240 ST7789 colour LCD (see st7789.hpp).

#ifndef BOARD_HPP
#define BOARD_HPP

#include <cstdint>

namespace board {

  // Capabilities (compile-time; demos branch on badge::color()/epaper()).
  constexpr bool COLOR  = true;   // full RGB panel
  constexpr bool EPAPER = false;  // fast, continuously refreshed

  // Native framebuffer geometry — the largest the runtime should wrap.
  constexpr int MAX_WIDTH  = 320;
  constexpr int MAX_HEIGHT = 240;

  // Bring up power, display and buttons. `mode` selects resolution:
  // 0 = LORES 160x120, 1 = HIRES 320x240 (matches badge::mode_t).
  void init(int mode);

  uint32_t *framebuffer();  // RGBA8888, width()*height()
  void      present();      // push the framebuffer to the panel
  int       width();
  int       height();

}

#endif // BOARD_HPP
