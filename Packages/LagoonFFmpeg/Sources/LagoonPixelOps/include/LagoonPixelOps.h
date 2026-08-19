#ifndef LAGOON_PIXEL_OPS_H
#define LAGOON_PIXEL_OPS_H

#include <stddef.h>
#include <stdint.h>

void lagoon_interleave_420_chroma(
    const uint8_t *source_u,
    ptrdiff_t source_u_stride,
    const uint8_t *source_v,
    ptrdiff_t source_v_stride,
    uint8_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
);

#endif
