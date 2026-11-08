// SPDX-License-Identifier: GPL-2.0-or-later

//! What to send for one presented frame, following the driver's `drm_sink/scanout.rs`.
//!
//! DLM does not stream whole frames. It hashes the surface a strip at a time, sends only the
//! macro-tiles whose content moved, and sends absolutely nothing while the desktop is still --
//! measured at 100.86 MB/s under load and exactly 0 bytes idle. The rig used to send a complete
//! 3600-strip keyframe for every frame the compositor produced, which is both orders of magnitude
//! more bytes and a different wire shape from the one the dock was designed around.
//!
//! Two pieces of state per head reproduce it:
//!
//! * **content hashes** -- one per strip, so a frame's changed strips are known without the
//!   compositor telling us. libevdi does report damage rectangles, but they describe what the
//!   client redrew, not what ended up different.
//! * **a retransmit debt** -- the dock rotates `dock_buffers` buffers, and one presentation
//!   reaches exactly one of them. A changed strip is therefore charged
//!   the dock's `damage_frames` transmissions and stays selected until it has paid them, which is
//!   what stops a strip from ghosting between an old and a new copy on alternate refreshes.
//!
//! Hashes and debt are published only once the frame has actually reached the dock ([`presented`]),
//! so a transport failure leaves the previous dock-visible state intact and the next frame repairs
//! it.
//!
//! [`presented`]: HeadScanout::presented

use crate::kvino;

/// What one presented frame should put on the wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    /// Send every strip, `dock_buffers` times, so all of the dock's buffers hold this image.
    Keyframe,
    /// Send the strips these half-open `(x0, y0, x1, y1)` clips select, once.
    Damage(Vec<(usize, usize, usize, usize)>),
    /// Send nothing: no strip's content moved and no strip still owes a retransmission.
    Idle,
}

/// Cap on the number of damage rectangles handed to the codec. Change too scattered to describe
/// exactly within it is sent as a coarser superset (local displaylink-lite patch).
const MAX_RECTS: usize = 128;

/// One frame's worth of EP08 records, and how many times to present it.
pub struct Frame {
    pub records: Vec<Vec<u8>>,
    pub presentations: u32,
}

/// Per-head content shadow and retransmit ledger.
pub struct HeadScanout {
    /// The dock being fed: it states the strip size and how a change is spread over its buffers.
    dock: kvino::DockProfile,
    w_pad: usize,
    h_pad: usize,
    hashes: Vec<u64>,
    debt: Vec<u8>,
    keyframe_owed: bool,
    /// Hashes computed by [`HeadScanout::plan`], published by [`HeadScanout::presented`].
    pending: Vec<u64>,
    /// The last encoded body of each strip, and the content hash it was encoded from.
    ///
    /// `damage_repeats` transmissions of one change are the same bytes three times over; encoding
    /// them once is what keeps a delta's cost proportional to what actually moved. A body is only
    /// served when its recorded hash still matches the strip's current content -- a body paired
    /// with newer pixels would paint stale content the dock then keeps, with nothing scheduled to
    /// repair it.
    bodies: Vec<Option<Vec<u8>>>,
    body_hashes: Vec<u64>,
    /// Strips that changed since the last [`HeadScanout::settle`]. Local displaylink-lite patch:
    /// once the surface goes still they are sent to every dock buffer again, so a transmission the
    /// dock missed or put in the wrong buffer while things were moving cannot leave a stale box.
    touched: Vec<bool>,
    /// Whether the last plan was the coarse superset for change too scattered for [`MAX_RECTS`].
    /// Local displaylink-lite patch, for performance counters.
    last_plan_coarse: bool,
}

impl HeadScanout {
    pub fn new(dock: kvino::DockProfile) -> Self {
        Self {
            dock,
            w_pad: 0,
            h_pad: 0,
            hashes: Vec::new(),
            debt: Vec::new(),
            keyframe_owed: true,
            pending: Vec::new(),
            bodies: Vec::new(),
            body_hashes: Vec::new(),
            touched: Vec::new(),
            last_plan_coarse: false,
        }
    }

    /// Require a full keyframe for the next frame.
    ///
    /// The dock's framebuffer is undefined until one arrives, so every mode-set owes this; so does
    /// anything else that leaves what the dock holds unknown.
    pub fn owe_keyframe(&mut self) {
        self.keyframe_owed = true;
    }

    /// Whether the last [`HeadScanout::plan_dirty`] fell back to a coarse superset because the
    /// change was too scattered for [`MAX_RECTS`] exact rectangles. Local displaylink-lite patch.
    pub fn last_plan_coarse(&self) -> bool {
        self.last_plan_coarse
    }

    /// Whether some strip still owes a transmission.
    ///
    /// A delta pays one of its the dock's `damage_frames` transmissions per presented frame, so a
    /// desktop that goes still immediately after a change would strand the rest and leave the
    /// dock's other buffers holding stale pixels -- which it shows as ghosting the moment it
    /// rotates. The caller must re-present the last surface while this holds, even though the
    /// compositor has produced nothing new.
    pub fn owes_retransmission(&self) -> bool {
        self.keyframe_owed || self.debt.iter().any(|&d| d > 0)
    }

    /// Owe every strip touched since the last settle a fresh round of transmissions to all of the
    /// dock's buffers. Returns whether anything was owed. Call once the surface has gone still.
    pub fn settle(&mut self) -> bool {
        let mut owed = false;
        for (touched, debt) in self.touched.iter_mut().zip(self.debt.iter_mut()) {
            if core::mem::take(touched) {
                *debt = (*debt).max(self.dock.damage_frames());
                owed = true;
            }
        }
        owed
    }

    /// Decide what to send for `rgb`, a padded surface of `w_pad` x `h_pad` packed RGB888.
    pub fn plan(&mut self, w_pad: usize, h_pad: usize, rgb: &[u8]) -> Plan {
        self.plan_dirty(w_pad, h_pad, rgb, None)
    }

    /// [`HeadScanout::plan`] where only strips meeting `dirty` (half-open `(x0, y0, x1, y1)`
    /// pixel rectangles) can have changed since the last planned surface; `None` means anything
    /// may have. Only those strips are hashed. Local displaylink-lite patch: the macOS capture
    /// reports exactly what changed, and hashing a whole 4K surface for a ticking clock was the
    /// largest steady CPU cost.
    pub fn plan_dirty(
        &mut self,
        w_pad: usize,
        h_pad: usize,
        rgb: &[u8],
        dirty: Option<&[(usize, usize, usize, usize)]>,
    ) -> Plan {
        let (strip_w, strip_h) = self.dock.strip_dims();
        let tiles_x = w_pad / strip_w;
        let tiles_y = h_pad / strip_h;
        let expected = tiles_x * tiles_y;

        // A surface of a different size says nothing about the one the dock is holding.
        if self.w_pad != w_pad || self.h_pad != h_pad || self.hashes.len() != expected {
            self.w_pad = w_pad;
            self.h_pad = h_pad;
            self.hashes = vec![0; expected];
            self.debt = vec![0; expected];
            self.bodies = vec![None; expected];
            self.body_hashes = vec![0; expected];
            self.touched = vec![false; expected];
            self.keyframe_owed = true;
        }

        self.pending = match dirty {
            Some(rects) if !self.keyframe_owed => {
                strip_hashes_within(rgb, w_pad, h_pad, strip_w, strip_h, &self.hashes, rects)
            }
            _ => strip_hashes(rgb, w_pad, h_pad, strip_w, strip_h),
        };
        if self.keyframe_owed {
            return Plan::Keyframe;
        }

        // Charge every strip whose content moved, then select every strip that still owes a
        // transmission -- including ones that changed on an earlier frame and have not yet reached
        // every dock buffer.
        for (i, &hash) in self.pending.iter().enumerate() {
            if self.hashes[i] != hash {
                self.debt[i] = self.dock.damage_frames();
                self.touched[i] = true;
            }
        }
        // Change too scattered to list exactly (App Exposé, a desktop swipe) is sent as a coarse
        // superset once, like any delta, rather than as a keyframe presented to every dock buffer
        // back to back: the retransmit debt still carries each changed strip to every buffer, and a
        // superset only resends strips the dock already holds (local displaylink-lite patch).
        let exact = owed_rects(&self.debt, tiles_x, tiles_y, strip_w, strip_h);
        self.last_plan_coarse = exact.is_none();
        let rects =
            exact.unwrap_or_else(|| coarse_owed_rects(&self.debt, tiles_x, tiles_y, strip_w, strip_h));
        if rects.is_empty() { Plan::Idle } else { Plan::Damage(rects) }
    }

    /// Encode the strips `plan` selects into EP08 records, reusing bodies that are still current.
    ///
    /// `rgb` must be the surface [`HeadScanout::plan`] was called with. Returns `None` when the
    /// plan selects no strip, in which case nothing at all goes on the wire.
    pub fn encode(
        &mut self,
        plan: &Plan,
        rgb: &[u8],
        head: u8,
    ) -> Result<Option<Frame>, crate::kshim::Error> {
        let (strip_w, strip_h) = self.dock.strip_dims();
        let tiles_x = self.w_pad / strip_w;
        let (coords, presentations) = match plan {
            Plan::Idle => return Ok(None),
            Plan::Damage(clips) => (
                kvino::strip_coords(self.dock, self.w_pad, self.h_pad, Some(clips))?,
                // Consecutive copies land in the same dock buffer on most hardware, so a delta is
                // presented as few times as the dock needs and its repeats are spread across
                // later frames by the retransmit debt.
                self.dock.delta_presentations(),
            ),
            // A keyframe must reach EVERY dock buffer: one presentation updates only one of them,
            // and the ledger is cleared on the strength of this frame, so a keyframe that comes up
            // short leaves stale pixels nothing will ever repair.
            Plan::Keyframe => (
                kvino::strip_coords(self.dock, self.w_pad, self.h_pad, None)?,
                self.dock.keyframe_presentations(),
            ),
        };
        if coords.is_empty() {
            return Ok(None);
        }

        // Strips without a current cached body are encoded across cores: each strip's body
        // depends only on its own pixels, and a 4K keyframe is 8100 of them.
        let mut fresh: Vec<(usize, usize, usize, Option<Result<Vec<u8>, crate::kshim::Error>>)> =
            Vec::new();
        for &(sx, sy) in &coords {
            let index = (sy / strip_h) * tiles_x + (sx / strip_w);
            let current = self.pending[index];
            if self.bodies[index].is_none() || self.body_hashes[index] != current {
                fresh.push((index, sx, sy, None));
            }
        }
        let (dock, w_pad) = (self.dock, self.w_pad);
        par_for_each_mut(&mut fresh, crate::pool::threads(), |_, (_, sx, sy, body)| {
            *body = Some(kvino::encode_strip(dock, w_pad, rgb, *sx, *sy));
        });
        for (index, _, _, body) in fresh {
            self.bodies[index] = Some(body.expect("every fresh strip was encoded")?);
            self.body_hashes[index] = self.pending[index];
        }

        let mut strips: Vec<&[u8]> = Vec::with_capacity(coords.len());
        for &(sx, sy) in &coords {
            let index = (sy / strip_h) * tiles_x + (sx / strip_w);
            strips.push(self.bodies[index].as_deref().expect("body cached above"));
        }
        Ok(Some(Frame {
            records: kvino::frame_records(self.dock, &strips, head)?,
            presentations,
        }))
    }

    /// Record that `plan`'s frame reached the dock.
    ///
    /// A keyframe rewrites the whole surface in every buffer, so it clears the ledger outright.
    /// A delta pays one transmission for every strip that still owed one.
    pub fn presented(&mut self, plan: &Plan) {
        match plan {
            Plan::Idle => return,
            Plan::Keyframe => {
                self.debt.iter_mut().for_each(|d| *d = 0);
                self.keyframe_owed = false;
            }
            Plan::Damage(_) => {
                for d in self.debt.iter_mut() {
                    *d = d.saturating_sub(1);
                }
            }
        }
        self.hashes = core::mem::take(&mut self.pending);
    }
}

/// Hash each strip of a packed RGB888 surface.
///
/// Only change detection rests on this, so it is a cheap multiply-xor ([`StripHasher`]) with a
/// position-dependent seed; the driver uses xxh64 for the same purpose. What matters is that two
/// different strips of pixels are overwhelmingly unlikely to agree, and that a strip's own hash is
/// stable across frames.
fn strip_hashes(
    rgb: &[u8],
    w_pad: usize,
    h_pad: usize,
    strip_w: usize,
    strip_h: usize,
) -> Vec<u64> {
    let tiles_x = w_pad / strip_w;
    let tiles_y = h_pad / strip_h;
    let mut hashes = vec![0u64; tiles_x * tiles_y];
    par_for_each_mut(&mut hashes, crate::pool::STREAMING_THREADS, |i, out| {
        *out = strip_hash(rgb, w_pad, strip_w, strip_h, i % tiles_x, i / tiles_x);
    });
    hashes
}

/// `previous` with only the strips meeting `rects` re-hashed.
fn strip_hashes_within(
    rgb: &[u8],
    w_pad: usize,
    h_pad: usize,
    strip_w: usize,
    strip_h: usize,
    previous: &[u64],
    rects: &[(usize, usize, usize, usize)],
) -> Vec<u64> {
    let tiles_x = w_pad / strip_w;
    let tiles_y = h_pad / strip_h;
    let mut selected = vec![false; tiles_x * tiles_y];
    for &(x0, y0, x1, y1) in rects {
        let (x1, y1) = (x1.min(w_pad), y1.min(h_pad));
        if x0 >= x1 || y0 >= y1 {
            continue;
        }
        for ty in y0 / strip_h..y1.div_ceil(strip_h) {
            for tx in x0 / strip_w..x1.div_ceil(strip_w) {
                selected[ty * tiles_x + tx] = true;
            }
        }
    }
    let mut work: Vec<(usize, u64)> =
        (0..selected.len()).filter(|&i| selected[i]).map(|i| (i, 0)).collect();
    par_for_each_mut(&mut work, crate::pool::STREAMING_THREADS, |_, (i, out)| {
        *out = strip_hash(rgb, w_pad, strip_w, strip_h, *i % tiles_x, *i / tiles_x);
    });
    let mut hashes = previous.to_vec();
    for (i, hash) in work {
        hashes[i] = hash;
    }
    hashes
}

fn strip_hash(rgb: &[u8], w_pad: usize, strip_w: usize, strip_h: usize, tx: usize, ty: usize) -> u64 {
    let row = w_pad * 3;
    let span = strip_w * 3;
    let mut h = StripHasher::new(StripHasher::PRIME ^ (tx as u64).rotate_left(17) ^ (ty as u64).rotate_left(43));
    for dy in 0..strip_h {
        let start = (ty * strip_h + dy) * row + tx * span;
        h.line(&rgb[start..start + span]);
    }
    h.finish()
}

/// Change-detection hash of a strip, fed one pixel line at a time. Local displaylink-lite patch.
///
/// Eight independent multiply-xor lanes take one 8-byte word each per 64-byte step and are
/// folded together at the end, so their multiplies overlap instead of each waiting on the last
/// (about 4x the single-chain rate on Apple Silicon; four lanes managed about 3x). A hash is only
/// ever compared with another from this same hasher, seed and line split.
pub struct StripHasher {
    lanes: [u64; 8],
}

impl StripHasher {
    pub const PRIME: u64 = 0x9e37_79b1_85eb_ca87;

    pub fn new(seed: u64) -> Self {
        // Distinct lane seeds, so equal data in different lanes hashes differently.
        Self { lanes: core::array::from_fn(|i| seed ^ (i as u64).wrapping_mul(0xc2b2_ae3d_27d4_eb4f)) }
    }

    fn mix(h: u64, word: u64) -> u64 {
        (h ^ word).wrapping_mul(Self::PRIME).rotate_left(31)
    }

    pub fn line(&mut self, line: &[u8]) {
        let word = |bytes: &[u8]| u64::from_le_bytes(bytes.try_into().unwrap_or([0; 8]));
        let mut steps = line.chunks_exact(64);
        for step in &mut steps {
            for (lane, bytes) in self.lanes.iter_mut().zip(step.chunks_exact(8)) {
                *lane = Self::mix(*lane, word(bytes));
            }
        }
        // At most seven whole words remain, one per lane, then at most seven bytes.
        let mut words = steps.remainder().chunks_exact(8);
        for (lane, bytes) in self.lanes.iter_mut().zip(&mut words) {
            *lane = Self::mix(*lane, word(bytes));
        }
        for &byte in words.remainder() {
            self.lanes[0] = (self.lanes[0] ^ u64::from(byte)).wrapping_mul(Self::PRIME);
        }
    }

    pub fn finish(&self) -> u64 {
        self.lanes[1..].iter().fold(self.lanes[0], |h, &lane| Self::mix(h, lane))
    }
}

/// Below this many items a pass runs on the calling thread: waking workers costs more than a
/// small damage region takes to encode.
const PARALLEL_MIN_ITEMS: usize = 64;

/// Run `f(index, item)` over `items` on at most `threads` threads of the shared worker pool.
/// Local displaylink-lite patch; see vendor/vino/UPSTREAM.md.
fn par_for_each_mut<T: Send>(items: &mut [T], threads: usize, f: impl Fn(usize, &mut T) + Sync) {
    if items.len() < PARALLEL_MIN_ITEMS {
        items.iter_mut().enumerate().for_each(|(i, item)| f(i, item));
        return;
    }
    crate::pool::for_each_mut(items, threads, f);
}

/// Turn the strips that still owe a transmission into tile-aligned damage rectangles.
///
/// Runs of owing strips within one band become one rectangle, and a rectangle directly above an
/// identical span is grown downwards rather than added -- the same merge the driver does, because
/// each rectangle costs the codec an overlap test per strip. `None` means the change is too
/// scattered to describe within [`MAX_RECTS`]; see [`coarse_owed_rects`].
fn owed_rects(
    debt: &[u8],
    tiles_x: usize,
    tiles_y: usize,
    strip_w: usize,
    strip_h: usize,
) -> Option<Vec<(usize, usize, usize, usize)>> {
    let mut rects: Vec<(usize, usize, usize, usize)> = Vec::new();
    for ty in 0..tiles_y {
        let mut tx = 0usize;
        while tx < tiles_x {
            if debt[ty * tiles_x + tx] == 0 {
                tx += 1;
                continue;
            }
            let run_start = tx;
            while tx < tiles_x && debt[ty * tiles_x + tx] > 0 {
                tx += 1;
            }
            let (x0, x1) = (run_start * strip_w, tx * strip_w);
            let y0 = ty * strip_h;
            let y1 = y0 + strip_h;
            match rects
                .iter_mut()
                .rev()
                .find(|prior| prior.0 == x0 && prior.2 == x1 && prior.3 == y0)
            {
                Some(prior) => prior.3 = y1,
                None => {
                    if rects.len() == MAX_RECTS {
                        return None;
                    }
                    rects.push((x0, y0, x1, y1));
                }
            }
        }
    }
    Some(rects)
}

/// At most [`MAX_RECTS`] rectangles covering every owing strip: owing strips are grouped into
/// bands of whole strip rows, and each band becomes one rectangle spanning its owing columns.
fn coarse_owed_rects(
    debt: &[u8],
    tiles_x: usize,
    tiles_y: usize,
    strip_w: usize,
    strip_h: usize,
) -> Vec<(usize, usize, usize, usize)> {
    let band = tiles_y.div_ceil(MAX_RECTS).max(1);
    let mut rects = Vec::with_capacity(tiles_y.div_ceil(band));
    for ty0 in (0..tiles_y).step_by(band) {
        let ty1 = (ty0 + band).min(tiles_y);
        let mut span: Option<(usize, usize)> = None;
        for ty in ty0..ty1 {
            let row = &debt[ty * tiles_x..(ty + 1) * tiles_x];
            if let (Some(first), Some(last)) = (row.iter().position(|&d| d > 0), row.iter().rposition(|&d| d > 0)) {
                span = Some(span.map_or((first, last), |(a, b)| (a.min(first), b.max(last))));
            }
        }
        if let Some((first, last)) = span {
            rects.push((first * strip_w, ty0 * strip_h, (last + 1) * strip_w, ty1 * strip_h));
        }
    }
    rects
}

#[cfg(test)]
mod tests {
    use super::*;

    fn surface(w: usize, h: usize, fill: u8) -> Vec<u8> {
        vec![fill; w * h * 3]
    }

    /// A 64x16-strip, double-buffered dock, which is what these surfaces are sized for.
    fn ridge() -> kvino::DockProfile {
        kvino::DockProfile::for_family(kvino::Family::Ridge).expect("Ridge")
    }

    #[test]
    fn first_frame_is_a_keyframe_and_clears_the_ledger() {
        let mut head = HeadScanout::new(ridge());
        let rgb = surface(128, 32, 0x20);
        assert_eq!(head.plan(128, 32, &rgb), Plan::Keyframe);
        head.presented(&Plan::Keyframe);
        // Same pixels again: nothing owed, nothing sent.
        assert_eq!(head.plan(128, 32, &rgb), Plan::Idle);
    }

    #[test]
    fn a_changed_strip_is_resent_until_every_dock_buffer_has_it() {
        let mut head = HeadScanout::new(ridge());
        let mut rgb = surface(128, 32, 0x20);
        head.plan(128, 32, &rgb);
        head.presented(&Plan::Keyframe);

        // Repaint the top-left strip only.
        for y in 0..16 {
            let row = y * 128 * 3;
            rgb[row..row + 64 * 3].fill(0xf0);
        }
        let plan = head.plan(128, 32, &rgb);
        assert_eq!(plan, Plan::Damage(vec![(0, 0, 64, 16)]));
        head.presented(&plan);

        // Still owed on the following frames, with the surface now unchanged.
        for _ in 1..ridge().damage_frames() {
            let plan = head.plan(128, 32, &rgb);
            assert_eq!(plan, Plan::Damage(vec![(0, 0, 64, 16)]));
            head.presented(&plan);
        }
        assert_eq!(head.plan(128, 32, &rgb), Plan::Idle);
    }

    /// Local displaylink-lite patch: change too scattered for MAX_RECTS exact rectangles (App
    /// Exposé, a desktop swipe) is planned as one coarse delta covering every changed strip, not a
    /// keyframe presented to every buffer at once, and it still reaches every dock buffer.
    #[test]
    fn scattered_change_is_a_coarse_delta_that_reaches_every_buffer() {
        let (w, h) = (64 * 20, 16 * 140);
        let mut head = HeadScanout::new(ridge());
        let mut rgb = surface(w, h, 0x20);
        head.plan(w, h, &rgb);
        head.presented(&Plan::Keyframe);

        // Every other strip of every strip row: 1400 separate runs, far beyond MAX_RECTS.
        for ty in 0..140 {
            for tx in (ty % 2..20).step_by(2) {
                for y in ty * 16..ty * 16 + 16 {
                    let row = (y * w + tx * 64) * 3;
                    rgb[row..row + 64 * 3].fill(0xf0);
                }
            }
        }
        let plan = head.plan(w, h, &rgb);
        let Plan::Damage(rects) = &plan else { panic!("expected a coarse delta, got {plan:?}") };
        assert!(rects.len() <= MAX_RECTS);
        for ty in 0..140 {
            for tx in (ty % 2..20).step_by(2) {
                let (x, y) = (tx * 64, ty * 16);
                assert!(rects.iter().any(|r| r.0 <= x && x < r.2 && r.1 <= y && y < r.3), "strip {tx},{ty} not covered");
            }
        }
        head.presented(&plan);
        // The remaining copies follow on later frames until every buffer holds the change.
        for _ in 1..ridge().damage_frames() {
            let plan = head.plan(w, h, &rgb);
            assert!(matches!(plan, Plan::Damage(_)));
            head.presented(&plan);
        }
        assert_eq!(head.plan(w, h, &rgb), Plan::Idle);
    }

    /// Local displaylink-lite patch: a dirty hint covering the change plans what a full hash
    /// plans, and strips outside it are not looked at.
    #[test]
    fn a_dirty_hint_plans_like_a_full_hash() {
        let mut hinted = HeadScanout::new(ridge());
        let mut full = HeadScanout::new(ridge());
        let mut rgb = surface(128, 32, 0x20);
        for head in [&mut hinted, &mut full] {
            let keyframe = head.plan(128, 32, &rgb);
            head.presented(&keyframe);
        }
        // Change one pixel in the bottom-right strip.
        let pixel = (20 * 128 + 100) * 3;
        rgb[pixel] = 0xff;
        let plan = hinted.plan_dirty(128, 32, &rgb, Some(&[(100, 20, 101, 21)]));
        assert_eq!(plan, full.plan(128, 32, &rgb));
        assert_eq!(plan, Plan::Damage(vec![(64, 16, 128, 32)]));
        // An empty hint sees nothing new, even though the surface differs from the last plan.
        let mut other = HeadScanout::new(ridge());
        let keyframe = other.plan(128, 32, &surface(128, 32, 0x20));
        other.presented(&keyframe);
        assert_eq!(other.plan_dirty(128, 32, &rgb, Some(&[])), Plan::Idle);
    }

    /// Local displaylink-lite patch: a settle re-owes what changed since the last settle, once.
    #[test]
    fn settle_resends_only_what_changed_since_the_last_settle() {
        let mut head = HeadScanout::new(ridge());
        let mut rgb = surface(128, 32, 0x20);
        let keyframe = head.plan(128, 32, &rgb);
        head.presented(&keyframe);
        // A keyframe already reached every buffer; nothing to settle.
        assert!(!head.settle());

        for y in 16..32 {
            let row = y * 128 * 3 + 64 * 3;
            rgb[row..row + 64 * 3].fill(0xf0);
        }
        loop {
            let plan = head.plan(128, 32, &rgb);
            if plan == Plan::Idle {
                break;
            }
            head.presented(&plan);
        }
        assert!(head.settle());
        for _ in 0..ridge().damage_frames() {
            let plan = head.plan(128, 32, &rgb);
            assert_eq!(plan, Plan::Damage(vec![(64, 16, 128, 32)]));
            head.presented(&plan);
        }
        assert_eq!(head.plan(128, 32, &rgb), Plan::Idle);
        assert!(!head.settle());
    }

    #[test]
    fn a_reused_body_is_the_bytes_a_fresh_encode_produces() {
        let mut head = HeadScanout::new(ridge());
        let mut rgb = surface(128, 32, 0x20);
        let plan = head.plan(128, 32, &rgb);
        head.encode(&plan, &rgb, 0).unwrap();
        head.presented(&plan);

        for y in 0..16 {
            let row = y * 128 * 3;
            for (x, px) in rgb[row..row + 64 * 3].chunks_exact_mut(3).enumerate() {
                px.copy_from_slice(&[x as u8, 0x40, 0x80]);
            }
        }
        // First delta encodes the changed strip; the retransmissions it still owes serve the
        // cached body, and must put exactly the same bytes on the wire.
        let first = head.plan(128, 32, &rgb);
        let fresh = head.encode(&first, &rgb, 0).unwrap().unwrap();
        head.presented(&first);
        let second = head.plan(128, 32, &rgb);
        let cached = head.encode(&second, &rgb, 0).unwrap().unwrap();
        assert_eq!(first, second);
        assert_eq!(fresh.records, cached.records);
        assert!(!fresh.records.is_empty());
    }

    #[test]
    fn a_keyframe_reaches_every_dock_buffer() {
        let mut head = HeadScanout::new(ridge());
        let rgb = surface(128, 32, 0x20);
        let plan = head.plan(128, 32, &rgb);
        let frame = head.encode(&plan, &rgb, 0).unwrap().unwrap();
        assert_eq!(frame.presentations, ridge().keyframe_presentations());
        head.presented(&plan);
        // A delta is presented once; its repeats are the debt, not back-to-back copies.
        let mut moved = rgb.clone();
        moved[..64 * 3].fill(0xff);
        let plan = head.plan(128, 32, &moved);
        assert_eq!(
            head.encode(&plan, &moved, 0)
                .unwrap()
                .unwrap()
                .presentations,
            ridge().delta_presentations()
        );
    }

    #[test]
    fn an_idle_frame_encodes_nothing() {
        let mut head = HeadScanout::new(ridge());
        let rgb = surface(128, 32, 0x20);
        let plan = head.plan(128, 32, &rgb);
        head.encode(&plan, &rgb, 0).unwrap();
        head.presented(&plan);
        let plan = head.plan(128, 32, &rgb);
        assert_eq!(plan, Plan::Idle);
        assert!(head.encode(&plan, &rgb, 0).unwrap().is_none());
    }

    #[test]
    fn a_new_surface_size_owes_a_keyframe() {
        let mut head = HeadScanout::new(ridge());
        head.plan(128, 32, &surface(128, 32, 0x20));
        head.presented(&Plan::Keyframe);
        assert_eq!(head.plan(192, 32, &surface(192, 32, 0x20)), Plan::Keyframe);
    }

    /// Local displaylink-lite patch: the lane-split hasher still sees every byte and its place.
    #[test]
    fn strip_hasher_notices_any_byte_and_any_line_swap() {
        let hash = |lines: &[&[u8]]| {
            let mut h = StripHasher::new(StripHasher::PRIME);
            lines.iter().for_each(|line| h.line(line));
            h.finish()
        };
        for len in [0usize, 1, 7, 8, 9, 63, 64, 65, 127, 192, 200] {
            let a: Vec<u8> = (0..len).map(|i| (i * 31 + 7) as u8).collect();
            let b: Vec<u8> = (0..len).map(|i| (i * 17 + 3) as u8).collect();
            let base = hash(&[&a, &b]);
            assert_eq!(base, hash(&[&a, &b]), "len {len}");
            if len > 0 {
                assert_ne!(base, hash(&[&b, &a]), "len {len}");
            }
            for i in 0..len {
                let mut flipped = a.clone();
                flipped[i] ^= 0x40;
                assert_ne!(base, hash(&[&flipped, &b]), "len {len} byte {i}");
            }
        }
    }

    #[test]
    fn owed_runs_merge_across_bands() {
        // Two vertically adjacent bands owing the same span become one rectangle.
        let debt = vec![1, 1, 0, 1, 1, 0];
        assert_eq!(owed_rects(&debt, 3, 2, 64, 16), Some(vec![(0, 0, 128, 32)]));
    }
}
