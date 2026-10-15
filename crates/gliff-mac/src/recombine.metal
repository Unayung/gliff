// AVC444 recombine: main + aux NV12 -> BGRX, with the YUV->RGB convert
// folded in. The Metal twin of gliff-vk's recombine.comp, and the inverse
// of its split.comp; with has_aux == 0 the main chroma is duplicated over
// each 2x2 block (the Single420 path). Each source pixel is written as a
// zoom x zoom block, so the display side can show the frame at an integer
// scale without resampling. Planes are read as integers and the convert
// rounds as gliff-proto::color does, so the output matches the CPU
// reference exactly.
#include <metal_stdlib>
// No fused multiply-adds: the CPU reference rounds every product.
#pragma METAL fp contract(off)
using namespace metal;

struct Params {
    int width;
    int height;
    int has_aux;
    int zoom;
    uint stride; // output row length in pixels
};

// BT.709 limited range, matching gliff-proto::color::yuv444_to_bgra.
static uchar4 to_bgrx(uint y8, uint u8, uint v8) {
    float y = float(y8) - 16.0;
    float cb = float(u8) - 128.0;
    float cr = float(v8) - 128.0;
    float r = 1.1644 * y + 1.7927 * cr;
    float g = 1.1644 * y - 0.2132 * cb - 0.5329 * cr;
    float b = 1.1644 * y + 2.1124 * cb;
    float3 c = clamp(round(float3(b, g, r)), 0.0, 255.0);
    return uchar4(uchar(c.x), uchar(c.y), uchar(c.z), 255);
}

static void store(device uchar4 *dst, constant Params &p, int x, int y, uchar4 px) {
    for (int j = 0; j < p.zoom; j++) {
        uint row = uint(y * p.zoom + j) * p.stride + uint(x * p.zoom);
        for (int i = 0; i < p.zoom; i++) {
            dst[row + uint(i)] = px;
        }
    }
}

kernel void recombine(texture2d<uint, access::read> main_y [[texture(0)]],
                      texture2d<uint, access::read> main_uv [[texture(1)]],
                      texture2d<uint, access::read> aux_y [[texture(2)]],
                      texture2d<uint, access::read> aux_uv [[texture(3)]],
                      device uchar4 *dst [[buffer(0)]],
                      constant Params &p [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    int bx = int(gid.x), by = int(gid.y);
    int x = 2 * bx, y = 2 * by;
    if (x >= p.width || y >= p.height) return;
    uint y00 = main_y.read(uint2(x, y)).r;
    uint y10 = main_y.read(uint2(x + 1, y)).r;
    uint y01 = main_y.read(uint2(x, y + 1)).r;
    uint y11 = main_y.read(uint2(x + 1, y + 1)).r;
    uint2 c00 = main_uv.read(uint2(bx, by)).rg;
    uint2 c10 = c00, c01 = c00, c11 = c00;
    if (p.has_aux != 0) {
        int half_h = p.height / 2;
        c10 = aux_uv.read(uint2(bx, by)).rg;
        c01 = uint2(aux_y.read(uint2(x, by)).r, aux_y.read(uint2(x, half_h + by)).r);
        c11 = uint2(aux_y.read(uint2(x + 1, by)).r, aux_y.read(uint2(x + 1, half_h + by)).r);
    }
    store(dst, p, x, y, to_bgrx(y00, c00.x, c00.y));
    store(dst, p, x + 1, y, to_bgrx(y10, c10.x, c10.y));
    store(dst, p, x, y + 1, to_bgrx(y01, c01.x, c01.y));
    store(dst, p, x + 1, y + 1, to_bgrx(y11, c11.x, c11.y));
}
