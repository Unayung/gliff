//! macOS media pipeline for the client: H.264 decode in VideoToolbox, the
//! AVC444 recombine as a Metal compute kernel, and BGRX frames in shared
//! memory for GTK. The counterpart of `gliff-vk`'s decode side, with the
//! same `Gpu` / `Decoder` / `DisplayFrame` shape.
//!
//! Framework calls use `unsafe` through the objc2 bindings. Callers see
//! plain Rust types. Empty on other platforms.
#![cfg(target_os = "macos")]

mod decode;
mod vt;

#[cfg(test)]
mod tests;

pub use decode::{Decoder, DisplayFrame, Gpu};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("no Metal device")]
    NoDevice,
    #[error("metal: {0}")]
    Metal(String),
    /// A VideoToolbox, CoreMedia or CoreVideo call failed with this status.
    #[error("{0} failed (OSStatus {1})")]
    Vt(&'static str, i32),
    #[error("unsupported: {0}")]
    Unsupported(String),
    #[error("decoder state poisoned")]
    Poisoned,
}

pub type Result<T> = std::result::Result<T, Error>;
