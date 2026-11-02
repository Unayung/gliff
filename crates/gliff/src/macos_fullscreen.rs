//! macOS fullscreen covers the remote's own top bar. A native fullscreen
//! window slides the menu bar and its title bar over the top edge when the
//! pointer touches it, and even with both hidden it keeps a reveal zone
//! across the top ~29 pt that swallows pointer motion for most of a second.
//!
//! The fullscreen button therefore fills the screen without a fullscreen
//! Space: a borderless window over the area below the camera housing, with
//! the menu bar and Dock hidden, has no such zone. Native fullscreen, from
//! the green title-bar button, still works, with the menu bar kept hidden:
//! GTK's window is its own NSWindow delegate, so its class is given
//! `window:willUseFullScreenPresentationOptions:`.

use std::cell::Cell;
use std::ffi::{c_char, c_void};

use objc2::runtime::AnyObject;
use objc2::{class, msg_send};
use objc2_foundation::{NSEdgeInsets, NSRect};

type Id = *mut c_void;
type Sel = *const c_void;

#[link(name = "objc")]
extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    fn class_addMethod(class: Id, sel: Sel, imp: *const c_void, types: *const c_char) -> i8;
}

const AUTO_HIDE_DOCK: usize = 1 << 0;
const HIDE_DOCK: usize = 1 << 1;
const AUTO_HIDE_MENU_BAR: usize = 1 << 2;
const HIDE_MENU_BAR: usize = 1 << 3;
const STYLE_BORDERLESS: usize = 0;
const STYLE_FULL_SCREEN: usize = 1 << 14;

thread_local! {
    /// The window's style and frame before `set(true)`, to restore.
    static SAVED: Cell<Option<(usize, NSRect)>> = const { Cell::new(None) };
}

extern "C" fn presentation_options(_this: Id, _cmd: Sel, _window: Id, proposed: usize) -> usize {
    // AppKit only allows a hidden menu bar together with a hidden Dock.
    (proposed & !(AUTO_HIDE_DOCK | AUTO_HIDE_MENU_BAR)) | HIDE_DOCK | HIDE_MENU_BAR
}

/// Keep the menu bar hidden while a GTK window is fullscreen. Call once.
pub fn hide_menu_bar_in_fullscreen() {
    // SAFETY: Objective-C runtime calls with static C strings; the method
    // signature (`Q@:@Q`) matches `presentation_options`.
    unsafe {
        let class = objc_getClass(c"GdkMacosWindow".as_ptr());
        if class.is_null() {
            tracing::warn!("no GdkMacosWindow class; the menu bar shows in fullscreen");
            return;
        }
        let sel = sel_registerName(c"window:willUseFullScreenPresentationOptions:".as_ptr());
        let imp = presentation_options as *const c_void;
        if class_addMethod(class, sel, imp, c"Q@:@Q".as_ptr()) == 0 {
            tracing::warn!("GTK already sets fullscreen presentation options");
        }
    }
}

/// Fill the screen below the camera housing (`true`), or restore the window.
/// Runs on the main thread, from the fullscreen button.
pub fn set(on: bool) {
    // SAFETY: AppKit messages on the main thread, with the argument and
    // return types the selectors declare.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let mut window: *mut AnyObject = msg_send![app, keyWindow];
        if window.is_null() {
            window = msg_send![app, mainWindow];
        }
        let Some(window) = window.as_ref() else {
            return;
        };
        let style: usize = msg_send![window, styleMask];
        if style & STYLE_FULL_SCREEN != 0 {
            // Native fullscreen, entered from the green button.
            return;
        }
        match (on, SAVED.get()) {
            (true, None) => {
                let screen: *mut AnyObject = msg_send![window, screen];
                let Some(screen) = screen.as_ref() else {
                    return;
                };
                let frame: NSRect = msg_send![window, frame];
                SAVED.set(Some((style, frame)));
                let mut area: NSRect = msg_send![screen, frame];
                let insets: NSEdgeInsets = msg_send![screen, safeAreaInsets];
                area.size.height -= insets.top;
                let _: () = msg_send![app, setPresentationOptions: HIDE_DOCK | HIDE_MENU_BAR];
                let _: () = msg_send![window, setStyleMask: STYLE_BORDERLESS];
                let _: () = msg_send![window, setFrame: area, display: true];
            }
            (false, Some((style, frame))) => {
                SAVED.set(None);
                let _: () = msg_send![window, setStyleMask: style];
                let _: () = msg_send![window, setFrame: frame, display: true];
                let _: () = msg_send![app, setPresentationOptions: 0usize];
            }
            _ => {}
        }
    }
}
