#include "board.hpp"

#include "st7789.hpp"
#include "psram.h"
#include "powman.h"

#include "pico/stdlib.h"
#include "hardware/gpio.h"

// BW_* pins come from pimoroni_tufty2350.h via the SDK board config.
#include "buttons.hpp"

namespace board {

  // 320x240 RGBA8888 framebuffer in SRAM (LORES uses the first 160x120 words).
  static uint32_t fb[MAX_WIDTH * MAX_HEIGHT];

  static int g_width  = 160;
  static int g_height = 120;

  void init(int mode) {
    // First thing at boot: if the power button (RESET) is being held, run the
    // long-press LED sweep and power off. Returns immediately on a normal boot.
    powman_boot_check();

    stdio_init_all();

    // Switched peripheral power rail (panel + backlight live on it).
    gpio_init(BW_SW_POWER_EN);
    gpio_set_dir(BW_SW_POWER_EN, GPIO_OUT);
    gpio_put(BW_SW_POWER_EN, 1);
    sleep_ms(50);

    rtc_enable();            // PCF85063 RTC available via rtc_get/set_datetime()
    psram_init(BW_PSRAM_CS); // bring PSRAM up; available for asset storage

    bool hires = (mode != 0);
    g_width  = hires ? 320 : 160;
    g_height = hires ? 240 : 120;

    st7789::set_mode(hires);
    st7789::init();
    buttons::init();
  }

  uint32_t *framebuffer() { return fb; }
  void      present()     { st7789::update(fb); }
  int       width()       { return g_width; }
  int       height()      { return g_height; }

}
