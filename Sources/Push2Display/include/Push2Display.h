#ifndef PUSH2_DISPLAY_H
#define PUSH2_DISPLAY_H

#include <stdint.h>

// Ableton Push 2's 960×160 display over USB bulk (interface 0, endpoint 0x01), as documented in
// Ableton's "Push 2 MIDI and Display Interface Manual". Only the documented frame header and
// 512-byte-aligned pixel data are ever sent. Call every function from one serial queue.

#define PUSH2_WIDTH 960
#define PUSH2_HEIGHT 160
#define PUSH2_LINE_BYTES 2048
#define PUSH2_FRAME_BYTES (PUSH2_HEIGHT * PUSH2_LINE_BYTES)

/// 0 = open; -1 = no Push 2 on USB; -2 = another app has the display (Ableton Live); -3 = other error.
int push2_display_open(void);
int push2_display_is_open(void);
/// Sends one frame of 960×160 pixels, row by row from the top, in the Push's 16-bit format
/// (red in bits 0–4, green 5–10, blue 11–15). 0 = sent; otherwise the display is closed.
int push2_display_send(const uint16_t *pixels);
void push2_display_close(void);

/// The bytes sent after the header: each line's pixels, 128 filler bytes, XORed with the
/// signal-shaping pattern. `out` holds PUSH2_FRAME_BYTES. Exposed for the self-test.
void push2_frame_encode(const uint16_t *pixels, uint8_t *out);

/// RGBA8 (sRGB) to the Push's 16-bit pixels: red bits 0–4, green 5–10, blue 11–15.
void push2_convert_rgba(const uint8_t *rgba, uint16_t *out, int count);
/// The waveform summary's visible window (left…left+span of the whole, 0…1) as one min/max per column.
void push2_wave_columns(const float *lows, const float *highs, int count, double left, double span,
                        int columns, float *outLow, float *outHigh);

#endif
