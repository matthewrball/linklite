// SPDX-License-Identifier: GPL-2.0-or-later

//! Engage the dock's encrypted session and report what is plugged into each connector.
//! Needs exclusive use of the dock: DisplayLink Manager must not be running.

use dllite_engine::edid;
use vino_chimera::session::ControlSession;

fn main() {
    let mut session = match ControlSession::engage() {
        Ok(session) => session,
        Err(error) => {
            eprintln!("dllite-probe: {error}");
            std::process::exit(1);
        }
    };
    let profile = session.profile();
    println!(
        "engaged {} ({} connectors, shared EDID handler: {}, reports presence: {})",
        profile.name(),
        session.connectors(),
        profile.shared_edid_handler(),
        profile.reports_presence()
    );
    for head in 0..session.connectors() as u8 {
        let present = session.probe_head_present(head);
        print!("connector {head}: presence {present:?}; ");
        match session.fetch_edid(head) {
            Ok(bytes) => match edid::parse(&bytes) {
                Ok(m) => println!(
                    "{} {} ({}x{}@{}, {}x{} mm, {} EDID bytes)",
                    m.manufacturer,
                    m.name.as_deref().unwrap_or("unnamed"),
                    m.preferred.width,
                    m.preferred.height,
                    m.preferred.refresh_hz,
                    m.width_mm,
                    m.height_mm,
                    bytes.len()
                ),
                Err(error) => println!("EDID unreadable ({error}, {} bytes)", bytes.len()),
            },
            Err(error) => println!("no EDID ({error})"),
        }
    }
}
