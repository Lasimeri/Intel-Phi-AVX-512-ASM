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
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

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


/* kernel5: a region that reads more of a read-only file mapping than the
 * card's pool holds (the model's weights are such a mapping, 2026-10-14):
 * each 2 MiB chunk wholly inside the mapping goes to the card as one pool
 * page, filled once, and once the pool is full the oldest pages of its
 * ring are evicted; the second call re-reads chunks evicted in the first,
 * which must fault again on the card instead of reading what their page
 * holds now. The file (RO_FILE, RO_BYTES, a distinct word everywhere) is
 * written in the current directory when missing. */
#define RO_FILE "avx512-region-test.ro"
#define RO_BYTES (384u << 20)
#define RO_SUMS 192

__attribute__((noinline))
static void kernel5(const uint32_t *m, size_t words, uint32_t *sums)
{
    const size_t per = RO_BYTES / 4 / RO_SUMS;	/* a constant trip count: vectorised at -O2 */
    (void)words;
    for (int k = 0; k < RO_SUMS; k++) {
        uint32_t s = 0;
        for (size_t i = 0; i < per; i++) s += m[k * per + i] ^ (uint32_t)i;
        sums[k] = s;
    }
}

__attribute__((noinline, target("no-avx512f")))
static void kernel5_ref(const uint32_t *m, size_t words, uint32_t *sums)
{
    const size_t per = RO_BYTES / 4 / RO_SUMS;
    (void)words;
    for (int k = 0; k < RO_SUMS; k++) {
        uint32_t s = 0;
        for (size_t i = 0; i < per; i++) s += m[k * per + i] ^ (uint32_t)i;
        sums[k] = s;
    }
}

/* the pattern file: word w = w * 2654435761 ^ (w >> 19), so every chunk
 * differs from every other; NULL when it cannot be made or mapped */
__attribute__((noinline, target("no-avx512f")))
static const uint32_t *ro_map(void)
{
    int fd = open(RO_FILE, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || (uint64_t)st.st_size != RO_BYTES) {
        if (fd >= 0) close(fd);
        static uint32_t buf[1 << 18];
        FILE *f = fopen(RO_FILE, "wb");
        if (!f) return NULL;
        for (uint64_t w = 0; w < RO_BYTES / 4; ) {
            for (int i = 0; i < (1 << 18); i++, w++) buf[i] = (uint32_t)(w * 2654435761u) ^ (uint32_t)(w >> 19);
            if (fwrite(buf, sizeof buf, 1, f) != 1) { fclose(f); return NULL; }
        }
        if (fclose(f)) return NULL;
        fd = open(RO_FILE, O_RDONLY);
        if (fd < 0) return NULL;
    }
    void *p = mmap(NULL, RO_BYTES, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return p == MAP_FAILED ? NULL : p;
}


/* kernel6: calls between AVX-512 functions stay on the card (in-card
 * calls, 2026-10-14): dot6 through a pointer and directly, scale6
 * directly; scale6 calls a plain function in its middle, an exit from
 * inside a callee the card entered, so the program's stack has to hold
 * the host's return addresses there. The first calls leave the card
 * (dot6 not translated yet); later ones find its blob in the card's
 * table. Inputs in quarters keep every sum exact in any order. */
typedef float (*dot_t)(const float *, const float *);

__attribute__((noinline))
static float dot6(const float *a, const float *b)
{
    float s = 0;
    for (int i = 0; i < 64; i++) s += a[i] * b[i];
    return s;
}

__attribute__((noinline, target("no-avx512f")))
static float dot6_ref(const float *a, const float *b)
{
    float s = 0;
    for (int i = 0; i < 64; i++) s += a[i] * b[i];
    return s;
}

__attribute__((noinline, target("no-avx512f")))
static float plain6(float *a)
{
    float s = 0;
    for (int i = 0; i < 64; i++) { s += a[i]; a[i] -= 1.0f; }
    return s;
}

__attribute__((noinline))
static float scale6(float *a, float k)
{
    for (int i = 0; i < 64; i++) a[i] *= k;
    float s = plain6(a);
    for (int i = 0; i < 64; i++) a[i] += s * 0.0625f;
    return s;
}

__attribute__((noinline, target("no-avx512f")))
static float scale6_ref(float *a, float k)
{
    for (int i = 0; i < 64; i++) a[i] *= k;
    float s = plain6(a);
    for (int i = 0; i < 64; i++) a[i] += s * 0.0625f;
    return s;
}

__attribute__((noinline))
static float kernel6(const float *x, float *y, int reps, dot_t f)
{
    float acc = 0;
    for (int r = 0; r < reps; r++) {
        for (int i = 0; i < 64; i++) y[i] = y[i] * 0.5f + x[i];	/* AVX-512 in the caller: its region calls from the blob */
        acc += f(x, y) + dot6(x + r, y);
    }
    acc += scale6(y, 0.5f);
    return acc + dot6(y, x);
}

__attribute__((noinline, target("no-avx512f")))
static float kernel6_ref(const float *x, float *y, int reps, dot_t f)
{
    float acc = 0;
    for (int r = 0; r < reps; r++) {
        for (int i = 0; i < 64; i++) y[i] = y[i] * 0.5f + x[i];	/* AVX-512 in the caller: its region calls from the blob */
        acc += f(x, y) + dot6_ref(x + r, y);
    }
    acc += scale6_ref(y, 0.5f);
    return acc + dot6_ref(y, x);
}


/* kernel8: caller promotion (2026-10-14): a plain caller (integer code
 * only, no vector instructions) calls an AVX-512 function in a loop, so
 * every call is a region of its own until the preload promotes the
 * caller (after PROMOTE_AT regions of the callee): the caller's entry
 * becomes ud2, its next call runs on the card from the entry, with the
 * callee called in-card. Three calls of the caller: the second and the
 * third run whole on the card. Integer sums: exact. */
__attribute__((noinline))
static int isum8(const int *a)
{
    int s = 0;
    for (int i = 0; i < 64; i++) s += a[i] * 3;
    return s;
}

__attribute__((noinline, target("no-avx512f")))
static int isum8_ref(const int *a)
{
    int s = 0;
    for (int i = 0; i < 64; i++) s += a[i] * 3;
    return s;
}

__attribute__((noinline, target("no-avx512f,no-avx2,no-avx"), optimize("no-tree-vectorize")))
static long caller8(const int *a, int n, int (*f)(const int *))
{
    long t = 0;
    for (int i = 0; i < n; i++) t += (long)(f(a + (i & 63)) ^ i);
    return t;
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
    const uint32_t *m = ro_map();
    if (!m) { printf("FAIL kernel5: %s could not be written or mapped\n", RO_FILE); fails++; }
    else {
        static uint32_t s1[RO_SUMS], s2[RO_SUMS], sr[RO_SUMS];
        kernel5(m, RO_BYTES / 4, s1);
        kernel5(m, RO_BYTES / 4, s2);
        kernel5_ref(m, RO_BYTES / 4, sr);
        int bad1 = 0, bad2 = 0, first = -1;
        for (int k = 0; k < RO_SUMS; k++) {
            if (s1[k] != sr[k]) { bad1++; if (first < 0) first = k; }
            if (s2[k] != sr[k]) { bad2++; if (first < 0) first = k; }
        }
        if (bad1 || bad2) { printf("FAIL kernel5: %d and %d of %d sums wrong (first at %d: %08x %08x want %08x)\n", bad1, bad2, RO_SUMS, first, s1[first], s2[first], sr[first]); fails++; }
        else printf("ok   kernel5 (%u MiB of a read-only file mapping read twice, %d sums)\n", RO_BYTES >> 20, RO_SUMS);
    }
    static float y6[256] __attribute__((aligned(64))), y6r[256] __attribute__((aligned(64)));
    memcpy(y6, x, sizeof y6);
    memcpy(y6r, x, sizeof y6r);
    float r6 = kernel6(x, y6, 8, dot6), w6 = kernel6_ref(x, y6r, 8, dot6_ref);
    if (r6 != w6 || memcmp(y6, y6r, sizeof y6)) { printf("FAIL kernel6: got %g want %g, arrays %s\n", r6, w6, memcmp(y6, y6r, sizeof y6) ? "differ" : "equal"); fails++; }
    else printf("ok   kernel6 (calls between AVX-512 functions, one with an exit inside: %g)\n", r6);
    static int a8[128];
    for (int i = 0; i < 128; i++) a8[i] = (i * 7) % 13 - 6;
    long r8 = 0, w8 = 0;
    for (int c = 0; c < 3; c++) { r8 += caller8(a8, 100, isum8); w8 += caller8(a8, 100, isum8_ref); }
    if (r8 != w8) { printf("FAIL kernel8: got %ld want %ld\n", r8, w8); fails++; }
    else printf("ok   kernel8 (a plain caller of an AVX-512 function, promoted: %ld)\n", r8);
    printf("%s\n", fails ? "FAIL" : "PASS: every region came back right");
    return fails != 0;
}
