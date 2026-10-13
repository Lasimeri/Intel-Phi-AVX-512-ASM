#!/bin/sh
# build.sh: the host-side drivers of the co-processor in assembly, so far
# phi-vpu-ping (ping.S), linked static with the common modules
# (host/asm/common) and no libc; the binaries land in host/asm/out/ and
# are copied to host/target/release/ (the path scripts find). See build.md.
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
for p in ping fexec; do
	as --64 -I "$here" -I "$common" -I "$proto" -o "$out/vpu_$p.o" "$here/$p.S"
	ld -static -nostdlib -e _start -z noexecstack -o "$out/phi-vpu-$p.new" \
		"$out/vpu_$p.o" "$out"/common_text.o "$out"/common_env.o \
		"$out"/common_lock.o "$out"/common_mem.o "$out"/common_table.o \
		"$out"/common_window.o "$out"/common_fp.o
	mv "$out/phi-vpu-$p.new" "$out/phi-vpu-$p"
	cp "$out/phi-vpu-$p" "$root/host/target/release/phi-vpu-$p.new"
	mv "$root/host/target/release/phi-vpu-$p.new" "$root/host/target/release/phi-vpu-$p"
	ls -l "$out/phi-vpu-$p"
done
