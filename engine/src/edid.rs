// SPDX-License-Identifier: GPL-2.0-or-later

//! The parts of an EDID the host needs to present a monitor to macOS: who made it, what it is
//! called, its physical size, and its preferred timing.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Monitor {
    /// Three-letter PNP manufacturer id, e.g. `HPN`.
    pub manufacturer: String,
    pub product_code: u16,
    pub serial: u32,
    /// Display product name descriptor (`0xFC`), if the monitor provides one.
    pub name: Option<String>,
    pub width_mm: u32,
    pub height_mm: u32,
    pub preferred: Timing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timing {
    pub width: u32,
    pub height: u32,
    /// Rounded to the nearest whole hertz.
    pub refresh_hz: u32,
    pub pixel_clock_khz: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub enum EdidError {
    TooShort(usize),
    BadHeader,
    BadChecksum,
    NoPreferredTiming,
}

impl std::fmt::Display for EdidError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooShort(len) => write!(f, "EDID is {len} bytes, need at least 128"),
            Self::BadHeader => f.write_str("EDID header is not 00 ff ff ff ff ff ff 00"),
            Self::BadChecksum => f.write_str("EDID base block checksum is wrong"),
            Self::NoPreferredTiming => f.write_str("EDID has no detailed preferred timing"),
        }
    }
}

const HEADER: [u8; 8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00];

pub fn parse(edid: &[u8]) -> Result<Monitor, EdidError> {
    if edid.len() < 128 {
        return Err(EdidError::TooShort(edid.len()));
    }
    let base = &edid[..128];
    if base[..8] != HEADER {
        return Err(EdidError::BadHeader);
    }
    if base.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0 {
        return Err(EdidError::BadChecksum);
    }

    let id = u16::from_be_bytes([base[8], base[9]]);
    let manufacturer = [10, 5, 0]
        .iter()
        .map(|shift| char::from(b'@' + ((id >> shift) & 0x1f) as u8))
        .collect();

    let descriptors = || base[54..126].chunks_exact(18);
    let text = |tag: u8| {
        descriptors()
            .find(|d| d[..3] == [0, 0, 0] && d[3] == tag)
            .map(|d| {
                let text = &d[5..18];
                let end = text.iter().position(|b| *b == 0x0a).unwrap_or(text.len());
                String::from_utf8_lossy(&text[..end]).trim().to_string()
            })
            .filter(|text| !text.is_empty())
    };
    let name = text(0xfc).as_deref().and_then(display_name);

    let preferred = descriptors()
        .find_map(detailed_timing)
        .ok_or(EdidError::NoPreferredTiming)?;

    // Many monitors (HP among them) leave the numeric serial at zero and put the real one in the
    // serial-number text descriptor. macOS refuses two virtual displays with the same vendor,
    // product and serial, so two identical models need the text serial to tell them apart.
    let numeric_serial = u32::from_le_bytes([base[12], base[13], base[14], base[15]]);
    let serial = match numeric_serial {
        0 => text(0xff).map_or(0, |serial_text| fnv1a32(serial_text.as_bytes())),
        numeric => numeric,
    };

    Ok(Monitor {
        manufacturer,
        product_code: u16::from_le_bytes([base[10], base[11]]),
        serial,
        name,
        width_mm: u32::from(base[21]) * 10,
        height_mm: u32::from(base[22]) * 10,
        preferred,
    })
}

/// 32-bit FNV-1a: a stable, nonzero-in-practice identifier derived from a serial string.
fn fnv1a32(bytes: &[u8]) -> u32 {
    bytes
        .iter()
        .fold(0x811c_9dc5u32, |hash, &byte| (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193))
}

fn detailed_timing(d: &[u8]) -> Option<Timing> {
    let clock_10khz = u32::from(u16::from_le_bytes([d[0], d[1]]));
    if clock_10khz == 0 {
        return None;
    }
    let h_active = u32::from(d[2]) | (u32::from(d[4] & 0xf0) << 4);
    let h_blank = u32::from(d[3]) | (u32::from(d[4] & 0x0f) << 8);
    let v_active = u32::from(d[5]) | (u32::from(d[7] & 0xf0) << 4);
    let v_blank = u32::from(d[6]) | (u32::from(d[7] & 0x0f) << 8);
    let total = (h_active + h_blank) * (v_active + v_blank);
    if h_active == 0 || v_active == 0 || total == 0 {
        return None;
    }
    let clock_hz = u64::from(clock_10khz) * 10_000;
    Some(Timing {
        width: h_active,
        height: v_active,
        refresh_hz: ((clock_hz + u64::from(total) / 2) / u64::from(total)) as u32,
        pixel_clock_khz: clock_10khz * 10,
    })
}

/// Modes LinkLite will program and capture. A malicious EDID can ask for a 1×1 display or a
/// refresh of hundreds of megahertz; neither is a dock this stack drives, and the large case
/// would pin capture and WindowServer. Keep the bounds identical to `MonitorLimits` in the app.
pub fn acceptable_desktop_mode(timing: &Timing) -> bool {
    const MIN_EDGE: u32 = 480;
    const MAX_EDGE: u32 = 5120;
    const MAX_HZ: u32 = 240;
    (MIN_EDGE..=MAX_EDGE).contains(&timing.width)
        && (MIN_EDGE..=MAX_EDGE).contains(&timing.height)
        && (1..=MAX_HZ).contains(&timing.refresh_hz)
}

/// Printable ASCII only. The product-name descriptor is device-controlled and is shown to the user.
fn display_name(raw: &str) -> Option<String> {
    let name: String = raw.chars().filter(|c| c.is_ascii_graphic() || *c == ' ').collect();
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    let name: String = name.chars().take(32).collect();
    (!name.is_empty()).then_some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 4K60 base block: manufacturer `HPN`, name "HP Z27k G3", preferred 3840x2160 at 533.25 MHz
    /// (CVT-RB: htotal 4000, vtotal 2222).
    fn sample() -> Vec<u8> {
        let mut e = vec![0u8; 128];
        e[..8].copy_from_slice(&HEADER);
        e[8..10].copy_from_slice(&0x220eu16.to_be_bytes()); // H=8 P=16 N=14
        e[10..12].copy_from_slice(&0x3a7fu16.to_le_bytes());
        e[12..16].copy_from_slice(&0x0102_0304u32.to_le_bytes());
        e[21] = 60;
        e[22] = 34;
        let dtd = &mut e[54..72];
        dtd[..2].copy_from_slice(&53325u16.to_le_bytes());
        dtd[2] = (3840 & 0xff) as u8;
        dtd[3] = (160 & 0xff) as u8;
        dtd[4] = (((3840 >> 8) as u8) << 4) | (160 >> 8) as u8;
        dtd[5] = (2160 & 0xff) as u8;
        dtd[6] = 62;
        dtd[7] = ((2160 >> 8) as u8) << 4;
        let name = &mut e[72..90];
        name[3] = 0xfc;
        name[5..18].copy_from_slice(b"HP Z27k G3\n  ");
        let sum = e.iter().fold(0u8, |s, b| s.wrapping_add(*b));
        e[127] = 0u8.wrapping_sub(sum);
        e
    }

    #[test]
    fn parses_identity_and_preferred_timing() {
        let monitor = parse(&sample()).unwrap();
        assert_eq!(monitor.manufacturer, "HPN");
        assert_eq!(monitor.product_code, 0x3a7f);
        assert_eq!(monitor.serial, 0x0102_0304);
        assert_eq!(monitor.name.as_deref(), Some("HP Z27k G3"));
        assert_eq!((monitor.width_mm, monitor.height_mm), (600, 340));
        assert_eq!(
            monitor.preferred,
            Timing { width: 3840, height: 2160, refresh_hz: 60, pixel_clock_khz: 533_250 }
        );
    }

    /// Two identical models whose numeric serial is zero (as HP ships them) must still get
    /// distinct serials, or macOS refuses the second virtual display.
    #[test]
    fn zero_numeric_serial_falls_back_to_the_serial_text() {
        let with_text_serial = |serial: &[u8; 13]| {
            let mut e = sample();
            e[12..16].fill(0);
            e[90 + 3] = 0xff;
            e[90 + 5..90 + 18].copy_from_slice(serial);
            e[127] = 0;
            let sum = e.iter().fold(0u8, |s, b| s.wrapping_add(*b));
            e[127] = 0u8.wrapping_sub(sum);
            parse(&e).unwrap().serial
        };
        let first = with_text_serial(b"CN000000AA\n  ");
        let second = with_text_serial(b"CN000000BB\n  ");
        assert_ne!(first, 0);
        assert_ne!(first, second);
        assert_eq!(first, with_text_serial(b"CN000000AA\n  "), "stable across reads");
    }

    #[test]
    fn rejects_corrupt_blocks() {
        let mut bad = sample();
        bad[127] ^= 1;
        assert_eq!(parse(&bad), Err(EdidError::BadChecksum));
        assert_eq!(parse(&bad[..100]), Err(EdidError::TooShort(100)));
        let mut header = sample();
        header[1] = 0;
        assert_eq!(parse(&header), Err(EdidError::BadHeader));
    }

    #[test]
    fn rejects_zero_active_dimensions_even_with_nonzero_blanking() {
        for horizontal in [true, false] {
            let mut edid = sample();
            if horizontal {
                edid[54 + 2] = 0;
                edid[54 + 4] &= 0x0f;
            } else {
                edid[54 + 5] = 0;
                edid[54 + 7] &= 0x0f;
            }
            edid[127] = 0;
            edid[127] = 0u8.wrapping_sub(edid.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)));
            assert_eq!(parse(&edid), Err(EdidError::NoPreferredTiming));
        }
    }

    #[test]
    fn strips_control_characters_from_the_product_name() {
        let mut edid = sample();
        edid[72 + 5..72 + 18].copy_from_slice(b"HP\x01Z27\tk G3\n ");
        edid[127] = 0;
        edid[127] = 0u8.wrapping_sub(edid.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)));
        assert_eq!(parse(&edid).unwrap().name.as_deref(), Some("HPZ27k G3"));
    }

    #[test]
    fn rejects_timings_that_must_not_become_a_display() {
        let ok = Timing { width: 3840, height: 2160, refresh_hz: 60, pixel_clock_khz: 533_250 };
        assert!(acceptable_desktop_mode(&ok));
        assert!(!acceptable_desktop_mode(&Timing { width: 1, ..ok }));
        assert!(!acceptable_desktop_mode(&Timing { height: 8, ..ok }));
        assert!(!acceptable_desktop_mode(&Timing { refresh_hz: 0, ..ok }));
        assert!(!acceptable_desktop_mode(&Timing { refresh_hz: 655_350_000, ..ok }));
        assert!(!acceptable_desktop_mode(&Timing { width: 7680, height: 4320, ..ok }));
    }
}
