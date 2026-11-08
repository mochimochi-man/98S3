// Audio backend for the ESP32-S3 build: a MAX98357A I2S amplifier on three GPIOs (board_pins.h).
//
// extern "C" interface: audio_init / audio_write_s32 / the counters. The emulator on one
// core converts and enqueues, a task on the other drains into I2S with a
// blocking write so the emulator never stalls on audio.

#include <string.h>
#include <stdlib.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/stream_buffer.h"
#include "freertos/idf_additions.h"  // xStreamBufferCreateWithCaps
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"

#include "driver/i2s_std.h"

#include "board_pins.h"
#include "pie_simd.h"  // falls back to plain C off Xtensa/S3

extern "C" int ets_printf(const char *fmt, ...);

static bool s_ok = false;
static int s_bufframes = 0;
static int16_t *s_buf = nullptr;                // conversion scratch (stereo int16)
static int16_t *s_dry16 = nullptr;              // conversion scratch (the beep)
static int16_t *s_frames = nullptr;             // the two, as ring frames
static StreamBufferHandle_t s_ring = nullptr;   // core1 -> core0 PCM stream (bytes)
// A ring frame is the FM mix and the beep side by side - L, R, beep L, beep R.
#define RING_FRAME 8
static i2s_chan_handle_t s_tx = nullptr;
static int s_volume = 70;                       // 0-100
static volatile int s_gain = 0;                 // Q8, from s_volume


#define PRIME_MS 80
#define HIGH_MS  150
static size_t s_prime_bytes = 22050 * RING_FRAME * PRIME_MS / 1000;
static size_t s_high_bytes = 22050 * RING_FRAME * HIGH_MS / 1000;

// The FM mix and the beep added back together, at the volume.
static void mix_plain(const int16_t *p, int16_t *o, int frames) {
    const int g = s_gain;
    for (int i = 0; i < frames; i++) {
        for (int ch = 0; ch < 2; ch++) {
            const int v = ((p[4 * i + ch] + p[4 * i + 2 + ch]) * g) >> 8;
            o[2 * i + ch] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
        }
    }
}

// ---- core 0: drain the ring into I2S --------------------------------
static void audio_task(void *arg) {
    (void)arg;
    // 4KB = 512 ring frames = ~23ms per codec write. On the S3 this was 1KB
    // because the ring behind it was small; here it just means fewer wakeups.
    static uint8_t rx[4096] __attribute__((aligned(4)));
    static int16_t mix[sizeof(rx) / RING_FRAME * 2];  // what goes to the codec
    size_t carry = 0;  // bytes of a split ring frame held back from last time
    bool primed = false;
    for (;;) {
        // Keep a cushion. The emulator hands over a frame's worth of sound at
        // a time, and a frame does not always take the same time; passed on
        // the moment it arrived, the codec was fed just in time, and every
        // frame that ran a little long was a gap - a click. So wait until
        // there is PRIME_MS of sound in hand before starting, and again after
        // running dry, and the jitter is absorbed by what is waiting.
        if (!primed) {
            if (xStreamBufferBytesAvailable(s_ring) < s_prime_bytes) {
                vTaskDelay(pdMS_TO_TICKS(5));
                continue;
            }
            primed = true;
        }
        size_t n = xStreamBufferReceive(s_ring, rx + carry, sizeof(rx) - carry, pdMS_TO_TICKS(100));
        if (n == 0) {
            primed = false;
            continue;
        }
        n += carry;
        // A ring frame is RING_FRAME bytes and the ring is byte-oriented, so
        // what comes back is not always a whole number of frames. Handing the
        // codec a partial frame shifts left and right for the rest of the
        // session — that is exactly the "clicking" bug the split build hit.
        // Carry the remainder into the next read instead.
        const size_t play = n - n % RING_FRAME;
        carry = n - play;
        if (play) {
            // The chips render a hair faster than the codec plays (about
            // 22,100 against 22,050 a second), so the cushion grows until the
            // ring is full and a whole block has to be refused - a click.
            // Past HIGH_MS, take two frames out of the block instead, each
            // folded into its neighbour: a 0.1% tightening nobody can hear.
            int frames = (int)(play / RING_FRAME);
            if (frames >= 16 && xStreamBufferBytesAvailable(s_ring) > s_high_bytes) {
                int16_t *f = (int16_t *)rx;
                for (int cut = 0; cut < 2; cut++) {
                    const int j = frames * (cut + 1) / 3;
                    for (int c = 0; c < 4; c++) {
                        f[4 * j + c] = (int16_t)((f[4 * j + c] + f[4 * j + 4 + c]) / 2);
                    }
                    memmove(&f[4 * (j + 1)], &f[4 * (j + 2)], (size_t)(frames - j - 2) * RING_FRAME);
                    frames--;
                }
            }
            mix_plain((const int16_t *)rx, mix, frames);
            size_t done = 0;
            i2s_channel_write(s_tx, mix, (size_t)frames * 4, &done, portMAX_DELAY);
        }
        if (carry) {
            memmove(rx, rx + play, carry);
        }
    }
}

// ---- init -----------------------------------------------------------------
// rate = sample rate, maxframes = the biggest block audio_write_s32 will get.
extern "C" void audio_set_volume(int percent);
extern "C" bool audio_init(int rate, int maxframes) {
    if (maxframes <= 0) {
        return false;
    }
    i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    cc.auto_clear = true;            // an underrun plays silence, not the last buffer again
    if (i2s_new_channel(&cc, &s_tx, nullptr) != ESP_OK) {
        ets_printf("audio: i2s_new_channel FAIL\n");
        return false;
    }
    i2s_std_config_t sc = {};
    sc.clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG((uint32_t)rate);
    sc.slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
    sc.gpio_cfg.mclk = I2S_GPIO_UNUSED;
    sc.gpio_cfg.bclk = (gpio_num_t)BRD_I2S_BCLK;
    sc.gpio_cfg.ws = (gpio_num_t)BRD_I2S_LRCLK;
    sc.gpio_cfg.dout = (gpio_num_t)BRD_I2S_DOUT;
    sc.gpio_cfg.din = I2S_GPIO_UNUSED;
    if (i2s_channel_init_std_mode(s_tx, &sc) != ESP_OK || i2s_channel_enable(s_tx) != ESP_OK) {
        ets_printf("audio: i2s std init FAIL\n");
        return false;
    }
    audio_set_volume(s_volume);

    s_bufframes = maxframes;
    // 16-byte align the scratch: the PIE fast path requires it on the S3, and
    // keeping the alignment costs nothing here.
    const size_t scratch = (size_t)maxframes * 2 * sizeof(int16_t) + 16;
    void *raw = heap_caps_malloc(scratch, MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL);
    if (!raw) {
        ets_printf("audio: scratch alloc FAIL\n");
        return false;
    }
    s_buf = (int16_t *)(((uintptr_t)raw + 15) & ~(uintptr_t)15);
    void *raw_dry = heap_caps_malloc(scratch, MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL);
    s_frames = (int16_t *)heap_caps_malloc((size_t)maxframes * RING_FRAME,
                                           MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL);
    if (!raw_dry || !s_frames) {
        ets_printf("audio: scratch alloc FAIL\n");
        return false;
    }
    s_dry16 = (int16_t *)(((uintptr_t)raw_dry + 15) & ~(uintptr_t)15);

    // 16 blocks of 20ms = ~320ms, sized for how long a stall it should ride
    // out. A shorter ring refills more often,
    // so the producer is throttled more frequently and the stutter at a BGM
    // change (where the game loads from the card and the emulator stalls) is
    // worse, not better. In PSRAM because only tasks touch it, never an ISR.
    const size_t ringbytes = (size_t)maxframes * RING_FRAME * 16;
    s_ring = xStreamBufferCreateWithCaps(ringbytes, 1, MALLOC_CAP_SPIRAM);
    if (!s_ring) {
        ets_printf("audio: ring alloc FAIL (%u bytes psram)\n", (unsigned)ringbytes);
        return false;
    }

    s_prime_bytes = (size_t)rate * RING_FRAME * PRIME_MS / 1000;
    s_high_bytes = (size_t)rate * RING_FRAME * HIGH_MS / 1000;
    s_ok = true;
    xTaskCreatePinnedToCore(audio_task, "audio", 4096, nullptr, 6, nullptr, 0);
    ets_printf("audio: I2S ready rate=%d\n", rate);
    return true;
}

// How much sound is in hand (us), for the emulator's pacing: below the
// cushion it runs ahead of real time until the cushion is back. -1 = no output.
extern "C" int audio_cushion_us(void) {
    if (!s_ok || !s_ring) return -1;
    return (int)((uint64_t)xStreamBufferBytesAvailable(s_ring) * (PRIME_MS * 1000) / s_prime_bytes);
}
extern "C" int audio_prime_us(void) {
    return PRIME_MS * 1000;
}

// ---- core 1: convert the mixer's SINT32 block and enqueue ----------------------
extern "C" void audio_write_s32(const int32_t *pcm, const int32_t *dry, int frames) {
    if (!s_ok || !s_ring || !s_buf || !pcm || frames <= 0) {
        return;
    }
    if (frames > s_bufframes) {
        frames = s_bufframes;
    }
    const int n = frames * 2;
    simd_s32_to_s16(pcm, s_buf, n, 0);
    if (dry) {
        simd_s32_to_s16(dry, s_dry16, n, 0);
    } else {
        memset(s_dry16, 0, (size_t)n * sizeof(int16_t));
    }
    for (int i = 0; i < frames; i++) {
        s_frames[4 * i] = s_buf[2 * i];
        s_frames[4 * i + 1] = s_buf[2 * i + 1];
        s_frames[4 * i + 2] = s_dry16[2 * i];
        s_frames[4 * i + 3] = s_dry16[2 * i + 1];
    }

    const size_t bytes = (size_t)frames * RING_FRAME;
    // All of the block or none of it. A send cut short at whatever byte the
    // ring had room for left the stream out of step with the frames, and
    // everything after it played as noise - left and right, high and low
    // bytes all crossed - until another cut happened to put it back.
    if (xStreamBufferSpacesAvailable(s_ring) < bytes) {
        return;
    }
    xStreamBufferSend(s_ring, s_frames, bytes, 0);
}

// ---- volume ---------------------------------------------------------------
// The MAX98357A has no level control of its own, so the volume is a gain on the
// samples; a square law, so the steps sound even, and 100% is unity.
extern "C" void audio_set_volume(int percent) {
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }
    s_volume = percent;
    s_gain = percent * percent * 256 / 10000;
}

extern "C" int audio_get_volume(void) {
    return s_volume;
}

