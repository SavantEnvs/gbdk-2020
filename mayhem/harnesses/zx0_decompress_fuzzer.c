// libFuzzer harness for gbcompress's ZX0 decompressor (gbdk-support/gbcompress/zx0/zx0_expand.c),
// the code `gbcompress -d --alg=zx0 <in> <out>` runs (main.c decompress()).
//
// It makes the same two salvador library calls with the same flags as the CLI:
//   buf_size_out = salvador_get_max_decompressed_size(in, len, 0);
//   salvador_decompress(in, out, len, buf_size_out, 0, FLG_IS_INVERTED);
// The only difference is the output buffer size. The CLI sizes it from the (uint32_t) return of
// salvador_get_max_decompressed_size, which is (size_t)-1 -> 0xFFFFFFFF on any parse error, so the
// CLI mallocs and memsets 4 GiB for nearly every input (seconds per exec; unfuzzable). Here the size
// is clamped to OUT_CAP. salvador_decompress takes the output buffer size as nMaxOutBufferSize and
// must keep every write inside it, so a smaller buffer is a valid caller of its API and still
// exercises its bounds checks. Every input is passed to the decompressor; none is rejected.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "zx0/zx0_libsalvador.h"

#define OUT_CAP (1u << 20)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size == 0)  // the CLI only decompresses when buf_size_in > 0 (main.c decompress())
    return 0;

  uint32_t buf_size_out = (uint32_t)salvador_get_max_decompressed_size(data, size, 0);
  if (buf_size_out > OUT_CAP)
    buf_size_out = OUT_CAP;

  unsigned char *out = malloc(buf_size_out ? buf_size_out : 1);
  if (!out)
    return 0;
  memset(out, 0, buf_size_out);
  salvador_decompress(data, out, size, buf_size_out, 0, FLG_IS_INVERTED);
  free(out);
  return 0;
}
