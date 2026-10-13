# fnscan.S: a function indexed for the translator

```
fn_scan(rdi = the function's bytes, rsi = its size, rdx = its address,
        rcx = the record out, r8 = the object, r9 = the index area)
    -> rax = 0, or the FNF_* flags that stop a translation
```

Decodes the function from its first byte to its last
([`decode.S`](decode.md)), writes one index entry per instruction
(`IX_*` of [`fnscan.inc`](x86dec.md): offset, length, kind, flags,
target) into the index area (at least `size * IX_BYTES` bytes), and
fills the record (`FN_*`: the counts by kind, the flags). The bytes need
not lie at the address: a file mapped elsewhere scans the same way,
which is how `tools/fnscan-check.c` runs it over a library on disk.

## The kinds

| kind | what the translator does with it |
| --- | --- |
| `K_COPY` | copied as it is (a rip-relative operand, `IXF_RIP`, is re-based through a scratch register, since the blob lies elsewhere) |
| `K_EVEX`, `K_VEX` | translated to the card's MVEX (a VEX form as a masked 512-bit operation; the card has no SSE or AVX) |
| `K_BR_IN` | a relative branch inside the function: re-laid out to the blob's own offsets; its target gets `IXF_LABEL` |
| `K_BR_OUT` | a relative branch leaving the function (a tail call, a `.cold` part): to the original address, where the card runs the resident text as it is |
| `K_CALL`, `K_PLT` | a direct call inside the object (to the callee's blob when loaded, else the original address) or into the PLT (an exit, for now) |
| `K_ICALL`, `K_IJMP` | an indirect call or jump (a jump table, a pointer): to wherever it points; untranslated code traps at its first EVEX instruction and is mapped lazily |
| `K_RET`, `K_TRAP`, `K_FAR` | copied; an exit; refused |

Flags: `IXF_LOCK` (a locked instruction), `IXF_FS` (an fs- or
gs-relative access: the card's `fs` block must carry what the program
expects there), `IXF_UNK` (no table entry: refused), `IXF_COND`.

The record's `FNF_*`: `FNF_FAILED` (bytes that are not an instruction,
`FN_FAIL_OFF` says where), `FNF_BADTARGET` (a branch into the middle of
an instruction: data in the function, or a wrong size), `FNF_FAR`,
`FNF_FULL`; the others mirror the counts.

## Measured (2026-10-13, the rack)

`fnscan-check` over `llama.phi/build-avx512f/bin/libggml-cpu.so.0.26.0`:
830 functions (the aliases of one address skipped) in 0.021 s, 0 failed,
0 bad targets; the totals equal the iced-x86 dump's within `nm`'s
bounds: 255741 instructions, 17243 EVEX, 54248 VEX, 5722 direct calls
(618 inside the object, 5104 into the PLT), 87 indirect calls, 37
indirect jumps, 770 returns, 18041 relative branches (17702 inside,
339 out); 3 locked, 747 through `fs`, 0 unknown, 8032 rip-relative,
11895 labels; 317 functions hold EVEX instructions. The function
llama-simple first faulted in, `ggml_backend_cpu_reg_get_device` (413
bytes): 79 instructions, 5 EVEX (the first at +251, the fault's
address), 14 VEX, 7 PLT calls, 31 rip-relative operands, 2 returns, one
tail jump. Record:
[`docs/results/2026-10-13-decoder.md`](../../../docs/results/2026-10-13-decoder.md).

Trap: `x86_decode` uses r8 to r11 and rcx, rdx, rsi, rdi; an offset
kept in r9 across the call is gone (the first run's offsets were).
