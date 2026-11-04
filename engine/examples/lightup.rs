// Throwaway: program a mode on every present head and show a solid colour per head.
// usage: lightup WIDTH HEIGHT HZ SECONDS
use std::time::{Duration, Instant};
fn main() {
    let a: Vec<usize> = std::env::args().skip(1).map(|s| s.parse().unwrap()).collect();
    let (w, h, hz, secs) = (a[0], a[1], a[2] as u32, a[3] as u64);
    let mut s = vino_chimera::session::ControlSession::engage().expect("engage");
    let colours = [[0u8, 80, 255], [255, 40, 40]];
    let mut lit = Vec::new();
    for head in 0..s.connectors() as u8 {
        let present = s.probe_head_present(head);
        let edid = s.fetch_edid(head).map(|e| e.len());
        eprintln!("head {head}: presence {present:?}, edid {edid:?}");
        if edid.is_err() {
            continue;
        }
        let t = Instant::now();
        match s.activate_mode(head, w, h, hz) {
            Ok(ok) => eprintln!("head {head}: activate {w}x{h}@{hz} -> {ok} in {} ms", t.elapsed().as_millis()),
            Err(e) => { eprintln!("head {head}: activate failed: {e}"); continue; }
        }
        lit.push(head);
    }
    let frames: Vec<Vec<u8>> = lit.iter().map(|&hd| colours[hd as usize % 2].iter().copied().cycle().take(w * h * 3).collect()).collect();
    let start = Instant::now();
    let mut last_keep = Instant::now();
    let mut presented = 0;
    while start.elapsed() < Duration::from_secs(secs) {
        for (i, &head) in lit.iter().enumerate() {
            if let Err(e) = s.present_rgb(head, w, h, &frames[i]) { eprintln!("head {head}: present failed: {e}"); return; }
            presented += 1;
        }
        if last_keep.elapsed() > Duration::from_secs(2) {
            let _ = s.heartbeat();
            last_keep = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    eprintln!("presented {presented}; status per head after: {:?}", lit.iter().map(|&h| s.probe_head_present(h)).collect::<Vec<_>>());
    for &head in &lit { let _ = s.deactivate_mode(head, w, h); }
    eprintln!("DONE");
}
