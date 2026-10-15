//! The decode pipeline: two VideoToolbox streams into NV12 pixel buffers,
//! the AVC444 recombine and BT.709 convert in a Metal compute kernel that
//! samples them in place, and BGRX frames in shared memory for the UI.

use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::{Arc, Mutex};

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::CFRetained;
use objc2_core_video::{
    CVMetalTexture, CVMetalTextureCache, CVMetalTextureGetTexture, CVPixelBuffer,
    CVPixelBufferGetHeightOfPlane, CVPixelBufferGetWidthOfPlane,
};
use objc2_foundation::NSString;
use objc2_metal::{
    MTLBuffer, MTLCommandBuffer, MTLCommandBufferStatus, MTLCommandEncoder, MTLCommandQueue,
    MTLCompileOptions, MTLComputeCommandEncoder, MTLComputePipelineState,
    MTLCreateSystemDefaultDevice, MTLDevice, MTLLibrary, MTLMathMode, MTLPixelFormat,
    MTLResourceOptions, MTLSize, MTLTexture,
};

use crate::vt::{self, Stream};
use crate::{Error, Result};

const RECOMBINE_MSL: &str = include_str!("recombine.metal");

/// Frames the UI may hold at once before the decoder allocates more; a
/// buffer the UI returns is reused while the frame size is unchanged.
const POOL_KEEP: usize = 4;

/// The Metal device, its queue and the compiled recombine.
pub struct Gpu {
    pub name: String,
    device: Retained<ProtocolObject<dyn MTLDevice>>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    recombine: Retained<ProtocolObject<dyn MTLComputePipelineState>>,
}

/// A Metal view of one plane of a decoded picture, with the CoreVideo
/// object that must outlive the GPU work sampling it.
type Plane = (
    CFRetained<CVMetalTexture>,
    Retained<ProtocolObject<dyn MTLTexture>>,
);

impl Gpu {
    pub fn open() -> Result<Arc<Self>> {
        let device = MTLCreateSystemDefaultDevice().ok_or(Error::NoDevice)?;
        let queue = device
            .newCommandQueue()
            .ok_or_else(|| Error::Metal("no command queue".into()))?;
        // Safe math: the convert must round exactly as the CPU reference in
        // `gliff_proto::color`, with no reassociation or fused multiplies.
        let options = MTLCompileOptions::new();
        options.setMathMode(MTLMathMode::Safe);
        let library = device
            .newLibraryWithSource_options_error(&NSString::from_str(RECOMBINE_MSL), Some(&options))
            .map_err(|e| Error::Metal(format!("compile recombine: {e}")))?;
        let function = library
            .newFunctionWithName(&NSString::from_str("recombine"))
            .ok_or_else(|| Error::Metal("no recombine function".into()))?;
        let recombine = device
            .newComputePipelineStateWithFunction_error(&function)
            .map_err(|e| Error::Metal(format!("recombine pipeline: {e}")))?;
        Ok(Arc::new(Self {
            name: device.name().to_string(),
            device,
            queue,
            recombine,
        }))
    }

    /// Every Apple GPU Metal runs on has a hardware H.264 decoder; a stream
    /// it cannot take fails its session, and the worker falls back then.
    pub fn can_decode(&self) -> bool {
        true
    }
}

/// A Metal view of one plane of a decoded picture, through `cache`.
fn plane(
    cache: &CVMetalTextureCache,
    picture: &CVPixelBuffer,
    plane: usize,
    format: MTLPixelFormat,
) -> Result<Plane> {
    let (w, h) = (
        CVPixelBufferGetWidthOfPlane(picture, plane),
        CVPixelBufferGetHeightOfPlane(picture, plane),
    );
    let mut texture: *mut CVMetalTexture = std::ptr::null_mut();
    // SAFETY: an IOSurface-backed pixel buffer, a plane it has, its
    // size, a format of the same texel width, and a valid out pointer.
    let status = unsafe {
        CVMetalTextureCache::create_texture_from_image(
            None,
            cache,
            picture,
            None,
            format,
            w,
            h,
            plane,
            NonNull::from(&mut texture),
        )
    };
    let cv = match NonNull::new(texture) {
        // SAFETY: a created object, returned at +1.
        Some(t) if status == 0 => unsafe { CFRetained::from_raw(t) },
        _ => return Err(Error::Vt("plane texture", status)),
    };
    let mtl = CVMetalTextureGetTexture(&cv)
        .ok_or_else(|| Error::Metal("pixel buffer plane has no texture".into()))?;
    Ok((cv, mtl))
}

/// Shared-memory buffers the frames are written into, recycled when the UI
/// drops a frame of the current size.
#[derive(Default)]
struct Pool {
    len: usize,
    free: Vec<Retained<ProtocolObject<dyn MTLBuffer>>>,
}

/// A decoded frame: packed BGRX, `stride` bytes per row, in a buffer the
/// GPU has finished writing. Dropping it returns the buffer to the decoder.
pub struct DisplayFrame {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub zoom: u32,
    buffer: Option<Retained<ProtocolObject<dyn MTLBuffer>>>,
    len: usize,
    pool: Arc<Mutex<Pool>>,
}

// SAFETY: the GPU work writing the buffer completed before the frame was
// made, and nothing writes it again until the frame drops and returns it to
// the pool; reading shared-storage contents from any thread is then sound.
unsafe impl Send for DisplayFrame {}

impl AsRef<[u8]> for DisplayFrame {
    fn as_ref(&self) -> &[u8] {
        let Some(buffer) = &self.buffer else {
            return &[];
        };
        // SAFETY: a shared-storage buffer of at least `len` bytes whose GPU
        // writes are complete (see the `Send` impl).
        unsafe { std::slice::from_raw_parts(buffer.contents().as_ptr().cast::<u8>(), self.len) }
    }
}

impl Drop for DisplayFrame {
    fn drop(&mut self) {
        let Some(buffer) = self.buffer.take() else {
            return;
        };
        if let Ok(mut pool) = self.pool.lock() {
            if pool.len == self.len && pool.free.len() < POOL_KEEP {
                pool.free.push(buffer);
            }
        }
    }
}

#[repr(C)]
struct Params {
    width: i32,
    height: i32,
    has_aux: i32,
    zoom: i32,
    /// Output row length in pixels.
    stride: u32,
}

pub struct Decoder {
    gpu: Arc<Gpu>,
    /// Maps decoded pixel buffers to textures. Per decoder: CoreVideo does
    /// not promise it may be shared across threads.
    cache: CFRetained<CVMetalTextureCache>,
    main: Stream,
    aux: Option<Stream>,
    width: u32,
    height: u32,
    zoom: u32,
    pool: Arc<Mutex<Pool>>,
    /// The last complete picture pair, for `redraw`.
    pub(crate) last: Option<(CFRetained<CVPixelBuffer>, Option<CFRetained<CVPixelBuffer>>)>,
}

impl Decoder {
    pub fn new(gpu: &Arc<Gpu>, dual: bool, width: u32, height: u32) -> Result<Self> {
        let mut cache: *mut CVMetalTextureCache = std::ptr::null_mut();
        // SAFETY: a valid device and out pointer; no attributes.
        let status = unsafe {
            CVMetalTextureCache::create(None, None, &gpu.device, None, NonNull::from(&mut cache))
        };
        let cache = match NonNull::new(cache) {
            // SAFETY: a created object, returned at +1.
            Some(c) if status == 0 => unsafe { CFRetained::from_raw(c) },
            _ => return Err(Error::Vt("metal texture cache", status)),
        };
        Ok(Self {
            gpu: gpu.clone(),
            cache,
            main: Stream::new(),
            aux: dual.then(Stream::new),
            width,
            height,
            zoom: 1,
            pool: Arc::default(),
            last: None,
        })
    }

    /// Write each stream pixel as a `zoom` x `zoom` block, so the display
    /// side shows the frame at that integer scale with no resampling.
    /// Returns the zoom in effect, capped to keep a frame under 16384 px.
    pub fn set_zoom(&mut self, zoom: u32) -> Result<u32> {
        let cap = (16384 / self.width.max(1)).min(16384 / self.height.max(1));
        self.zoom = zoom.clamp(1, cap.max(1));
        Ok(self.zoom)
    }

    pub fn zoom(&self) -> u32 {
        self.zoom
    }

    /// Recombine the last decoded picture again, as after a zoom change on
    /// a still screen. `None` before the first complete picture.
    pub fn redraw(&mut self) -> Result<Option<DisplayFrame>> {
        let Some((main, aux)) = &self.last else {
            return Ok(None);
        };
        self.recombine(main, aux.as_deref()).map(Some)
    }

    /// Decode one access unit pair and recombine to a display frame. Blocks
    /// until the frame is complete. `None` when the unit had no picture.
    pub fn decode(&mut self, main: &[u8], aux: &[u8]) -> Result<Option<DisplayFrame>> {
        // Both streams are fed every unit so the pair stays in step.
        let main_pic = self.main.decode(main);
        let aux_pic = self.aux.as_mut().map(|s| s.decode(aux)).transpose();
        let (main_pic, aux_pic) = (main_pic?, aux_pic?);
        let pair = match (main_pic, aux_pic) {
            (Some(m), None) if self.aux.is_none() => (m, None),
            (Some(m), Some(Some(a))) => (m, Some(a)),
            (None, None | Some(None)) => return Ok(None),
            _ => {
                self.last = None;
                return Err(Error::Unsupported(
                    "main and aux streams fell out of step".into(),
                ));
            }
        };
        if !vt::is_nv12(&pair.0) || pair.1.as_deref().is_some_and(|a| !vt::is_nv12(a)) {
            return Err(Error::Unsupported("decoder output is not NV12".into()));
        }
        let frame = self.recombine(&pair.0, pair.1.as_deref())?;
        self.last = Some(pair);
        Ok(Some(frame))
    }

    fn recombine(&self, main: &CVPixelBuffer, aux: Option<&CVPixelBuffer>) -> Result<DisplayFrame> {
        let gpu = &self.gpu;
        let (w, h) = (self.width * self.zoom, self.height * self.zoom);
        let len = w as usize * h as usize * 4;
        let buffer = self.take_buffer(len)?;

        let cache = &self.cache;
        let main_y = plane(cache, main, 0, MTLPixelFormat::R8Uint)?;
        let main_uv = plane(cache, main, 1, MTLPixelFormat::RG8Uint)?;
        let aux_planes = match aux {
            Some(a) => Some((
                plane(cache, a, 0, MTLPixelFormat::R8Uint)?,
                plane(cache, a, 1, MTLPixelFormat::RG8Uint)?,
            )),
            None => None,
        };
        // A kernel without aux still has the slots bound; main stands in.
        let (aux_y, aux_uv) = match &aux_planes {
            Some((y, uv)) => (&y.1, &uv.1),
            None => (&main_y.1, &main_uv.1),
        };
        let params = Params {
            width: self.width as i32,
            height: self.height as i32,
            has_aux: aux.is_some() as i32,
            zoom: self.zoom as i32,
            stride: w,
        };

        let cmd = gpu
            .queue
            .commandBuffer()
            .ok_or_else(|| Error::Metal("no command buffer".into()))?;
        let enc = cmd
            .computeCommandEncoder()
            .ok_or_else(|| Error::Metal("no compute encoder".into()))?;
        enc.setComputePipelineState(&gpu.recombine);
        // SAFETY: the textures, buffer and parameters match the kernel's
        // bindings, and every resource outlives `waitUntilCompleted`.
        unsafe {
            enc.setTexture_atIndex(Some(&main_y.1), 0);
            enc.setTexture_atIndex(Some(&main_uv.1), 1);
            enc.setTexture_atIndex(Some(aux_y), 2);
            enc.setTexture_atIndex(Some(aux_uv), 3);
            enc.setBuffer_offset_atIndex(Some(&buffer), 0, 0);
            enc.setBytes_length_atIndex(
                NonNull::from(&params).cast::<c_void>(),
                std::mem::size_of::<Params>(),
                1,
            );
        }
        // One thread per 2x2 block of the stream.
        enc.dispatchThreads_threadsPerThreadgroup(
            MTLSize {
                width: (self.width / 2) as usize,
                height: (self.height / 2) as usize,
                depth: 1,
            },
            MTLSize {
                width: 16,
                height: 16,
                depth: 1,
            },
        );
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
        if cmd.status() != MTLCommandBufferStatus::Completed {
            let why = cmd.error().map(|e| e.to_string()).unwrap_or_default();
            return Err(Error::Metal(format!("recombine failed: {why}")));
        }
        drop((main_y, main_uv, aux_planes));
        cache.flush(0);
        Ok(DisplayFrame {
            width: w,
            height: h,
            stride: w as usize * 4,
            zoom: self.zoom,
            buffer: Some(buffer),
            len,
            pool: self.pool.clone(),
        })
    }

    fn take_buffer(&self, len: usize) -> Result<Retained<ProtocolObject<dyn MTLBuffer>>> {
        if let Ok(mut pool) = self.pool.lock() {
            if pool.len != len {
                *pool = Pool {
                    len,
                    free: Vec::new(),
                };
            }
            if let Some(buffer) = pool.free.pop() {
                return Ok(buffer);
            }
        }
        self.gpu
            .device
            .newBufferWithLength_options(len, MTLResourceOptions::StorageModeShared)
            .ok_or_else(|| Error::Metal(format!("cannot allocate a {len}-byte frame")))
    }
}
