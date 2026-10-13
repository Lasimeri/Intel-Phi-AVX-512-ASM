# seeds.S: the hand-translated blobs of stage 2

The three kernels of `tools/avx512-seamless-test.c`, translated by hand
from gcc's output (`-O2 -mavx512f -mno-avx512vl -mno-avx512bw
-mno-avx512dq -mno-avx512cd`, 2026-10-13) into the card's MVEX with
[`../../../card/vpu/mvex.inc`](../../../card/vpu/mvex.md), instruction for
instruction. Each blob expects the state at the function's first AVX-512
instruction (whatever gcc put before it: argument moves, a zeroed
counter) and ends with `ret`. They are the scaffold of stage 2; stage 3's
translator produces the same from the binary.

## The seed table

`SD_BYTES` (128) per seed ([`defs.inc`](defs.md)): the name (resolved on
first fault by `elf_find`), the blob and its length, the loop's counter
and bound registers and step (0: not split), whether the function
returns in xmm0, and up to four memory operands {register, element
stride, kind, fixed length}: `OPK_READ` and `OPK_WRITE` are indexed by
the counter (the stripe's range of elements times the stride), `OPK_FIXED`
is a fixed number of bytes at the register.

| seed | entry state | split | operands |
| --- | --- | --- | --- |
| `poly_avx512` | r10 out, r9 x, r8 n, rsi coef, rdi coef + 0x74, rdx coef - 4, rcx 0 | rcx to r8, step 16 | x read, out written, coef 124 bytes |
| `dot_avx512` | rdi a, rsi b, rdx n, rax 0, zmm0 0 | none (a reduction) | a, b read |
| `ints_avx512` | rdi out, rsi in, rdx n, rax 0 | rax to rdx, step 16 | in read, out written |

## Lessons the blobs taught

- The card copies a blob to a 64-byte-aligned arena address, so in-blob
  offsets keep their alignment only if the blob label is 64-aligned in
  the library: `ints`' constants (4-byte broadcast loads) at an offset of
  2 mod 4 raised `#GP` (fault address 0) on the card.
- KNC's swizzle names are the result's order: `cdab` swaps neighbours
  (lane l with l^1), `badc` swaps pairs (l^2). gcc's
  `_mm512_reduce_add_ps` adds the 256-bit halves, the 128-bit halves,
  then l^2 (`vpermilps 0x4e`), then l^1 (`vshufps 0x55`); with the two
  swizzles the other way round the sum differed in the last bit
  (-28.6031113 for -28.6031036).
- The 256- and 128-bit halves are added with `vpermf32x4` (0F3A 07,
  groups 2 3 0 1 and 1 0 3 2): the VL extracts have no MVEX form.
- MVEX takes `base + disp32` only, so gcc's `(%r9,%rcx,4)` forms become
  a `lea` into r11 first.

## Retired to a comparison (2026-10-13, later)

The hand-written blobs are no longer the path: `xlfn.S` translates the
seed's function at its first fault and the record's `SD_ABLOB`,
`SD_ABLOB_LEN`, `SD_MAP`, `SD_INDEX`, `SD_NINSN` and `SD_REFUSED`
(`SD_BYTES` 192) hold the result; `PHI512_HANDBLOBS=1` keeps the hand
blobs (the entry at the blob's start, the loop's registers and the
operands still from this table, which stage 3's planner replaces next).
