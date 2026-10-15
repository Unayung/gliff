//! The pipeline against the CPU tier and the CPU reference: real Dual420 and
//! Single420 streams from `gliff_sw::Encoder`, decoded by VideoToolbox and
//! recombined in Metal.

use gliff_proto::chroma::{nv12_to_yuv444, recombine_yuv444, Nv12};
use gliff_proto::color::yuv444_to_bgra;
use gliff_sw::{Encoder, EncoderSettings};
use objc2_core_video::{
    CVPixelBuffer, CVPixelBufferGetBaseAddressOfPlane, CVPixelBufferGetBytesPerRowOfPlane,
    CVPixelBufferLockBaseAddress, CVPixelBufferLockFlags, CVPixelBufferUnlockBaseAddress,
};

use crate::{Decoder, Gpu};

/// A frame with what blurs first under 4:2:0: one-pixel coloured strokes on
/// a gradient, shifted per frame so P frames carry motion.
fn test_frame(w: usize, h: usize, t: usize) -> Vec<u8> {
    let mut px = vec![0u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            let (mut b, mut g, mut r) = ((x * 255 / w) as u8, (y * 255 / h) as u8, 96u8);
            let xs = x + t * 3;
            if (xs / 2 + y / 7).is_multiple_of(5) {
                (b, g, r) = (20, 30, 230);
            }
            if xs.is_multiple_of(11) && !y.is_multiple_of(3) {
                (b, g, r) = (240, 40, 10);
            }
            px[i..i + 4].copy_from_slice(&[b, g, r, 255]);
        }
    }
    px
}

/// The visible `w` x `h` part of a decoded NV12 picture, tightly packed.
fn planes(picture: &CVPixelBuffer, w: usize, h: usize) -> Nv12 {
    let mut out = Nv12::new(w, h);
    // SAFETY: a locked pixel buffer's planes are readable at their base
    // addresses for `bytes_per_row * rows` bytes; we read inside that.
    unsafe {
        assert_eq!(
            CVPixelBufferLockBaseAddress(picture, CVPixelBufferLockFlags::ReadOnly),
            0
        );
        for (plane, dst, rows) in [(0, &mut out.y, h), (1, &mut out.uv, h / 2)] {
            let base = CVPixelBufferGetBaseAddressOfPlane(picture, plane).cast::<u8>();
            let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, plane);
            for row in 0..rows {
                let src = std::slice::from_raw_parts(base.add(row * stride), w);
                dst[row * w..row * w + w].copy_from_slice(src);
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, CVPixelBufferLockFlags::ReadOnly);
    }
    out
}

fn run(dual: bool, w: u32, h: u32) {
    let gpu = Gpu::open().expect("metal device");
    let settings = EncoderSettings {
        width: w,
        height: h,
        bitrate: 20_000_000,
        framerate: 60,
    };
    let mut enc = Encoder::new(settings, dual).expect("encoder");
    let mut cpu = gliff_sw::Decoder::new(dual).expect("cpu decoder");
    let mut dec = Decoder::new(&gpu, dual, w, h).expect("decoder");
    let (wu, hu) = (w as usize, h as usize);
    let mut frames = 0;
    let mut compared = 0;
    for t in 0..8 {
        let src = test_frame(wu, hu, t);
        let unit = enc.encode_bgra(&src, t == 0).expect("encode");
        let aux = unit.aux.clone().unwrap_or_default();
        let ours = dec.decode(&unit.main, &aux).expect("decode");
        let Some(ours) = ours else { continue };
        frames += 1;
        assert_eq!((ours.width, ours.height), (w, h));

        // The kernel against the CPU reference on the very planes it read.
        let (main_pic, aux_pic) = dec.last.as_ref().expect("last pair");
        let main = planes(main_pic, wu, hu);
        let yuv = match aux_pic {
            Some(a) => recombine_yuv444(&main, &planes(a, wu, hu)),
            None => nv12_to_yuv444(&main),
        };
        let reference = yuv444_to_bgra(&yuv);
        let mismatched = ours
            .as_ref()
            .chunks_exact(4)
            .zip(reference.chunks_exact(4))
            .filter(|(p, q)| p[..3] != q[..3])
            .inspect(|(p, q)| {
                assert!(
                    (0..3).all(|c| p[c].abs_diff(q[c]) <= 1),
                    "frame {t}: {p:?} vs {q:?}"
                )
            })
            .count();
        assert_eq!(
            mismatched, 0,
            "frame {t}: kernel differs from the reference"
        );

        // H.264 decode is bit-exact, so the CPU tier sees the same picture,
        // up to its fixed-point convert.
        if let Some(theirs) = cpu.decode(&unit.main, &aux).expect("cpu decode") {
            compared += 1;
            let worst = ours
                .as_ref()
                .chunks_exact(4)
                .zip(theirs.pixels.chunks_exact(4))
                .flat_map(|(p, q)| (0..3).map(move |c| p[c].abs_diff(q[c])))
                .max()
                .unwrap_or(0);
            assert!(worst <= 2, "frame {t}: CPU tier differs by {worst}");
        }
    }
    assert!(frames >= 7, "only {frames} of 8 frames decoded");
    assert!(
        compared >= 6,
        "only {compared} frames compared with the CPU tier"
    );
}

#[test]
fn dual420_matches_reference() {
    run(true, 1280, 720);
}

#[test]
fn single420_matches_reference() {
    run(false, 640, 368);
}

#[test]
fn zoom_writes_blocks() {
    let gpu = Gpu::open().expect("metal device");
    let (w, h) = (320u32, 192u32);
    let settings = EncoderSettings {
        width: w,
        height: h,
        bitrate: 8_000_000,
        framerate: 60,
    };
    let mut enc = Encoder::new(settings, true).expect("encoder");
    let mut dec = Decoder::new(&gpu, true, w, h).expect("decoder");
    let unit = enc
        .encode_bgra(&test_frame(w as usize, h as usize, 0), true)
        .expect("encode");
    let one = dec
        .decode(&unit.main, unit.aux.as_deref().unwrap_or_default())
        .expect("decode")
        .expect("a picture");
    assert_eq!(dec.set_zoom(2).expect("zoom"), 2);
    let two = dec.redraw().expect("redraw").expect("a picture");
    assert_eq!((two.width, two.height), (2 * w, 2 * h));
    let (a, b) = (one.as_ref(), two.as_ref());
    for (y, x) in [(0usize, 0usize), (17, 33), (191, 319)] {
        let src = &a[(y * w as usize + x) * 4..][..4];
        for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            let at = ((2 * y + dy) * 2 * w as usize + 2 * x + dx) * 4;
            assert_eq!(&b[at..at + 4], src, "pixel {x},{y} block {dx},{dy}");
        }
    }
}
