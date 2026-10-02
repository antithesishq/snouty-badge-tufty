#include "st7789.hpp"

#include <cmath>
#include <algorithm>

#include "pico/stdlib.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/pio.h"
#include "hardware/pwm.h"
#include "hardware/clocks.h"

#include "st7789_parallel.pio.h"

// BW_DISPLAY_* / BW_LCD_* come from pimoroni_tufty2350.h via the SDK board config.

namespace st7789 {

  // --- panel geometry -------------------------------------------------------
  static const int WIDTH  = BW_DISPLAY_WIDTH;   // 320 (landscape, framebuffer)
  static const int HEIGHT = BW_DISPLAY_HEIGHT;  // 240

  // --- interface pins -------------------------------------------------------
  static const uint CS     = BW_LCD_CS;
  static const uint DC     = BW_LCD_DC;
  static const uint WR_SCK = BW_LCD_WR;
  static const uint RD_SCK = BW_LCD_RD;
  static const uint D0     = BW_LCD_D0;
  static const uint BL     = BW_LCD_BL;
  static const uint VSYNC  = BW_LCD_VSYNC;

  // --- PIO / DMA state ------------------------------------------------------
  static PIO      parallel_pio = pio1;
  static uint     parallel_sm;
  static uint     parallel_offset;
  static uint     st_dma;
  static uint32_t startup_hz  = 0;
  static uint32_t max_pio_clk = 44 * MHZ;
  static bool     use_vsync   = false;
  static bool     fullres     = true;

  // Two scratch columns: convert one while the other DMAs out. The panel is
  // 240 tall, so one transposed column is 240 px (480 bytes); keep a/b halves.
  static uint16_t linebuffer[240 * 4] __attribute__((aligned(4)));

  // --- ST7789 register set --------------------------------------------------
  enum reg : uint8_t {
    SWRESET = 0x01, SLPOUT = 0x11, INVON = 0x21, DISPON = 0x29,
    CASET = 0x2A, RASET = 0x2B, RAMWR = 0x2C, TEON = 0x35, STE = 0x44,
    MADCTL = 0x36, COLMOD = 0x3A, RAMCTRL = 0xB0, PORCTRL = 0xB2,
    GCTRL = 0xB7, VCOMS = 0xBB, LCMCTRL = 0xC0, VDVVRHEN = 0xC2,
    VRHS = 0xC3, VDVS = 0xC4, FRCTRL2 = 0xC6, PWCTRL1 = 0xD0,
    GMCTRP1 = 0xE0, GMCTRN1 = 0xE1,
  };

  enum madctl : uint8_t {
    ROW_ORDER = 0x80, COL_ORDER = 0x40, SWAP_XY = 0x20,
    SCAN_ORDER = 0x10, RGB_BGR = 0x08, HORIZ_ORDER = 0x04,
  };

  static void configure_dma(bool read_increment) {
    dma_channel_config cfg = dma_channel_get_default_config(st_dma);
    channel_config_set_read_increment(&cfg, read_increment);
    channel_config_set_transfer_data_size(&cfg, DMA_SIZE_8);
    channel_config_set_bswap(&cfg, false);
    channel_config_set_dreq(&cfg, pio_get_dreq(parallel_pio, parallel_sm, true));
    dma_channel_configure(st_dma, &cfg, &parallel_pio->txf[parallel_sm], NULL, 0, false);
  }

  static inline void pio_block_until_stalled() {
    uint32_t mask = 1u << (parallel_sm + PIO_FDEBUG_TXSTALL_LSB);
    parallel_pio->fdebug = mask;
    while (!(parallel_pio->fdebug & mask)) {}
  }

  static inline void wait_for_dma() {
    dma_channel_wait_for_finish_blocking(st_dma);
    pio_block_until_stalled();  // avoid racing CS/DC against the last PIO word
  }

  static void write_blocking(const uint8_t *src, size_t len) {
    dma_channel_set_trans_count(st_dma, len, false);
    dma_channel_set_read_addr(st_dma, src, true);
    wait_for_dma();
  }

  static void start_dma(const uint8_t *src, size_t len) {
    dma_channel_set_trans_count(st_dma, len, false);
    dma_channel_set_read_addr(st_dma, src, true);
  }

  static void command(uint8_t cmd, size_t len = 0, const char *data = nullptr) {
    wait_for_dma();
    gpio_put(DC, 0);            // command
    gpio_put(CS, 0);
    write_blocking(&cmd, 1);
    if (data) {
      gpio_put(DC, 1);         // data
      write_blocking((const uint8_t *)data, len);
    }
    gpio_put(CS, 1);
  }

  void backlight(uint8_t brightness) {
    const float gamma = 2.8f;
    uint16_t value = (uint16_t)(powf((float)brightness / 255.0f, gamma) * 65535.0f + 0.5f);
    pwm_set_gpio_level(BL, value);
  }

  void set_vsync(bool enabled) { use_vsync = enabled; }
  void set_mode(bool fr)       { fullres = fr; }

  void init() {
    // RP2350 PIO can window 32 contiguous GPIOs; our data pins are 32..39, so
    // base the PIO at GPIO16 (covering 16..47).
    pio_set_gpio_base(parallel_pio, D0 + 8 >= 32 ? 16 : 0);

    parallel_sm     = pio_claim_unused_sm(parallel_pio, true);
    parallel_offset = pio_add_program(parallel_pio, &st7789_parallel_program);

    pio_gpio_init(parallel_pio, WR_SCK);
    gpio_set_function(RD_SCK, GPIO_FUNC_SIO);
    gpio_set_dir(RD_SCK, GPIO_OUT);
    for (uint i = 0; i < 8; i++) pio_gpio_init(parallel_pio, D0 + i);

    pio_sm_set_consecutive_pindirs(parallel_pio, parallel_sm, D0, 8, true);
    pio_sm_set_consecutive_pindirs(parallel_pio, parallel_sm, WR_SCK, 1, true);

    pio_sm_config c = st7789_parallel_program_get_default_config(parallel_offset);
    sm_config_set_out_pins(&c, D0, 8);
    sm_config_set_sideset_pins(&c, WR_SCK);
    sm_config_set_fifo_join(&c, PIO_FIFO_JOIN_TX);
    sm_config_set_out_shift(&c, false, true, 8);   // shift left, autopull @ 8 bits

    startup_hz = clock_get_hz(clk_sys);
    sm_config_set_clkdiv(&c, ceilf(2.0f * fmaxf(1.0f, (float)startup_hz / max_pio_clk)) * 0.5f);

    pio_sm_init(parallel_pio, parallel_sm, parallel_offset, &c);
    pio_sm_set_enabled(parallel_pio, parallel_sm, true);

    st_dma = dma_claim_unused_channel(true);
    configure_dma(true);

    gpio_put(RD_SCK, 1);

    // --- DC / CS as plain GPIO outputs ---
    gpio_set_function(DC, GPIO_FUNC_SIO); gpio_set_dir(DC, GPIO_OUT);
    gpio_set_function(CS, GPIO_FUNC_SIO); gpio_set_dir(CS, GPIO_OUT);
    gpio_init(VSYNC);  // TE input

    // --- backlight via PWM, off until init completes ---
    pwm_config pcfg = pwm_get_default_config();
    pwm_set_wrap(pwm_gpio_to_slice_num(BL), 65535);
    pwm_init(pwm_gpio_to_slice_num(BL), &pcfg, true);
    gpio_set_function(BL, GPIO_FUNC_PWM);
    backlight(0);

    // --- panel init sequence (matches the stock Tufty 2350 driver) ---
    command(SWRESET);
    sleep_ms(150);

    command(COLMOD,   1, "\x05");                       // 16 bpp
    command(PORCTRL,  5, "\x0c\x0c\x00\x33\x33");
    command(LCMCTRL,  1, "\x2c");
    command(VDVVRHEN, 1, "\x01");
    command(VRHS,     1, "\x0f");
    command(VDVS,     1, "\x20");
    command(PWCTRL1,  2, "\xa4\xa1");
    command(FRCTRL2,  1, "\x0f");
    command(RAMCTRL,  2, "\x00\xc0");                   // fixes low-brightness green banding
    command(GCTRL,    1, "\x35");
    command(VCOMS,    1, "\x1b");
    command(GMCTRP1, 14, "\xF0\x00\x06\x04\x05\x05\x31\x44\x48\x36\x12\x12\x2B\x34");
    command(GMCTRN1, 14, "\xF0\x0B\x0F\x0F\x0D\x26\x31\x43\x47\x38\x14\x14\x2C\x32");

    command(INVON);
    command(SLPOUT);
    sleep_ms(100);

    uint8_t mad = madctl::ROW_ORDER | madctl::SCAN_ORDER;
    uint16_t caset[2] = { __builtin_bswap16(0), __builtin_bswap16(239) }; // 240 wide GRAM
    uint16_t raset[2] = { __builtin_bswap16(0), __builtin_bswap16(319) }; // 320 tall GRAM
    command(CASET,  4, (char *)caset);
    command(RASET,  4, (char *)raset);
    command(MADCTL, 1, (char *)&mad);

    // Clear GRAM to black: clock out a single zero with read-increment off.
    uint8_t cmd = RAMWR;
    gpio_put(DC, 0); gpio_put(CS, 0);
    write_blocking(&cmd, 1);
    gpio_put(DC, 1);
    linebuffer[0] = 0;
    configure_dma(false);
    write_blocking((uint8_t *)linebuffer, WIDTH * HEIGHT * sizeof(uint16_t));
    configure_dma(true);

    command(TEON, 1, "\x00");
    command(STE,  2, "\x00\x00");
    command(DISPON);
    backlight(230);
  }

  // Convert RGBA8888 (R=byte0, G=byte1, B=byte2) to big-endian RGB565.
  static inline uint16_t to_rgb565_be(uint32_t src) {
    return __builtin_bswap16((uint16_t)(((src & 0xf8) << 8) | ((src & 0xfc00) >> 5) | ((src & 0xf80000) >> 19)));
  }

  void update(const uint32_t *framebuffer) {
    // Re-derive the PIO clock divider if the system clock changed since init.
    uint32_t hz = clock_get_hz(clk_sys);
    if (hz != startup_hz) {
      startup_hz = hz;
      pio_sm_set_clkdiv(parallel_pio, parallel_sm, fmaxf(1.0f, (float)hz / max_pio_clk));
    }

    wait_for_dma();

    if (use_vsync) {
      while (gpio_get(VSYNC) == 0) { tight_loop_contents(); }
    }

    uint8_t cmd = RAMWR;
    gpio_put(DC, 0); gpio_put(CS, 0);
    write_blocking(&cmd, 1);
    gpio_put(DC, 1);

    // Two scratch columns: convert one while the previous DMAs out ("chase the
    // beam"). Both paths transpose the landscape framebuffer into panel columns.
    uint16_t *buf_a = linebuffer;
    uint16_t *buf_b = linebuffer + 240 * 2;

    if (fullres) {
      // 320x240 1:1 -> one 240-px panel column per source column.
      for (int x = 0; x < WIDTH; x++) {
        const uint32_t *col = framebuffer + x;
        for (int y = 0; y < HEIGHT; y++) buf_a[y] = to_rgb565_be(col[y * WIDTH]);
        wait_for_dma();
        start_dma((uint8_t *)buf_a, HEIGHT * 2);
        std::swap(buf_a, buf_b);
      }
    } else {
      // LORES 160x120 -> 320x240: double each source pixel into a 2x2 block.
      // Vertical double = each row written as [p,p] (pixel | pixel<<16); the
      // whole 240-px column is emitted twice for the horizontal double.
      const int LW = WIDTH / 2, LH = HEIGHT / 2; // 160 x 120
      for (int x = 0; x < LW; x++) {
        const uint32_t *col = framebuffer + x;
        for (int y = 0; y < LH; y++) {
          uint16_t pixel = to_rgb565_be(col[y * LW]);
          uint32_t doubled = pixel | ((uint32_t)pixel << 16);
          ((uint32_t *)buf_a)[y]      = doubled;
          ((uint32_t *)buf_a)[LH + y] = doubled;
        }
        wait_for_dma();
        start_dma((uint8_t *)buf_a, HEIGHT * 2 * 2); // two 240-px columns
        std::swap(buf_a, buf_b);
      }
    }
    wait_for_dma();
    gpio_put(CS, 1);
  }

}
