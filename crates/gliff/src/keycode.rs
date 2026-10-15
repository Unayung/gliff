//! The evdev code the server expects for a local key, from GDK's hardware
//! keycode. On Linux that is the xkb keycode, evdev plus 8. On macOS it is
//! the virtual keycode (`kVK_*`), which names a physical position on an ANSI
//! keyboard, so it maps to the evdev key at the same position: Command is
//! Super, Option is Alt.

/// Caps Lock's evdev code. macOS reports Caps Lock as a toggle (press when
/// it turns on, release when it turns off), not as a key going down and up.
pub const CAPS_LOCK: u32 = 58;

/// The evdev code for a GDK hardware keycode, or `None` for a key the remote
/// has no use for.
#[cfg(not(target_os = "macos"))]
pub fn evdev(hardware: u32) -> Option<u32> {
    hardware.checked_sub(8)
}

#[cfg(target_os = "macos")]
pub fn evdev(hardware: u32) -> Option<u32> {
    MAC_TO_EVDEV
        .get(hardware as usize)
        .copied()
        .filter(|&code| code != 0)
}

/// Indexed by macOS virtual keycode; 0 means no evdev counterpart.
#[cfg(any(target_os = "macos", test))]
#[rustfmt::skip]
const MAC_TO_EVDEV: [u32; 0x80] = [
    // 0x00 A S D F H G Z X
    30, 31, 32, 33, 35, 34, 44, 45,
    // 0x08 C V ISO§ B Q W E R
    46, 47, 86, 48, 16, 17, 18, 19,
    // 0x10 Y T 1 2 3 4 6 5
    21, 20, 2, 3, 4, 5, 7, 6,
    // 0x18 = 9 7 - 8 0 ] O
    13, 10, 8, 12, 9, 11, 27, 24,
    // 0x20 U [ I P Return L J '
    22, 26, 23, 25, 28, 38, 36, 40,
    // 0x28 K ; \ , / N M .
    37, 39, 43, 51, 53, 49, 50, 52,
    // 0x30 Tab Space ` Backspace - Escape RightCmd Cmd
    15, 57, 41, 14, 0, 1, 126, 125,
    // 0x38 Shift CapsLock Option Control RightShift RightOption RightControl Fn
    42, 58, 56, 29, 54, 100, 97, 0,
    // 0x40 F17 KP. - KP* - KP+ - Clear(NumLock)
    187, 83, 0, 55, 0, 78, 0, 69,
    // 0x48 VolUp VolDown Mute KP/ KPEnter - KP- F18
    115, 114, 113, 98, 96, 0, 74, 188,
    // 0x50 F19 KP= KP0 KP1 KP2 KP3 KP4 KP5
    189, 117, 82, 79, 80, 81, 75, 76,
    // 0x58 KP6 KP7 F20 KP8 KP9 JIS¥ JIS_ JIS KP,
    77, 71, 190, 72, 73, 124, 89, 95,
    // 0x60 F5 F6 F7 F3 F8 F9 JIS Eisu F11
    63, 64, 65, 61, 66, 67, 123, 87,
    // 0x68 JIS Kana F13 F16 F14 - F10 Menu F12
    122, 183, 186, 184, 0, 68, 127, 88,
    // 0x70 - F15 Help(Insert) Home PageUp ForwardDelete F4 End
    0, 185, 110, 102, 104, 111, 62, 107,
    // 0x78 F2 PageDown F1 Left Right Down Up -
    60, 109, 59, 105, 106, 108, 103, 0,
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_table_is_injective() {
        let mut seen = std::collections::HashSet::new();
        for &code in MAC_TO_EVDEV.iter().filter(|&&c| c != 0) {
            assert!(seen.insert(code), "evdev {code} mapped twice");
        }
    }

    #[test]
    fn mac_table_spot_checks() {
        // kVK_ANSI_A, kVK_Return, kVK_Command, kVK_Option, kVK_UpArrow.
        assert_eq!(MAC_TO_EVDEV[0x00], 30);
        assert_eq!(MAC_TO_EVDEV[0x24], 28);
        assert_eq!(MAC_TO_EVDEV[0x37], 125);
        assert_eq!(MAC_TO_EVDEV[0x3A], 56);
        assert_eq!(MAC_TO_EVDEV[0x7E], 103);
        assert_eq!(MAC_TO_EVDEV[0x39], CAPS_LOCK);
    }
}
