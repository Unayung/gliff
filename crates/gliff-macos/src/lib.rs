//! Native macOS UI, display capture and input over the existing Gliff wire.
#![forbid(unsafe_code)]

pub mod discovery;
pub mod keys;
pub mod native;

#[cfg(any(target_os = "macos", test))]
mod encoder;
#[cfg(any(target_os = "macos", test))]
mod host_bridge;

#[cfg(any(target_os = "macos", test))]
mod client;
#[cfg(any(target_os = "macos", test))]
mod clipboard;
#[cfg(target_os = "macos")]
mod server;
#[cfg(target_os = "macos")]
mod stream;
// The Linux server's link estimator and rate controller: pure logic, shared
// so both hosts adapt the same way.
#[cfg(target_os = "macos")]
#[allow(dead_code)]
#[path = "../../gliff-server/src/rate.rs"]
mod rate;

#[cfg(target_os = "macos")]
pub use client::client_main;
#[cfg(target_os = "macos")]
pub use server::server_main;
