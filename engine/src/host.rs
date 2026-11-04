// SPDX-License-Identifier: GPL-2.0-or-later

//! The engine thread: engage the dock, light what is plugged into it, and forward frames the
//! display host hands over. Follows the vendored chimera daemon's session loop, with the Linux
//! virtual-display card replaced by per-head mailboxes the macOS host fills.

use crate::edid::{self, Monitor};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use vino_chimera::kvino::DockProfile;
use vino_chimera::session::ControlSession;
use vino_chimera::MAX_CONNECTORS;

const HEARTBEAT_PERIOD: Duration = Duration::from_secs(3);
const PRESENCE_PERIOD: Duration = Duration::from_secs(1);
/// Presence probes sent, one per [`PRESENCE_PERIOD`], after a dock pushes a downstream change.
/// Three covers the two consecutive negatives a removal needs plus one for the change itself.
const PRESENCE_BURST: u8 = 3;
/// How often sockets with nothing attached are probed while another head is lit.
const EMPTY_SOCKET_PERIOD: Duration = Duration::from_secs(2);
const PRESENCE_GRACE: Duration = Duration::from_secs(10);
const PRESENCE_SILENT_LIMIT: u8 = 3;
const SEARCH_PERIOD: Duration = Duration::from_secs(2);
const RESTART_DELAY: Duration = Duration::from_secs(1);
/// How long a head's surface must be still before its recently changed strips are re-sent to
/// every dock buffer.
const SETTLE_DELAY: Duration = Duration::from_millis(100);

/// Sustained video rate the dock is fed, for all heads together. Vino measured DLM on this dock
/// family at 120 MB/s over one second and 99 MB/s over five. With no limit, full-screen motion
/// (App Exposé on two 4K screens) reset an M/Connect 2 off the USB bus within minutes.
const VIDEO_BYTES_PER_SEC: f64 = 100_000_000.0;
/// Burst the budget may bank: one 4K keyframe presented to both of a Ridge dock's buffers.
const VIDEO_BURST_BYTES: f64 = 8_000_000.0;

/// Token bucket over video bytes. A frame goes out only while the bucket is positive; its size is
/// then charged, so one large frame can take it negative and hold later frames back until the
/// rate has paid for it. Held-back frames wait in their mailbox, where a newer one replaces them.
struct VideoBudget {
    tokens: f64,
    refilled: Instant,
}

impl VideoBudget {
    fn new() -> Self {
        Self { tokens: VIDEO_BURST_BYTES, refilled: Instant::now() }
    }

    fn refill(&mut self, now: Instant) {
        let earned = now.saturating_duration_since(self.refilled).as_secs_f64() * VIDEO_BYTES_PER_SEC;
        self.tokens = (self.tokens + earned).min(VIDEO_BURST_BYTES);
        self.refilled = now;
    }

    fn available(&mut self) -> bool {
        self.refill(Instant::now());
        self.tokens > 0.0
    }

    fn spend(&mut self, bytes: usize) {
        self.tokens -= bytes as f64;
    }

    /// How long to sleep: no longer than `frame_wait`, and no longer than it takes the bucket to
    /// come back above zero.
    fn wait_hint(&mut self, frame_wait: Duration) -> Duration {
        self.refill(Instant::now());
        if self.tokens > 0.0 {
            return frame_wait;
        }
        Duration::from_secs_f64(-self.tokens / VIDEO_BYTES_PER_SEC + 0.000_5).min(frame_wait)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Searching = 0,
    Engaged = 1,
    Retrying = 2,
}

/// What the engine tells the display host. Implemented over the C callbacks in `ffi`.
pub trait Events: Send + 'static {
    /// `hardware_cursor`: the dock draws the pointer itself, so the host must leave it out of the
    /// frames and report it through `set_cursor_shape` / `move_cursor` instead.
    fn attached(&self, head: u8, monitor: &Monitor, mode: Mode, edid: &[u8], hardware_cursor: bool);
    fn detached(&self, head: u8);
    fn state(&self, state: State, message: &str);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mode {
    pub width: usize,
    pub height: usize,
    pub refresh_hz: u32,
}

/// Geometry a head accepts frames at: the programmed mode, and that mode rounded up to whole
/// codec strips, which is the raster the dock is sent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Accepting {
    width: usize,
    height: usize,
    padded_width: usize,
    padded_height: usize,
}

/// A half-open `(x0, y0, x1, y1)` pixel rectangle of a head's surface.
pub type Rect = (usize, usize, usize, usize);

/// Past this many separate changed areas the whole surface is treated as changed.
const MAX_DIRTY_RECTS: usize = 64;

#[derive(Default)]
struct Mailbox {
    accepting: Option<Accepting>,
    /// Latest captured surface, packed RGB888 at the padded size. Capture rewrites only the areas
    /// that changed, so a ticking clock costs a few kilobytes rather than a 4K conversion.
    surface: Vec<u8>,
    /// Areas changed since the engine last took the surface; `None` means all of it.
    dirty: Option<Vec<Rect>>,
    /// Whether the surface changed since the engine last took it.
    fresh: bool,
    /// Latest display-power request not yet acted on.
    power: Option<bool>,
}

/// A pointer image for the dock's hardware cursor: BGRA, top row first, tightly packed.
pub struct CursorShape {
    pub bgra: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub hot_x: i32,
    pub hot_y: i32,
}

/// Latest pointer state from the host. Generations let the engine apply only what changed.
#[derive(Default)]
struct CursorBox {
    shape: Option<Arc<CursorShape>>,
    shape_gen: u64,
    /// Head under the pointer and the hotspot's position on it, in the head's mode pixels.
    position: Option<(u8, i32, i32)>,
    position_gen: u64,
}

pub struct Shared {
    stop: AtomicBool,
    mailboxes: [Mutex<Mailbox>; MAX_CONNECTORS],
    cursor: Mutex<CursorBox>,
    /// Signalled whenever a mailbox or the cursor changes, or stop is requested.
    signal: Mutex<u64>,
    wake: Condvar,
}

impl Shared {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            stop: AtomicBool::new(false),
            mailboxes: core::array::from_fn(|_| Mutex::new(Mailbox::default())),
            cursor: Mutex::new(CursorBox::default()),
            signal: Mutex::new(0),
            wake: Condvar::new(),
        })
    }

    fn notify(&self) {
        *self.signal.lock().unwrap() += 1;
        self.wake.notify_all();
    }

    /// Wait until notified or `timeout` passes.
    fn wait(&self, seen: &mut u64, timeout: Duration) {
        let guard = self.signal.lock().unwrap();
        let (guard, _) = self
            .wake
            .wait_timeout_while(guard, timeout, |count| *count == *seen && !self.stopping())
            .unwrap();
        *seen = *guard;
    }

    pub fn stopping(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.notify();
    }

    /// Accept one BGRA frame from the host, of which only `dirty` changed (`None`: all of it).
    /// Dropped unless it matches the head's programmed mode.
    pub fn submit_frame(
        &self,
        head: usize,
        bgra: &[u8],
        stride: usize,
        width: usize,
        height: usize,
        dirty: Option<&[Rect]>,
    ) {
        let Some(slot) = self.mailboxes.get(head) else {
            return;
        };
        let mut mailbox = slot.lock().unwrap();
        let Some(accepting) = mailbox.accepting else {
            return;
        };
        let row_bytes = width * 4;
        if (accepting.width, accepting.height) != (width, height)
            || stride < row_bytes
            || height == 0
            || bgra.len() < stride * (height - 1) + row_bytes
        {
            return;
        }
        let size = accepting.padded_width * 3 * accepting.padded_height;
        let mut dirty = dirty;
        if mailbox.surface.len() != size {
            mailbox.surface = vec![0; size];
            dirty = None;
        }
        let areas: Vec<Rect> = match dirty {
            None => vec![(0, 0, width, height)],
            Some(rects) => rects
                .iter()
                .map(|&(x0, y0, x1, y1)| (x0, y0, x1.min(width), y1.min(height)))
                .filter(|&(x0, y0, x1, y1)| x0 < x1 && y0 < y1)
                .collect(),
        };
        if areas.is_empty() {
            return;
        }
        for &area in &areas {
            bgra_area_to_rgb(bgra, stride, accepting.padded_width, area, &mut mailbox.surface);
        }
        let changed = dirty.map(|_| areas);
        mailbox.dirty = if !mailbox.fresh {
            changed
        } else {
            match (mailbox.dirty.take(), changed) {
                (Some(mut known), Some(more)) => {
                    known.extend(more);
                    (known.len() <= MAX_DIRTY_RECTS).then_some(known)
                }
                _ => None,
            }
        };
        mailbox.fresh = true;
        drop(mailbox);
        self.notify();
    }

    pub fn set_power(&self, head: usize, on: bool) {
        if let Some(slot) = self.mailboxes.get(head) {
            slot.lock().unwrap().power = Some(on);
            self.notify();
        }
    }

    fn open(&self, head: usize, accepting: Accepting) {
        let mut mailbox = self.mailboxes[head].lock().unwrap();
        *mailbox = Mailbox { accepting: Some(accepting), ..Mailbox::default() };
    }

    fn close(&self, head: usize) {
        *self.mailboxes[head].lock().unwrap() = Mailbox::default();
    }

    /// Bring `shadow` up to the head's latest surface if it changed, returning what changed
    /// (`Some(None)`: all of it). Copies only the changed areas.
    fn take_frame(&self, head: usize, shadow: &mut Vec<u8>) -> Option<Option<Vec<Rect>>> {
        let mut mailbox = self.mailboxes[head].lock().unwrap();
        if !mailbox.fresh {
            return None;
        }
        mailbox.fresh = false;
        let dirty = mailbox.dirty.take();
        let accepting = mailbox.accepting?;
        match &dirty {
            Some(rects) if shadow.len() == mailbox.surface.len() => {
                let row = accepting.padded_width * 3;
                for &(x0, y0, x1, y1) in rects {
                    for y in y0..y1 {
                        let span = y * row + x0 * 3..y * row + x1 * 3;
                        shadow[span.clone()].copy_from_slice(&mailbox.surface[span]);
                    }
                }
                Some(dirty)
            }
            _ => {
                shadow.clear();
                shadow.extend_from_slice(&mailbox.surface);
                Some(None)
            }
        }
    }

    fn take_power(&self, head: usize) -> Option<bool> {
        self.mailboxes[head].lock().unwrap().power.take()
    }

    pub fn set_cursor_shape(&self, shape: CursorShape) {
        let mut cursor = self.cursor.lock().unwrap();
        cursor.shape = Some(Arc::new(shape));
        cursor.shape_gen += 1;
        drop(cursor);
        self.notify();
    }

    /// `None` when the pointer is on none of the dock's heads.
    pub fn move_cursor(&self, position: Option<(u8, i32, i32)>) {
        let mut cursor = self.cursor.lock().unwrap();
        if cursor.position == position {
            return;
        }
        cursor.position = position;
        cursor.position_gen += 1;
        drop(cursor);
        self.notify();
    }
}

/// Convert one area of a BGRA8888 frame into the packed RGB888 surface (`padded_width` wide).
/// Large areas are split across cores by rows. The caller has checked the source geometry.
fn bgra_area_to_rgb(bgra: &[u8], stride: usize, padded_width: usize, area: Rect, surface: &mut [u8]) {
    let (x0, y0, x1, y1) = area;
    let row = padded_width * 3;
    let convert = |y: usize, target: &mut [u8]| {
        let source = &bgra[y * stride + x0 * 4..y * stride + x1 * 4];
        for (rgb, px) in target[x0 * 3..x1 * 3].chunks_exact_mut(3).zip(source.chunks_exact(4)) {
            rgb[0] = px[2];
            rgb[1] = px[1];
            rgb[2] = px[0];
        }
    };
    let rows = &mut surface[y0 * row..y1 * row];
    let workers = std::thread::available_parallelism().map_or(1, |n| n.get());
    if workers < 2 || (x1 - x0) * (y1 - y0) < 512 * 512 {
        for (i, target) in rows.chunks_exact_mut(row).enumerate() {
            convert(y0 + i, target);
        }
        return;
    }
    let band = (y1 - y0).div_ceil(workers);
    std::thread::scope(|scope| {
        for (b, chunk) in rows.chunks_mut(band * row).enumerate() {
            let convert = &convert;
            scope.spawn(move || {
                for (i, target) in chunk.chunks_exact_mut(row).enumerate() {
                    convert(y0 + b * band + i, target);
                }
            });
        }
    });
}

fn padded(profile: DockProfile, width: usize, height: usize) -> (usize, usize) {
    let (strip_w, strip_h) = profile.strip_dims();
    (width.div_ceil(strip_w) * strip_w, height.div_ceil(strip_h) * strip_h)
}

struct Output {
    mode: Mode,
    lit: bool,
    padded_width: usize,
    padded_height: usize,
    /// The surface last handed to the codec. Updated in place from the mailbox's changed areas.
    shadow: Vec<u8>,
    /// The EDID this head was lit with, used to reject the other socket's monitor echoed back
    /// by a shared EDID handler.
    edid: Vec<u8>,
    presence_debounce: u8,
    silent_probes: u8,
    presence_grace_until: Instant,
    /// Generation of the cursor shape this head's dock cursor holds; 0 for none.
    cursor_shape_gen: u64,
    /// Whether the dock is currently showing the pointer on this head.
    cursor_visible: bool,
    /// When the last new frame was presented.
    last_change: Instant,
    /// Whether the settle pass has run since the last new frame.
    settled: bool,
    /// Earliest time an owed retransmission of the last frame may go out.
    next_repaint: Instant,
}

/// The engine thread body. Returns when stop is requested.
pub fn run(shared: Arc<Shared>, events: impl Events) {
    let mut failed_before = false;
    while !shared.stopping() {
        let engaged = std::panic::catch_unwind(std::panic::AssertUnwindSafe(ControlSession::engage))
            .unwrap_or_else(|_| Err("dock engage panicked".into()));
        let session = match engaged {
            Ok(session) => session,
            Err(error) => {
                let state = if failed_before { State::Retrying } else { State::Searching };
                events.state(state, &searching_message(&error));
                sleep_unless_stopped(&shared, SEARCH_PERIOD);
                continue;
            }
        };
        failed_before = false;
        let mut outputs: [Option<Output>; MAX_CONNECTORS] = core::array::from_fn(|_| None);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_session(&shared, &events, session, &mut outputs)
        }))
        .unwrap_or_else(|_| Err("engine panicked".into()));
        for (head, output) in outputs.iter_mut().enumerate() {
            if output.take().is_some() {
                shared.close(head);
                events.detached(head as u8);
            }
        }
        if let Err(error) = result {
            failed_before = true;
            events.state(State::Retrying, &format!("Dock session stopped: {error}. Reconnecting…"));
            sleep_unless_stopped(&shared, RESTART_DELAY);
        }
    }
}

fn searching_message(error: &str) -> String {
    if error.contains("Access") || error.contains("Busy") {
        format!("Dock is in use by another app (quit DisplayLink Manager): {error}")
    } else if error.contains("NoDevice") || error.contains("no DisplayLink") || error.contains("not found") {
        "Looking for the DisplayLink dock…".to_string()
    } else {
        format!("Cannot open the dock: {error}")
    }
}

fn sleep_unless_stopped(shared: &Shared, period: Duration) {
    let mut seen = *shared.signal.lock().unwrap();
    let deadline = Instant::now() + period;
    while !shared.stopping() {
        let now = Instant::now();
        if now >= deadline {
            return;
        }
        shared.wait(&mut seen, deadline - now);
    }
}

fn run_session(
    shared: &Shared,
    events: &impl Events,
    mut session: ControlSession,
    outputs: &mut [Option<Output>; MAX_CONNECTORS],
) -> Result<(), String> {
    let profile = session.profile();
    events.state(State::Engaged, "Dock connected. Looking for monitors…");

    // Discovery as the chimera daemon does it: a dock with one EDID handler shared between its
    // heads answers a blind fetch on an empty socket with the other head's monitor, so there the
    // presence probe gates the fetch.
    let discover_by_edid = !profile.shared_edid_handler();
    let reports_presence = profile.reports_presence();
    let mut found = 0;
    for head in 0..session.connectors() as u8 {
        if (discover_by_edid || !reports_presence || session.probe_head_present(head)? == Some(true))
            && attach(shared, events, &mut session, outputs, head, Discovery::Gated)?
        {
            found += 1;
        }
    }
    // A cold Ridge dock can report an occupied socket empty until its EDID handler has been
    // engaged for it (docs/ridge.md in the Vino tree). With nothing found, read each socket once,
    // keeping an EDID only if that socket then probes present.
    if found == 0 && !discover_by_edid && reports_presence {
        for head in 0..session.connectors() as u8 {
            if attach(shared, events, &mut session, outputs, head, Discovery::Blind)? {
                found += 1;
            }
        }
    }
    report_monitors(events, found);

    let frame_wait = Duration::from_millis(profile.frame_period_ms().max(1) as u64);
    let keepalive_period = Duration::from_millis(profile.status_period_ms().max(1) as u64);
    let mut next_keepalive = Instant::now() + keepalive_period;
    let mut next_heartbeat = Instant::now() + HEARTBEAT_PERIOD;
    // A dock with one EDID handler shared between its heads loses a lit connector's link to a
    // timed presence probe: measured on the M/Connect 2, probing both heads once a second kept
    // both monitors in standby, and they lit as soon as it stopped. DLM probes such a dock only
    // after it pushes its downstream-change notice, so this does the same, with a short burst so
    // a removal can still be confirmed twice before the head is dropped.
    let timed_presence = reports_presence && !profile.shared_edid_handler();
    let mut burst_probes_left = 0u8;
    let mut next_presence = Instant::now() + PRESENCE_PERIOD;
    let mut next_empty_scan = Instant::now() + EMPTY_SOCKET_PERIOD;
    let mut seen = *shared.signal.lock().unwrap();
    let mut budget = VideoBudget::new();
    let mut first_head = 0usize;
    let mut cursor_position_applied = 0u64;

    while !shared.stopping() {
        // With nothing owed on any head, sleep until new input or the next housekeeping deadline
        // instead of ticking every frame period: an idle desktop then costs a few wakeups a second.
        let busy = outputs.iter().enumerate().any(|(head, output)| {
            output.as_ref().is_some_and(|output| {
                output.lit && (!output.settled || session.owes_repaint(head as u8))
            })
        });
        let wait = if busy {
            budget.wait_hint(frame_wait)
        } else {
            let now = Instant::now();
            // Only deadlines that will actually be acted on: a stale presence deadline for a dock
            // that is not being probed would otherwise wake this loop every millisecond.
            let nothing_lit = !outputs.iter().flatten().any(|output| output.lit);
            let presence_active = timed_presence || nothing_lit || burst_probes_left > 0;
            [
                Some(next_keepalive),
                Some(next_heartbeat),
                presence_active.then_some(next_presence),
                reports_presence.then_some(next_empty_scan),
            ]
            .into_iter()
            .flatten()
            .min()
            .map_or(frame_wait, |due| due.saturating_duration_since(now))
            .max(Duration::from_millis(1))
        };
        shared.wait(&mut seen, wait);
        if profile.hw_cursor() {
            sync_cursor(shared, &mut session, outputs, &mut cursor_position_applied)?;
        }
        // Start from a different head each pass so one busy screen cannot starve the other of the
        // shared budget.
        first_head = (first_head + 1) % MAX_CONNECTORS;
        for head in (0..MAX_CONNECTORS).map(|i| (first_head + i) % MAX_CONNECTORS) {
            let Some(output) = outputs[head].as_mut() else { continue };
            if let Some(on) = shared.take_power(head) {
                set_power(&mut session, output, head as u8, on)?;
            }
            if !output.lit || !budget.available() {
                continue;
            }
            let now = Instant::now();
            if let Some(dirty) = shared.take_frame(head, &mut output.shadow) {
                let sent = session.present_rgb_dirty(
                    head as u8,
                    output.padded_width,
                    output.padded_height,
                    &output.shadow,
                    dirty.as_deref(),
                )?;
                budget.spend(sent);
                output.last_change = now;
                output.settled = false;
                output.next_repaint = now + refresh_period(output.mode);
                continue;
            }
            // Once the surface has been still for a moment, send everything that moved since the
            // last settle to every dock buffer again (local patch in vendor/vino/UPSTREAM.md).
            if !output.settled && now.duration_since(output.last_change) >= SETTLE_DELAY {
                session.settle(head as u8);
                output.settled = true;
            }
            // Owed retransmissions go out one refresh apart, so each lands in a different dock
            // buffer however the dock times its buffer swaps.
            if now >= output.next_repaint && session.owes_repaint(head as u8) {
                if !output.shadow.is_empty() {
                    // Nothing new since the last present, so no strip needs re-hashing.
                    let sent = session.present_rgb_dirty(
                        head as u8,
                        output.padded_width,
                        output.padded_height,
                        &output.shadow,
                        Some(&[]),
                    )?;
                    budget.spend(sent);
                    output.next_repaint = now + refresh_period(output.mode);
                }
            }
        }
        if reports_presence && !timed_presence && session.take_downstream_change() {
            burst_probes_left = PRESENCE_BURST;
            next_presence = Instant::now();
        }
        let now = Instant::now();
        // With no head lit there is no link for a probe to disturb, and a dock that has just come
        // back (unplugged, power-cycled) may not announce monitors that wake after it, so poll.
        let nothing_lit = !outputs.iter().flatten().any(|output| output.lit);
        if (timed_presence || nothing_lit || burst_probes_left > 0) && now >= next_presence {
            refresh_topology(shared, events, &mut session, outputs)?;
            burst_probes_left = burst_probes_left.saturating_sub(1);
            next_presence = Instant::now() + PRESENCE_PERIOD;
        } else if reports_presence && now >= next_empty_scan {
            // Measured on the M/Connect 2: a monitor switched on beside a lit one is not announced,
            // so empty sockets are probed slowly. Lit sockets are never probed here.
            for head in 0..session.connectors() {
                if outputs[head].is_none() && session.probe_head_present(head as u8)? == Some(true) {
                    attach(shared, events, &mut session, outputs, head as u8, Discovery::Gated)?;
                    report_monitors(events, outputs.iter().flatten().count());
                }
            }
            next_empty_scan = Instant::now() + EMPTY_SOCKET_PERIOD;
        }
        if now >= next_keepalive {
            session.keepalive_poll()?;
            next_keepalive = Instant::now() + keepalive_period;
        }
        if now >= next_heartbeat {
            session.heartbeat()?;
            next_heartbeat = Instant::now() + HEARTBEAT_PERIOD;
        }
    }

    // Orderly shutdown: blank and power down every lit head so the monitors sleep instead of
    // freezing on the last frame, then drop the session to release the dock.
    for (head, slot) in outputs.iter_mut().enumerate() {
        if let Some(output) = slot.as_mut().filter(|output| output.lit) {
            session.deactivate_mode(head as u8, output.mode.width, output.mode.height)?;
            output.lit = false;
        }
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Discovery {
    /// The presence probe said the socket is occupied.
    Gated,
    /// Read without a positive probe; the result must be confirmed before it is published.
    Blind,
}

fn report_monitors(events: &impl Events, count: usize) {
    let message = match count {
        0 => "Dock connected. No monitors detected on its DisplayPort outputs.".to_string(),
        1 => "Dock connected: 1 monitor".to_string(),
        n => format!("Dock connected: {n} monitors"),
    };
    events.state(State::Engaged, &message);
}

/// Fetch a head's EDID, program its preferred mode, and tell the host it is ready.
/// Returns whether the head was lit. A monitor that cannot be read or programmed is reported and
/// skipped, not fatal.
fn attach(
    shared: &Shared,
    events: &impl Events,
    session: &mut ControlSession,
    outputs: &mut [Option<Output>; MAX_CONNECTORS],
    head: u8,
    discovery: Discovery,
) -> Result<bool, String> {
    let report = |message: String| {
        if discovery == Discovery::Gated {
            events.state(State::Engaged, &message);
        }
    };
    let edid_bytes = match session.fetch_edid(head) {
        Ok(bytes) => bytes,
        Err(error) => {
            report(format!("Connector {}: cannot read the monitor ({error})", head + 1));
            return Ok(false);
        }
    };
    // The dock's shared EDID handler can answer for the other socket's monitor.
    if outputs.iter().flatten().any(|output| output.edid == edid_bytes) {
        return Ok(false);
    }
    if discovery == Discovery::Blind && session.probe_head_present(head)? != Some(true) {
        return Ok(false);
    }
    let monitor = match edid::parse(&edid_bytes) {
        Ok(monitor) => monitor,
        Err(error) => {
            report(format!("Connector {}: unusable EDID ({error})", head + 1));
            return Ok(false);
        }
    };
    let mode = Mode {
        width: monitor.preferred.width as usize,
        height: monitor.preferred.height as usize,
        refresh_hz: monitor.preferred.refresh_hz,
    };
    if !session.activate_mode(head, mode.width, mode.height, mode.refresh_hz)? {
        // Only a dock that reconfigures whole declines a single connector; program them together.
        let mut requests: Vec<(u8, usize, usize, u32)> = (0u8..)
            .zip(outputs.iter())
            .filter_map(|(other, output)| {
                output.as_ref().map(|o| (other, o.mode.width, o.mode.height, o.mode.refresh_hz))
            })
            .collect();
        requests.push((head, mode.width, mode.height, mode.refresh_hz));
        session.activate_modes(&requests)?;
    }
    let (padded_width, padded_height) = padded(session.profile(), mode.width, mode.height);
    shared.open(
        usize::from(head),
        Accepting { width: mode.width, height: mode.height, padded_width, padded_height },
    );
    events.attached(head, &monitor, mode, &edid_bytes, session.profile().hw_cursor());
    outputs[usize::from(head)] = Some(Output {
        mode,
        lit: true,
        padded_width,
        padded_height,
        shadow: Vec::new(),
        edid: edid_bytes,
        presence_debounce: 0,
        silent_probes: 0,
        presence_grace_until: Instant::now() + PRESENCE_GRACE,
        cursor_shape_gen: 0,
        cursor_visible: false,
        last_change: Instant::now(),
        settled: true,
        next_repaint: Instant::now(),
    });
    Ok(true)
}

/// One refresh period of `mode`.
fn refresh_period(mode: Mode) -> Duration {
    Duration::from_secs(1) / mode.refresh_hz.max(1)
}

/// Bring every lit head's dock cursor up to the host's latest pointer shape and position.
fn sync_cursor(
    shared: &Shared,
    session: &mut ControlSession,
    outputs: &mut [Option<Output>; MAX_CONNECTORS],
    position_applied: &mut u64,
) -> Result<(), String> {
    let (shape, shape_gen, position, position_gen) = {
        let cursor = shared.cursor.lock().unwrap();
        (cursor.shape.clone(), cursor.shape_gen, cursor.position, cursor.position_gen)
    };
    let Some(shape) = shape else { return Ok(()) };
    let mut reposition = position_gen != *position_applied;
    for (head, slot) in outputs.iter_mut().enumerate() {
        let Some(output) = slot.as_mut().filter(|output| output.lit) else { continue };
        if output.cursor_shape_gen != shape_gen {
            session.set_cursor(head as u8, shape.width, shape.height, &shape.bgra)?;
            output.cursor_shape_gen = shape_gen;
            // A fresh image is shown wherever the dock last had the pointer; place it again.
            output.cursor_visible = true;
            reposition = true;
        }
    }
    if !reposition {
        return Ok(());
    }
    for (head, slot) in outputs.iter_mut().enumerate() {
        let Some(output) = slot.as_mut().filter(|output| output.lit) else { continue };
        match position {
            Some((on, x, y)) if usize::from(on) == head => {
                session.move_cursor(head as u8, x - shape.hot_x, y - shape.hot_y)?;
                output.cursor_visible = true;
            }
            _ if output.cursor_visible => {
                session.hide_cursor(head as u8)?;
                output.cursor_visible = false;
            }
            _ => {}
        }
    }
    *position_applied = position_gen;
    Ok(())
}

fn set_power(session: &mut ControlSession, output: &mut Output, head: u8, on: bool) -> Result<(), String> {
    match (on, output.lit) {
        (false, true) => {
            session.deactivate_mode(head, output.mode.width, output.mode.height)?;
            output.lit = false;
            // Presence can read negative while a sink is powered down; give it time on wake.
            output.presence_grace_until = Instant::now() + PRESENCE_GRACE;
        }
        (true, false) => {
            let mode = output.mode;
            output.lit = session.activate_mode(head, mode.width, mode.height, mode.refresh_hz)?;
            output.presence_grace_until = Instant::now() + PRESENCE_GRACE;
        }
        _ => {}
    }
    Ok(())
}

fn refresh_topology(
    shared: &Shared,
    events: &impl Events,
    session: &mut ControlSession,
    outputs: &mut [Option<Output>; MAX_CONNECTORS],
) -> Result<(), String> {
    let before = outputs.iter().flatten().count();
    for head in 0..session.connectors() {
        // A deliberately powered-down head can look removed; leave it alone until it is woken.
        if outputs[head].as_ref().is_some_and(|output| !output.lit) {
            continue;
        }
        let present = session.probe_head_present(head as u8)?;
        let Some(output) = outputs[head].as_mut() else {
            if present == Some(true) {
                attach(shared, events, session, outputs, head as u8, Discovery::Gated)?;
            }
            continue;
        };
        let present = match present {
            Some(present) => {
                output.silent_probes = 0;
                present
            }
            None => {
                output.silent_probes = output.silent_probes.saturating_add(1);
                if output.silent_probes < PRESENCE_SILENT_LIMIT {
                    continue;
                }
                false
            }
        };
        if present || Instant::now() < output.presence_grace_until {
            output.presence_debounce = 0;
            continue;
        }
        output.presence_debounce = output.presence_debounce.saturating_add(1);
        if output.presence_debounce >= 2 {
            outputs[head] = None;
            shared.close(head);
            events.detached(head as u8);
        }
    }
    let after = outputs.iter().flatten().count();
    if after != before {
        report_monitors(events, after);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn accepting(width: usize, height: usize, padded_width: usize, padded_height: usize) -> Accepting {
        Accepting { width, height, padded_width, padded_height }
    }

    #[test]
    fn converts_bgra_with_stride_into_a_black_padded_surface() {
        let shared = Shared::new();
        shared.open(0, accepting(2, 2, 3, 3));
        // 2x2 source with a 12-byte stride (one pad pixel per row), padded to 3x3.
        let bgra = [
            1, 2, 3, 255, 4, 5, 6, 255, 9, 9, 9, 9, //
            7, 8, 9, 255, 10, 11, 12, 255, 9, 9, 9, 9,
        ];
        shared.submit_frame(0, &bgra, 12, 2, 2, None);
        let mut shadow = Vec::new();
        assert_eq!(shared.take_frame(0, &mut shadow), Some(None));
        assert_eq!(
            shadow,
            [
                3, 2, 1, 6, 5, 4, 0, 0, 0, //
                9, 8, 7, 12, 11, 10, 0, 0, 0, //
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            ]
        );
    }

    #[test]
    fn mailbox_drops_frames_it_cannot_use() {
        let shared = Shared::new();
        let mut shadow = Vec::new();
        // No head attached.
        shared.submit_frame(0, &[0; 16], 8, 2, 2, None);
        assert!(shared.take_frame(0, &mut shadow).is_none());
        shared.open(0, accepting(2, 2, 2, 2));
        // Short buffer, too-small stride, wrong size for the mode.
        shared.submit_frame(0, &[0; 15], 8, 2, 2, None);
        shared.submit_frame(0, &[0; 16], 4, 2, 2, None);
        shared.submit_frame(0, &[3; 36], 12, 3, 3, None);
        assert!(shared.take_frame(0, &mut shadow).is_none());
        shared.close(0);
        shared.submit_frame(0, &[4; 16], 8, 2, 2, None);
        assert!(shared.take_frame(0, &mut shadow).is_none());
    }

    /// Changed areas accumulate until the engine takes them, and only they are copied over.
    #[test]
    fn mailbox_accumulates_changed_areas_between_takes() {
        let shared = Shared::new();
        shared.open(0, accepting(4, 2, 4, 2));
        let mut shadow = Vec::new();
        shared.submit_frame(0, &[1; 32], 16, 4, 2, None);
        assert_eq!(shared.take_frame(0, &mut shadow), Some(None));
        assert_eq!(shadow, vec![1; 24]);

        // Two partial updates before the engine looks: left column, then bottom-right pixel.
        shared.submit_frame(0, &[2; 32], 16, 4, 2, Some(&[(0, 0, 1, 2)]));
        shared.submit_frame(0, &[3; 32], 16, 4, 2, Some(&[(3, 1, 9, 9)]));
        assert_eq!(shared.take_frame(0, &mut shadow), Some(Some(vec![(0, 0, 1, 2), (3, 1, 4, 2)])));
        assert_eq!(
            shadow,
            [2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 3, 3, 3]
        );
        assert!(shared.take_frame(0, &mut shadow).is_none());

        // An empty change is not a new frame; a whole-frame change wins over partial ones.
        shared.submit_frame(0, &[4; 32], 16, 4, 2, Some(&[(0, 0, 0, 0)]));
        assert!(shared.take_frame(0, &mut shadow).is_none());
        shared.submit_frame(0, &[5; 32], 16, 4, 2, Some(&[(0, 0, 1, 1)]));
        shared.submit_frame(0, &[6; 32], 16, 4, 2, None);
        assert_eq!(shared.take_frame(0, &mut shadow), Some(None));
        assert_eq!(shadow, vec![6; 24]);
    }

    #[test]
    fn padding_rounds_up_to_whole_ridge_strips() {
        let ridge = vino_chimera::kvino::DockProfile::for_family(vino_chimera::kvino::Family::Ridge)
            .expect("Ridge profile");
        // Ridge strips are 64x16: 4K needs no padding, an odd size rounds up on both axes.
        assert_eq!(padded(ridge, 3840, 2160), (3840, 2160));
        assert_eq!(padded(ridge, 65, 17), (128, 32));
    }

    #[test]
    fn video_budget_holds_back_after_a_burst_and_refills_at_the_rate() {
        let start = Instant::now();
        let mut budget = VideoBudget { tokens: VIDEO_BURST_BYTES, refilled: start };
        // A full burst plus one byte leaves nothing to send with.
        budget.spend(VIDEO_BURST_BYTES as usize + 1_000_000);
        budget.refill(start);
        assert!(budget.tokens < 0.0);
        // 10 ms at 100 MB/s earns 1 MB, exactly the overdraft.
        budget.refill(start + Duration::from_millis(11));
        assert!(budget.tokens > 0.0);
        // A long idle spell banks no more than one burst.
        budget.refill(start + Duration::from_secs(60));
        assert_eq!(budget.tokens, VIDEO_BURST_BYTES);
    }
}
