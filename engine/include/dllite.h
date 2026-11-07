// SPDX-License-Identifier: GPL-2.0-or-later
//
// C ABI between the Rust dock engine (libdllite_engine.a) and the Swift display host.
//
// Threading: callbacks run on the engine's own thread. Functions other than dll_engine_stop may
// be called concurrently from any thread while the engine is alive. Stop must be serialized
// against all other calls and must not run from a callback. Strings and buffers passed to
// callbacks are valid only for the callback's duration; copy what you keep.

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
/// A non-NULL dirty pointer with dirty_count == 0 means no changed areas.
/// For valid nonempty geometry, bgra must contain at least stride * (height - 1) + width * 4
/// readable bytes, and dirty, unless NULL, must contain dirty_count * 4 aligned uint32_t values.
/// Both buffers must remain valid and unmodified until this returns. The changed pixels are
/// copied before returning. Frames with invalid or unrepresentable lengths, or whose size
/// differs from the head's programmed mode, are dropped.
void dll_engine_submit_frame(DLLEngine *engine, uint8_t head, const uint8_t *bgra, size_t stride,
                             uint32_t width, uint32_t height, const uint32_t *dirty,
                             size_t dirty_count);

/// Power a head's monitor down (false) or back up (true), e.g. on display sleep and wake.
void dll_engine_set_display_power(DLLEngine *engine, uint8_t head, bool on);

/// Set a head's gamma transfer table: r, g and b each point to 256 bytes mapping a captured
/// channel value to the value sent to the monitor. All three NULL (or an identity table) clears it.
/// A different table repaints the head's whole picture, even with no new frame.
void dll_engine_set_gamma(DLLEngine *engine, uint8_t head, const uint8_t *r, const uint8_t *g,
                          const uint8_t *b);

/// Set the pointer image the dock draws: BGRA8888 (premultiplied), top row first, tightly packed,
/// at most 64x64. hot_x/hot_y is the hotspot within the image, in image pixels.
void dll_engine_set_cursor(DLLEngine *engine, const uint8_t *bgra, uint32_t width, uint32_t height,
                           int32_t hot_x, int32_t hot_y);

/// Report where the pointer's hotspot is: on `head` at (x, y) in that head's mode pixels, or on
/// none of the dock's heads when head < 0. Cheap; call on every pointer move.
void dll_engine_move_cursor(DLLEngine *engine, int32_t head, int32_t x, int32_t y);

/// Most heads one dll_engine_stats call reports.
#define DLL_MAX_HEADS 4

/// Engine-wide performance counters since the previous dll_engine_stats call.
typedef struct {
    /// Engine loop wakeups that went on to visit the heads.
    uint64_t loop_passes;
    /// Time the engine loop slept because the shared video budget was exhausted.
    uint64_t budget_wait_us;
} DLLEngineStats;

/// One attached head's performance counters since the previous dll_engine_stats call.
/// Times are summed microseconds.
typedef struct {
    uint8_t head;
    /// Frames dll_engine_submit_frame accepted (matching the head's mode), changed or not.
    uint64_t frames_submitted;
    /// Presentations attempted: new frames and owed retransmissions, including ones that sent
    /// nothing. Stage times below except submit_us accumulate over these.
    uint64_t present_calls;
    /// Presentations that put video bytes on the wire.
    uint64_t presents;
    /// Head visits with a new frame or a due retransmission held back by the video budget.
    uint64_t skipped;
    /// Presents whose change was too scattered for exact damage and went as a coarse superset.
    uint64_t coarse_fallbacks;
    /// Video bytes submitted to the dock.
    uint64_t bytes_sent;
    /// dll_engine_submit_frame: hashing and BGRA to RGB conversion, including its lock wait.
    uint64_t submit_us;
    /// Copying changed strips out of the head's mailbox, on every in-budget visit.
    uint64_t take_us;
    /// Selecting the strips to send.
    uint64_t plan_us;
    /// Encoding them.
    uint64_t encode_us;
    /// Building the frame reports and USB transfers.
    uint64_t pack_us;
    /// Submitting the transfers to the video endpoint.
    uint64_t usb_us;
    /// The status poll after each presentation.
    uint64_t poll_us;
} DLLHeadStats;

/// Copy the performance counters accumulated since the previous call, and reset them.
/// engine_stats, unless NULL, receives the engine-wide counters. heads, unless NULL, receives
/// one entry per attached head, at most max_heads of them; returns how many were written.
/// Every head's counters are reset whether or not they fit. Pass DLL_MAX_HEADS to see them all.
size_t dll_engine_stats(DLLEngine *engine, DLLEngineStats *engine_stats, DLLHeadStats *heads,
                        size_t max_heads);

/// Blank every head, release the dock, join the engine thread, and free the engine.
/// No callback runs after this returns. Must not be called from a callback. Before calling,
/// exclude all other calls using this engine, including another stop; never use it afterwards.
void dll_engine_stop(DLLEngine *engine);

#ifdef __cplusplus
}
#endif

#endif
