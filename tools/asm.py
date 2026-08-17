#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# MCU 汇编器（词寻址 + 自动压缩/打包）：助记符 .asm → ins_rom.hex
#   （2026-08-17 架构：12 位词寻址 ROM，32bit 定长取指）
#
# 编码依据：decoder.v / if_reg.v / pc.v / ins_rom.v
#   PC 12 位【词地址】0x000-0xFFF（4096 词 × 32bit BRAM）
#   byte0 = opcode[5:0]<<2 | flag[1:0]
#     flag=00 原长指令（长度由 opcode 决定，独占一个 32bit 词，不足 4 字节补 0）
#     flag=11 ALU 类压缩 16bit：6op + 2flag + 2rd + 3r1 + 3r2（I 型末字段=imm[2:0]）
#     flag=01 无操作数压缩 16bit：NOP / IRET
#   bytmov 16 位【词单位】，基准 W+2（指令在词 W 执行时 pc_addr 已到 W+2）：
#     R(向前) = target-(W+2)，L(向后) = (W+2)-target；1 ≤ bytmov ≤ 0xFFFF
#     （目标=当前词+2 时 bytmov=0 不可编码；向前最少跳 2 词）
#   自动压缩：ALU-R/I 满足 rd≤3、r1/r2≤7（I 型 imm≤7）→ flag=11；NOP/IRET → flag=01
#   自动打包：相邻两条压缩指令共享一个 32bit 词（前=[31:16]，后=[15:0]）
#     跳转/分支目标必须落在【词首指令】；.org 处恒为词首
#     压缩但无法配对的指令退回原长（保证每个压缩词两半都非空，cstall 才正确）
# 用法：
#   python tools/asm.py 程序.asm [-o 输出.hex]   # 默认写 project_self-try.srcs/ins_rom.hex
# .asm 语法：
#   注释：# 或 //；寄存器 rN 或裸数字（分支须 0-15，r255 只读=tx_busy）
#   跳转/分支目标：label 名 或 绝对词地址（汇编器自动算 bytmov）
#   标签：`名字:` 独立一行 或 指令行首
#   伪指令：.org <词地址>  .equ NAME <值>  .byte <b>[,<b>..]  .str "text"
#   伪指令：MOV rd, rs = 复制，自动翻译为 ADDI rd, rs, 0（RTL 已放弃 MOV 独立 opcode）
# ============================================================

import argparse
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------- 指令集
# opcode[5:0]（来自 decoder.v localparam）
OPCODE = {
    'HALT': 0x00, 'ADDI': 0x01, 'ADD': 0x02, 'SUBI': 0x03, 'SUB': 0x04,
    'AND': 0x05, 'OR': 0x06, 'XOR': 0x07, 'LJAL': 0x08, 'RJAL': 0x09,
    'ANDI': 0x0A, 'ORI': 0x0B, 'XORI': 0x0C, 'SLL': 0x0D, 'SRL': 0x0E,
    'SLLI': 0x0F, 'SRLI': 0x10, 'SLTU': 0x11, 'SLTIU': 0x12, 'JALR': 0x13,
    'NOP': 0x14, 'IRET': 0x15, 'LBEQ': 0x16, 'RBEQ': 0x17, 'LBNE': 0x18,
    'RBNE': 0x19, 'LBLTU': 0x1A, 'RBLTU': 0x1B, 'LBU': 0x1C, 'SB': 0x1D,
    # 'MOV' 无独立 opcode：RTL 已放弃 MOV，汇编器把 `MOV rd, rs` 翻译为 ADDI rd,rs,0（见 parse_lines）
}

# (格式, 原长字节数)
# 格式：none=无操作数；jalr=返回；jump=绝对目标→bytmov；branch=r1,r2,绝对目标→bytmov；
#       alu_r=rd,rs1,rs2；alu_i=rd,rs1,imm8；lb=rd,addr16；sb=rs,addr16
INS = {
    # 控制
    'HALT': ('none', 1),
    'NOP':  ('none', 1),
    'IRET': ('none', 1),
    # 跳转
    'LJAL': ('jump', 3),   # 向后压栈调用
    'RJAL': ('jump', 3),   # 向前压栈调用
    'JALR': ('jalr', 2),   # 弹栈返回
    # 分支（寄存器 4 位 0-15；bytmov 16 位词单位）
    'LBEQ':  ('branch', 4),
    'RBEQ':  ('branch', 4),
    'LBNE':  ('branch', 4),
    'RBNE':  ('branch', 4),
    'LBLTU': ('branch', 4),
    'RBLTU': ('branch', 4),
    # ALU-R
    'ADD': ('alu_r', 4), 'SUB': ('alu_r', 4), 'AND': ('alu_r', 4),
    'OR': ('alu_r', 4), 'XOR': ('alu_r', 4), 'SLL': ('alu_r', 4),
    'SRL': ('alu_r', 4), 'SLTU': ('alu_r', 4),
    # ALU-I
    'ADDI': ('alu_i', 4), 'SUBI': ('alu_i', 4), 'ANDI': ('alu_i', 4),
    'ORI': ('alu_i', 4), 'XORI': ('alu_i', 4), 'SLLI': ('alu_i', 4),
    'SRLI': ('alu_i', 4), 'SLTIU': ('alu_i', 4),
    # 访存
    'LBU': ('lb', 4),
    'SB':  ('sb', 4),
}

# flag=01 无操作数压缩（对应 decoder 注释 CNOP/CIRET/CMOV 里的前两个；MOV 按 ALU 类 flag=11 处理）
COMPRESSIBLE_01 = ('NOP', 'IRET')
# flag=11 ALU 类压缩：alu_r / alu_i（字段满足才可压）

ROM_TOP = 0xFFF  # PC 12 位词地址，0x000-0xFFF（4096 词）

OPERAND_N = {'none': 0, 'jalr': 0, 'jump': 1, 'branch': 3,
             'alu_r': 3, 'alu_i': 3, 'lb': 2, 'sb': 2}
LABEL_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


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


# ---------------------------------------------------------------- 编码
def calc_bytmov(direction, word, target):
    """bytmov 16 位【词单位】，基准 W+2。R=向前 target-(W+2)，L=向后 (W+2)-target。
    须 1 ≤ bytmov ≤ 0xFFFF（pc.v 判 0 为不跳 → 目标=W+2 不可编码）。"""
    if not (0 <= target <= ROM_TOP):
        raise AsmError(f'跳转目标越界: 0x{target:03X}（须 0x000-0xFFF）')
    bm = target - (word + 2) if direction == 'R' else (word + 2) - target
    if not (1 <= bm <= 0xFFFF):
        raise AsmError(f'跳转越界：word=0x{word:03X} target=0x{target:03X} '
                       f'bytmov={bm}（须 1-0xFFFF；目标=当前词+2 时 bytmov=0 不可编码；'
                       f'方向不对换 {"L" if direction == "R" else "R"} 前缀？）')
    return bm


def compressed_bytes(m, fmt, ops, symbols):
    """返回 16bit 压缩编码 [b0,b1]，不可压返回 None。
    flag=11（ALU-R/I）：byte1={rd[1:0],r1[2:0],r2[2:0]}，I 型末字段=imm[2:0]；
    flag=01（NOP/IRET）：byte1=0x00。"""
    if m in COMPRESSIBLE_01:
        return [OPCODE[m] << 2 | 0x01, 0x00]
    if fmt == 'alu_r':
        rd = parse_reg(ops[0], symbols)
        r1 = parse_reg(ops[1], symbols)
        r2 = parse_reg(ops[2], symbols)
        if rd <= 3 and r1 <= 7 and r2 <= 7:
            return [OPCODE[m] << 2 | 0x03, (rd << 6) | (r1 << 3) | r2]
    if fmt == 'alu_i':
        rd = parse_reg(ops[0], symbols)
        rs1 = parse_reg(ops[1], symbols)
        imm = parse_int(ops[2], symbols)
        if rd <= 3 and rs1 <= 7 and 0 <= imm <= 7:
            return [OPCODE[m] << 2 | 0x03, (rd << 6) | (rs1 << 3) | imm]
    return None


def long_bytes(m, fmt, ops, symbols, word, tget):
    """原长编码（flag=00）→ 4 字节 [b0,b1,b2,b3]（不足补 0）。tget(tok)→绝对词地址。"""
    b0 = OPCODE[m] << 2
    if fmt == 'none':
        return [b0, 0, 0, 0]
    if fmt == 'jalr':
        return [b0, 0, 0, 0]
    if fmt == 'jump':
        target = tget(ops[0])
        bm = calc_bytmov(m[0], word, target)
        return [b0, (bm >> 8) & 0xFF, bm & 0xFF, 0x00]
    if fmt == 'branch':
        r1 = parse_reg(ops[0], symbols)
        r2 = parse_reg(ops[1], symbols)
        if r1 > 0xF or r2 > 0xF:
            raise AsmError(f'{m} 分支寄存器须 0-15（4 位）：r1={r1} r2={r2}')
        target = tget(ops[2])
        bm = calc_bytmov(m[0], word, target)
        return [b0, (bm >> 8) & 0xFF, bm & 0xFF, (r1 << 4) | r2]
    if fmt == 'alu_r':
        return [b0, parse_reg(ops[0], symbols), parse_reg(ops[1], symbols),
                parse_reg(ops[2], symbols)]
    if fmt == 'alu_i':
        rd = parse_reg(ops[0], symbols)
        rs1 = parse_reg(ops[1], symbols)
        imm = parse_int(ops[2], symbols)
        if not (0 <= imm <= 0xFF):
            raise AsmError(f'{m} 立即数越界: {ops[2]}（须 0-255）')
        return [b0, rd, rs1, imm]
    if fmt == 'lb':
        rd = parse_reg(ops[0], symbols)
        a = parse_int(ops[1], symbols)
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 位地址越界: {ops[1]}')
        return [b0, rd, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'sb':
        rs = parse_reg(ops[0], symbols)
        a = parse_int(ops[1], symbols)
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 位地址越界: {ops[1]}')
        return [b0, rs, (a >> 8) & 0xFF, a & 0xFF]
    raise AsmError(f'未知格式 {fmt}')


# ---------------------------------------------------------------- 解析
def parse_lines(src_lines):
    symbols = {}
    items = []
    errs = []
    for ln, raw in enumerate(src_lines, 1):
        line = raw.split('#', 1)[0].split('//', 1)[0].strip()
        if not line:
            continue
        label = None
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$', line)
        if m:
            label = m.group(1)
            line = m.group(2).strip()
        try:
            if label:
                items.append({'kind': 'label', 'name': label, 'ln': ln})
            if not line:
                continue
            toks = line.split(None, 1)
            mnem = toks[0].upper()
            operands = toks[1] if len(toks) > 1 else ''
            ops = split_operands(operands)
            if mnem == '.ORG':
                if len(ops) != 1:
                    raise AsmError('.org 需要 1 个词地址')
                a = parse_int(ops[0], symbols)
                if not (0 <= a <= ROM_TOP):
                    raise AsmError(f'.org 越界: 0x{a:03X}')
                items.append({'kind': 'org', 'addr': a, 'ln': ln})
                continue
            if mnem == '.EQU':
                if len(ops) != 2:
                    raise AsmError('.equ 需要 .equ NAME value')
                symbols[ops[0]] = parse_int(ops[1], symbols)
                continue
            if mnem == '.BYTE':
                bs = []
                for t in ops:
                    b = parse_int(t, symbols)
                    if not (0 <= b <= 0xFF):
                        raise AsmError(f'.byte 越界: {t}')
                    bs.append(b)
                items.append({'kind': 'data', 'bytes': bs, 'src': raw.strip(), 'ln': ln})
                continue
            if mnem == '.STR':
                bs = list(parse_str(operands))
                items.append({'kind': 'data', 'bytes': bs, 'src': raw.strip(), 'ln': ln})
                continue
            if mnem == 'MOV':
                # 伪指令：MOV rd, rs = rd 复制 rs。RTL 已放弃 MOV，翻译为 ADDI rd, rs, 0（语义等价，
                # 自动继承 ADDI 的压缩能力：rd≤3 且 rs≤7 时压成 16bit，否则原长 4 字节）。
                if len(ops) != 2:
                    raise AsmError('MOV 需要 2 个操作数（复制语义，自动转 ADDI）：MOV rd, rs')
                mnem = 'ADDI'
                ops = ops + ['0']
            if mnem not in INS:
                raise AsmError(f'未知助记符/伪指令: {mnem}')
            fmt, nb = INS[mnem]
            if len(ops) != OPERAND_N[fmt]:
                raise AsmError(f'{mnem} 需要 {OPERAND_N[fmt]} 个操作数，给了 {len(ops)}')
            cb = compressed_bytes(mnem, fmt, ops, symbols)  # 可压则给出 16bit，否则 None
            items.append({'kind': 'ins', 'mnem': mnem, 'fmt': fmt, 'nbytes': nb,
                          'ops': ops, 'cbytes': cb, 'src': raw.strip(), 'ln': ln})
        except AsmError as e:
            errs.append(f'第 {ln} 行: {e}')
            errs.append(f'    {raw.rstrip()}')
    if errs:
        raise AsmError('\n'.join(errs))
    return items, symbols


# ---------------------------------------------------------------- 布局
def compute_layout(items, must_first):
    """分配每条指令/数据的词地址。返回 (layout: item_idx→(word,is_second), word_packed: set, final_word)。
    相邻两条都可压且第二条非 must_first → 打包共享一词。"""
    layout = {}
    word_packed = set()
    word = 0
    i = 0
    n = len(items)
    while i < n:
        it = items[i]
        k = it['kind']
        if k == 'org':
            word = it['addr']
            i += 1
            continue
        if k == 'label':
            i += 1
            continue
        if k == 'data':
            layout[i] = (word, False)
            word += (len(it['bytes']) + 3) // 4
            i += 1
            continue
        nxt = items[i + 1] if i + 1 < n else None
        if (nxt is not None and nxt['kind'] == 'ins'
                and it['cbytes'] is not None and nxt['cbytes'] is not None
                and (i + 1) not in must_first):
            layout[i] = (word, False)
            layout[i + 1] = (word, True)
            word_packed.add(word)
            word += 1
            i += 2
        else:
            layout[i] = (word, False)
            word += 1
            i += 1
    return layout, word_packed, word


def run_layout(items):
    """固定点布局：让所有跳转目标（label）落在词首。返回 (layout, word_packed, label_word)。"""
    label_item = {}
    for idx, it in enumerate(items):
        if it['kind'] == 'label':
            j = idx + 1
            while j < len(items) and items[j]['kind'] == 'label':
                j += 1
            label_item[it['name']] = j
    target_items = set()
    for idx, it in enumerate(items):
        if it['kind'] == 'ins' and it['fmt'] in ('jump', 'branch'):
            tok = it['ops'][0] if it['fmt'] == 'jump' else it['ops'][2]
            tok = tok.strip()
            if is_label(tok) and tok in label_item:
                target_items.add(label_item[tok])
    must_first = set(target_items)
    while True:
        layout, word_packed, _ = compute_layout(items, must_first)
        bad = [t for t in target_items if layout[t][1]]
        if not bad:
            break
        must_first |= set(bad)
    label_word = {name: layout[idx][0] for name, idx in label_item.items()}
    return layout, word_packed, label_word


def is_label(tok):
    return LABEL_RE.match(tok) is not None


# ---------------------------------------------------------------- 汇编
def assemble(src_lines):
    items, symbols = parse_lines(src_lines)
    if not items:
        raise AsmError('程序为空')
    layout, word_packed, label_word = run_layout(items)

    def resolve_t(tok):
        t = tok.strip()
        if t in symbols:
            return symbols[t]
        if is_label(t):
            if t in label_word:
                return label_word[t]
            raise AsmError(f'未定义标签: {t}')
        return parse_int(t, symbols)

    words = {}
    srcs = {}
    first_slots = set()
    max_word = 0

    i = 0
    n = len(items)
    while i < n:
        it = items[i]
        k = it['kind']
        if k in ('label', 'org'):
            i += 1
            continue
        word, second = layout[i]
        if k == 'data':
            for j, b in enumerate(it['bytes']):
                w = word + j // 4
                shift = 24 - 8 * (j % 4)
                words[w] = words.get(w, 0) | (b << shift)
                max_word = max(max_word, w)
            first_slots.add(word)
            srcs.setdefault(word, []).append(it['src'])
            i += 1
            continue
        # ins
        if second:
            b0, b1 = it['cbytes']
            words[word] = words.get(word, 0) | ((b0 << 8) | b1)
            srcs.setdefault(word, []).append(it['src'])
            i += 1
            continue
        # first slot
        first_slots.add(word)
        if word in word_packed and it['cbytes'] is not None:
            b0, b1 = it['cbytes']
            words[word] = words.get(word, 0) | (((b0 << 8) | b1) << 16)
            srcs.setdefault(word, []).append(it['src'])
        else:
            bs = long_bytes(it['mnem'], it['fmt'], it['ops'], symbols, word, resolve_t)
            v = 0
            for j, b in enumerate(bs):
                v |= b << (24 - 8 * j)
            words[word] = words.get(word, 0) | v
            srcs.setdefault(word, []).append(it['src'])
        max_word = max(max_word, word)
        i += 1

    # 绝对目标必须落在词首（label 目标已在固定点里保证）
    for idx, it in enumerate(items):
        if it['kind'] == 'ins' and it['fmt'] in ('jump', 'branch'):
            tok = it['ops'][0] if it['fmt'] == 'jump' else it['ops'][2]
            t = tok.strip()
            if not is_label(t):
                v = resolve_t(t)
                if v not in first_slots:
                    raise AsmError(f'{it["mnem"]} 目标 0x{v:03X} 不是词首指令'
                                   f'（label 目标会自动对齐；绝对目标请核对 listing）')
    return words, srcs, max_word


# ---------------------------------------------------------------- 输出
def write_hex(words, srcs, max_word, fh):
    """$readmemh 格式（32bit 词）：@0000 + 每行一个 8 位十六进制词；
    未用词填 0x00000000（HALT）保证 ROM 无 X。词内字节序：byte0=高位（opcode 在 [31:24]）。"""
    fh.write('@0000\n')
    for w in range(0, ROM_TOP + 1):
        if w in srcs:
            fh.write('%08X' % words[w])
            fh.write('   // ' + ' | '.join(s.strip() for s in srcs[w]))
            fh.write('\n')
        else:
            fh.write('%08X\n' % 0x00000000)


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='MCU 汇编器：.asm → ins_rom.hex（词寻址 + 自动压缩/打包）')
    ap.add_argument('src', help='源 .asm 文件')
    ap.add_argument('-o', '--output', help='输出 hex 路径（默认 project_self-try.srcs/ins_rom.hex）')
    args = ap.parse_args()

    try:
        src_lines = Path(args.src).read_text(encoding='utf-8').splitlines()
    except OSError as e:
        print(f'无法读取源文件: {e}')
        sys.exit(1)

    try:
        words, srcs, max_word = assemble(src_lines)
    except AsmError as e:
        print('汇编失败：')
        print(e)
        sys.exit(1)

    if args.output:
        out_path = Path(args.output)
    else:
        out_path = Path(__file__).resolve().parent.parent / 'project_self-try.srcs' / 'ins_rom.hex'

    with open(out_path, 'w', encoding='utf-8', newline='\n') as fh:
        write_hex(words, srcs, max_word, fh)

    print(f'程序范围: 0x000–0x{max_word:03X}（{max_word + 1} 词），ROM 已填满 0x000–0xFFF -> {out_path}')
    print('---- listing（词地址 | 32bit 词 | 源）----')
    for w in range(0, max_word + 1):
        if w in srcs:
            print(f'0x{w:03X}: {words[w]:08X} | {" | ".join(s.strip() for s in srcs[w])}')
        else:
            print(f'0x{w:03X}: {words.get(w, 0):08X} | (填充)')


if __name__ == '__main__':
    main()
