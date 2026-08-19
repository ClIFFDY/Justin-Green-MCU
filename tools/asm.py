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
    'SBI': 0x1E, 'LIND': 0x1F, 'SIND': 0x20,
    # 'MOV' 无独立 opcode：RTL 已放弃 MOV，汇编器把 `MOV rd, rs` 翻译为 ADDI rd,rs,0（见 parse_lines）
}

# (格式, 原长字节数)
# 格式：none=无操作数；jalr=返回；jump=绝对目标→bytmov；branch=r1,r2,绝对目标→bytmov；
#       alu_r=rd,rs1,rs2；alu_i=rd,rs1,imm8；lb=rd,addr16；sb=rs,addr16；sbi=imm8,addr16
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
    'SBI': ('sbi', 4),
    # 间接访存（寄存器寻址，addr = r1:r2）
    'LIND': ('lind', 4),
    'SIND': ('sind', 4),
}

# flag=01 无操作数压缩（对应 decoder 注释 CNOP/CIRET/CMOV 里的前两个；MOV 按 ALU 类 flag=11 处理）
COMPRESSIBLE_01 = ('NOP', 'IRET')
# flag=11 ALU 类压缩：alu_r / alu_i（字段满足才可压）

ROM_TOP = 0xFFF  # PC 12 位词地址，0x000-0xFFF（4096 词）
DATA_BASE = 0xB000  # 数据区总线地址（ram_sec_4，RTL 初始化读 hex 后半）
DATA_ROM_START = 4096  # hex 后半起始词（词 4096-8191 = 数据区 4096 字节，每词低 8 位）
HEX_TOP = 8191  # hex 总词数（前 4096 程序 + 后 4096 数据）

OPERAND_N = {'none': 0, 'jalr': 0, 'jump': 1, 'branch': 3,
             'alu_r': 3, 'alu_i': 3, 'lb': 2, 'sb': 2, 'sbi': 2,
             'lind': 3, 'sind': 3}
LABEL_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


class AsmError(Exception):
    pass


# ---------------------------------------------------------------- 解析工具
def parse_int(tok, symbols):
    """数字、.equ 常量、字符字面量、简单表达式（base&N / base>>N / base±N）→ int。"""
    tok = tok.strip()
    if not tok:
        raise AsmError('空操作数')
    # 简单表达式：base op num（递归解析 base，支持 datalabel 如 (msg>>8)/(msg&0xFF)）
    m = re.match(r'^\(?(.+?)\)?\s*(&|>>|<<|\+|-)\s*(\d+|0x[0-9a-fA-F]+)$', tok)
    if m:
        base, op, num = m.group(1).strip(), m.group(2), int(m.group(3), 0)
        bv = parse_int(base, symbols)
        if op == '&': return bv & num
        if op == '>>': return bv >> num
        if op == '<<': return bv << num
        if op == '+': return bv + num
        if op == '-': return bv - num
    if tok in symbols:
        return symbols[tok]
    if len(tok) >= 3 and tok[0] == "'" and tok[-1] == "'":
        inner = tok[1:-1]
        if len(inner) == 1:
            return ord(inner)
        if len(inner) == 2 and inner[0] == '\\':
            simple = {'r': 13, 'n': 10, 't': 9, 'b': 8, 'a': 7, 'f': 12,
                      '\\': 92, "'": 39, '0': 0}
            if inner[1] in simple:
                return simple[inner[1]]
            raise AsmError(f'无效字符转义: {tok}')
        if len(inner) == 4 and inner[0] == '\\' and inner[1] == 'x':
            try:
                return int(inner[2:4], 16)
            except ValueError:
                pass
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


def eval_expr(tok, symbols):
    """安全求值算术表达式：十进制/0x/0b 字面量 + 符号，支持 + - * / % ( )。
    供 .rep 展开后的地址表达式（如 `0x9400 + 2*$i`）使用。"""
    src = tok.strip()
    n = len(src)
    pos = 0

    def peek():
        return src[pos] if pos < n else ''

    def skip():
        nonlocal pos
        while pos < n and src[pos] in ' \t':
            pos += 1

    def num():
        nonlocal pos
        skip()
        m = re.match(r'(0[xX][0-9a-fA-F]+|0[bB][01]+|\d+|[A-Za-z_][A-Za-z0-9_]*)', src[pos:])
        if not m:
            raise AsmError(f'表达式无效: {tok}')
        t = m.group()
        pos += len(t)
        if t in symbols:
            return symbols[t]
        if t.lower().startswith('0x'):
            return int(t, 16)
        if t.lower().startswith('0b'):
            return int(t, 2)
        return int(t)

    def factor():
        nonlocal pos
        skip()
        if peek() == '(':
            pos += 1
            v = expr()
            skip()
            if peek() != ')':
                raise AsmError(f'表达式括号不配对: {tok}')
            pos += 1
            return v
        if peek() == '-':
            pos += 1
            return -factor()
        return num()

    def term():
        nonlocal pos
        v = factor()
        while True:
            skip()
            c = peek()
            if c == '*':
                pos += 1
                v *= factor()
            elif c == '/':
                pos += 1
                d = factor()
                if d == 0:
                    raise AsmError(f'除零: {tok}')
                v //= d
            elif c == '%':
                pos += 1
                d = factor()
                if d == 0:
                    raise AsmError(f'取模除零: {tok}')
                v %= d
            else:
                return v

    def expr():
        nonlocal pos
        v = term()
        while True:
            skip()
            c = peek()
            if c == '+':
                pos += 1
                v += term()
            elif c == '-':
                pos += 1
                v -= term()
            else:
                return v

    v = expr()
    skip()
    if pos != n:
        raise AsmError(f'表达式尾部多余: {tok}')
    return int(v)


def parse_int(tok, symbols):
    tok = tok.strip()
    if not tok:
        raise AsmError('空操作数')
    # datalabel 偏移表达式：lab>>N / lab&N（数据区标签 → 0xB000+偏移）
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*(&|>>)\s*(\d+|0x[0-9a-fA-F]+)$', tok)
    if m:
        base, op, num = m.group(1), m.group(2), int(m.group(3), 0)
        bv = parse_int(base, symbols)
        return bv & num if op == '&' else bv >> num
    if tok in symbols:
        return symbols[tok]
    if len(tok) >= 3 and tok[0] == "'" and tok[-1] == "'":
        inner = tok[1:-1]
        if len(inner) == 1:
            return ord(inner)
        if len(inner) == 2 and inner[0] == '\\':
            simple = {'r': 13, 'n': 10, 't': 9, 'b': 8, 'a': 7, 'f': 12,
                      '\\': 92, "'": 39, '0': 0}
            if inner[1] in simple:
                return simple[inner[1]]
            raise AsmError(f'无效字符转义: {tok}')
        if len(inner) == 4 and inner[0] == '\\' and inner[1] == 'x':
            try:
                return int(inner[2:4], 16)
            except ValueError:
                pass
        raise AsmError(f'无效字符字面量: {tok}')
    try:
        if re.search(r'[+\-*/%()]', tok):
            return eval_expr(tok, symbols)
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


def strip_comment(line):
    """去掉 # 和 // 注释；引号内的 # 和 // 是字符常量，不处理。"""
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c in "'\"":
            j = i + 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == c:
                    break
                j += 1
            i = j + 1
            continue
        if c == '#':
            return line[:i]
        if c == '/' and i + 1 < n and line[i + 1] == '/':
            return line[:i]
        i += 1
    return line


def expand_reps(src_lines):
    """展开 `.rep N` .. `.endr` 循环（支持嵌套）：`$i`=最内层索引，`$j`=外层索引。
    行级预处理，在 parse_lines 之前。"""
    result = []
    i, n = 0, len(src_lines)
    while i < n:
        line = src_lines[i]
        m = re.match(r'^\.REP\s+(\d+)\s*$', line.strip(), re.I)
        if m:
            count = int(m.group(1))
            depth = 1
            body = []
            i += 1
            while i < n and depth > 0:
                s = src_lines[i].strip()
                if re.match(r'^\.REP\b', s, re.I):
                    depth += 1
                elif re.match(r'^\.ENDR\b', s, re.I):
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                if depth > 0:
                    body.append(src_lines[i])
                i += 1
            if depth != 0:
                raise AsmError('.rep 缺少 .endr 配对')
            inner = expand_reps(body)
            for idx in range(count):
                for bl in inner:
                    result.append(bl.replace('$i', str(idx)).replace('$j', str(idx)))
            continue
        result.append(line)
        i += 1
    return result


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
        o = ord(c)
        if o < 128:
            out.append(o)                # ASCII 单字节
        else:
            out += c.encode('utf-8')     # 非 ASCII（中文等）→ UTF-8 多字节
        i += 1
    return bytes(out)


# ---------------------------------------------------------------- 编码
# 自动修正计数（main 里汇总打印）
AUTO_NOP_COUNT = 0
AUTO_FLIP_COUNT = 0
# .puts 展开用唯一标签计数器
_PUTS_CTR = 0
# 自动 jpad 计数 + 标签计数器
AUTO_JPAD_COUNT = 0
_JPAD_CTR = 0


def _flip_side(m):
    """翻转分支前缀 L↔R（语义不变，仅编码方向位）。"""
    return ('L' if m[0] == 'R' else 'R') + m[1:]


def bytmov_for(mnem, word, target):
    """bytmov 16 位【词单位】，基准 W+2。R=向前 target-(W+2)，L=向后 (W+2)-target。
    须 1 ≤ bytmov ≤ 0xFFFF（pc.v 判 0 为不跳 → 目标=W+2 不可编码）。
    方向与前缀相反时自动翻转前缀（L↔R），仍越界才报错（此时需人工处理）。"""
    global AUTO_FLIP_COUNT
    if not (0 <= target <= ROM_TOP):
        raise AsmError(f'跳转目标越界: 0x{target:03X}（须 0x000-0xFFF）')
    fwd = target - (word + 2)
    bwd = (word + 2) - target
    d0 = mnem[0]
    for d, bm in ((d0, fwd if d0 == 'R' else bwd),
                  ('L' if d0 == 'R' else 'R', bwd if d0 == 'R' else fwd)):
        if 1 <= bm <= 0xFFFF:
            if d != d0:
                AUTO_FLIP_COUNT += 1
                return bm, _flip_side(mnem)
            return bm, mnem
    raise AsmError(f'跳转越界：word=0x{word:03X} target=0x{target:03X} '
                   f'bytmov={fwd if d0 == "R" else bwd}（须 1-0xFFFF；'
                   f'目标=当前词+2 时 bytmov=0 不可编码，属死区）')


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
        try:
            imm = parse_int(ops[2], symbols)
        except AsmError:
            return None      # 表达式含未定义 datalabel（如 __pdN>>8）→ 不压缩
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
        bm, eff = bytmov_for(m, word, target)
        return [OPCODE[eff] << 2, (bm >> 8) & 0xFF, bm & 0xFF, 0x00]
    if fmt == 'branch':
        r1 = parse_reg(ops[0], symbols)
        r2 = parse_reg(ops[1], symbols)
        if r1 > 0xF or r2 > 0xF:
            raise AsmError(f'{m} 分支寄存器须 0-15（4 位）：r1={r1} r2={r2}')
        target = tget(ops[2])
        bm, eff = bytmov_for(m, word, target)
        return [OPCODE[eff] << 2, (bm >> 8) & 0xFF, bm & 0xFF, (r1 << 4) | r2]
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
        a = tget(ops[1])
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 位地址越界: {ops[1]}')
        return [b0, rd, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'sb':
        rs = parse_reg(ops[0], symbols)
        a = tget(ops[1])
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 位地址越界: {ops[1]}')
        return [b0, rs, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'sbi':
        # SBI imm8, addr16：byte1=立即数，byte2:3=16 位地址（与 SB 布局一致，仅源改为立即数）
        imm = parse_int(ops[0], symbols)
        a = parse_int(ops[1], symbols)
        if not (0 <= imm <= 0xFF):
            raise AsmError(f'{m} 立即数越界: {ops[0]}（须 0-255）')
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 位地址越界: {ops[1]}')
        return [b0, imm, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'lind':
        # LIND rd, r1, r2：byte1=rd，byte2=r1(addr 高8位)，byte3=r2(addr 低8位)；addr = r1:r2
        rd = parse_reg(ops[0], symbols)
        r1 = parse_reg(ops[1], symbols)
        r2 = parse_reg(ops[2], symbols)
        return [b0, rd, r1, r2]
    if fmt == 'sind':
        # SIND rs, r1, r2：byte1=rs(源寄存器，RTL 存 bus_data_final=r_bus 值)，
        #   byte2=r1(addr 高8位)，byte3=r2(addr 低8位)；写 rs 的值到 [r1:r2]
        rs = parse_reg(ops[0], symbols)
        r1 = parse_reg(ops[1], symbols)
        r2 = parse_reg(ops[2], symbols)
        return [b0, rs, r1, r2]
    raise AsmError(f'未知格式 {fmt}')


# ---------------------------------------------------------------- 解析
def parse_lines(src_lines):
    global _PUTS_CTR
    symbols = {}
    items = []
    errs = []
    in_data = False          # .data 数据区：后续 .byte/.str/.db 进 hex 后半（0xB000 区）
    for ln, raw in enumerate(src_lines, 1):
        line = strip_comment(raw).strip()
        if not line:
            continue
        label = None
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$', line)
        if m:
            label = m.group(1)
            line = m.group(2).strip()
        try:
            if label:
                items.append({'kind': 'datalabel' if in_data else 'label',
                              'name': label, 'ln': ln})
            if not line:
                continue
            toks = line.split(None, 1)
            mnem = toks[0].upper()
            operands = toks[1] if len(toks) > 1 else ''
            ops = split_operands(operands)
            if mnem == '.DATA':
                in_data = True
                continue
            if mnem == '.DB':
                if not in_data:
                    raise AsmError('.db 必须位于 .data 数据区内')
                bs = []
                for t in ops:
                    if t.startswith('"') or t.startswith("'"):
                        bs += list(parse_str(t))
                    else:
                        b = parse_int(t, symbols)
                        if not (0 <= b <= 0xFF):
                            raise AsmError(f'.db 越界: {t}')
                        bs.append(b)
                items.append({'kind': 'datadata', 'bytes': bs, 'src': raw.strip(), 'ln': ln})
                continue
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
                items.append({'kind': 'datadata' if in_data else 'data',
                              'bytes': bs, 'src': raw.strip(), 'ln': ln})
                continue
            if mnem == '.STR':
                bs = list(parse_str(operands))
                items.append({'kind': 'datadata' if in_data else 'data',
                              'bytes': bs, 'src': raw.strip(), 'ln': ln})
                continue
            if mnem == '.PUTS':
                # 伪指令 .puts "text"：>3 字符用数据区 LIND 循环（文本进 hex 后半，每字符 1 字节；
                # 循环 ~13 词固定 + 数据区）。短文本（≤3 字符）保持内联逐字符（3 词/字符）——
                # 长文本数据区省、短文本内联省。默认目标 putc，可用第二个参数换。
                bs = list(parse_str(operands))
                ops = split_operands(operands)
                tgt = 'putc'
                if len(ops) == 2:
                    tgt = ops[1]
                if len(bs) > 8 and tgt == 'putc':
                    lab = f'__pd{_PUTS_CTR}'
                    # datalabel 必须在 datadata 前：偏移 = 当前累积（文本起始），否则取到文本后
                    items.append({'kind': 'datalabel', 'name': lab, 'ln': ln})
                    items.append({'kind': 'datadata', 'bytes': bs, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'ADDI', 'fmt': 'alu_i', 'nbytes': 4,
                                  'ops': ['r1', 'r0', f'{lab}>>8'], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'ADDI', 'fmt': 'alu_i', 'nbytes': 4,
                                  'ops': ['r2', 'r0', f'{lab}&0xFF'], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'ADDI', 'fmt': 'alu_i', 'nbytes': 4,
                                  'ops': ['r6', 'r0', str(len(bs))], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'label', 'name': f'__pl{_PUTS_CTR}', 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'LIND', 'fmt': 'lind', 'nbytes': 4,
                                  'ops': ['r7', 'r1', 'r2'], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'ADDI', 'fmt': 'alu_i', 'nbytes': 4,
                                  'ops': ['r2', 'r2', '1'], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'LJAL', 'fmt': 'jump', 'nbytes': 3,
                                  'ops': [tgt], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'ADDI', 'fmt': 'alu_i', 'nbytes': 4,
                                  'ops': ['r6', 'r6', '0xFF'], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'RBNE', 'fmt': 'branch', 'nbytes': 4,
                                  'ops': ['r6', 'r0', f'__pl{_PUTS_CTR}'], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    _PUTS_CTR += 1
                    continue
                for i, b in enumerate(bs):
                    lab = f'__puts{_PUTS_CTR}_{i}'
                    items.append({'kind': 'ins', 'mnem': 'ADDI', 'fmt': 'alu_i', 'nbytes': 4,
                                  'ops': ['r7', 'r0', str(b)], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'LBNE', 'fmt': 'branch', 'nbytes': 4,
                                  'ops': ['r0', 'r0', lab], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                    items.append({'kind': 'label', 'name': lab, 'ln': ln})
                    items.append({'kind': 'ins', 'mnem': 'LJAL', 'fmt': 'jump', 'nbytes': 3,
                                  'ops': [tgt], 'cbytes': None, 'src': raw.strip(), 'ln': ln})
                _PUTS_CTR += 1
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
        if k in ('label', 'datalabel', 'datadata'):
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
                and (i + 1) not in must_first
                and not nxt.get('force_first')):
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
            while j < len(items) and items[j]['kind'] in ('label', 'datalabel', 'datadata'):
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


def _insert_deadzone_nops(items, layout, label_word):
    """死区自动补 NOP：前向分支(jump/branch)目标落在死区（target < word+3，
    bytmov 0/-1 硬件判不跳）时，在目标 label 前自动插 NOP 把距离拉到 ≥1。
    返回本次插入的 NOP 总数（0=无需再插）。label 紧跟 .org 时跳过（避免移位破坏固定地址）。"""
    label_pos = {}
    for idx, it in enumerate(items):
        if it['kind'] == 'label':
            label_pos[it['name']] = idx
    need = {}   # label item 下标 → 需插 NOP 数
    for idx, it in enumerate(items):
        if it['kind'] == 'ins' and it['fmt'] in ('jump', 'branch'):
            tok = it['ops'][0] if it['fmt'] == 'jump' else it['ops'][2]
            t = tok.strip()
            if is_label(t) and t in label_word and t in label_pos:
                word = layout[idx][0]
                target = label_word[t]
                # 死区 = target 恰在 word+2：L 与 R 的 bytmov 都=0，无前缀可救。
                # (target=word+1 可用 L 编码 bytmov=1，方向翻转可救，不需要补 NOP)
                if target == word + 2:
                    li = label_pos[t]
                    if li > 0 and items[li - 1]['kind'] == 'org':
                        continue      # label 紧跟 .org：不自动移位，留给编码报错
                    n = word + 3 - target
                    need[li] = max(need.get(li, 0), n)
    if not need:
        return 0
    for li in sorted(need, reverse=True):   # 从后往前插，保证下标稳定
        for _ in range(need[li]):
            items.insert(li, {
                'kind': 'ins', 'mnem': 'NOP', 'fmt': 'none', 'nbytes': 1,
                'ops': [], 'cbytes': [OPCODE['NOP'] << 2 | 0x01, 0x00],
                'src': '// 自动 NOP（bytmov 死区）', 'ln': 0,
                'force_first': True,
            })
    return sum(need.values())


def is_label(tok):
    return LABEL_RE.match(tok) is not None


# ---- 自动 __jpad 垫层（IRET W+2 语义硬性约定）----
# 中断只在顺序指令（授权点，irq_en==11）派发；派发时 W+1 被跳过。
# 若控制转移在 W+1 槽位会被吞 → 每条【顺序指令后的控制转移】前必须垫
# `LBNE r0,r0,<lab>` + `<lab>:`（自跳 1 词、永不取）。汇编器自动补：
#   · 控制转移 = 9 条（LJAL/RJAL/JALR/LBEQ/RBEQ/LBNE/RBNE/LBLTU/RBLTU）
#   · 前一条真实指令是顺序指令 → 插入垫层；是控制转移（含 IRET/HALT）→ 天然安全不插
#   · 源里已手写垫层（LBNE r0,r0,<lab> 紧跟 <lab>:）→ 跳过（对既有程序字节兼容）
# 不 pad IRET/HALT（前者是返回、后者停机，均无授权点跳过问题）。

CTRL_FMTS = ('jump', 'branch', 'jalr')


def _is_ctrl_ins(it):
    return (it['kind'] == 'ins'
            and (it['fmt'] in CTRL_FMTS or it['mnem'] in ('IRET', 'HALT')))


def _is_jpad_pair(items, i):
    """items[i] 是否为源里手写的 jpad：LBNE r0,r0,<lab> 紧跟 <lab> 标签。"""
    return (i + 1 < len(items)
            and items[i]['kind'] == 'ins' and items[i]['mnem'] == 'LBNE'
            and len(items[i]['ops']) == 3 and items[i]['ops'][0] == 'r0'
            and items[i]['ops'][1] == 'r0'
            and items[i + 1]['kind'] == 'label'
            and items[i + 1]['name'] == items[i]['ops'][2])


def auto_jpad(items):
    """按序扫描，给需要垫层的控制转移前插 jpad。返回新 items。
    控制转移本身是分支，若前一条真实指令是顺序指令（授权点）则需垫层。
    源里手写的 jpad（LBNE r0,r0,<lab>+<lab>:）是已完成的垫层：不重复垫、
    且其后紧邻的控制转移视为已有垫层。"""
    global AUTO_JPAD_COUNT, _JPAD_CTR
    out = []
    prev_ctrl = True            # 程序首指令前无授权点，视为安全
    i = 0
    n = len(items)
    while i < n:
        it = items[i]
        if _is_jpad_pair(items, i):
            # 源里手写 jpad：原样搬运（不垫它自己），并把下一个真实指令视为安全
            out.append(it)
            out.append(items[i + 1])
            prev_ctrl = True
            i += 2
            continue
        if it['kind'] == 'ins' and it['fmt'] in CTRL_FMTS and not prev_ctrl:
            lab = f'__jpadAUTO{_JPAD_CTR}'
            _JPAD_CTR += 1
            out.append({'kind': 'ins', 'mnem': 'LBNE', 'fmt': 'branch', 'nbytes': 4,
                        'ops': ['r0', 'r0', lab], 'cbytes': None,
                        'src': '// 自动 jpad（IRET W+2 垫层）', 'ln': 0})
            out.append({'kind': 'label', 'name': lab, 'ln': 0})
            AUTO_JPAD_COUNT += 1
        out.append(it)
        if it['kind'] == 'ins':
            prev_ctrl = _is_ctrl_ins(it)
        elif it['kind'] == 'data':
            prev_ctrl = False   # 数据词视作顺序，保守补垫
        i += 1
    return out


# ---------------------------------------------------------------- 汇编
def assemble(src_lines):
    global AUTO_NOP_COUNT
    src_lines = expand_reps(src_lines)   # 展开 .rep/.endr（行级预处理）
    items, symbols = parse_lines(src_lines)
    if not items:
        raise AsmError('程序为空')
    # 自动 __jpad 垫层（IRET W+2）：顺序指令后的控制转移自动补垫，既有手写垫层跳过
    items = auto_jpad(items)
    # 死区自动 NOP：前向分支目标落在 [W+1, W+2]（bytmov 0/-1 不可编码）时在目标
    # label 前插 NOP 拉开。固定点迭代：插 NOP 只会增大前向距离，必然收敛。
    while True:
        layout, word_packed, label_word = run_layout(items)
        added = _insert_deadzone_nops(items, layout, label_word)
        if not added:
            break
        AUTO_NOP_COUNT += added

    # 数据区（.data）：收集字节 + datalabel 地址（0xB000 + 偏移）
    data_bytes = []
    datalabel = {}
    for it in items:
        if it['kind'] == 'datadata':
            data_bytes.extend(it['bytes'])
        elif it['kind'] == 'datalabel':
            datalabel[it['name']] = DATA_BASE + len(data_bytes)
    if len(data_bytes) > 4096:
        raise AsmError(f'数据区超 4096 字节: {len(data_bytes)}')
    symbols.update(datalabel)   # 数据标签可被 parse_int 表达式引用（(msg>>8)/(msg&0xFF)）

    def resolve_t(tok):
        t = tok.strip()
        # label±N（数据/符号标签偏移）
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*([+-])\s*(\d+)$', t)
        if m:
            base = m.group(1)
            off = int(m.group(3))
            bv = resolve_t(base)
            return bv + off if m.group(2) == '+' else bv - off
        if t in symbols:
            return symbols[t]
        if t in datalabel:
            return datalabel[t]
        if is_label(t):
            if t in label_word:
                return label_word[t]
            raise AsmError(f'未定义标签: {t}')
        return parse_int(t, symbols)

    words = {}
    srcs = {}
    first_slots = set()
    max_word = 0
    # 数据字节 → hex 后半（词 DATA_ROM_START+j，低 8 位字节）
    for j, b in enumerate(data_bytes):
        words[DATA_ROM_START + j] = b & 0xFF
        max_word = max(max_word, DATA_ROM_START + j)

    i = 0
    n = len(items)
    while i < n:
        it = items[i]
        k = it['kind']
        if k in ('label', 'org', 'datalabel', 'datadata'):
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
    """程序 hex（0-4095 词，32bit 词，byte0=高位 opcode 在 [31:24]）。未用词填 0。"""
    fh.write('@0000\n')
    for w in range(0, ROM_TOP + 1):
        if w in srcs:
            fh.write('%08X' % words[w])
            fh.write('   // ' + ' | '.join(s.strip() for s in srcs[w]))
            fh.write('\n')
        else:
            fh.write('%08X\n' % words.get(w, 0x00000000))


def write_data_hex(words, fh):
    """数据 hex（0-4095 词，每词 8 位字节；ram_sec_init 载入到 0xB000 区）。"""
    fh.write('@0000\n')
    for j in range(0, 4096):
        fh.write('%02X\n' % (words.get(DATA_ROM_START + j, 0x00000000) & 0xFF))


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
    data_path = out_path.with_name('data.hex')

    with open(out_path, 'w', encoding='utf-8', newline='\n') as fh:
        write_hex(words, srcs, max_word, fh)
    # 数据区单独输出 data.hex（词 4096-8191，ram_sec_init 载入到 0xB000）
    with open(data_path, 'w', encoding='utf-8', newline='\n') as fh:
        write_data_hex(words, fh)

    print(f'程序范围: 0x000–0x{max_word:03X}（{max_word + 1} 词），ROM 已填满 0x000–0xFFF -> {out_path}')
    print(f'数据区: 输出 -> {data_path}')
    if AUTO_NOP_COUNT or AUTO_FLIP_COUNT or AUTO_JPAD_COUNT:
        print(f'自动修正: 补 NOP {AUTO_NOP_COUNT} 个（bytmov 死区），'
              f'方向翻转 {AUTO_FLIP_COUNT} 处（L/R 前缀自动纠正），'
              f'补 jpad {AUTO_JPAD_COUNT} 个（IRET W+2 垫层）')
    print('---- listing（词地址 | 32bit 词 | 源）----')
    for w in range(0, max_word + 1):
        if w in srcs:
            print(f'0x{w:03X}: {words[w]:08X} | {" | ".join(s.strip() for s in srcs[w])}')
        else:
            print(f'0x{w:03X}: {words.get(w, 0):08X} | (填充)')


if __name__ == '__main__':
    main()
