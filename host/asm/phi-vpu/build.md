# build.sh: the host drivers in assembly

Assembles `ping.S` with the common modules (`host/asm/common`: text, env,
lock, mem, table, window, fp) and links `phi-vpu-ping` static, no libc,
entry `_start`, into `host/asm/out/`, then copies it to
`host/target/release/phi-vpu-ping` (by a `.new` file and `mv`), the path
`scripts/phi-vpu.sh ping` runs. The Makefile's `build` target runs it
after the backend's `build.sh`. Needs only GNU `as` and `ld`.
