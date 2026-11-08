// Tab5 hardware this board does not have: the panel rail, the switched USB-A power, the touch
// panel, the RTC chip and the P4's HP-core probe. The callers are kept as they are; here these do nothing.
#include <stdint.h>
#include <stdbool.h>

extern "C" {
void panel_tab5_blank_early(void) { }
void tab5_usb_host_power(bool on) { (void)on; }
bool touch_mouse_init(void) { return false; }
void rtc_tab5_sync(void) { }
void hpm_probe(void) { }
}
