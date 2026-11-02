//! macOS matches its own shortcuts (Cmd+Space, Cmd+Tab, input-source
//! switching, Mission Control) before any app sees the key, so
//! `inhibit_system_shortcuts` has nothing to inhibit there and GTK never gets
//! them. While the picture has the keyboard, a HID-level event tap takes
//! every key ahead of that matching and posts it straight to this process,
//! where the key controller forwards it like any other key. Cmd+Opt+Esc and
//! secure input stay with macOS.

use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering::Relaxed};
use std::sync::Once;

type Ref = *mut c_void;
type Callback = extern "C" fn(Ref, u32, Ref, Ref) -> Ref;

const HID_TAP: u32 = 0;
const HEAD_INSERT: u32 = 0;
const DEFAULT_TAP: u32 = 0;
const KEY_DOWN: u32 = 10;
const KEY_UP: u32 = 11;
const FLAGS_CHANGED: u32 = 12;
const DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;
const USER_DATA_FIELD: u32 = 42;
/// Marks the copies this process posts to itself, so the tap lets them by.
const REPOSTED: i64 = 0x676c_6966;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events: u64,
        callback: Callback,
        info: Ref,
    ) -> Ref;
    fn CGEventTapEnable(tap: Ref, enable: bool);
    fn CGEventCreateCopy(event: Ref) -> Ref;
    fn CGEventGetIntegerValueField(event: Ref, field: u32) -> i64;
    fn CGEventSetIntegerValueField(event: Ref, field: u32, value: i64);
    fn CGEventPostToPid(pid: i32, event: Ref);
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFRunLoopCommonModes: Ref;
    fn CFMachPortCreateRunLoopSource(alloc: Ref, port: Ref, order: isize) -> Ref;
    fn CFRunLoopGetCurrent() -> Ref;
    fn CFRunLoopAddSource(run_loop: Ref, source: Ref, mode: Ref);
    fn CFRunLoopRun();
    fn CFRelease(object: Ref);
}

static CAPTURING: AtomicBool = AtomicBool::new(false);
static TAP: AtomicPtr<c_void> = AtomicPtr::new(null_mut());
static START: Once = Once::new();

/// Take the shortcuts macOS claims while the picture has the keyboard
/// (`true`), or leave them to macOS again.
pub fn capture(on: bool) {
    CAPTURING.store(on, Relaxed);
    if on {
        START.call_once(|| {
            std::thread::spawn(run);
        });
    }
}

fn run() {
    let events = (1 << KEY_DOWN) | (1 << KEY_UP) | (1 << FLAGS_CHANGED);
    // SAFETY: plain CoreGraphics/CoreFoundation calls; the tap and its
    // source live for the rest of the process on this thread's run loop.
    unsafe {
        let tap = CGEventTapCreate(
            HID_TAP,
            HEAD_INSERT,
            DEFAULT_TAP,
            events,
            on_event,
            null_mut(),
        );
        if tap.is_null() {
            tracing::error!(
                "could not tap the keyboard; shortcuts macOS claims stay on the Mac until Gliff has Accessibility permission"
            );
            return;
        }
        TAP.store(tap, Relaxed);
        let source = CFMachPortCreateRunLoopSource(null_mut(), tap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CFRunLoopRun();
    }
}

extern "C" fn on_event(_proxy: Ref, kind: u32, event: Ref, _info: Ref) -> Ref {
    // SAFETY: `event` is the live event the tap hands us; the copy is
    // released after posting.
    unsafe {
        if kind == DISABLED_BY_TIMEOUT || kind == DISABLED_BY_USER_INPUT {
            CGEventTapEnable(TAP.load(Relaxed), true);
            return event;
        }
        if !CAPTURING.load(Relaxed)
            || CGEventGetIntegerValueField(event, USER_DATA_FIELD) == REPOSTED
        {
            return event;
        }
        let copy = CGEventCreateCopy(event);
        CGEventSetIntegerValueField(copy, USER_DATA_FIELD, REPOSTED);
        CGEventPostToPid(std::process::id() as i32, copy);
        CFRelease(copy);
    }
    null_mut()
}
