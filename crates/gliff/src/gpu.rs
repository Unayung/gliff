//! The GPU decode tier, per platform: VA-API decode with the recombine in
//! Vulkan compute on Linux (`gliff_vk`), VideoToolbox decode with the
//! recombine in Metal on macOS (`gliff_mac`). Elsewhere there is no GPU
//! tier, so `open` fails and the worker decodes on the CPU.

#[cfg(target_os = "linux")]
pub use gliff_vk::{Decoder, DisplayFrame, Gpu};

/// Open the GPU the compositor renders on.
#[cfg(target_os = "linux")]
pub fn open() -> Result<std::sync::Arc<Gpu>, gliff_vk::Error> {
    Gpu::open(Some(&hypr_capture::render_node(None)))
}

#[cfg(target_os = "macos")]
pub use gliff_mac::{Decoder, DisplayFrame, Gpu};

/// Open the system's default Metal device.
#[cfg(target_os = "macos")]
pub fn open() -> Result<std::sync::Arc<Gpu>, gliff_mac::Error> {
    Gpu::open()
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub use none::{open, Decoder, DisplayFrame, Gpu};

/// Stand-ins that can never be constructed, so the worker's GPU paths
/// compile and are statically dead.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod none {
    use std::convert::Infallible;
    use std::sync::Arc;

    #[derive(Debug, thiserror::Error)]
    #[error("no GPU video pipeline on this platform")]
    pub struct Unsupported;

    pub struct Gpu {
        pub name: String,
        never: Infallible,
    }

    impl Gpu {
        pub fn can_decode(&self) -> bool {
            match self.never {}
        }
    }

    pub fn open() -> Result<Arc<Gpu>, Unsupported> {
        Err(Unsupported)
    }

    pub enum DisplayFrame {}

    pub struct Decoder(Infallible);

    impl Decoder {
        pub fn new(gpu: &Arc<Gpu>, _dual: bool, _w: u32, _h: u32) -> Result<Self, Unsupported> {
            match gpu.never {}
        }

        pub fn zoom(&self) -> u32 {
            match self.0 {}
        }

        pub fn set_zoom(&mut self, _zoom: u32) -> Result<u32, Unsupported> {
            match self.0 {}
        }

        pub fn redraw(&mut self) -> Result<Option<DisplayFrame>, Unsupported> {
            match self.0 {}
        }

        pub fn decode(
            &mut self,
            _main: &[u8],
            _aux: &[u8],
        ) -> Result<Option<DisplayFrame>, Unsupported> {
            match self.0 {}
        }
    }
}
