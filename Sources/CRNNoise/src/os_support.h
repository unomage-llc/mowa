/* Mowa: minimal stand-in for Opus's os_support.h, which the RNNoise 0.2 release tarball
   references from vec.h/vec_neon.h (the Apple silicon / generic SIMD paths) but doesn't ship.
   Only OPUS_CLEAR is used. */
#ifndef OS_SUPPORT_H
#define OS_SUPPORT_H
#include <string.h>
#define OPUS_CLEAR(dst, n) (memset((dst), 0, (n)*sizeof(*(dst))))
#endif
