#!/usr/bin/env python3
"""Extract this experiment's ELF64 little-endian x86-64 RELA stencils.
Reject anything outside the deliberately narrow supported object format.
"""
import pathlib
import struct
import sys

src, dst = map(pathlib.Path, sys.argv[1:])
data = src.read_bytes()
assert data[:7] == b'\x7fELF\x02\x01\x01', 'expected little-endian ELF64'
assert struct.unpack_from('<HH', data, 16) == (1, 62), 'expected x86-64 ET_REL'
shoff = struct.unpack_from('<Q', data, 40)[0]
entsize, count, names_index = struct.unpack_from('<HHH', data, 58)
assert entsize == 64
sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * 64)
            for i in range(count)]
def contents(s):
    return data[s[4]:s[4] + s[5]]
def string(blob, off):
    return blob[off:blob.index(b'\0', off)].decode('ascii')
names = contents(sections[names_index])
section_names = [string(names, s[0]) for s in sections]
symtab = next(s for s in sections if s[1] == 2)
assert symtab[9] == 24
strtab = contents(sections[symtab[6]])
symbols = [struct.unpack_from('<IBBHQQ', contents(symtab), off)
           for off in range(0, symtab[5], 24)]
result = ['return {']
for i, (name, section) in enumerate(zip(section_names, sections)):
    if not name.startswith('.text.'):
        continue
    code = contents(section)
    # One complete function per section, no unnamed prefix/suffix to copy.
    funcs = [s for s in symbols if s[3] == i and s[1] & 15 == 2]
    assert len(funcs) == 1 and funcs[0][4:] == (0, len(code)), name
    relocs = []
    for r in sections:
        if r[7] != i or r[1] not in (4, 9):
            continue
        assert r[1] == 4 and r[9] == 24, 'only RELA is supported'
        for off in range(0, r[5], 24):
            pos, info, addend = struct.unpack_from('<QQq', contents(r), off)
            kind, sym = info & 0xffffffff, symbols[info >> 32]
            symbol = string(strtab, sym[0])
            assert sym[3] == 0 and symbol in ('NEXT', 'ZERO', 'IMM'), symbol
            assert kind in (2, 4, 10, 11) and pos + 4 <= len(code), kind
            assert (symbol == 'IMM') == (kind in (10, 11)), (symbol, kind)
            relocs.append('{offset=%d, kind=%d, symbol="%s", addend=%d}' %
                          (pos, kind, symbol, addend))
    escaped = ''.join('\\%03d' % byte for byte in code)
    result.append('  ["%s"] = {code="%s", relocs={%s}},' %
                  (name[6:], escaped, ','.join(relocs)))
    print('%s: %d bytes, %d relocations' % (name[6:], len(code), len(relocs)))
result.append('}')
dst.write_text('\n'.join(result) + '\n')
