/* libm-test: a function with AVX-512 code (a region on the card) calling
 * expf and sinf through the PLT for each element (as ggml's gated delta
 * net and rope cache do); the results compared bit for bit with the host's
 * libm called from code without AVX-512 (main). With libm's functions
 * sized from its unwind index, the calls run in the card (a handful of
 * regions); without, each call is a round trip to the host. */
#include <immintrin.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
__attribute__((noinline)) void run(float *out, const float *in, int n) {
    __m512 z = _mm512_loadu_ps(in);
    _mm512_storeu_ps(out, _mm512_add_ps(z, _mm512_setzero_ps()));
    for (int i = 0; i < n; i++) out[i] = expf(in[i]) + sinf(in[i] * 3.0f);
}
__attribute__((target("no-avx512f"))) int main(void) {
    static float in[4096], out[4096];
    for (int i = 0; i < 4096; i++) in[i] = (float) ((i % 997) - 498) * 0.0173f;
    run(out, in, 4096);
    int bad = 0;
    for (int i = 0; i < 4096; i++) { float w = expf(in[i]) + sinf(in[i] * 3.0f); uint32_t a, b; memcpy(&a, &out[i], 4); memcpy(&b, &w, 4); if (a != b) { if (bad < 4) printf("[%d] x %.6g: card %.9g, host %.9g\n", i, in[i], out[i], w); bad++; } }
    printf("%s: %d of 4096 differ\n", bad ? "FAIL" : "PASS", bad);
    return bad != 0;
}
