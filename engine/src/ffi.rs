// SPDX-License-Identifier: GPL-2.0-or-later

//! The C ABI declared in `include/dllite.h`.

use crate::edid::Monitor;
use crate::host::{self, CursorShape, Events, HeadStats, Mode, Shared, State};
use std::ffi::{c_char, c_void, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::thread::JoinHandle;

#[repr(C)]
pub struct DLLMonitor {
    pub head: u8,
    pub width: u32,
    pub height: u32,
    pub refresh_hz: u32,
    pub width_mm: u32,
    pub height_mm: u32,
    pub vendor_id: u16,
    pub product_code: u16,
    pub serial: u32,
    pub name: *const c_char,
    pub edid: *const u8,
    pub edid_len: usize,
    pub hardware_cursor: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct DLLCallbacks {
    pub context: *mut c_void,
    pub monitor_attached: Option<extern "C" fn(*mut c_void, *const DLLMonitor)>,
    pub monitor_detached: Option<extern "C" fn(*mut c_void, u8)>,
    pub state_changed: Option<extern "C" fn(*mut c_void, i32, *const c_char)>,
}

// The host promises in dllite.h that its callbacks may be invoked from the engine thread.
unsafe impl Send for DLLCallbacks {}

impl Events for DLLCallbacks {
    fn attached(&self, head: u8, monitor: &Monitor, mode: Mode, edid: &[u8], hardware_cursor: bool) {
        let Some(callback) = self.monitor_attached else { return };
        let name = c_string(monitor.name.as_deref().unwrap_or("DisplayLink monitor"));
        let vendor_id = monitor
            .manufacturer
            .bytes()
            .fold(0u16, |id, letter| (id << 5) | u16::from(letter.saturating_sub(b'@') & 0x1f));
        let record = DLLMonitor {
            head,
            width: mode.width as u32,
            height: mode.height as u32,
            refresh_hz: mode.refresh_hz,
            width_mm: monitor.width_mm,
            height_mm: monitor.height_mm,
            vendor_id,
            product_code: monitor.product_code,
            serial: monitor.serial,
            name: name.as_ptr(),
            edid: edid.as_ptr(),
            edid_len: edid.len(),
            hardware_cursor,
        };
        callback(self.context, &record);
    }

    fn detached(&self, head: u8) {
        if let Some(callback) = self.monitor_detached {
            callback(self.context, head);
        }
    }

    fn state(&self, state: State, message: &str) {
        if let Some(callback) = self.state_changed {
            let message = c_string(message);
            callback(self.context, state as i32, message.as_ptr());
        }
    }
}

fn c_string(text: &str) -> CString {
    CString::new(text.replace('\0', " ")).expect("NULs removed")
}

pub struct DLLEngine {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

#[no_mangle]
pub extern "C" fn dll_engine_start(callbacks: DLLCallbacks) -> *mut DLLEngine {
    catch_unwind(|| {
        let shared = Shared::new();
        let engine_shared = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("dllite-engine".into())
            .spawn(move || host::run(engine_shared, callbacks))
            .ok()?;
        Some(Box::into_raw(Box::new(DLLEngine { shared, thread: Some(thread) })))
    })
    .ok()
    .flatten()
    .unwrap_or(std::ptr::null_mut())
}

/// Count of u32 elements in the C damage array, bounded by Rust's slice byte-length limit.
fn dirty_len(count: usize) -> Option<usize> {
    let len = count.checked_mul(4)?;
    (len.checked_mul(std::mem::size_of::<u32>())? <= isize::MAX as usize).then_some(len)
}

/// # Safety
/// `engine` must come from `dll_engine_start` and not yet be stopped. For nonempty geometry with
/// representable lengths, `bgra` must point to at least `stride * (height - 1) + width * 4`
/// readable bytes; `dirty`, unless null, to `dirty_count * 4` aligned, readable `u32`s.
/// Neither buffer may be mutated during the call.
#[no_mangle]
pub unsafe extern "C" fn dll_engine_submit_frame(
    engine: *mut DLLEngine,
    head: u8,
    bgra: *const u8,
    stride: usize,
    width: u32,
    height: u32,
    dirty: *const u32,
    dirty_count: usize,
) {
    let (Some(engine), false) = (unsafe { engine.as_ref() }, bgra.is_null()) else { return };
    let Some(len) = host::frame_len(stride, width as usize, height as usize) else { return };
    let dirty_len = if dirty.is_null() {
        0
    } else {
        let Some(len) = dirty_len(dirty_count) else { return };
        len
    };
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let pixels = unsafe { std::slice::from_raw_parts(bgra, len) };
        let full = dirty.is_null().then_some((0, 0, width as usize, height as usize));
        let quads = if dirty.is_null() {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(dirty, dirty_len) }
        };
        let rects = full.into_iter().chain(quads.chunks_exact(4).map(|r| {
            let (x, y) = (r[0] as usize, r[1] as usize);
            (x, y, x.saturating_add(r[2] as usize), y.saturating_add(r[3] as usize))
        }));
        engine.shared.submit_frame(
            usize::from(head),
            pixels,
            stride,
            width as usize,
            height as usize,
            rects,
        )
    }));
}

/// # Safety
/// `engine` must come from `dll_engine_start` and not yet be stopped.
#[no_mangle]
pub unsafe extern "C" fn dll_engine_set_display_power(engine: *mut DLLEngine, head: u8, on: bool) {
    if let Some(engine) = unsafe { engine.as_ref() } {
        let _ = catch_unwind(AssertUnwindSafe(|| engine.shared.set_power(usize::from(head), on)));
    }
}

/// # Safety
/// `engine` must come from `dll_engine_start` and not yet be stopped; `r`, `g` and `b` must
/// each be NULL or point to 256 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn dll_engine_set_gamma(engine: *mut DLLEngine, head: u8, r: *const u8, g: *const u8, b: *const u8) {
    let Some(engine) = (unsafe { engine.as_ref() }) else { return };
    let lut = if r.is_null() || g.is_null() || b.is_null() {
        None
    } else {
        let read = |p: *const u8| unsafe { *p.cast::<[u8; 256]>() };
        Some([read(r), read(g), read(b)])
    };
    let _ = catch_unwind(AssertUnwindSafe(|| engine.shared.set_gamma(usize::from(head), lut)));
}

/// Largest pointer image the dock's hardware cursor takes.
const CURSOR_MAX: u32 = 64;

/// # Safety
/// `engine` must come from `dll_engine_start` and not yet be stopped; `bgra` must point to
/// `width * height * 4` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn dll_engine_set_cursor(
    engine: *mut DLLEngine,
    bgra: *const u8,
    width: u32,
    height: u32,
    hot_x: i32,
    hot_y: i32,
) {
    let (Some(engine), false) = (unsafe { engine.as_ref() }, bgra.is_null()) else { return };
    if width == 0 || height == 0 || width > CURSOR_MAX || height > CURSOR_MAX {
        return;
    }
    let pixels = unsafe { std::slice::from_raw_parts(bgra, (width * height * 4) as usize) }.to_vec();
    let _ = catch_unwind(AssertUnwindSafe(|| {
        engine.shared.set_cursor_shape(CursorShape { bgra: pixels, width, height, hot_x, hot_y })
    }));
}

/// # Safety
/// `engine` must come from `dll_engine_start` and not yet be stopped.
#[no_mangle]
pub unsafe extern "C" fn dll_engine_move_cursor(engine: *mut DLLEngine, head: i32, x: i32, y: i32) {
    if let Some(engine) = unsafe { engine.as_ref() } {
        let position = u8::try_from(head).ok().map(|head| (head, x, y));
        let _ = catch_unwind(AssertUnwindSafe(|| engine.shared.move_cursor(position)));
    }
}

/// Heads a `dll_engine_stats` call can report; `DLL_MAX_HEADS` in dllite.h.
const MAX_HEADS: usize = 4;
const _: () = assert!(MAX_HEADS == vino_chimera::MAX_CONNECTORS);

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DLLEngineStats {
    pub loop_passes: u64,
    pub budget_wait_us: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DLLHeadStats {
    pub head: u8,
    pub frames_submitted: u64,
    pub present_calls: u64,
    pub presents: u64,
    pub skipped: u64,
    pub coarse_fallbacks: u64,
    pub bytes_sent: u64,
    pub submit_us: u64,
    pub take_us: u64,
    pub plan_us: u64,
    pub encode_us: u64,
    pub pack_us: u64,
    pub usb_us: u64,
    pub poll_us: u64,
}

impl DLLHeadStats {
    fn new(head: u8, stats: HeadStats) -> Self {
        Self {
            head,
            frames_submitted: stats.frames_submitted,
            present_calls: stats.present_calls,
            presents: stats.presents,
            skipped: stats.skipped,
            coarse_fallbacks: stats.coarse_fallbacks,
            bytes_sent: stats.bytes_sent,
            submit_us: stats.submit_us,
            take_us: stats.take_us,
            plan_us: stats.plan_us,
            encode_us: stats.encode_us,
            pack_us: stats.pack_us,
            usb_us: stats.usb_us,
            poll_us: stats.poll_us,
        }
    }
}

/// # Safety
/// `engine` must come from `dll_engine_start` and not yet be stopped. `engine_stats`, unless
/// null, must point to a writable `DLLEngineStats`; `heads`, unless null, to `max_heads`
/// writable `DLLHeadStats`.
#[no_mangle]
pub unsafe extern "C" fn dll_engine_stats(
    engine: *mut DLLEngine,
    engine_stats: *mut DLLEngineStats,
    heads: *mut DLLHeadStats,
    max_heads: usize,
) -> usize {
    let Some(engine) = (unsafe { engine.as_ref() }) else { return 0 };
    let Ok(stats) = catch_unwind(AssertUnwindSafe(|| engine.shared.take_stats())) else { return 0 };
    if let Some(out) = unsafe { engine_stats.as_mut() } {
        *out = DLLEngineStats { loop_passes: stats.loop_passes, budget_wait_us: stats.budget_wait_us };
    }
    if heads.is_null() {
        return 0;
    }
    let attached = stats.heads.iter().enumerate().filter_map(|(head, stats)| {
        stats.map(|stats| DLLHeadStats::new(head as u8, stats))
    });
    let mut count = 0;
    for entry in attached.take(max_heads) {
        unsafe { heads.add(count).write(entry) };
        count += 1;
    }
    count
}

/// # Safety
/// `engine` must come from `dll_engine_start`; it is freed and must not be used afterwards.
/// The caller must exclude concurrent calls using this engine, and must not stop from a callback
/// (which runs on the thread this function joins).
#[no_mangle]
pub unsafe extern "C" fn dll_engine_stop(engine: *mut DLLEngine) {
    if engine.is_null() {
        return;
    }
    let mut engine = unsafe { Box::from_raw(engine) };
    engine.shared.request_stop();
    if let Some(thread) = engine.thread.take() {
        let _ = thread.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirty_lengths_fit_rust_slices_in_bytes_not_elements() {
        assert_eq!(dirty_len(0), Some(0));
        assert_eq!(dirty_len(2), Some(8));
        let max = isize::MAX as usize / (4 * std::mem::size_of::<u32>());
        assert_eq!(dirty_len(max), Some(max * 4));
        assert_eq!(dirty_len(max + 1), None);
        assert_eq!(dirty_len(usize::MAX / 4 + 1), None);
        assert_eq!(dirty_len(usize::MAX), None);
    }

    #[test]
    fn invalid_frame_lengths_return_before_constructing_slices() {
        // No engine thread or USB session is needed to exercise the public boundary.
        let mut engine = DLLEngine { shared: Shared::new(), thread: None };
        let bgra = [0u8; 4];
        let dirty = [0u32; 4];
        unsafe {
            // Arithmetic overflow, then a representable span above isize::MAX.
            dll_engine_submit_frame(&mut engine, 0, bgra.as_ptr(), usize::MAX, 1, 3, std::ptr::null(), 0);
            dll_engine_submit_frame(&mut engine, 0, bgra.as_ptr(), isize::MAX as usize, 1, 2, std::ptr::null(), 0);
            // An invalid damage count must be rejected before either buffer is interpreted.
            dll_engine_submit_frame(&mut engine, 0, bgra.as_ptr(), 4, 1, 1, dirty.as_ptr(), usize::MAX);
            dll_engine_submit_frame(
                &mut engine, 0, bgra.as_ptr(), 4, 1, 1, dirty.as_ptr(),
                isize::MAX as usize / (4 * std::mem::size_of::<u32>()) + 1,
            );
        }
        // Rejected input must not poison engine state for later control calls.
        unsafe { dll_engine_set_display_power(&mut engine, 0, true) };
        assert!(!engine.shared.stopping());
    }

    #[test]
    fn stats_report_only_attached_heads_and_tolerate_null_outputs() {
        let mut engine = DLLEngine { shared: Shared::new(), thread: None };
        let mut totals = DLLEngineStats { loop_passes: 9, budget_wait_us: 9 };
        let mut heads = [DLLHeadStats { head: 7, ..Default::default() }; MAX_HEADS];
        let count = unsafe { dll_engine_stats(&mut engine, &mut totals, heads.as_mut_ptr(), heads.len()) };
        assert_eq!(count, 0);
        assert_eq!(totals, DLLEngineStats::default());
        assert_eq!(heads[0].head, 7);
        unsafe {
            assert_eq!(dll_engine_stats(&mut engine, std::ptr::null_mut(), std::ptr::null_mut(), 4), 0);
            assert_eq!(dll_engine_stats(std::ptr::null_mut(), &mut totals, heads.as_mut_ptr(), 4), 0);
        }
    }
}
