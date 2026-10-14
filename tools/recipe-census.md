# recipe-census.c

Which vector instructions of an ELF object the translator has a recipe
for, counted by the decoder's own mnemonic id: every instruction of the
object's `.text` (or of one function, `-f FUNCTION`, by `.symtab`) that
`blob.S` would hand to a recipe (a VEX or EVEX encoding, or a legacy
instruction with an xmm operand) goes under its mnemonic, and the
mnemonics with no entry in `xlate.S`'s table are listed by count (`-a`
lists the covered ones too), with a tally per object and in total.

```
gcc -O2 -o recipe-census tools/recipe-census.c host/asm/out/p512_{decode,xlate,mvex,fnscan,blob}.o
recipe-census [-f FUNCTION] [-a] ELF...
```

It links the library's own objects (`host/asm/phi512/build.sh` leaves
them in `host/asm/out`), so it counts against the recipes as built. It
says which forms exist, not whether they run: `xlate-check` translates
a function and reports the first refusal inside a recipe, and the form
suites on the card are the check of the sequences.

On 2026-10-13 over the objects llama-server loads (libllama-server-impl,
libllama-common, libllama, libggml-base, libggml-cpu, libggml, libmtmd):
322,212 vector instructions of 289 mnemonics; with no recipe 41,491
before the batch of that evening and 25,321 (123 mnemonics) after it,
most of them the byte and word forms of the quantized kernels
(vpshufb, vpmaddubsw, vpmaddwd, vpblendw, vpsrlw).
