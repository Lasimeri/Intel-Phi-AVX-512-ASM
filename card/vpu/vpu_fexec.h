/* Protocol v3: the slots. A host thread owns a slot of the window and
 * speaks to one slot process on the card through it: the request block,
 * one u16 of the SLOTSEQ line (the doorbell the dispatcher reads for every
 * slot with one 64-byte load), the reply block, the demand mail and the
 * progress line, all in the slot's 4 KiB at VPU_OFF_SLOTS; the bulk data
 * (register blocks, refresh bytes, write-back, the deferred call list, the
 * demand landing area) in the slot's 1 MiB at VPU_OFF_SLOTDATA. The
 * legacy kinds 1 to 8 (vpu_proto.h, vpu_matmul.h) keep the REQ and REPLY
 * lines and the wide pool. Nothing of v3 lies above 128 MiB, where the
 * backend's areas begin.
 *
 * The assembly mirror is card/vpu/proto.inc (the card worker) and
 * host/asm/phi512/state.inc (the preload); tools/vpu-layout-check.c
 * compares every offset. See vpu_fexec.md.
 */
#ifndef VPU_FEXEC_H
#define VPU_FEXEC_H
#include <stdint.h>

#define VPU_OFF_SLOTSEQ   448                     /* uint16_t seq[32], one line */
#define VPU_NSLOTS        32
#define VPU_OFF_SLOTS     65536                   /* struct vpu_slot[32] */
#define VPU_SLOT_BYTES    4096
#define VPU_OFF_SLOTDATA  (48u << 20)             /* 32 x 1 MiB */
#define VPU_SLOTDATA_BYTES (1u << 20)
#define VPU_OFF_LOADAREA  (80u << 20)             /* blobs staged for K_LOAD */
#define VPU_LOADAREA_BYTES (16u << 20)
#define VPU_OFF_RESIDENT  (96u << 20)             /* chunks in flight for K_RESIDENT */
#define VPU_RESIDENT_BYTES (32u << 20)

/* Inside a slot's 1 MiB of SLOTDATA. */
#define VPU_SD_REGS_IN     0
#define VPU_SD_REGS_OUT    4096
#define VPU_SD_REFRESH_TAB 8192                   /* 512 x {addr, len} */
#define VPU_SD_REFRESH     16384                  /* up to 256 KiB of refresh bytes */
#define VPU_SD_WB_TAB      (272u * 1024)
#define VPU_SD_WB          (288u * 1024)
#define VPU_SD_DEFER       (528u * 1024)          /* 2048 x 128 bytes */
#define VPU_SD_LAND        (784u * 1024)          /* demand landing, to the MiB's end */
#define VPU_SD_DEFER_MAX   2048
#define VPU_FX_SCRATCH_TPOFF 1536                /* fs-relative: the translated code's per-thread scratch (512 bytes) */
#define VPU_FX_SCRATCH_BYTES 512
#define VPU_SD_DEFER_BYTES 128

/* Request kinds of the slots. */
#define VPU_K_PING     9     /* nothing: the floor of a request */
#define VPU_K_LOAD     10    /* a blob from LOADAREA into the code arena */
#define VPU_K_UNLOAD   11
#define VPU_K_RESIDENT 12    /* chunks of the program's memory, pulled by DMA and mapped at identity */
#define VPU_K_FEXEC    13    /* run a function instance */
#define VPU_K_RESUME   14    /* continue the slot's instance after an exit */
#define VPU_K_FLUSH    15    /* the session's end: the pool pages back, the residency table emptied; exit_aux = pages returned */
#define VPU_K_PUSH     16    /* fn_id = a program address, entry = bytes (64-aligned, at most VPU_SD_WB_BYTES): copied from the card's memory into SD_WB */
#define VPU_K_LAST     16
#define VPU_SD_WB_BYTES (VPU_SD_DEFER - VPU_SD_WB)

/* How a function instance left the card (reply.exit_kind). */
#define VPU_X_RET        0
#define VPU_X_CALL       1   /* a PLT or indirect call: the callee in exit_aux */
#define VPU_X_ATOMIC     2   /* a locked instruction: its address in exit_rip */
#define VPU_X_SYSCALL    3
#define VPU_X_FAULT      4   /* the address in exit_aux */
#define VPU_X_REFUSED    5   /* an instruction the card cannot run: exit_rip */
#define VPU_X_LOOP       6   /* a split loop's head reached: the loop id in exit_aux */
#define VPU_X_DEFER_FULL 7
#define VPU_X_LIMIT      8
#define VPU_X_JUMP       9   /* the host resumes at exit_rip (a branch out, an indirect jump, a return) */
#define VPU_FXF_IDSTACK  1   /* K_FEXEC flags: the file's rsp is the program's stack at identity */
#define VPU_FX_EXIT_TPOFF 1048 /* fs-relative: the exit stub's address (TLS_EXEC + 24) */
#define VPU_FX_S_KIND    436 /* scratch slots the exit reads: the kind, the resume address, the aux */
#define VPU_FX_S_SITE    440
#define VPU_FX_S_XFER    448

struct vpu_stripe { uint64_t lo, hi; };

/* The request, at the slot's start. The host writes every field, then
 * the slot's u16 in SLOTSEQ. */
struct vpu_slot_req {
    uint64_t seq;
    uint32_t kind;             /* VPU_K_* */
    uint32_t flags;            /* K_FEXEC: VPU_FXF_*; K_RESIDENT: the units of the chunk, a bit per 64 KiB */
    uint64_t fn_id;
    uint64_t entry;            /* offset into the blob */
    uint32_t threads;
    uint32_t nstripes;
    struct vpu_stripe stripes[16];
    uint32_t ind_reg;
    uint32_t bound_reg;
    int64_t  step;
    uint64_t loop_exit;
    uint32_t refresh_n;
    uint32_t defer_cap;
    uint32_t wb_n;             /* write-back ranges in SD_WB_TAB ({addr, len}, 64-byte aligned and sized) */
    uint32_t wb_bytes;         /* their bytes together */
    uint64_t fill_off;         /* K_RESIDENT: the range of the chunk to fill from the staging slot */
    uint64_t fill_len;         /* (0: the page only, nothing copied) */
    uint64_t canary;           /* K_FEXEC: the program's stack-protector canary (fs:0x28), set in every thread's TLS */
};

/* The reply, at VPU_SLOT_REPLY: the fields, then seq last. */
struct vpu_slot_reply {
    uint64_t seq;
    int32_t  status;           /* VPU_OK or a VPU_E_* value */
    uint32_t exit_kind;        /* VPU_X_* */
    uint64_t exit_rip;
    uint64_t exit_aux;
    uint64_t run_ns;
    uint64_t fetch_ns;
    uint64_t wb_ns;
    uint64_t total_ns;
    uint32_t wb_n;
    uint32_t defer_n;
    uint32_t threads_ran;
    uint32_t siginfo;          /* X_FAULT, X_REFUSED: the signal number | si_code << 8 */
    uint64_t free_bytes;       /* the card's free memory when the reply was written */
};

/* The demand mail, at VPU_SLOT_MAIL: the card asks, the host answers. */
struct vpu_slot_mail {
    uint64_t addr;
    uint64_t len;
    uint64_t seq;
    uint64_t ack;
    int32_t  status;
    int32_t  pad;
};

#define VPU_SLOT_REPLY    2048
#define VPU_SLOT_MAIL     3072
#define VPU_SLOT_PROGRESS 3136   /* uint64_t defer_n, card-written while an instance runs */

_Static_assert(sizeof(struct vpu_slot_req) == 360, "slot request layout is shared with the card and the preload");
_Static_assert(sizeof(struct vpu_slot_reply) == 88, "slot reply layout is shared");
_Static_assert(sizeof(struct vpu_slot_mail) == 40, "slot mail layout is shared");

#endif
