/// Pimoroni Badgeware Tufty 2350 board configuration (RP2350B).
///
/// Pin map from Pimoroni's badgeware-cpp board header
/// (reference/badgeware-cpp-tufty/pimoroni_tufty2350.h, MIT).
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const Pio = hal.pio.Pio;

// Crystal oscillator frequency (12 MHz on the Tufty 2350)
pub const xosc_freq = 12_000_000;

// Tell microzig we have the 48-GPIO RP2350B (the LCD bus lives on GPIO 27..39)
pub const has_rp2350b = true;

// ========================================
// Power
// ========================================

// Switched peripheral power rail (panel, backlight and the RTC live on it).
// Drive high, then wait ~50 ms before touching the panel.
pub const sw_power_en = gpio.num(41);

// ========================================
// LCD: 320x240 ST7789, 8-bit 8080 parallel, driven by PIO
// ========================================

pub const lcd_cs = gpio.num(27); // chip select (LCD_CS), active low, SIO
pub const lcd_dc = gpio.num(28); // data/command (LCD_RS): 0 = command, SIO
pub const lcd_wr = gpio.num(30); // write strobe (LCD_WR), PIO side-set
pub const lcd_rd = gpio.num(31); // read strobe (LCD_RD), held high, SIO
pub const lcd_d0 = gpio.num(32); // LCD_DB0..DB7 = GPIO 32..39, PIO out pins
pub const lcd_data_count = 8;
pub const lcd_backlight = gpio.num(26); // backlight PWM (slice 5, channel A)
pub const lcd_te = gpio.num(21); // tearing-effect / vsync output of the panel

// The parallel bus state machine runs on PIO1, as in the reference driver.
pub const lcd_pio: Pio = .pio1;

// An RP2350 PIO block reaches 32 consecutive GPIOs: GPIOBASE = 16 maps
// PIO pin index 0..31 to GPIO 16..47, which covers WR (30) and D0..D7 (32..39).
pub const lcd_pio_gpio_base = 16;

// ========================================
// Buttons: active low, need the internal pull-ups
// ========================================

pub const button_a = gpio.num(7);
pub const button_b = gpio.num(9);
pub const button_c = gpio.num(10);
pub const button_up = gpio.num(11);
pub const button_down = gpio.num(6);
pub const button_home = gpio.num(22); // also the BOOT button

// ========================================
// Not used by M0 (listed so nothing else claims them)
// ========================================

// Rear white case LEDs, GPIO 0..3. Left untouched (off after reset).
pub const case_led_0 = gpio.num(0);
pub const case_led_1 = gpio.num(1);
pub const case_led_2 = gpio.num(2);
pub const case_led_3 = gpio.num(3);

// PCF85063 RTC on I2C0
pub const rtc_sda = gpio.num(4);
pub const rtc_scl = gpio.num(5);

// 8 MB PSRAM chip select (QMI CS1)
pub const psram_cs = gpio.num(8);

// Power / reset button sense, VBUS detect, RTC alarm, switch interrupt
pub const reset_sw = gpio.num(14);
pub const vbus_detect = gpio.num(12);
pub const rtc_alarm = gpio.num(13);
pub const switch_int = gpio.num(15);

// CYW43 Wi-Fi/BT: GPIO 23 (WL_REG_ON), 24 (data/irq), 25 (CS), 29 (clock)
