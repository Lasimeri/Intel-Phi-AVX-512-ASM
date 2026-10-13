#!/bin/sh
# build.sh: libphi512-asm.so, the assembly preload library of the
# restart's stage 2, from the common modules (host/asm/common) and
# main.S, sigill.S, card.S, elf.S, seeds.S, linked as a shared object
# that exports nothing (its constructor runs from .init_array). The
# library lands in host/asm/out/ and is copied to
# host/target/release/libphi512-asm.so, which scripts/phi512.sh preloads
# with PHI512_V3=1. See build.md.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
common="$here/../common"
proto="$root/card/vpu"
out="$root/host/asm/out"
mkdir -p "$out" "$root/host/target/release"

for s in text env lock mem table window fp; do
	as --64 -I "$common" -I "$proto" -o "$out/common_$s.o" "$common/$s.S"
done
for s in main sigill card elf seeds decode; do
	as --64 -I "$here" -I "$common" -I "$proto" -o "$out/p512_$s.o" "$here/$s.S"
done
ld -shared -soname libphi512-asm.so -z now -z relro -z noexecstack -Bsymbolic \
	-o "$out/libphi512-asm.so.new" \
	"$out/p512_main.o" "$out/p512_sigill.o" "$out/p512_card.o" "$out/p512_elf.o" "$out/p512_seeds.o" "$out/p512_decode.o" \
	"$out"/common_text.o "$out"/common_env.o "$out"/common_lock.o \
	"$out"/common_mem.o "$out"/common_table.o "$out"/common_window.o \
	"$out"/common_fp.o
mv "$out/libphi512-asm.so.new" "$out/libphi512-asm.so"
cp "$out/libphi512-asm.so" "$root/host/target/release/libphi512-asm.so.new"
mv "$root/host/target/release/libphi512-asm.so.new" "$root/host/target/release/libphi512-asm.so"
ls -l "$out/libphi512-asm.so"
