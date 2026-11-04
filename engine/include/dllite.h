// SPDX-License-Identifier: GPL-2.0-or-later
//
// C ABI between the Rust dock engine (libdllite_engine.a) and the Swift display host.
//
// Threading: callbacks run on the engine's own thread. Every dll_engine_* function may be called
// from any thread. Strings and buffers passed to callbacks are valid only for the callback's
// duration; copy what you keep.

#ifndef DLLITE_H
#define DLLITE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DLLEngine DLLEngine;

typedef enum {
    /// No dock found, or the dock is owned by another process (e.g. DisplayLink Manager).
    DLL_STATE_SEARCHING = 0,
    /// Encrypted session established; monitors are reported through monitor_attached.
    DLL_STATE_ENGAGED = 1,
    /// The session failed; the engine tears down every head and retries.
    DLL_STATE_RETRYING = 2,
} DLLState;

typedef struct {
    /// Dock connector index, 0-based. Stable for the life of the attachment.
    uint8_t head;
    /// Mode the dock was programmed with. Frames for this head must be exactly this size.
    uint32_t width;
    uint32_t height;
    uint32_t refresh_hz;
    /// Physical size from the EDID, 0 when the monitor does not report one.
    uint32_t width_mm;
    uint32_t height_mm;
    /// Raw big-endian EDID manufacturer id (bytes 8..9), product code, and serial number.
    uint16_t vendor_id;
    uint16_t product_code;
    uint32_t serial;
    /// NUL-terminated UTF-8 product name, e.g. "HP Z27k G3".
    const char *name;
    const uint8_t *edid;
    size_t edid_len;
    /// The dock draws the pointer itself. Capture without the cursor and report it through
    /// dll_engine_set_cursor / dll_engine_move_cursor; otherwise draw it into the frames.
    bool hardware_cursor;
} DLLMonitor;

typedef struct {
    void *context;
    /// A monitor is lit and accepting frames at monitor->width x monitor->height.
    void (*monitor_attached)(void *context, const DLLMonitor *monitor);
    /// The head is gone (unplugged, or the session is being rebuilt). Stop submitting frames.
    void (*monitor_detached)(void *context, uint8_t head);
    /// Engine state changed. message is human-readable and NUL-terminated.
    void (*state_changed)(void *context, DLLState state, const char *message);
} DLLCallbacks;

/// Start the engine thread. It searches for the dock, engages it, and reports monitors.
/// Returns NULL only if the thread could not be spawned.
DLLEngine *dll_engine_start(DLLCallbacks callbacks);

/// Hand the engine the newest frame for a head: BGRA8888, top row first, stride in bytes.
/// `dirty` lists the areas that changed since the previous frame as dirty_count (x, y, width,
/// height) quads in frame pixels; pass NULL when that is unknown (the whole frame is read).
/// The changed pixels are copied before this returns. Frames whose size differs from the head's
/// programmed mode are dropped.
void dll_engine_submit_frame(DLLEngine *engine, uint8_t head, const uint8_t *bgra, size_t stride,
                             uint32_t width, uint32_t height, const uint32_t *dirty,
                             size_t dirty_count);

/// Power a head's monitor down (false) or back up (true), e.g. on display sleep and wake.
void dll_engine_set_display_power(DLLEngine *engine, uint8_t head, bool on);

/// Set the pointer image the dock draws: BGRA8888 (premultiplied), top row first, tightly packed,
/// at most 64x64. hot_x/hot_y is the hotspot within the image, in image pixels.
void dll_engine_set_cursor(DLLEngine *engine, const uint8_t *bgra, uint32_t width, uint32_t height,
                           int32_t hot_x, int32_t hot_y);

/// Report where the pointer's hotspot is: on `head` at (x, y) in that head's mode pixels, or on
/// none of the dock's heads when head < 0. Cheap; call on every pointer move.
void dll_engine_move_cursor(DLLEngine *engine, int32_t head, int32_t x, int32_t y);

/// Blank every head, release the dock, join the engine thread, and free the engine.
/// No callback runs after this returns.
void dll_engine_stop(DLLEngine *engine);

#ifdef __cplusplus
}
#endif

#endif
