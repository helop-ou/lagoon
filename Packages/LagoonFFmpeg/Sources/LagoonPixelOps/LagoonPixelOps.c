#include "LagoonPixelOps.h"

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

void lagoon_interleave_420_chroma(
    const uint8_t *source_u,
    ptrdiff_t source_u_stride,
    const uint8_t *source_v,
    ptrdiff_t source_v_stride,
    uint8_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
) {
    const size_t chroma_width = width / 2;
    for (size_t row = 0; row < rows; row++) {
        const uint8_t *u = source_u + (ptrdiff_t)row * source_u_stride;
        const uint8_t *v = source_v + (ptrdiff_t)row * source_v_stride;
        uint8_t *output = destination + (ptrdiff_t)row * destination_stride;
        size_t column = 0;

#if defined(__ARM_NEON)
        for (; column + 16 <= chroma_width; column += 16) {
            uint8x16x2_t uv;
            uv.val[0] = vld1q_u8(u + column);
            uv.val[1] = vld1q_u8(v + column);
            vst2q_u8(output + column * 2, uv);
        }
#endif

        for (; column < chroma_width; column++) {
            output[column * 2] = u[column];
            output[column * 2 + 1] = v[column];
        }
    }
}
