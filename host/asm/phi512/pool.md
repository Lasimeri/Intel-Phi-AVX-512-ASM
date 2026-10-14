# pool.S: the region path's worker threads, 16 per card

A region's host work is per unit: the refresh reads each resident unit
of the program's memory (`copy_mapped`, through `/proc/self/mem`) and
compares it with its shadow; the write-back diffs each unit pulled back
from the card. One thread did all of it, the faulting one inside its
SIGILL handler, and in `llama-server` that thread sat at 100 % of a rack
core (2026-10-14, `perf record` of the main thread over 10 s: 41 %
re-reading and parsing `/proc/self/maps` per unit, now one read per
fault in [`elf.S`](elf.md); about 32 % in the kernel's copies out of
`/proc/self/mem`; 0.55 % waiting on the card).

| function | what |
| --- | --- |
| `pool_start(groups)` | 16 workers per card group (`POOL_PER_CARD`, at most 4 groups), once per process, with a 64 KiB buffer each and one for the caller; the region path calls it with the number of cards at every refresh, a no-op after the first |
| `pool_run(group, fn, items)` | `fn(item, buffer)` for every item over the group's workers and the calling thread; it returns when every item is done and every worker of the group has left the job (a worker counts itself idle after its last failed take), so no worker of one job can take an item of the next |

The library has no libc, and the first region runs inside a signal
handler where `pthread_create` is not async-signal-safe: the workers are
raw `clone` threads (`CLONE_VM | FS | FILES | SIGHAND | THREAD |
SYSVSEM`) on 256 KiB `mmap`'d stacks, created with every signal blocked
in the creating thread (restored after, on failure too) and blocking
every signal themselves, so the program's handlers never run on them.
They run only this library's code and system calls, wait on their
group's generation word with `FUTEX_WAIT_PRIVATE`, and take items with
`lock xadd`. A process forked after them (its pid differs) runs its jobs
inline, as does one where they could not be made.

Jobs today: the refresh's per-unit read and compare
([`region.md`](region.md), `wu_refresh_unit`). The group is the card's:
regions run on card 0, so card 0's 16 workers serve them.
