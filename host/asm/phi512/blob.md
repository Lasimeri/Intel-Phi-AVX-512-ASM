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
