//! One H.264 stream decoded by VideoToolbox into IOSurface-backed NV12
//! pixel buffers that Metal can sample without a copy.
//!
//! The server sends Annex B access units with the SPS and PPS in front of
//! every IDR. VideoToolbox wants the parameter sets in a format description
//! and the slices length-prefixed (AVCC), so each unit is rewritten. Decode
//! runs synchronously: neither the asynchronous nor the temporal-processing
//! flag is set, so the output callback has run when `decode_frame` returns,
//! and frames come out in decode order, one per unit, with no reordering
//! delay (our streams have no B frames).

use std::ffi::c_void;
use std::ptr::{self, NonNull};
use std::sync::Mutex;

use objc2_core_foundation::{
    kCFAllocatorNull, kCFBooleanTrue, CFBoolean, CFDictionary, CFNumber, CFRetained, CFString,
    CFType,
};
use objc2_core_media::{
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMTime,
    CMVideoFormatDescriptionCreateFromH264ParameterSets,
};
use objc2_core_video::{
    kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey,
    kCVPixelBufferPixelFormatTypeKey, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    CVImageBuffer, CVPixelBuffer, CVPixelBufferGetPixelFormatType,
};
use objc2_video_toolbox::{
    kVTDecompressionPropertyKey_RealTime,
    kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder, VTDecodeFrameFlags,
    VTDecodeInfoFlags, VTDecompressionOutputCallbackRecord, VTDecompressionSession,
    VTSessionSetProperty,
};

use crate::{Error, Result};

const NAL_SLICE: u8 = 1;
const NAL_IDR: u8 = 5;
const NAL_SEI: u8 = 6;
const NAL_SPS: u8 = 7;
const NAL_PPS: u8 = 8;

/// The NAL units of an Annex B byte stream, start codes removed.
pub(crate) fn nal_units(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let ends: Vec<usize> = starts
        .iter()
        .skip(1)
        .map(|&s| {
            // The next start code is 00 00 01, possibly with a leading 00.
            let mut e = s - 3;
            while e > 0 && data[e - 1] == 0 {
                e -= 1;
            }
            e
        })
        .chain(std::iter::once(data.len()))
        .collect();
    starts
        .into_iter()
        .zip(ends)
        .filter(|(s, e)| s < e)
        .map(move |(s, e)| &data[s..e])
}

/// Where the output callback leaves the picture of the unit being decoded.
#[derive(Default)]
struct Slot {
    status: i32,
    picture: Option<CFRetained<CVPixelBuffer>>,
}

unsafe extern "C-unwind" fn on_output(
    refcon: *mut c_void,
    _frame_refcon: *mut c_void,
    status: i32,
    _flags: VTDecodeInfoFlags,
    image: *mut CVImageBuffer,
    _pts: CMTime,
    _duration: CMTime,
) {
    // SAFETY: `refcon` is the `Mutex<Slot>` boxed by the `Stream` that owns
    // the session; the session is invalidated before that box is freed.
    let slot = unsafe { &*(refcon as *const Mutex<Slot>) };
    let Ok(mut slot) = slot.lock() else { return };
    slot.status = status;
    // SAFETY: a non-null image is a valid pixel buffer for the duration of
    // the callback; retaining it keeps it alive past that.
    slot.picture = NonNull::new(image).map(|p| unsafe { CFRetained::retain(p) });
}

pub(crate) struct Stream {
    session: Option<CFRetained<VTDecompressionSession>>,
    format: Option<CFRetained<CMFormatDescription>>,
    sps: Vec<u8>,
    pps: Vec<u8>,
    slot: Box<Mutex<Slot>>,
}

impl Stream {
    pub(crate) fn new() -> Self {
        Self {
            session: None,
            format: None,
            sps: Vec::new(),
            pps: Vec::new(),
            slot: Box::default(),
        }
    }

    /// Decode one access unit. `None` while no parameter sets have arrived,
    /// or when the unit carries no slice.
    pub(crate) fn decode(&mut self, unit: &[u8]) -> Result<Option<CFRetained<CVPixelBuffer>>> {
        let mut avcc = Vec::with_capacity(unit.len() + 16);
        for nal in nal_units(unit) {
            match nal[0] & 0x1f {
                NAL_SPS => self.set_parameter_set(nal, true),
                NAL_PPS => self.set_parameter_set(nal, false),
                NAL_SLICE | NAL_IDR | NAL_SEI => {
                    avcc.extend_from_slice(&(nal.len() as u32).to_be_bytes());
                    avcc.extend_from_slice(nal);
                }
                _ => {}
            }
        }
        if !has_slice(&avcc) {
            return Ok(None);
        }
        if self.session.is_none() {
            if self.sps.is_empty() || self.pps.is_empty() {
                return Ok(None);
            }
            self.open()?;
        }
        let (Some(session), Some(format)) = (&self.session, &self.format) else {
            return Ok(None);
        };
        let sample = sample_buffer(&mut avcc, format)?;
        *self.slot.lock().map_err(|_| Error::Poisoned)? = Slot::default();
        let mut info = VTDecodeInfoFlags::empty();
        // SAFETY: the sample buffer points into `avcc`, which outlives the
        // call, and synchronous decode finishes before it returns.
        let status = unsafe {
            session.decode_frame(
                &sample,
                VTDecodeFrameFlags::empty(),
                ptr::null_mut(),
                &mut info,
            )
        };
        if status != 0 {
            // A session the system invalidated (after sleep, say) is
            // rebuilt from the stored parameter sets on the next unit.
            self.close();
            return Err(Error::Vt("decode", status));
        }
        let mut slot = self.slot.lock().map_err(|_| Error::Poisoned)?;
        if slot.status != 0 {
            return Err(Error::Vt("decoded frame", slot.status));
        }
        Ok(slot.picture.take())
    }

    /// Store a new SPS or PPS; a change makes the next unit open a new
    /// session (a new stream size, or a server restart).
    fn set_parameter_set(&mut self, nal: &[u8], sps: bool) {
        let current = if sps { &mut self.sps } else { &mut self.pps };
        if current.as_slice() != nal {
            *current = nal.to_vec();
            self.close();
        }
    }

    fn open(&mut self) -> Result<()> {
        let sets = [
            NonNull::from(self.sps.as_slice()).cast::<u8>(),
            NonNull::from(self.pps.as_slice()).cast::<u8>(),
        ];
        let sizes = [self.sps.len(), self.pps.len()];
        let mut format: *const CMFormatDescription = ptr::null();
        // SAFETY: two parameter sets with their sizes, 4-byte AVCC lengths,
        // and a valid out pointer.
        let status = unsafe {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                None,
                2,
                NonNull::from(&sets).cast(),
                NonNull::from(&sizes).cast(),
                4,
                NonNull::from(&mut format),
            )
        };
        let format = match NonNull::new(format.cast_mut()) {
            // SAFETY: a created object, returned at +1.
            Some(f) if status == 0 => unsafe { CFRetained::from_raw(f) },
            _ => return Err(Error::Vt("format description", status)),
        };

        let spec = CFDictionary::<CFString, CFType>::from_slices(
            // SAFETY: an immutable framework constant.
            &[unsafe { kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder }],
            &[true_value()],
        );
        let pixel_format =
            CFNumber::new_i32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as i32);
        let no_props = CFDictionary::<CFString, CFType>::empty();
        let attributes = CFDictionary::<CFString, CFType>::from_slices(
            // SAFETY: immutable framework constants.
            unsafe {
                &[
                    kCVPixelBufferPixelFormatTypeKey,
                    kCVPixelBufferMetalCompatibilityKey,
                    kCVPixelBufferIOSurfacePropertiesKey,
                ]
            },
            &[&pixel_format, true_value(), &no_props],
        );
        let callback = VTDecompressionOutputCallbackRecord {
            decompressionOutputCallback: Some(on_output),
            decompressionOutputRefCon: (&*self.slot as *const Mutex<Slot>).cast_mut().cast(),
        };
        let mut session: *mut VTDecompressionSession = ptr::null_mut();
        // SAFETY: valid dictionaries of the documented key and value types;
        // the callback's refcon outlives the session (see `close`).
        let status = unsafe {
            VTDecompressionSession::create(
                None,
                &format,
                Some(spec.as_opaque()),
                Some(attributes.as_opaque()),
                &callback,
                NonNull::from(&mut session),
            )
        };
        let session = match NonNull::new(session) {
            // SAFETY: a created object, returned at +1.
            Some(s) if status == 0 => unsafe { CFRetained::from_raw(s) },
            _ => return Err(Error::Vt("decompression session", status)),
        };
        // SAFETY: a session, a property key and a CFBoolean value.
        unsafe {
            VTSessionSetProperty(
                &session,
                kVTDecompressionPropertyKey_RealTime,
                Some(true_value()),
            );
        }
        self.format = Some(format);
        self.session = Some(session);
        Ok(())
    }

    fn close(&mut self) {
        if let Some(session) = self.session.take() {
            // SAFETY: tears down the session, so no callback can reach the
            // slot after this.
            unsafe { session.invalidate() };
        }
        self.format = None;
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        self.close();
    }
}

/// Whether a length-prefixed unit holds a slice (IDR or not).
fn has_slice(avcc: &[u8]) -> bool {
    let mut i = 0;
    while i + 4 < avcc.len() {
        let len = u32::from_be_bytes([avcc[i], avcc[i + 1], avcc[i + 2], avcc[i + 3]]) as usize;
        if matches!(avcc[i + 4] & 0x1f, NAL_SLICE | NAL_IDR) {
            return true;
        }
        i += 4 + len;
    }
    false
}

fn true_value() -> &'static CFType {
    // SAFETY: an immutable framework constant, never null.
    let t: &'static CFBoolean = unsafe { kCFBooleanTrue }.expect("kCFBooleanTrue");
    t
}

/// A one-sample buffer over `avcc` without copying it; the caller keeps
/// `avcc` alive until the decode returns.
fn sample_buffer(
    avcc: &mut [u8],
    format: &CMFormatDescription,
) -> Result<CFRetained<CMSampleBuffer>> {
    let mut block: *mut CMBlockBuffer = ptr::null_mut();
    // SAFETY: `kCFAllocatorNull` makes the block borrow `avcc` and never
    // free it; the out pointer is valid.
    let status = unsafe {
        CMBlockBuffer::create_with_memory_block(
            None,
            avcc.as_mut_ptr().cast(),
            avcc.len(),
            kCFAllocatorNull,
            ptr::null(),
            0,
            avcc.len(),
            0,
            NonNull::from(&mut block),
        )
    };
    let block = match NonNull::new(block) {
        // SAFETY: a created object, returned at +1.
        Some(b) if status == 0 => unsafe { CFRetained::from_raw(b) },
        _ => return Err(Error::Vt("block buffer", status)),
    };
    let size = avcc.len();
    let mut sample: *mut CMSampleBuffer = ptr::null_mut();
    // SAFETY: one sample of `size` bytes with no timing; valid out pointer.
    let status = unsafe {
        CMSampleBuffer::create_ready(
            None,
            Some(&block),
            Some(format),
            1,
            0,
            ptr::null(),
            1,
            &size,
            NonNull::from(&mut sample),
        )
    };
    match NonNull::new(sample) {
        // SAFETY: a created object, returned at +1.
        Some(s) if status == 0 => Ok(unsafe { CFRetained::from_raw(s) }),
        _ => Err(Error::Vt("sample buffer", status)),
    }
}

/// Whether a decoded picture is the NV12 layout the recombine reads.
pub(crate) fn is_nv12(picture: &CVPixelBuffer) -> bool {
    CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_annex_b_with_both_start_code_lengths() {
        let data = [
            0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5,
        ];
        let nals: Vec<&[u8]> = nal_units(&data).collect();
        assert_eq!(nals, vec![&[0x67, 1, 2][..], &[0x68, 3], &[0x65, 4, 5]]);
    }

    #[test]
    fn finds_slices_in_avcc() {
        assert!(has_slice(&[0, 0, 0, 2, 0x06, 9, 0, 0, 0, 1, 0x65]));
        assert!(!has_slice(&[0, 0, 0, 2, 0x06, 9]));
    }
}
