/* avx512-region-test.c: a program whose AVX-512 code is broken into
 * regions by calls, as any compiled function is: a kernel that works on
 * a stack array with AVX-512 instructions, calls a plain function in the
 * middle (which prints and changes the array), continues with AVX-512,
 * and returns a value; a second kernel calls through a function pointer
 * and branches out of its loop. Each result is compared with a scalar
 * reference compiled without AVX-512 (`target("no-avx512f")`). Bare on
 * a host without AVX-512 it dies with SIGILL; under the preload it says
 * whether every region came back right.
 *
 *   gcc -O2 -mprefer-vector-width=512 -mavx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq -mno-avx512cd \
 *       -o avx512-region-test tools/avx512-region-test.c
 *   PHI512_CARDS=0 LD_PRELOAD=libphi512-asm.so ./avx512-region-test
 *
 * See avx512-region-test.md. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int fails;
static float side[16] __attribute__((aligned(64)));

/* The plain function the kernel calls: it reads what the kernel wrote so
 * far (the write-back has to have happened), prints, and changes the
 * array (the refresh has to happen before the kernel continues). */
__attribute__((noinline, target("no-avx512f")))
static float middle(float *a, int n)
{
    float s = 0;
    for (int i = 0; i < n; i++) s += a[i];
    printf("  middle sees sum %g\n", s);
    for (int i = 0; i < n; i++) a[i] += 1.0f;
    side[0] = s;
    return s;
}

__attribute__((noinline))
static float kernel1(const float *x, int n)
{
    float a[64] __attribute__((aligned(64)));
    for (int i = 0; i < 64; i++) a[i] = x[i] * 2.0f;		/* vmulps on the stack array */
    float s = middle(a, 64);					/* an exit: the host runs this */
    float acc = 0;
    for (int i = 0; i < 64; i++) acc += a[i] * x[i];		/* the array as middle left it */
    return acc + s;
}

__attribute__((noinline, target("no-avx512f")))
static float kernel1_ref(const float *x, int n)
{
    float a[64];
    for (int i = 0; i < 64; i++) a[i] = x[i] * 2.0f;
    float s = 0;
    for (int i = 0; i < 64; i++) s += a[i];
    for (int i = 0; i < 64; i++) a[i] += 1.0f;
    float acc = 0;
    for (int i = 0; i < 64; i++) acc += a[i] * x[i];
    return acc + s;
}

typedef float (*fn_t)(const float *, int);
__attribute__((noinline, target("no-avx512f")))
static float leaf(const float *x, int n) { return x[0] + (float)n; }

__attribute__((noinline))
static float kernel2(const float *x, float *y, int n, fn_t f)
{
    float t = 0;
    for (int i = 0; i < n; i++) y[i] = x[i] * x[i] + 1.0f;	/* vectorised */
    t = f(y, n);						/* an indirect call: an exit */
    for (int i = 0; i < n; i++) y[i] = y[i] * t;			/* vectorised again */
    if (y[0] > 1e30f) return -1.0f;				/* a branch out of the hot path */
    return y[n - 1];
}

__attribute__((noinline, target("no-avx512f")))
static float kernel2_ref(const float *x, float *y, int n, fn_t f)
{
    float t = 0;
    for (int i = 0; i < n; i++) y[i] = x[i] * x[i] + 1.0f;
    t = f(y, n);
    for (int i = 0; i < n; i++) y[i] = y[i] * t;
    if (y[0] > 1e30f) return -1.0f;
    return y[n - 1];
}

/* kernel3: a region broken by an instruction the card has no recipe for
 * and the host runs itself (vperm2i128: VEX, AVX2): the card runs to it
 * and exits (X_HOST, blob.S's lazy path), the host executes it and goes
 * on natively until the next EVEX instruction faults into a new region.
 * zmm16 and k1, set on the card and never touched by the host, must come
 * through; the host's ymm3 must reach the card; the card's ymm2 must
 * reach the host. */
__attribute__((noinline))
static void kernel3(const float *x, float *out)
{
    __asm__ volatile(
        "vmovups (%0), %%zmm16\n\t"
        "vcmpps $1, 64(%0), %%zmm16, %%k1\n\t"
        "vmovups 128(%0), %%ymm2\n\t"
        "vperm2i128 $0x01, %%ymm2, %%ymm2, %%ymm3\n\t"
        "vaddps %%zmm16, %%zmm16, %%zmm17%{%%k1%}%{z%}\n\t"
        "vmovups %%zmm17, (%1)\n\t"
        "vmovups %%zmm3, 64(%1)\n\t"
        : : "r"(x), "r"(out) : "xmm2", "xmm3", "xmm16", "xmm17", "k1", "memory");
}

__attribute__((noinline, target("no-avx512f")))
static void kernel3_ref(const float *x, float *out)
{
    for (int i = 0; i < 16; i++) out[i] = x[i] < x[16 + i] ? 2.0f * x[i] : 0.0f;
    for (int j = 0; j < 4; j++) { out[16 + j] = x[36 + j]; out[20 + j] = x[32 + j]; }
    for (int j = 24; j < 32; j++) out[j] = 0.0f;
}

/* kernel4: a region that moves rsp down: a 160-byte struct passed by value
 * is built with zmm moves and copied to the call's stack arguments below
 * the frame (gcc: sub rsp, then the stores, inside the region). Before
 * 2026-10-14 the lines below rsp - 128 never came back (llama-server's
 * context parameters reached llama_init_from_model with n_batch 0). */
struct big { float v[40]; };

__attribute__((noinline, target("no-avx512f")))
static float take_big(struct big b)
{
    float s = 0.0f;
    for (int i = 0; i < 40; i++) s += b.v[i] * (float)(i + 1);
    return s;
}

__attribute__((noinline))
static float kernel4(const float *x)
{
    struct big b;
    for (int i = 0; i < 40; i++) b.v[i] = x[i] * 2.0f + 1.0f;
    return take_big(b);
}

__attribute__((noinline, target("no-avx512f")))
static float kernel4_ref(const float *x)
{
    struct big b;
    for (int i = 0; i < 40; i++) b.v[i] = x[i] * 2.0f + 1.0f;
    return take_big(b);
}

/* main itself has no AVX-512 code: the inputs come from a scalar helper
 * (gcc would vectorise the loop in main with forms the kernels never
 * use). */
__attribute__((noinline, target("no-avx512f")))
static void fill(float *x, int n)
{
    for (int i = 0; i < n; i++) x[i] = (float)(i % 17) * 0.25f - 1.0f;
}

__attribute__((target("no-avx512f")))
int main(void)
{
    static float x[256] __attribute__((aligned(64)));
    static float y1[256] __attribute__((aligned(64))), y2[256] __attribute__((aligned(64)));
    fill(x, 256);
    float r = kernel1(x, 64);
    float want = kernel1_ref(x, 64);
    if (r != want) { printf("FAIL kernel1: got %g want %g\n", r, want); fails++; }
    else printf("ok   kernel1 (%g)\n", r);
    float r2 = kernel2(x, y1, 256, leaf);
    float want2 = kernel2_ref(x, y2, 256, leaf);
    if (r2 != want2 || memcmp(y1, y2, sizeof y1)) { printf("FAIL kernel2: got %g want %g, arrays %s\n", r2, want2, memcmp(y1, y2, sizeof y1) ? "differ" : "equal"); fails++; }
    else printf("ok   kernel2 (%g)\n", r2);
    static float o1[32] __attribute__((aligned(64))), o2[32] __attribute__((aligned(64)));
    kernel3(x, o1);
    kernel3_ref(x, o2);
    if (memcmp(o1, o2, sizeof o1)) {
        printf("FAIL kernel3:");
        for (int i = 0; i < 32; i++) if (o1[i] != o2[i]) printf(" [%d] %g want %g", i, o1[i], o2[i]);
        printf("\n");
        fails++;
    } else printf("ok   kernel3 (a VEX instruction the host runs between two card regions)\n");
    float r4 = kernel4(x), want4 = kernel4_ref(x);
    if (r4 != want4) { printf("FAIL kernel4: got %g want %g\n", r4, want4); fails++; }
    else printf("ok   kernel4 (stack arguments written below the frame by the region: %g)\n", r4);
    printf("%s\n", fails ? "FAIL" : "PASS: every region came back right");
    return fails != 0;
}
