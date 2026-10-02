# Snouty Arcade launcher for the Supabase / Badgeware Tufty 2350 firmware.
#
# Reboots the badge into the Snouty Arcade, installed beside MicroPython in
# the free flash gap 0x1014F000..0x10200000 by
# snouty-tufty-arcade-supabase.uf2. In the arcade, the last menu row
# (SUPABASE BADGE) or the RESET button comes back here. Details, install
# steps and recovery: docs/DUALBOOT.md in the snouty-tufty repository.
#
# The launch logic is in snouty_dualboot.py (host-tested); this file is the
# screen and the buttons.
import time

import machine
import uctypes

import snouty_dualboot as dualboot

FRAMEBUFFER_BYTES = 320 * 240 * 4  # the st7789 module's buffer (main SRAM)


def wrap(text, width):
    lines, line = [], ""
    for word in text.split(" "):
        candidate = word if not line else line + " " + word
        if line and screen.measure_text(candidate)[0] > width:
            lines.append(line)
            line = word
        else:
            line = candidate
    if line:
        lines.append(line)
    return lines


def show(title, body="", hint=""):
    screen.pen = color.black
    screen.shape(shape.rectangle(0, 0, 160, 120))
    try:
        screen.font = font.absolute
    except OSError:
        pass
    screen.pen = color.rgb(241, 130, 113)  # coral
    w, _ = screen.measure_text(title)
    screen.text(title, 80 - (w / 2), 14)
    screen.pen = color.white
    y = 36
    for line in wrap(body, 148):
        screen.text(line, 6, y)
        y += 13
    if hint:
        screen.pen = color.rgb(142, 124, 150)
        w, _ = screen.measure_text(hint)
        screen.text(hint, 80 - (w / 2), 104)
    display.update()


def wait_for_b():
    # HOME goes back to the launcher on its own (badgeware launch()).
    while badge.pressed() or badge.held():
        badge.poll()
    while True:
        badge.poll()
        if badge.pressed(BUTTON_B):
            return
        time.sleep(0.01)


def start():
    show("SNOUTY ARCADE", "Starting...")
    time.sleep(0.3)
    try:
        base, size = dualboot.prepare(machine.mem32, uctypes.addressof(display), FRAMEBUFFER_BYTES)
    except dualboot.LaunchError as e:
        return str(e)
    except Exception as e:  # noqa: BLE001
        return "Unexpected error: %s" % e
    # From here on nothing may draw: the stub sits in the framebuffer.
    machine.disable_irq()
    dualboot.run_reboot(machine.mem32, base, size)
    while True:
        pass


failure = dualboot.last_failure(machine.mem32)
if failure:
    show("LAST START FAILED", failure + ". The badge went back to MicroPython.", "B: TRY AGAIN   HOME: BACK")
    wait_for_b()

problem = start()
if problem:
    show("SNOUTY ARCADE", problem, "B OR HOME: BACK")
    wait_for_b()
# Returning ends the app: the badge goes back to its launcher.
