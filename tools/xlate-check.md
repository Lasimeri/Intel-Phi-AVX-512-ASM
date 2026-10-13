# xlate-check.c: a function translated out of an ELF file

```
gcc -O2 -o xlate-check tools/xlate-check.c host/asm/out/p512_{blob,xlate,mvex,fnscan,decode}.o
xlate-check FILE FUNCTION [OUT.bin]
```

Maps the file, finds the function in `.symtab`, runs `fn_scan` and
`blob_build` ([`../host/asm/phi512/blob.md`](../host/asm/phi512/blob.md))
on its bytes at their file offset, and prints the function's size and
instruction count, the blob's size, constants and fixups, and the rip
map (original offset to blob offset, with each instruction's length and
kind), or the refusal and its offset. With `OUT.bin` the blob (code,
padding, constants) is written out for `objdump -D -b binary -m
i386:x86-64`, which reads the scalar parts and the structure (the MVEX
instructions come out as EVEX nonsense there, and the bytes after one
are often misparsed: count from the hex). The scratch's fs offset is a
constant (0x1000) for reading.

2026-10-13: the three seamless kernels of the test binary translate to
128, 896 and 320 bytes; it is how the SIB-index bug and the extract's
operand order were found before the card ran them
([`../docs/results/2026-10-13-translator-seamless.md`](../docs/results/2026-10-13-translator-seamless.md)).
