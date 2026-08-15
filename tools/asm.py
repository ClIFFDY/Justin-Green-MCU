#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# MCU v2.0 汇编器：助记符 .asm → ins_rom.hex（$readmemh 格式，4096 字节 ROM）
#
# 编码依据：说明文档/指令集说明/mc_v2.0_ins.md
#   byte0 = opcode[5:0]<<2 | len（len = 字节数-2，0..3）
#   指令长度：2B=HALT/NOP/IRET/JALR；4B=ALU/LBU/SB；5B=跳转/分支
#   bytmov 有效 12 位（±4095），相对指令末尾（addr+len）：
#     5B 跳转/分支：byte1=bm[11:4]，byte4 高半字节=bm[3:0]（byte4={bm[3:0],0000}）
#     方向：R(向前)=target-(addr+len)，L(向后)=(addr+len)-target
#
# 用法：
#   python tools/asm.py 程序.asm                 # 默认输出 project_self-try.srcs/ins_rom.hex
#   python tools/asm.py 程序.asm -o 别的.hex      # 指定输出
#
# .asm 语法：
#   注释：# 或 //；助记符大小写不敏感；操作数用逗号或空格分隔
#   寄存器：rN 或裸数字（0-255）；立即数/地址：十进制或 0x 十六进制
#   跳转目标写【绝对地址】，汇编器自动算 bytmov（方向由 L/R 前缀决定）
#   伪指令：
#     .org <addr>       设置当前地址（程序区 0x000-0xFFF，4096 字节 ROM）
#     .equ NAME <value> 定义常量，可被操作数引用
#     .byte <b>[,<b>..] 直接放原始字节
#     .str "text"       放 ASCII 字符串（支持 \r \n \t \\ \" \xNN）
# ============================================================

import argparse
import sys
from pathlib import Path

# ---------------------------------------------------------------- 指令表
# (opcode6, 字节数, 格式)
# 格式：none=无操作数；jalr=byte1 预留 0；jump=绝对目标→bytmov12；
#       branch=r1,r2,绝对目标→bytmov12；alu_r=rd,rs1,rs2；alu_i=rd,rs1,imm8；
#       lb=rd,addr16；sb=rs,addr16
# byte0 = opcode<<2 | (字节数-2)
INS = {
    # 控制（2B）
    'HALT': (0x00, 2, 'none'),
    'NOP':  (0x14, 2, 'none'),
    'IRET': (0x15, 2, 'none'),
    # 跳转（5B，bytmov 12 位）
    'LJAL': (0x08, 5, 'jump'),   # 向后压栈调用
    'RJAL': (0x09, 5, 'jump'),   # 向前压栈调用
    'JALR': (0x13, 2, 'jalr'),   # 弹栈返回（2B）
    # 分支（5B）
    'LBEQ':  (0x16, 5, 'branch'),
    'RBEQ':  (0x17, 5, 'branch'),
    'LBNE':  (0x18, 5, 'branch'),
    'RBNE':  (0x19, 5, 'branch'),
    'LBLTU': (0x1A, 5, 'branch'),
    'RBLTU': (0x1B, 5, 'branch'),
    # ALU-R（4B）
    'ADD':  (0x02, 4, 'alu_r'),
    'SUB':  (0x04, 4, 'alu_r'),
    'AND':  (0x05, 4, 'alu_r'),
    'OR':   (0x06, 4, 'alu_r'),
    'XOR':  (0x07, 4, 'alu_r'),
    'SLL':  (0x0D, 4, 'alu_r'),
    'SRL':  (0x0E, 4, 'alu_r'),
    'SLTU': (0x11, 4, 'alu_r'),
    # ALU-I（4B）
    'ADDI':  (0x01, 4, 'alu_i'),
    'SUBI':  (0x03, 4, 'alu_i'),
    'ANDI':  (0x0A, 4, 'alu_i'),
    'ORI':   (0x0B, 4, 'alu_i'),
    'XORI':  (0x0C, 4, 'alu_i'),
    'SLLI':  (0x0F, 4, 'alu_i'),
    'SRLI':  (0x10, 4, 'alu_i'),
    'SLTIU': (0x12, 4, 'alu_i'),
    # 访存（4B）
    'LBU': (0x1C, 4, 'lb'),
    'SB':  (0x1D, 4, 'sb'),
}

ROM_TOP = 0xFFF  # PC 16 位，程序区 0x000-0xFFF（4096 字节 ROM）
BM_MAX = 0xFFF   # bytmov 有效 12 位（±4095）


class AsmError(Exception):
    pass


# ---------------------------------------------------------------- 解析工具
def parse_int(tok, symbols):
    """数字（十进制/0x/0b）、.equ 常量或单引号字符（'c' / '\\r' / '\\xNN'）→ int。"""
    tok = tok.strip()
    if not tok:
        raise AsmError('空操作数')
    if tok in symbols:
        return symbols[tok]
    # 单引号字符：'A' / '\r' / '\x0D'
    if len(tok) >= 3 and tok[0] == "'" and tok[-1] == "'":
        inner = tok[1:-1]
        if len(inner) == 1:
            return ord(inner)
        if len(inner) == 2 and inner[0] == '\\':
            simple = {'r': 13, 'n': 10, 't': 9, '\\': 92, "'": 39, '0': 0}
            if inner[1] in simple:
                return simple[inner[1]]
            raise AsmError(f'无效字符转义: {tok}')
        raise AsmError(f'无效字符字面量: {tok}')
    try:
        low = tok.lower()
        if low.startswith('0x'):
            return int(tok, 16)
        if low.startswith('0b'):
            return int(tok, 2)
        return int(tok, 10)
    except ValueError:
        raise AsmError(f'无效数字/未定义常量: {tok}')


def parse_reg(tok, symbols):
    t = tok.strip()
    # 支持 rN / RN 或裸数字
    if t[:1].lower() == 'r' and t[1:].isdigit():
        v = int(t[1:], 10)
    else:
        v = parse_int(t, symbols)
    if not (0 <= v <= 0xFF):
        raise AsmError(f'寄存器号越界: {tok}（须 0-255）')
    return v


def split_operands(s):
    """按逗号/空白切分操作数；引号内的空格/逗号不切（支持 ' ' 这类字符常量）。"""
    toks = []
    cur = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in ("'", '"'):
            # 引号串整体作为一个 token（含转义）
            j = i + 1
            while j < n:
                if s[j] == '\\':
                    j += 2
                    continue
                if s[j] == c:
                    break
                j += 1
            cur.append(s[i:j + 1])
            i = j + 1
            continue
        if c in ', \t':
            if cur:
                toks.append(''.join(cur))
                cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    if cur:
        toks.append(''.join(cur))
    return toks


def calc_bytmov(direction, addr, nbytes, target):
    """direction='R' 向前（target-(addr+len)），'L' 向后（(addr+len)-target）。
    返回 0..BM_MAX（12 位有效）。"""
    end = addr + nbytes
    if direction == 'R':
        bm = target - end
        if not (0 <= bm <= BM_MAX):
            raise AsmError(f'向前跳越界：addr=0x{addr:03X} target=0x{target:03X} '
                           f'bytmov={bm}（须 0-0x{BM_MAX:X}，方向不对换 L 前缀？）')
        return bm
    else:
        bm = end - target
        if not (0 <= bm <= BM_MAX):
            raise AsmError(f'向后跳越界：addr=0x{addr:03X} target=0x{target:03X} '
                           f'bytmov={bm}（须 0-0x{BM_MAX:X}，方向不对换 R 前缀？）')
        return bm


def bm_bytes(bm):
    """bytmov 12 位 → 5B 指令的 byte1 / byte4 编码。
    byte1=bm[11:4]，byte4 高半字节=bm[3:0]。"""
    return [(bm >> 4) & 0xFF, ((bm & 0xF) << 4)]


def parse_str(operands):
    """从 .str 操作数里取双引号串并解码转义 → bytes。"""
    s = operands.strip()
    a, b = s.find('"'), s.rfind('"')
    if a < 0 or b <= a:
        raise AsmError('.str 需要双引号字符串')
    inner = s[a + 1:b]
    out = bytearray()
    i = 0
    simple = {'r': 13, 'n': 10, 't': 9, '\\': 92, '"': 34, '0': 0}
    while i < len(inner):
        c = inner[i]
        if c == '\\' and i + 1 < len(inner):
            n = inner[i + 1]
            if n in simple:
                out.append(simple[n]); i += 2; continue
            if n == 'x' and i + 3 < len(inner):
                try:
                    out.append(int(inner[i + 2:i + 4], 16)); i += 4; continue
                except ValueError:
                    pass
            raise AsmError(f'.str 未知转义: \\{n}')
        out.append(ord(c)); i += 1
    return bytes(out)


def place(addr, bs, comment, mem, instrs):
    """把 bs 放到 addr 起始；冲突报错。mem 记录字节，instrs 记录输出排布。"""
    if addr > ROM_TOP or addr + len(bs) - 1 > ROM_TOP:
        raise AsmError(f'程序区越界：0x{addr:03X}（PC 16 位，最大 0x{ROM_TOP:03X}）')
    for i, b in enumerate(bs):
        a = addr + i
        if a in mem:
            raise AsmError(f'地址 0x{a:03X} 重复定义（.org 回退进了已写区域？）')
        mem[a] = b
    instrs[addr] = (list(bs), comment.strip())


# ---------------------------------------------------------------- 汇编
def assemble(src_lines):
    """src_lines：源文件行（含换行）。返回 (mem, instrs, max_addr)；出错抛 AsmError 含多行信息。"""
    symbols = {}
    mem = {}
    instrs = {}
    addr = 0
    errs = []

    for ln, raw in enumerate(src_lines, 1):
        # 去注释（# 或 //）
        line = raw.split('#', 1)[0].split('//', 1)[0].strip()
        if not line:
            continue
        toks = line.split(None, 1)
        m = toks[0].upper()
        operands = toks[1] if len(toks) > 1 else ''
        ops = split_operands(operands)
        try:
            if m == '.ORG':
                if len(ops) != 1:
                    raise AsmError('.org 需要 1 个地址')
                addr = parse_int(ops[0], symbols)
                if not (0 <= addr <= ROM_TOP):
                    raise AsmError(f'.org 越界: 0x{addr:03X}')
                continue
            if m == '.EQU':
                if len(ops) != 2:
                    raise AsmError('.equ 需要 .equ NAME value')
                symbols[ops[0]] = parse_int(ops[1], symbols)
                continue
            if m == '.BYTE':
                bs = []
                for t in ops:
                    b = parse_int(t, symbols)
                    if not (0 <= b <= 0xFF):
                        raise AsmError(f'.byte 越界: {t}')
                    bs.append(b)
                place(addr, bs, raw, mem, instrs)
                addr += len(bs)
                continue
            if m == '.STR':
                bs = list(parse_str(operands))
                place(addr, bs, raw, mem, instrs)
                addr += len(bs)
                continue
            if m not in INS:
                raise AsmError(f'未知助记符/伪指令: {m}')

            opcode, nbytes, fmt = INS[m]
            ops = split_operands(operands)
            bs = encode(m, opcode, nbytes, fmt, ops, addr, symbols)
            place(addr, bs, raw, mem, instrs)
            addr += nbytes
        except AsmError as e:
            errs.append(f'第 {ln} 行: {e}')
            errs.append(f'    {raw.rstrip()}')

    if errs:
        raise AsmError('\n'.join(errs))
    if not mem:
        raise AsmError('程序为空')
    return mem, instrs, max(mem)


def encode(m, opcode, nbytes, fmt, ops, addr, symbols):
    byte0 = (opcode << 2) | (nbytes - 2)

    def need(n):
        if len(ops) != n:
            raise AsmError(f'{m} 需要 {n} 个操作数，给了 {len(ops)}')

    if fmt == 'none':
        need(0)
        return [byte0, 0x00]
    if fmt == 'jalr':
        need(0)
        return [byte0, 0x00]
    if fmt == 'jump':
        need(1)
        target = parse_int(ops[0], symbols)
        if not (0 <= target <= ROM_TOP):
            raise AsmError(f'跳转目标越界: 0x{target:03X}')
        bm = calc_bytmov(m[0], addr, nbytes, target)
        b1, b4 = bm_bytes(bm)
        return [byte0, b1, 0x00, 0x00, b4]
    if fmt == 'branch':
        need(3)
        # 汇编写法：LBEQ r1, r2, 目标（RISC-V 风格：寄存器在前、绝对目标最后）
        r1 = parse_reg(ops[0], symbols)
        r2 = parse_reg(ops[1], symbols)
        target = parse_int(ops[2], symbols)
        if not (0 <= target <= ROM_TOP):
            raise AsmError(f'跳转目标越界: 0x{target:03X}')
        bm = calc_bytmov(m[0], addr, nbytes, target)
        b1, b4 = bm_bytes(bm)
        return [byte0, b1, r1, r2, b4]
    if fmt == 'alu_r':
        need(3)
        return [byte0, parse_reg(ops[0], symbols), parse_reg(ops[1], symbols), parse_reg(ops[2], symbols)]
    if fmt == 'alu_i':
        need(3)
        rd, rs1 = parse_reg(ops[0], symbols), parse_reg(ops[1], symbols)
        imm = parse_int(ops[2], symbols)
        if not (0 <= imm <= 0xFF):
            raise AsmError(f'立即数越界: {ops[2]}（须 0-255）')
        return [byte0, rd, rs1, imm]
    if fmt == 'lb':
        need(2)
        rd = parse_reg(ops[0], symbols)
        a = parse_int(ops[1], symbols)
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'16 位地址越界: {ops[1]}')
        return [byte0, rd, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'sb':
        need(2)
        rs = parse_reg(ops[0], symbols)
        a = parse_int(ops[1], symbols)
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'16 位地址越界: {ops[1]}')
        return [byte0, rs, (a >> 8) & 0xFF, a & 0xFF]
    raise AsmError(f'未知格式 {fmt}')


# ---------------------------------------------------------------- 输出
def write_hex(mem, instrs, fh):
    """$readmemh 格式：@0000 + 字节；间隙填 HALT(0x00)；指令行带源注释。
    写满 0x000-0xFFF 共 4096 字节——$readmemh 未指定地址会留 X，全填 HALT 保证 ROM 无 X。"""
    fh.write('@0000\n')
    i = 0
    while i <= ROM_TOP:
        if i in instrs:
            bs, comment = instrs[i]
            fh.write(' '.join('%02X' % b for b in bs))
            if comment:
                fh.write('   // ' + comment.strip())
            fh.write('\n')
            i += len(bs)
        else:
            run = []
            while i <= ROM_TOP and i not in instrs and len(run) < 8:
                run.append(mem.get(i, 0x00))
                i += 1
            fh.write(' '.join('%02X' % b for b in run) + '\n')


def main():
    # 保证在 UTF-8/GBK 终端里中文都尽量不糊
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='MCU v2.0 汇编器：.asm → ins_rom.hex')
    ap.add_argument('src', help='源 .asm 文件')
    ap.add_argument('-o', '--output', help='输出 hex 路径（默认 project_self-try.srcs/ins_rom.hex）')
    args = ap.parse_args()

    try:
        src_lines = Path(args.src).read_text(encoding='utf-8').splitlines()
    except OSError as e:
        print(f'无法读取源文件: {e}')
        sys.exit(1)

    try:
        mem, instrs, max_addr = assemble(src_lines)
    except AsmError as e:
        print('汇编失败：')
        print(e)
        sys.exit(1)

    # 默认输出到 ins_rom.v 硬编码的绝对路径
    if args.output:
        out_path = Path(args.output)
    else:
        out_path = Path(__file__).resolve().parent.parent / 'project_self-try.srcs' / 'ins_rom.hex'

    with open(out_path, 'w', encoding='utf-8', newline='\n') as fh:
        write_hex(mem, instrs, fh)

    # 打印 listing 便于核对
    print(f'程序范围: 0x000–0x{max_addr:03X}（{len(mem)} 字节），ROM 已填满 0x000–0xFFF -> {out_path}')
    print('---- listing ----')
    i = 0
    while i <= max_addr:
        if i in instrs:
            bs, comment = instrs[i]
            print(f'0x{i:03X}: {" ".join("%02X" % b for b in bs):20} | {comment.strip()}')
            i += len(bs)
        else:
            run = []
            while i <= max_addr and i not in instrs and len(run) < 8:
                run.append(mem.get(i, 0x00))
                i += 1
            print(f'0x{i - len(run):03X}: {" ".join("%02X" % b for b in run):20} | (填充)')


if __name__ == '__main__':
    main()
