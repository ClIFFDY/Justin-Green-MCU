#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# MCU æ±ç¼å¨ï¼è¯å¯»å + èªå¨åç¼©/æåï¼ï¼å©è®°ç¬¦ .asm â ins_rom.hex
#   ï¼2026-08-17 æ¶æï¼12 ä½è¯å¯»å ROMï¼32bit å®é¿åæï¼
#
# ç¼ç ä¾æ®ï¼decoder.v / if_reg.v / pc.v / ins_rom.v
#   PC 13 ä½ãè¯å°åã0x000-0x1FFFï¼8192 è¯ Ã 32bit BRAMï¼
#   byte0 = opcode[5:0]<<2 | flag[1:0]
#     flag=00 åé¿æä»¤ï¼é¿åº¦ç± opcode å³å®ï¼ç¬å ä¸ä¸ª 32bit è¯ï¼ä¸è¶³ 4 å­èè¡¥ 0ï¼
#     flag=11 ALU ç±»åç¼© 16bitï¼6op + 2flag + 2rd + 3r1 + 3r2ï¼I åæ«å­æ®µ=imm[2:0]ï¼
#     flag=01 æ æä½æ°åç¼© 16bitï¼NOP / IRET
#   bytmov 16 ä½ãè¯åä½ãï¼åºå W+2ï¼æä»¤å¨è¯ W æ§è¡æ¶ pc_addr å·²å° W+2ï¼ï¼
#     R(åå) = target-(W+2)ï¼L(åå) = (W+2)-targetï¼1 â¤ bytmov â¤ 0xFFFF
#     ï¼ç®æ =å½åè¯+2 æ¶ bytmov=0 ä¸å¯ç¼ç ï¼ååæå°è·³ 2 è¯ï¼
#   èªå¨åç¼©ï¼ALU-R/I æ»¡è¶³ rdâ¤3ãr1/r2â¤7ï¼I å immâ¤7ï¼â flag=11ï¼NOP/IRET â flag=01
#   èªå¨æåï¼ç¸é»ä¸¤æ¡åç¼©æä»¤å±äº«ä¸ä¸ª 32bit è¯ï¼å=[31:16]ï¼å=[15:0]ï¼
#     è·³è½¬/åæ¯ç®æ å¿é¡»è½å¨ãè¯é¦æä»¤ãï¼.org å¤æä¸ºè¯é¦
#     åç¼©ä½æ æ³éå¯¹çæä»¤éååé¿ï¼ä¿è¯æ¯ä¸ªåç¼©è¯ä¸¤åé½éç©ºï¼cstall ææ­£ç¡®ï¼
# ç¨æ³ï¼
#   python tools/asm.py ç¨åº.asm [-o è¾åº.hex]   # é»è®¤å project_self-try.srcs/ins_rom.hex
# .asm è¯­æ³ï¼
#   æ³¨éï¼# æ //ï¼å¯å­å¨ rN æè£¸æ°å­ï¼åæ¯é¡» 0-15ï¼r255 åªè¯»=tx_busyï¼
#   è·³è½¬/åæ¯ç®æ ï¼label å æ ç»å¯¹è¯å°åï¼æ±ç¼å¨èªå¨ç® bytmovï¼
#   æ ç­¾ï¼`åå­:` ç¬ç«ä¸è¡ æ æä»¤è¡é¦
#   ä¼ªæä»¤ï¼.org <è¯å°å>  .equ NAME <å¼>  .byte <b>[,<b>..]  .str "text"
#   ä¼ªæä»¤ï¼MOV rd, rs = å¤å¶ï¼èªå¨ç¿»è¯ä¸º ADDI rd, rs, 0ï¼RTL å·²æ¾å¼ MOV ç¬ç« opcodeï¼
# ============================================================

import argparse
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------- æä»¤é
# opcode[5:0]ï¼æ¥èª decoder.v localparamï¼
OPCODE = {
    'NOP': 0x00, 'ADDI': 0x01, 'ADD': 0x02, 'SUBI': 0x03, 'SUB': 0x04,
    'AND': 0x05, 'OR': 0x06, 'XOR': 0x07, 'LJAL': 0x08, 'RJAL': 0x09,
    'ANDI': 0x0A, 'ORI': 0x0B, 'XORI': 0x0C, 'SLL': 0x0D, 'SRL': 0x0E,
    'SLLI': 0x0F, 'SRLI': 0x10, 'SLTU': 0x11, 'SLTIU': 0x12, 'JALR': 0x13,
    'HALT': 0x14, 'IRET': 0x15, 'LBEQ': 0x16, 'RBEQ': 0x17, 'LBNE': 0x18,
    'RBNE': 0x19, 'LBLTU': 0x1A, 'RBLTU': 0x1B, 'LBU': 0x1C, 'SB': 0x1D,
    'SBI': 0x1E, 'LIND': 0x1F, 'SIND': 0x20,
    # 'MOV' æ ç¬ç« opcodeï¼RTL å·²æ¾å¼ MOVï¼æ±ç¼å¨æ `MOV rd, rs` ç¿»è¯ä¸º ADDI rd,rs,0ï¼è§ parse_linesï¼
}

# (æ ¼å¼, åé¿å­èæ°)
# æ ¼å¼ï¼none=æ æä½æ°ï¼jalr=è¿åï¼jump=ç»å¯¹ç®æ âbytmovï¼branch=r1,r2,ç»å¯¹ç®æ âbytmovï¼
#       alu_r=rd,rs1,rs2ï¼alu_i=rd,rs1,imm8ï¼lb=rd,addr16ï¼sb=rs,addr16ï¼sbi=imm8,addr16
INS = {
    # æ§å¶
    'HALT': ('none', 1),
    'NOP':  ('none', 1),
    'IRET': ('none', 1),
    # è·³è½¬
    'LJAL': ('jump', 3),   # åååæ è°ç¨
    'RJAL': ('jump', 3),   # åååæ è°ç¨
    'JALR': ('jalr', 2),   # å¼¹æ è¿å
    # åæ¯ï¼å¯å­å¨ 4 ä½ 0-15ï¼bytmov 16 ä½è¯åä½ï¼
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
    # è®¿å­
    'LBU': ('lb', 4),
    'SB':  ('sb', 4),
    'SBI': ('sbi', 4),
    # é´æ¥è®¿å­ï¼å¯å­å¨å¯»åï¼addr = r1:r2ï¼
    'LIND': ('lind', 4),
    'SIND': ('sind', 4),
}

# flag=01 æ æä½æ°åç¼©ï¼å¯¹åº decoder æ³¨é CNOP/CIRET/CMOV éçåä¸¤ä¸ªï¼MOV æ ALU ç±» flag=11 å¤çï¼
COMPRESSIBLE_01 = ('NOP', 'IRET')
# flag=11 ALU ç±»åç¼©ï¼alu_r / alu_iï¼å­æ®µæ»¡è¶³æå¯åï¼

ROM_TOP = 0x1FFF  # PC 13 ä½è¯å°åï¼0x000-0x1FFFï¼8192 è¯ï¼ins_rom æ©å®¹ï¼
DATA_BASE = 0xA000  # æ°æ®åºæ»çº¿å°åï¼ram_sec_init @0xA000ï¼0xB000 å·²è¢« ram_ext éçå ç¨ï¼
DATA_ROM_START = 8192  # words æ°ç»éæ°æ®åºèµ·å§ï¼ç¨åº 0-8191 è¯ + æ°æ®åº 4096 å­èï¼
HEX_TOP = 12287  # words æ°ç»æ»æ§½ï¼8192 ç¨åº + 4096 æ°æ®ï¼

OPERAND_N = {'none': 0, 'jalr': 0, 'jump': 1, 'branch': 3,
             'alu_r': 3, 'alu_i': 3, 'lb': 2, 'sb': 2, 'sbi': 2,
             'lind': 3, 'sind': 3}
LABEL_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


class AsmError(Exception):
    pass


# ---------------------------------------------------------------- è§£æå·¥å·
def parse_int(tok, symbols):
    """æ°å­ã.equ å¸¸éãå­ç¬¦å­é¢éãç®åè¡¨è¾¾å¼ï¼base&N / base>>N / baseÂ±Nï¼â intã"""
    tok = tok.strip()
    if not tok:
        raise AsmError('ç©ºæä½æ°')
    # ç®åè¡¨è¾¾å¼ï¼base op numï¼éå½è§£æ baseï¼æ¯æ datalabel å¦ (msg>>8)/(msg&0xFF)ï¼
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
            raise AsmError(f'æ æå­ç¬¦è½¬ä¹: {tok}')
        if len(inner) == 4 and inner[0] == '\\' and inner[1] == 'x':
            try:
                return int(inner[2:4], 16)
            except ValueError:
                pass
        raise AsmError(f'æ æå­ç¬¦å­é¢é: {tok}')
    try:
        low = tok.lower()
        if low.startswith('0x'):
            return int(tok, 16)
        if low.startswith('0b'):
            return int(tok, 2)
        return int(tok, 10)
    except ValueError:
        raise AsmError(f'æ ææ°å­/æªå®ä¹å¸¸é: {tok}')


def eval_expr(tok, symbols):
    """å®å¨æ±å¼ç®æ¯è¡¨è¾¾å¼ï¼åè¿å¶/0x/0b å­é¢é + ç¬¦å·ï¼æ¯æ + - * / % ( )ã
    ä¾ .rep å±å¼åçå°åè¡¨è¾¾å¼ï¼å¦ `0x9400 + 2*$i`ï¼ä½¿ç¨ã"""
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
            raise AsmError(f'è¡¨è¾¾å¼æ æ: {tok}')
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
                raise AsmError(f'è¡¨è¾¾å¼æ¬å·ä¸éå¯¹: {tok}')
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
                    raise AsmError(f'é¤é¶: {tok}')
                v //= d
            elif c == '%':
                pos += 1
                d = factor()
                if d == 0:
                    raise AsmError(f'åæ¨¡é¤é¶: {tok}')
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
        raise AsmError(f'è¡¨è¾¾å¼å°¾é¨å¤ä½: {tok}')
    return int(v)


def parse_int(tok, symbols):
    tok = tok.strip()
    if not tok:
        raise AsmError('ç©ºæä½æ°')
    # datalabel åç§»è¡¨è¾¾å¼ï¼lab>>N / lab&Nï¼æ°æ®åºæ ç­¾ â 0xA000+åç§»ï¼
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
            raise AsmError(f'æ æå­ç¬¦è½¬ä¹: {tok}')
        if len(inner) == 4 and inner[0] == '\\' and inner[1] == 'x':
            try:
                return int(inner[2:4], 16)
            except ValueError:
                pass
        raise AsmError(f'æ æå­ç¬¦å­é¢é: {tok}')
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
        raise AsmError(f'æ ææ°å­/æªå®ä¹å¸¸é: {tok}')


def parse_reg(tok, symbols):
    t = tok.strip()
    abs_reg = False
    if re.search(r'\.base$', t, re.I):
        abs_reg = True
        t = re.sub(r'\.base$', '', t, flags=re.I).strip()
    if t[:1].lower() == 'r' and t[1:].isdigit():
        v = int(t[1:], 10)
    else:
        v = parse_int(t, symbols)
    if abs_reg:
        # ç©çç»å¯¹å· Kï¼ç¼ç ç¸å¯¹å· raw = K - baseï¼K>=253 è±åï¼ç¡¬ä»¶ä¸å  base â raw ä¿æ Kï¼
        if v >= 253:
            raw = v
        else:
            raw = v - CURRENT_BASE
        if not (0 <= raw <= 0xFF):
            raise AsmError(f'ç»å¯¹å¯å­å¨ {tok} æ¢ç®è¶ç: {v}-{CURRENT_BASE} ä¸å¨ 0-255')
        return raw
    if not (0 <= v <= 0xFF):
        raise AsmError(f'å¯å­å¨å·è¶ç: {tok}ï¼é¡» 0-255ï¼')
    return v


def strip_comment(line):
    """å»æ # å // æ³¨éï¼å¼å·åç # å // æ¯å­ç¬¦å¸¸éï¼ä¸å¤çã"""
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
    """å±å¼ `.rep N` .. `.endr` å¾ªç¯ï¼æ¯æåµå¥ï¼ï¼`$i`=æåå±ç´¢å¼ï¼`$j`=å¤å±ç´¢å¼ã
    è¡çº§é¢å¤çï¼å¨ parse_lines ä¹åã"""
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
                raise AsmError('.rep ç¼ºå° .endr éå¯¹')
            inner = expand_reps(body)
            for idx in range(count):
                for bl in inner:
                    result.append(bl.replace('$i', str(idx)).replace('$j', str(idx)))
            continue
        result.append(line)
        i += 1
    return result


def split_operands(s):
    """æéå·/ç©ºç½ååæä½æ°ï¼å¼å·åçç©ºæ ¼/éå·ä¸åï¼æ¯æ ' ' è¿ç±»å­ç¬¦å¸¸éï¼ã"""
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
    """ä» .str æä½æ°éååå¼å·ä¸²å¹¶è§£ç è½¬ä¹ â bytesã"""
    s = operands.strip()
    a, b = s.find('"'), s.rfind('"')
    if a < 0 or b <= a:
        raise AsmError('.str éè¦åå¼å·å­ç¬¦ä¸²')
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
            raise AsmError(f'.str æªç¥è½¬ä¹: \\{n}')
        o = ord(c)
        if o < 128:
            out.append(o)                # ASCII åå­è
        else:
            out += c.encode('utf-8')     # é ASCIIï¼ä¸­æç­ï¼â UTF-8 å¤å­è
        i += 1
    return bytes(out)


# ---------------------------------------------------------------- ç¼ç 
# èªå¨ä¿®æ­£è®¡æ°ï¼main éæ±æ»æå°ï¼
AUTO_NOP_COUNT = 0
AUTO_FLIP_COUNT = 0
# .puts å±å¼ç¨å¯ä¸æ ç­¾è®¡æ°å¨
_PUTS_CTR = 0
# èªå¨ jpad è®¡æ° + æ ç­¾è®¡æ°å¨
AUTO_JPAD_COUNT = 0
_JPAD_CTR = 0
# å½å .baseï¼ä»»å¡çªå£åºåï¼ç¨äºæ rK.base ç»å¯¹å·æ¢ç®æç¸å¯¹å·ï¼
CURRENT_BASE = 0


def _flip_side(m):
    """ç¿»è½¬åæ¯åç¼ LâRï¼è¯­ä¹ä¸åï¼ä»ç¼ç æ¹åä½ï¼ã"""
    return ('L' if m[0] == 'R' else 'R') + m[1:]


def bytmov_for(mnem, word, target):
    """bytmov 16 ä½ãè¯åä½ãï¼åºå W+3ï¼rpu æµæ°´çº¿çº§ï¼åæå»¶è¿ 3 æï¼ãR=åå target-(W+3)ï¼L=åå (W+3)-targetã
    é¡» 1 â¤ bytmov â¤ 0xFFFFï¼pc.v å¤ 0 ä¸ºä¸è·³ â ç®æ =W+3 ä¸å¯ç¼ç ï¼ã
    æ¹åä¸åç¼ç¸åæ¶èªå¨ç¿»è½¬åç¼ï¼LâRï¼ï¼ä»è¶çææ¥éï¼æ­¤æ¶éäººå·¥å¤çï¼ã"""
    global AUTO_FLIP_COUNT
    if not (0 <= target <= ROM_TOP):
        raise AsmError(f'è·³è½¬ç®æ è¶ç: 0x{target:03X}ï¼é¡» 0x000-0x1FFFï¼')
    fwd = target - (word + 3)
    bwd = (word + 3) - target
    d0 = mnem[0]
    for d, bm in ((d0, fwd if d0 == 'R' else bwd),
                  ('L' if d0 == 'R' else 'R', bwd if d0 == 'R' else fwd)):
        if 0 <= bm <= 0xFFFF:
            if d != d0:
                AUTO_FLIP_COUNT += 1
                return bm, _flip_side(mnem)
            return bm, mnem
    raise AsmError(f'è·³è½¬è¶çï¼word=0x{word:03X} target=0x{target:03X} '
                   f'bytmov={fwd if d0 == "R" else bwd}ï¼é¡» 1-0xFFFFï¼'
                   f'ç®æ =å½åè¯+3 æ¶ bytmov=0 ä¸å¯ç¼ç ï¼å±æ­»åºï¼')


def compressed_bytes(m, fmt, ops, symbols):
    """è¿å 16bit åç¼©ç¼ç  [b0,b1]ï¼ä¸å¯åè¿å Noneã
    flag=11ï¼ALU-R/Iï¼ï¼byte1={rd[1:0],r1[2:0],r2[2:0]}ï¼I åæ«å­æ®µ=imm[2:0]ï¼
    flag=01ï¼NOP/IRETï¼ï¼byte1=0x00ã"""
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
            return None      # è¡¨è¾¾å¼å«æªå®ä¹ datalabelï¼å¦ __pdN>>8ï¼â ä¸åç¼©
        if rd <= 3 and rs1 <= 7 and 0 <= imm <= 7:
            return [OPCODE[m] << 2 | 0x03, (rd << 6) | (rs1 << 3) | imm]
    return None


def long_bytes(m, fmt, ops, symbols, word, tget):
    """åé¿ç¼ç ï¼flag=00ï¼â 4 å­è [b0,b1,b2,b3]ï¼ä¸è¶³è¡¥ 0ï¼ãtget(tok)âç»å¯¹è¯å°åã"""
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
            raise AsmError(f'{m} åæ¯å¯å­å¨é¡» 0-15ï¼4 ä½ï¼ï¼r1={r1} r2={r2}')
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
            raise AsmError(f'{m} ç«å³æ°è¶ç: {ops[2]}ï¼é¡» 0-255ï¼')
        return [b0, rd, rs1, imm]
    if fmt == 'lb':
        rd = parse_reg(ops[0], symbols)
        a = tget(ops[1])
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 ä½å°åè¶ç: {ops[1]}')
        return [b0, rd, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'sb':
        rs = parse_reg(ops[0], symbols)
        a = tget(ops[1])
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 ä½å°åè¶ç: {ops[1]}')
        return [b0, rs, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'sbi':
        # SBI imm8, addr16ï¼byte1=ç«å³æ°ï¼byte2:3=16 ä½å°åï¼ä¸ SB å¸å±ä¸è´ï¼ä»æºæ¹ä¸ºç«å³æ°ï¼
        imm = parse_int(ops[0], symbols)
        a = parse_int(ops[1], symbols)
        if not (0 <= imm <= 0xFF):
            raise AsmError(f'{m} ç«å³æ°è¶ç: {ops[0]}ï¼é¡» 0-255ï¼')
        if not (0 <= a <= 0xFFFF):
            raise AsmError(f'{m} 16 ä½å°åè¶ç: {ops[1]}')
        return [b0, imm, (a >> 8) & 0xFF, a & 0xFF]
    if fmt == 'lind':
        # LIND rd, r1, r2ï¼byte1=rdï¼byte2=r1(addr é«8ä½)ï¼byte3=r2(addr ä½8ä½)ï¼addr = r1:r2
        rd = parse_reg(ops[0], symbols)
        r1 = parse_reg(ops[1], symbols)
        r2 = parse_reg(ops[2], symbols)
        return [b0, rd, r1, r2]
    if fmt == 'sind':
        # SIND rs, r1, r2ï¼byte1=rs(æºå¯å­å¨ï¼RTL å­ bus_data_final=r_bus å¼)ï¼
        #   byte2=r1(addr é«8ä½)ï¼byte3=r2(addr ä½8ä½)ï¼å rs çå¼å° [r1:r2]
        rs = parse_reg(ops[0], symbols)
        r1 = parse_reg(ops[1], symbols)
        r2 = parse_reg(ops[2], symbols)
        return [b0, rs, r1, r2]
    raise AsmError(f'æªç¥æ ¼å¼ {fmt}')


# ---------------------------------------------------------------- è§£æ
def parse_lines(src_lines):
    global _PUTS_CTR, CURRENT_BASE
    CURRENT_BASE = 0
    symbols = {}
    items = []
    errs = []
    in_data = False          # .data æ°æ®åºï¼åç»­ .byte/.str/.db è¿æ°æ®åºï¼0xA000 åºï¼
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
                    raise AsmError('.db å¿é¡»ä½äº .data æ°æ®åºå')
                bs = []
                for t in ops:
                    if t.startswith('"') or t.startswith("'"):
                        bs += list(parse_str(t))
                    else:
                        b = parse_int(t, symbols)
                        if not (0 <= b <= 0xFF):
                            raise AsmError(f'.db è¶ç: {t}')
                        bs.append(b)
                items.append({'kind': 'datadata', 'bytes': bs, 'src': raw.strip(), 'ln': ln})
                continue
            if mnem == '.ORG':
                if len(ops) != 1:
                    raise AsmError('.org éè¦ 1 ä¸ªè¯å°å')
                a = parse_int(ops[0], symbols)
                if not (0 <= a <= ROM_TOP):
                    raise AsmError(f'.org è¶ç: 0x{a:03X}')
                items.append({'kind': 'org', 'addr': a, 'ln': ln})
                continue
            if mnem == '.EQU':
                if len(ops) != 2:
                    raise AsmError('.equ éè¦ .equ NAME value')
                symbols[ops[0]] = parse_int(ops[1], symbols)
                continue
            if mnem == '.BASE':
                if len(ops) != 1:
                    raise AsmError('.base éè¦ 1 ä¸ªå¯å­å¨åºåå¼')
                b = parse_int(ops[0], symbols)
                if not (0 <= b <= 0xF0):
                    raise AsmError(f'.base è¶ç: 0x{b:02X}ï¼é¡» 0-240ï¼çªå£é¡»ç 16 æ ¼ + è±åæ®µï¼')
                CURRENT_BASE = b
                continue
            if mnem == '.BYTE':
                bs = []
                for t in ops:
                    b = parse_int(t, symbols)
                    if not (0 <= b <= 0xFF):
                        raise AsmError(f'.byte è¶ç: {t}')
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
                # ä¼ªæä»¤ .puts "text"ï¼>3 å­ç¬¦ç¨æ°æ®åº LIND å¾ªç¯ï¼ææ¬è¿ hex ååï¼æ¯å­ç¬¦ 1 å­èï¼
                # å¾ªç¯ ~13 è¯åºå® + æ°æ®åºï¼ãç­ææ¬ï¼â¤3 å­ç¬¦ï¼ä¿æåèéå­ç¬¦ï¼3 è¯/å­ç¬¦ï¼ââ
                # é¿ææ¬æ°æ®åºçãç­ææ¬åèçãé»è®¤ç®æ  putcï¼å¯ç¨ç¬¬äºä¸ªåæ°æ¢ã
                bs = list(parse_str(operands))
                ops = split_operands(operands)
                tgt = 'putc'
                if len(ops) == 2:
                    tgt = ops[1]
                if len(bs) > 8 and tgt == 'putc':
                    lab = f'__pd{_PUTS_CTR}'
                    # datalabel å¿é¡»å¨ datadata åï¼åç§» = å½åç´¯ç§¯ï¼ææ¬èµ·å§ï¼ï¼å¦ååå°ææ¬å
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
                # ä¼ªæä»¤ï¼MOV rd, rs = rd å¤å¶ rsãRTL å·²æ¾å¼ MOVï¼ç¿»è¯ä¸º ADDI rd, rs, 0ï¼è¯­ä¹ç­ä»·ï¼
                # èªå¨ç»§æ¿ ADDI çåç¼©è½åï¼rdâ¤3 ä¸ rsâ¤7 æ¶åæ 16bitï¼å¦ååé¿ 4 å­èï¼ã
                if len(ops) != 2:
                    raise AsmError('MOV éè¦ 2 ä¸ªæä½æ°ï¼å¤å¶è¯­ä¹ï¼èªå¨è½¬ ADDIï¼ï¼MOV rd, rs')
                mnem = 'ADDI'
                ops = ops + ['0']
            if mnem not in INS:
                raise AsmError(f'æªç¥å©è®°ç¬¦/ä¼ªæä»¤: {mnem}')
            fmt, nb = INS[mnem]
            if len(ops) != OPERAND_N[fmt]:
                raise AsmError(f'{mnem} éè¦ {OPERAND_N[fmt]} ä¸ªæä½æ°ï¼ç»äº {len(ops)}')
            cb = compressed_bytes(mnem, fmt, ops, symbols)  # å¯ååç»åº 16bitï¼å¦å None
            items.append({'kind': 'ins', 'mnem': mnem, 'fmt': fmt, 'nbytes': nb,
                          'ops': ops, 'cbytes': cb, 'src': raw.strip(), 'ln': ln})
        except AsmError as e:
            errs.append(f'ç¬¬ {ln} è¡: {e}')
            errs.append(f'    {raw.rstrip()}')
    if errs:
        raise AsmError('\n'.join(errs))
    return items, symbols


# ---------------------------------------------------------------- å¸å±
def compute_layout(items, must_first):
    """åéæ¯æ¡æä»¤/æ°æ®çè¯å°åãè¿å (layout: item_idxâ(word,is_second), word_packed: set, final_word)ã
    ç¸é»ä¸¤æ¡é½å¯åä¸ç¬¬äºæ¡é must_first â æåå±äº«ä¸è¯ã"""
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
    """åºå®ç¹å¸å±ï¼è®©ææè·³è½¬ç®æ ï¼labelï¼è½å¨è¯é¦ãè¿å (layout, word_packed, label_word)ã"""
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
    """æ­»åºèªå¨è¡¥ NOPï¼åååæ¯(jump/branch)ç®æ è½å¨æ­»åºï¼target < word+3ï¼
    bytmov 0/-1 ç¡¬ä»¶å¤ä¸è·³ï¼æ¶ï¼å¨ç®æ  label åèªå¨æ NOP æè·ç¦»æå° â¥1ã
    è¿åæ¬æ¬¡æå¥ç NOP æ»æ°ï¼0=æ éåæï¼ãlabel ç´§è· .org æ¶è·³è¿ï¼é¿åç§»ä½ç ´ååºå®å°åï¼ã"""
    label_pos = {}
    for idx, it in enumerate(items):
        if it['kind'] == 'label':
            label_pos[it['name']] = idx
    need = {}   # label item ä¸æ  â éæ NOP æ°
    for idx, it in enumerate(items):
        if it['kind'] == 'ins' and it['fmt'] in ('jump', 'branch'):
            tok = it['ops'][0] if it['fmt'] == 'jump' else it['ops'][2]
            t = tok.strip()
            if is_label(t) and t in label_word and t in label_pos:
                word = layout[idx][0]
                target = label_word[t]
                # æ­»åº = target æ°å¨ word+3ï¼L ä¸ R ç bytmov é½=0ï¼æ åç¼å¯æã
                # (target=word+2 å¯ç¨ L ç¼ç  bytmov=1ï¼æ¹åç¿»è½¬å¯æï¼ä¸éè¦è¡¥ NOP)
                if target == word + 3:
                    li = label_pos[t]
                    if li > 0 and items[li - 1]['kind'] == 'org':
                        continue      # label ç´§è· .orgï¼ä¸èªå¨ç§»ä½ï¼çç»ç¼ç æ¥é
                    n = word + 4 - target
                    need[li] = max(need.get(li, 0), n)
    if not need:
        return 0
    for li in sorted(need, reverse=True):   # ä»åå¾åæï¼ä¿è¯ä¸æ ç¨³å®
        for _ in range(need[li]):
            items.insert(li, {
                'kind': 'ins', 'mnem': 'NOP', 'fmt': 'none', 'nbytes': 1,
                'ops': [], 'cbytes': [OPCODE['NOP'] << 2 | 0x01, 0x00],
                'src': '// èªå¨ NOPï¼bytmov æ­»åºï¼', 'ln': 0,
                'force_first': True,
            })
    return sum(need.values())


def is_label(tok):
    return LABEL_RE.match(tok) is not None


# ---- èªå¨ __jpad å«å±ï¼IRET W+2 è¯­ä¹ç¡¬æ§çº¦å®ï¼----
# ä¸­æ­åªå¨é¡ºåºæä»¤ï¼ææç¹ï¼irq_en==11ï¼æ´¾åï¼æ´¾åæ¶ W+1 è¢«è·³è¿ã
# è¥æ§å¶è½¬ç§»å¨ W+1 æ§½ä½ä¼è¢«å â æ¯æ¡ãé¡ºåºæä»¤åçæ§å¶è½¬ç§»ãåå¿é¡»å«
# `LBNE r0,r0,<lab>` + `<lab>:`ï¼èªè·³ 1 è¯ãæ°¸ä¸åï¼ãæ±ç¼å¨èªå¨è¡¥ï¼
#   Â· æ§å¶è½¬ç§» = 9 æ¡ï¼LJAL/RJAL/JALR/LBEQ/RBEQ/LBNE/RBNE/LBLTU/RBLTUï¼
#   Â· åä¸æ¡çå®æä»¤æ¯é¡ºåºæä»¤ â æå¥å«å±ï¼æ¯æ§å¶è½¬ç§»ï¼å« IRET/HALTï¼â å¤©ç¶å®å¨ä¸æ
#   Â· æºéå·²æåå«å±ï¼LBNE r0,r0,<lab> ç´§è· <lab>:ï¼â è·³è¿ï¼å¯¹æ¢æç¨åºå­èå¼å®¹ï¼
# ä¸ pad IRET/HALTï¼åèæ¯è¿åãåèåæºï¼åæ ææç¹è·³è¿é®é¢ï¼ã

CTRL_FMTS = ('jump', 'branch', 'jalr')


def _is_ctrl_ins(it):
    return (it['kind'] == 'ins'
            and (it['fmt'] in CTRL_FMTS or it['mnem'] in ('IRET', 'HALT')))


def _is_jpad_pair(items, i):
    """items[i] æ¯å¦ä¸ºæºéæåç jpadï¼LBNE r0,r0,<lab> ç´§è· <lab> æ ç­¾ã"""
    return (i + 1 < len(items)
            and items[i]['kind'] == 'ins' and items[i]['mnem'] == 'LBNE'
            and len(items[i]['ops']) == 3 and items[i]['ops'][0] == 'r0'
            and items[i]['ops'][1] == 'r0'
            and items[i + 1]['kind'] == 'label'
            and items[i + 1]['name'] == items[i]['ops'][2])


def auto_jpad(items):
    """æåºæ«æï¼ç»éè¦å«å±çæ§å¶è½¬ç§»åæ jpadãè¿åæ° itemsã
    æ§å¶è½¬ç§»æ¬èº«æ¯åæ¯ï¼è¥åä¸æ¡çå®æä»¤æ¯é¡ºåºæä»¤ï¼ææç¹ï¼åéå«å±ã
    æºéæåç jpadï¼LBNE r0,r0,<lab>+<lab>:ï¼æ¯å·²å®æçå«å±ï¼ä¸éå¤å«ã
    ä¸å¶åç´§é»çæ§å¶è½¬ç§»è§ä¸ºå·²æå«å±ã"""
    global AUTO_JPAD_COUNT, _JPAD_CTR
    out = []
    prev_ctrl = True            # ç¨åºé¦æä»¤åæ ææç¹ï¼è§ä¸ºå®å¨
    i = 0
    n = len(items)
    while i < n:
        it = items[i]
        if _is_jpad_pair(items, i):
            # æºéæå jpadï¼åæ ·æ¬è¿ï¼ä¸å«å®èªå·±ï¼ï¼å¹¶æä¸ä¸ä¸ªçå®æä»¤è§ä¸ºå®å¨
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
                        'src': '// èªå¨ jpadï¼IRET W+2 å«å±ï¼', 'ln': 0})
            out.append({'kind': 'label', 'name': lab, 'ln': 0})
            AUTO_JPAD_COUNT += 1
        out.append(it)
        if it['kind'] == 'ins':
            prev_ctrl = _is_ctrl_ins(it)
        elif it['kind'] == 'data':
            prev_ctrl = False   # æ°æ®è¯è§ä½é¡ºåºï¼ä¿å®è¡¥å«
        i += 1
    return out


# ---------------------------------------------------------------- æ±ç¼
def assemble(src_lines):
    global AUTO_NOP_COUNT, CURRENT_BASE
    CURRENT_BASE = 0
    src_lines = expand_reps(src_lines)   # å±å¼ .rep/.endrï¼è¡çº§é¢å¤çï¼
    items, symbols = parse_lines(src_lines)
    if not items:
        raise AsmError('ç¨åºä¸ºç©º')
    # æ­»åºèªå¨ NOPï¼åååæ¯ç®æ è½å¨ [W+1, W+2]ï¼bytmov 0/-1 ä¸å¯ç¼ç ï¼æ¶å¨ç®æ 
    # label åæ NOP æå¼ãåºå®ç¹è¿­ä»£ï¼æ NOP åªä¼å¢å¤§ååè·ç¦»ï¼å¿ç¶æ¶æã
    layout, word_packed, label_word = run_layout(items)   # bytmov=0 合法，无需死区 NOP

    # æ°æ®åºï¼.dataï¼ï¼æ¶éå­è + datalabel å°åï¼0xA000 + åç§»ï¼
    # è·¨ 256 å­èé¡µä¿æ¤ï¼.puts é¿ææ¬ç¨ LIND å¾ªç¯è¯»ï¼å°å = {hi, lo}ï¼lo èªå¢åç»æ¶ hi ä¸è¿ä½ï¼ï¼
    # ææ¬å¿é¡»æ´ä½è½å¨åä¸ 256 é¡µåãè¥æææ¬è·¨é¡µï¼å¨ææ¬åæå¡«åæå®æ¨å°ä¸ä¸é¡µèµ·å§ï¼é¡µå¯¹é½ï¼ã
    data_bytes = []
    datalabel = {}
    pending_label = None
    for it in items:
        if it['kind'] == 'datadata':
            # è·¨é¡µæ£æ¥ï¼å½åé¡µåå©ä½ < ææ¬é¿ â å¡«åå°é¡µå¯¹é½
            if (len(data_bytes) % 256) + len(it['bytes']) > 256:
                pad = 256 - (len(data_bytes) % 256)
                data_bytes.extend([0] * pad)
            if pending_label is not None:
                datalabel[pending_label] = DATA_BASE + len(data_bytes)
                pending_label = None
            data_bytes.extend(it['bytes'])
        elif it['kind'] == 'datalabel':
            pending_label = it['name']
    if len(data_bytes) > 4096:
        raise AsmError(f'æ°æ®åºè¶ 4096 å­è: {len(data_bytes)}')
    symbols.update(datalabel)   # æ°æ®æ ç­¾å¯è¢« parse_int è¡¨è¾¾å¼å¼ç¨ï¼(msg>>8)/(msg&0xFF)ï¼

    def resolve_t(tok):
        t = tok.strip()
        # labelÂ±Nï¼æ°æ®/ç¬¦å·æ ç­¾åç§»ï¼
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
            raise AsmError(f'æªå®ä¹æ ç­¾: {t}')
        return parse_int(t, symbols)

    words = {}
    srcs = {}
    first_slots = set()
    max_word = 0
    # æ°æ®å­è â hex ååï¼è¯ DATA_ROM_START+jï¼ä½ 8 ä½å­èï¼
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
    # ç»å¯¹ç®æ å¿é¡»è½å¨è¯é¦ï¼label ç®æ å·²å¨åºå®ç¹éä¿è¯ï¼
    for idx, it in enumerate(items):
        if it['kind'] == 'ins' and it['fmt'] in ('jump', 'branch'):
            tok = it['ops'][0] if it['fmt'] == 'jump' else it['ops'][2]
            t = tok.strip()
            if not is_label(t):
                v = resolve_t(t)
                if v not in first_slots:
                    raise AsmError(f'{it["mnem"]} ç®æ  0x{v:03X} ä¸æ¯è¯é¦æä»¤'
                                   f'ï¼label ç®æ ä¼èªå¨å¯¹é½ï¼ç»å¯¹ç®æ è¯·æ ¸å¯¹ listingï¼')
    return words, srcs, max_word


# ---------------------------------------------------------------- è¾åº
def write_hex(words, srcs, max_word, fh):
    """ç¨åº hexï¼0-4095 è¯ï¼32bit è¯ï¼byte0=é«ä½ opcode å¨ [31:24]ï¼ãæªç¨è¯å¡« 0ã"""
    fh.write('@0000\n')
    for w in range(0, ROM_TOP + 1):
        if w in srcs:
            fh.write('%08X' % words[w])
            fh.write('   // ' + ' | '.join(s.strip() for s in srcs[w]))
            fh.write('\n')
        else:
            fh.write('%08X\n' % words.get(w, 0x00000000))


def write_data_hex(words, fh):
    """æ°æ® hexï¼0-4095 è¯ï¼æ¯è¯ 8 ä½å­èï¼ram_sec_init è½½å¥å° 0xA000 åºï¼ã"""
    fh.write('@0000\n')
    for j in range(0, 4096):
        fh.write('%02X\n' % (words.get(DATA_ROM_START + j, 0x00000000) & 0xFF))


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='MCU æ±ç¼å¨ï¼.asm â ins_rom.hexï¼è¯å¯»å + èªå¨åç¼©/æåï¼')
    ap.add_argument('src', help='æº .asm æä»¶')
    ap.add_argument('-o', '--output', help='è¾åº hex è·¯å¾ï¼é»è®¤ project_self-try.srcs/ins_rom.hexï¼')
    args = ap.parse_args()

    try:
        src_lines = Path(args.src).read_text(encoding='utf-8').splitlines()
    except OSError as e:
        print(f'æ æ³è¯»åæºæä»¶: {e}')
        sys.exit(1)

    try:
        words, srcs, max_word = assemble(src_lines)
    except AsmError as e:
        print('æ±ç¼å¤±è´¥ï¼')
        print(e)
        sys.exit(1)

    if args.output:
        out_path = Path(args.output)
    else:
        out_path = Path(__file__).resolve().parent.parent / 'project_self-try.srcs' / 'ins_rom.hex'
    data_path = out_path.with_name('data.hex')

    with open(out_path, 'w', encoding='utf-8', newline='\n') as fh:
        write_hex(words, srcs, max_word, fh)
    # æ°æ®åºåç¬è¾åº data.hexï¼è¯ 8192-12287ï¼ram_sec_init è½½å¥å° 0xA000ï¼
    with open(data_path, 'w', encoding='utf-8', newline='\n') as fh:
        write_data_hex(words, fh)

    print(f'ç¨åºèå´: 0x000â0x{max_word:03X}ï¼{max_word + 1} è¯ï¼ï¼ROM å·²å¡«æ»¡ 0x000â0x1FFF -> {out_path}')
    print(f'æ°æ®åº: è¾åº -> {data_path}')
    if AUTO_NOP_COUNT or AUTO_FLIP_COUNT or AUTO_JPAD_COUNT:
        print(f'èªå¨ä¿®æ­£: è¡¥ NOP {AUTO_NOP_COUNT} ä¸ªï¼bytmov æ­»åºï¼ï¼'
              f'æ¹åç¿»è½¬ {AUTO_FLIP_COUNT} å¤ï¼L/R åç¼èªå¨çº æ­£ï¼ï¼'
              f'è¡¥ jpad {AUTO_JPAD_COUNT} ä¸ªï¼IRET W+2 å«å±ï¼')
    print('---- listingï¼è¯å°å | 32bit è¯ | æºï¼----')
    for w in range(0, max_word + 1):
        if w in srcs:
            print(f'0x{w:03X}: {words[w]:08X} | {" | ".join(s.strip() for s in srcs[w])}')
        else:
            print(f'0x{w:03X}: {words.get(w, 0):08X} | (å¡«å)')


if __name__ == '__main__':
    main()
