# elf.S: the program's symbols and mappings

## `elf_init`, `elf_find(name)`

The executable is mapped whole through `/proc/self/exe` and its
`.symtab` walked for `STT_FUNC` symbols (a binary keeps `.symtab`
unless stripped: the seamless test's static kernels are found this
way). The load address is the first line of `/proc/self/maps` (the
executable's first mapping); a symbol's address is its value plus that
base, which holds for a position-independent executable (the first
mapping starts at the base) and for a fixed one (base 0x400000 and
values absolute would double-count: not met yet, `.dynsym` and
stripped binaries neither; stage 3's `elf.S` grows the plan's full
lookup).

## `mapped_range(address)`

The mapping holding an address, from `/proc/self/maps` read and
scanned per call.

## `copy_mapped(dst, src, len)`

Sets `copy_mapped_pages` and `copy_mapped_wpages`, a bit per 4 KiB page
of the source's first 64 KiB that was readable, and writable, for a
unit's page bitmaps ([`region.md`](region.md)).

The parts of `[src, src + len)` the program has mapped readable, copied
to `dst` at the same offsets: a 2 MiB chunk staged for the card where an
array may start or end inside it with nothing, a guard page or another
mapping beside it. The copy is a `pread` of `/proc/self/mem` per
mapped range, so a range that cannot be read after all ends as a short
read, never a signal: with a plain copy, a file mapping past its file's
end (the executable's own, next to the heap) raised SIGBUS in 5 of 6
runs of the seamless test at 65536 elements (2026-10-13); through
`/proc/self/mem`, 10 of 10 ran.

## `heap_bounds`

The `[heap]` mapping's start and end from `/proc/self/maps` (both 0
when there is none), for [`region.S`](region.md)'s heap walk.
