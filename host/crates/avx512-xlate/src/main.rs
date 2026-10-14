//! `avx512-xlate`: turn a function written in AVX-512 into one the card can
//! run.
//!
//! The observation this tool is built on: Knights Corner is x86-64. The
//! scalar half of an AVX-512 function, the pointer arithmetic, the loop
//! counter, the branches, is already valid card code and needs no
//! translation at all. Only the EVEX instructions have to be rewritten.
//!
//! So the pipeline is: assemble the AVX-512 source with the host's own
//! assembler, which can encode instructions this host cannot execute;
//! decode the result; rewrite each EVEX instruction into its MVEX
//! equivalent; pass everything else through after checking it against the
//! deletions Knights Corner made to the base instruction set; and emit
//! assembly for the card.
//!
//! Instruction lengths change during the rewrite, since an unaligned
//! AVX-512 load becomes two card instructions. Relative branch
//! displacements would therefore be wrong if bytes were copied verbatim,
//! so branch targets are collected first, a label is emitted at each one,
//! and branches are emitted as text against those labels for the card's
//! assembler to resolve.

use std::collections::BTreeSet;
use std::io::Write;
use std::process::Command;

use anyhow::{bail, Context, Result};
use iced_x86::{Decoder, DecoderOptions, Formatter, Instruction, IntelFormatter, Mnemonic, OpKind};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: avx512-xlate <input.s> [--name FN] [--out OUT.S]");
        eprintln!();
        eprintln!("Assembles an AVX-512 function with llvm-mc, translates every EVEX");
        eprintln!("instruction to Knights Corner MVEX, and writes card assembly.");
        std::process::exit(2);
    }
    if args[1] == "--gen-opcodes" {
        return gen_opcodes(args.get(2).context("--gen-opcodes needs an output path")?);
    }
    if args[1] == "--dump" {
        return dump(args.get(2).context("--dump needs an ELF path")?);
    }
    let input = &args[1];
    let mut name = "kernel".to_string();
    let mut out: Option<String> = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--name" => {
                name = args.get(i + 1).context("--name needs a value")?.clone();
                i += 2;
            }
            "--out" => {
                out = Some(args.get(i + 1).context("--out needs a value")?.clone());
                i += 2;
            }
            other => bail!("unknown argument {other}"),
        }
    }

    let code = assemble(input)?;
    let text = translate_function(&code, &name)?;
    match out {
        Some(p) => {
            std::fs::write(&p, text).with_context(|| format!("writing {p}"))?;
            eprintln!("wrote {p}");
        }
        None => std::io::stdout().write_all(text.as_bytes())?,
    }
    Ok(())
}

/// Assemble the AVX-512 source with `llvm-mc` and return the `.text` bytes.
///
/// The host assembler encodes AVX-512 happily; it is the host *processor*
/// that cannot run it. That gap is the whole reason this tool exists.
fn assemble(path: &str) -> Result<Vec<u8>> {
    let obj = std::env::temp_dir().join(format!("avx512-xlate-{}.o", std::process::id()));
    let status = Command::new("llvm-mc")
        .args(["-triple=x86_64", "-mattr=+avx512f", "-filetype=obj", "-o"])
        .arg(&obj)
        .arg(path)
        .status()
        .context("running llvm-mc; is it on PATH?")?;
    if !status.success() {
        bail!("llvm-mc failed to assemble {path}");
    }
    let data = std::fs::read(&obj)?;
    let _ = std::fs::remove_file(&obj);
    section_text(&data).context("no .text section in the assembled object")
}

/// Pull the code section out of the assembled relocatable.
fn section_text(data: &[u8]) -> Option<Vec<u8>> {
    use object::{Object, ObjectSection};
    let file = object::File::parse(data).ok()?;
    let text = file.section_by_name(".text")?;
    Some(text.data().ok()?.to_vec())
}

/// Decode, translate, and emit card assembly for one function body.
fn translate_function(code: &[u8], name: &str) -> Result<String> {
    // Pass one: decode everything, and note every address a branch can
    // reach, so a label can be planted there.
    let mut insns: Vec<Instruction> = Vec::new();
    let mut decoder = Decoder::with_ip(64, code, 0, DecoderOptions::NONE);
    while decoder.can_decode() {
        insns.push(decoder.decode());
    }
    let mut targets: BTreeSet<u64> = BTreeSet::new();
    for insn in &insns {
        if is_branch(insn) {
            if let Some(t) = branch_target(insn) {
                targets.insert(t);
            }
        }
    }

    let mut fmt = IntelFormatter::new();
    fmt.options_mut().set_space_after_operand_separator(true);
    // GNU as in .intel_syntax mode wants 0x40, not the MASM 40h that iced
    // emits by default.
    fmt.options_mut().set_hex_prefix("0x");
    fmt.options_mut().set_hex_suffix("");
    fmt.options_mut().set_uppercase_hex(false);
    let mut s = String::new();
    let mut translated_count = 0usize;
    let mut passthrough_count = 0usize;

    s.push_str(&format!("// {name}: generated by avx512-xlate from AVX-512 source.\n"));
    s.push_str("// Do not edit. EVEX instructions have been rewritten as MVEX; the\n");
    s.push_str("// scalar instructions are the originals, which Knights Corner runs as\n");
    s.push_str("// they are because it is an x86-64 core.\n");
    s.push_str(".intel_syntax noprefix\n.text\n");
    s.push_str(&format!(".globl {name}\n.type {name}, @function\n{name}:\n"));

    for insn in &insns {
        if targets.contains(&insn.ip()) {
            s.push_str(&format!(".L_{:x}:\n", insn.ip()));
        }
        let mut text = String::new();
        fmt.format(insn, &mut text);

        if is_evex(insn) {
            let translated = avx512_xlate::translate(insn).map_err(|e| anyhow::anyhow!("{e}"))?;
            s.push_str(&format!("    // {text}\n"));
            for t in &translated {
                s.push_str(&format!("    .byte {}  // {}\n", hex(&t.bytes), t.text));
            }
            translated_count += 1;
        } else if is_branch(insn) {
            let target = branch_target(insn).context("branch with no computable target")?;
            let mnem = text.split_whitespace().next().unwrap_or("jmp").to_string();
            s.push_str(&format!("    {mnem} .L_{target:x}\n"));
            passthrough_count += 1;
        } else {
            if let Some(reason) = knc_illegal(insn) {
                bail!("{text}: {reason}");
            }
            s.push_str(&format!("    {text}\n"));
            passthrough_count += 1;
        }
    }
    s.push_str(&format!(".size {name}, .-{name}\n"));
    eprintln!("{name}: {translated_count} EVEX instructions translated, {passthrough_count} scalar passed through");
    Ok(s)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("0x{b:02x}")).collect::<Vec<_>>().join(", ")
}

/// An EVEX-encoded instruction is one this host can assemble but not run,
/// and the one this tool has to rewrite. iced reports the encoding
/// directly.
fn is_evex(insn: &Instruction) -> bool {
    insn.encoding() == iced_x86::EncodingKind::EVEX
}

fn is_branch(insn: &Instruction) -> bool {
    matches!(insn.op0_kind(), OpKind::NearBranch16 | OpKind::NearBranch32 | OpKind::NearBranch64)
}

fn branch_target(insn: &Instruction) -> Option<u64> {
    match insn.op0_kind() {
        OpKind::NearBranch64 => Some(insn.near_branch64()),
        OpKind::NearBranch32 => Some(insn.near_branch32().into()),
        OpKind::NearBranch16 => Some(insn.near_branch16().into()),
        _ => None,
    }
}

/// The base-instruction-set deletions that matter for generated code.
/// `docs/research/isa-deletions.md` has the full list and its sources; the
/// ones a compiler or a hand-written kernel actually emits are these.
fn knc_illegal(insn: &Instruction) -> Option<&'static str> {
    match insn.mnemonic() {
        Mnemonic::Cmovo
        | Mnemonic::Cmovno
        | Mnemonic::Cmovb
        | Mnemonic::Cmovae
        | Mnemonic::Cmove
        | Mnemonic::Cmovne
        | Mnemonic::Cmovbe
        | Mnemonic::Cmova
        | Mnemonic::Cmovs
        | Mnemonic::Cmovns
        | Mnemonic::Cmovp
        | Mnemonic::Cmovnp
        | Mnemonic::Cmovl
        | Mnemonic::Cmovge
        | Mnemonic::Cmovle
        | Mnemonic::Cmovg => Some("cmov is not supported in 64-bit mode on Knights Corner (ISA reference B.2)"),
        Mnemonic::Pause => Some("pause is not supported; the card has DELAY instead (ISA reference B.2)"),
        Mnemonic::Lfence | Mnemonic::Mfence | Mnemonic::Sfence => Some("the fence instructions are absent; use lock addq 0, [rsp]"),
        Mnemonic::Prefetcht0 | Mnemonic::Prefetcht1 | Mnemonic::Prefetcht2 | Mnemonic::Prefetchnta | Mnemonic::Prefetchw => {
            Some("scalar prefetch is absent; the card has VPREFETCH* (SSDG 4.2.12)")
        }
        Mnemonic::Popcnt | Mnemonic::Lzcnt | Mnemonic::Tzcnt => Some("not present on the card in scalar form"),
        Mnemonic::Clflush => Some("clflush is absent; the card has CLEVICT0/1"),
        _ => {
            if insn.encoding() == iced_x86::EncodingKind::VEX {
                Some("VEX-encoded AVX: the card has no xmm or ymm registers at all (ISA reference B.2)")
            } else {
                None
            }
        }
    }
}

/// `--gen-opcodes OUT`: the listing `tools/x86-opcodes.txt` that
/// `tools/gen-x86-tables.c` turns into the assembly decoder's tables
/// (`host/asm/phi512/x86tab.inc`): one line per instruction code
/// iced-x86 knows in 64-bit mode with a legacy, VEX or EVEX encoding,
/// tab-separated: encoding, opcode table, mandatory prefix, opcode
/// (hex), opcode bytes, ModRM.reg group (-1 if /r), ModRM.rm group,
/// W (0, 1, or W when ignored), L (0, 1, 2, or L when ignored), tuple
/// type, flags, operand size, address size, the operand kinds joined
/// by commas, the mnemonic, the code, the opcode string, the
/// instruction string.
fn gen_opcodes(out: &str) -> Result<()> {
    use iced_x86::{Code, DecoderOptions, EncodingKind};
    use std::fmt::Write as _;
    let mut s = String::new();
    s.push_str("# x86-opcodes.txt: every instruction code of iced-x86 1.21 (OpCodeInfo) that is\n");
    s.push_str("# a 64-bit-mode legacy, VEX or EVEX instruction needing no decoder option.\n");
    s.push_str("# Written by `avx512-xlate --gen-opcodes`; read by tools/gen-x86-tables.c.\n");
    s.push_str("# enc\ttable\tpfx\topcode\tlen\tgrp\trmgrp\tW\tL\ttuple\tflags\topsize\taddrsize\toperands\tmnemonic\tcode\topcode-string\tinstruction-string\n");
    let mut n = 0usize;
    for code in Code::values() {
        let oc = code.op_code();
        if !oc.is_instruction() || !oc.mode64() {
            continue;
        }
        match oc.encoding() {
            EncodingKind::Legacy | EncodingKind::VEX | EncodingKind::EVEX => {}
            _ => continue,
        }
        if oc.decoder_option() != DecoderOptions::NONE {
            continue;
        }
        let w = if oc.is_wig() || oc.is_wig32() {
            "W".to_string()
        } else {
            oc.w().to_string()
        };
        let l = if oc.is_lig() { "L".to_string() } else { oc.l().to_string() };
        let mut flags = String::new();
        if oc.can_broadcast() {
            flags.push('b');
        }
        if oc.can_use_zeroing_masking() {
            flags.push('z');
        }
        if oc.can_use_op_mask_register() {
            flags.push('k');
        }
        if oc.require_op_mask_register() {
            flags.push('K');
        }
        if oc.can_use_rounding_control() {
            flags.push('r');
        }
        if oc.can_suppress_all_exceptions() {
            flags.push('e');
        }
        if oc.ignores_mod_bits() {
            flags.push('m');
        }
        if oc.is_stack_instruction() {
            flags.push('s');
        }
        if oc.is_nop() || oc.is_reserved_nop() {
            flags.push('n');
        }
        if oc.fwait() {
            flags.push('f');
        }
        if oc.can_use_lock_prefix() {
            flags.push('l');
        }
        if oc.default_op_size64() {
            flags.push('D');
        }
        if oc.force_op_size64() {
            flags.push('F');
        }
        if oc.is_privileged() {
            flags.push('p');
        }
        if flags.is_empty() {
            flags.push('-');
        }
        let ops: Vec<String> = (0..oc.op_count()).map(|i| format!("{:?}", oc.op_kind(i))).collect();
        let ops = if ops.is_empty() { "-".to_string() } else { ops.join(",") };
        writeln!(
            s,
            "{:?}\t{:?}\t{:?}\t{:04x}\t{}\t{}\t{}\t{}\t{}\t{:?}\t{}\t{}\t{}\t{}\t{:?}\t{:?}\t{}\t{}",
            oc.encoding(),
            oc.table(),
            oc.mandatory_prefix(),
            oc.op_code(),
            oc.op_code_len(),
            oc.group_index(),
            oc.rm_group_index(),
            w,
            l,
            oc.tuple_type(),
            flags,
            oc.operand_size(),
            oc.address_size(),
            ops,
            oc.mnemonic(),
            code,
            oc.op_code_string(),
            oc.instruction_string()
        )?;
        n += 1;
    }
    std::fs::write(out, s).with_context(|| format!("writing {out}"))?;
    eprintln!("wrote {out}: {n} codes");
    Ok(())
}

/// `--dump ELF`: iced's decoding of the file's `.text`, one line per
/// instruction, the reference the assembly decoder's dump is compared
/// with (`tools/decode-check.c`): offset in the file's address space,
/// length, flow control, encoding, the code, then for a memory operand
/// `base index scale disp` (register names, decimal scale, signed hex
/// displacement, `-` for none), the immediate (signed hex or `-`), the
/// mask register and zeroing and broadcast flags.
fn dump(path: &str) -> Result<()> {
    use iced_x86::{Decoder, DecoderOptions, OpKind, Register};
    use object::{Object, ObjectSection};
    use std::fmt::Write as _;
    let data = std::fs::read(path).with_context(|| format!("reading {path}"))?;
    let file = object::File::parse(&*data)?;
    let text = file.section_by_name(".text").context("no .text")?;
    let bytes = text.data()?;
    let mut decoder = Decoder::with_ip(64, bytes, text.address(), DecoderOptions::NONE);
    let mut out = String::with_capacity(bytes.len() * 8);
    let mut insn = iced_x86::Instruction::default();
    while decoder.can_decode() {
        decoder.decode_out(&mut insn);
        let mut mem = String::from("-");
        let mut imm = String::from("-");
        for i in 0..insn.op_count() {
            match insn.op_kind(i) {
                OpKind::Memory => {
                    let base = insn.memory_base();
                    let idx = insn.memory_index();
                    let d = insn.memory_displacement64() as i64;
                    let d = if base == Register::RIP {
                        (insn.memory_displacement64() as i64) - (insn.next_ip() as i64)
                    } else {
                        d
                    };
                    mem = format!(
                        "{:?} {:?} {} {}",
                        base,
                        idx,
                        insn.memory_index_scale(),
                        if d < 0 { format!("-{:x}", -d) } else { format!("{:x}", d) }
                    );
                }
                OpKind::Immediate8
                | OpKind::Immediate16
                | OpKind::Immediate32
                | OpKind::Immediate64
                | OpKind::Immediate8to16
                | OpKind::Immediate8to32
                | OpKind::Immediate8to64
                | OpKind::Immediate32to64
                | OpKind::Immediate8_2nd => {
                    let v = insn.immediate(i) as i64;
                    imm = if v < 0 { format!("-{:x}", -v) } else { format!("{:x}", v) };
                }
                OpKind::NearBranch64 => {
                    imm = format!("{:x}", insn.near_branch64());
                }
                _ => {}
            }
        }
        let _ = writeln!(
            out,
            "{:x} {} {:?} {:?} {:?} {} {} {:?} {} {}",
            insn.ip(),
            insn.len(),
            insn.flow_control(),
            insn.encoding(),
            insn.code(),
            mem,
            imm,
            insn.op_mask(),
            insn.zeroing_masking() as u8,
            insn.is_broadcast() as u8
        );
    }
    std::io::stdout().write_all(out.as_bytes())?;
    Ok(())
}
