# blob.S: a function's blob

```
blob_build(rdi = the blob block, rsi = the function record, rdx = the
           function's bytes, rcx = the object) -> rax = 0 or the refusal
```

Builds the card's code for a whole function from its index
([`fnscan.S`](fnscan.md)) in two passes over a block (`BL_*` of
[`xlate.inc`](xlate.md)) whose areas the caller provides: the code, the
constants, the constant fixups, the rip map, the branch fixups.

## Pass one: instruction by instruction

| kind | emitted |
| --- | --- |
| copied | the bytes as they are; an x87 or legacy SSE instruction is refused for now |
| copied, rip-relative | `mov [fs:S_RIPB], r; movabs r, the operand's address`; the instruction with its ModRM re-based to `[r]` (mod 00, the displacement gone into the address; a REX with B, or the VEX/EVEX B bit, for r above 7); `mov r, [fs:S_RIPB]` unless the instruction left. r is r8, r9, r10, r11, r14 or r15, none of which anything uses implicitly, the first the instruction does not name; under a two-byte VEX (no B bit) rax, rcx, rdx, rbx, rsi or rdi |
| EVEX, VEX | the recipe ([`xlate.S`](xlate.md)), a rip-relative memory operand re-based the same way around it |
| a branch inside the function | `jcc rel32` (0F 80+cc) or `jmp rel32` (E9) with a fixup to the target's offset |
| a branch out of it, a direct call | the original address through the transfer slot: rax saved, `movabs rax`, `mov [fs:S_XFER], rax`, rax restored, `jmp` or `call [fs:S_XFER]`; a conditional branch skips the sequence under the inverse condition |
| an indirect call or jump, a return | as they are |
| a loop or jrcxz, a trap, a far form | refused |

The map records every instruction's blob offset first, so a fault
inside the function enters the blob at the right place.

## Pass two

The branch fixups are resolved through the map (the target's offset to
its index entry by a binary search, then the entry's blob offset); the
constants the recipes asked for are appended at the next 64-byte
boundary (int3 padding between) and their rip-relative displacements
fixed up.

## What the first run found (2026-10-13)

The three seamless kernels (23, 19 and 22 instructions) become blobs of
128, 896 and 320 bytes; the dot product's VL reduce is the 896. The
first integer blob's constant displacement read wrong under objdump's
misparse of the MVEX bytes before it and was right; the real fault was
the SIB index ([`mvex.md`](mvex.md)).

## Lazy sites (2026-10-14)

An instruction the blob cannot carry no longer refuses the whole
function. A recipe that refuses (`xl_insn` nonzero), a legacy SSE or x87
form, a loop or `jrcxz` instruction, a rip-relative operand with no
free scratch register and an atomic on the program's memory (a `lock`
prefix, or `xchg` with memory: on the card it would be atomic on the
card's copy alone, and the program's other threads would lose their
updates) all go to `.Llazy`: what the path emitted for the
instruction is rolled back to its start (its rip-map entry, and the
counts of constants, fixups and branch fixups snapshotted at `.Lnext`),
and an exit takes its place at the instruction's own address
(`S_SITE`), the same 57-byte sequence as a branch out:

- `X_HOST` (10) when the host runs the instruction itself
  (`lazy_host_ok`): any legacy form, and a VEX form unless it is one of
  the AVX-512 opmask instructions (VEX-encoded, AVX-512F/BW/DQ) or a VEX
  form of a feature the EPYC 7742 lacks (VNNI, NE-CONVERT, AMX, IFMA,
  SHA512, GFNI, VNNI-INT16, SM3/SM4, VAES and VPCLMULQDQ at 256 bits,
  CMPccXADD; the host's flags from the rack's `/proc/cpuinfo`). The host
  executes it and goes on natively to the next fault: a new region.
- `X_REFUSED` (5) for an EVEX form: the program dies there only if the
  card reaches it.

`blob_lazy` keeps the first 256 sites of the last build (offset, kind,
reason) for [`xlfn.S`](xlfn.md)'s log and [`xlate-check`](../../../tools/xlate-check.md).
Measured: `llama-server` went from refusing `common_params_fit_impl`
(one VEX.128 `vshufpd`) at 1080 regions to 3679 regions with four lazy
sites, none of them reached; [`avx512-region-test`](../../../tools/avx512-region-test.md)'s
`kernel3` crosses card, host, card.

## In-card calls (2026-10-14)

A call site, direct or indirect, gets `.Lincall` between the callee and
site slots and its `X_CALL` exit: `S_RETA` = the host return address
(the site plus the call's length), then `call *%fs:S_INCALL` (the card's
`fx_incall`: the callee's blob when the card holds it, else back here to
the exit). A `ret` pops into `S_SITE` and jumps to `*%fs:S_INRET` (the
card's `fx_inret`). See [`../../../card/vpu/fexec.md`](../../../card/vpu/fexec.md).
`PHI512_INCALL=0` (main.S `incall_off`) keeps the old sequences.

## Calls through a PLT stub (2026-10-14)

A library's calls to its own exported functions go through its PLT
(libggml-cpu is lazily bound: `call ggml_vec_dot_f32@plt`, a stub of `jmp
*GOT(%rip)`, `push`, `jmp PLT0`). The card's in-card call table holds
functions, so every such call missed and the region left the card
(llama-server: `gated_delta_net` and `vec_dot_f32` regions 1:1).
`plt_resolve` looks at a direct call's target: a stub (optional `endbr64`,
optional `bnd`, then `ff 25 disp32`) whose GOT slot is resolved (not
pointing back into the stub) gives the function in the slot as `S_XFER`.
The host's own call at the site still goes through the stub.

A blob built before the slot resolved keeps the stub (lazy binding: a
caller with its own AVX-512 code is translated at its first instruction,
before its first call of the callee). Then the host aliases at run time:
`region.S alias_check`, at every `X_CALL` exit, resolves the callee; a
stub that now reaches a function with a blob is registered on every card
as that blob's (`card.S card_alias`: `K_LOAD` with no bytes and the key in
`fill_off`; card `fexec.S` inserts it in the in-card call table), once per
stub.
