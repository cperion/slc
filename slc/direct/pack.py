#!/usr/bin/env python3
"""Offline ELF64/RELA extraction for the direct backend's declared hole ABI.
This is a trusted toolchain input, not an arbitrary-object execution service.
"""
import hashlib
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
sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * 64) for i in range(count)]
def contents(s):
    return data[s[4]:s[4] + s[5]]
def string(blob, off):
    return blob[off:blob.index(b'\0', off)].decode('ascii')
names = contents(sections[names_index])
section_names = [string(names, s[0]) for s in sections]
symi, symtab = next((i, s) for i, s in enumerate(sections) if s[1] == 2)
assert symtab[9] == 24
strtab = contents(sections[symtab[6]])
symbols = [struct.unpack_from('<IBBHQQ', contents(symtab), off)
           for off in range(0, symtab[5], 24)]
def escaped(blob):
    return ''.join('\\%03d' % byte for byte in blob)
readonly = {}
for i, (name, section) in enumerate(zip(section_names, sections)):
    if name.startswith('.rodata'):
        assert section[1] == 1 and section[8] <= 32, 'unsupported read-only section'
        assert not any(r[1] in (4, 9) and r[7] == i for r in sections), 'relocated read-only data'
        readonly[i] = '@data:' + str(i)
result = ['return { abi=2, target="linux-x64", ni=11, nf=8,',
          'object_sha256="%s", data={' % hashlib.sha256(data).hexdigest()]
for i, name in readonly.items():
    result.append('["%s"]={bytes="%s",align=%d},' % (name, escaped(contents(sections[i])), max(1, sections[i][8])))
result.append('}, stencils={')
seen = set()
for i, (name, section) in enumerate(zip(section_names, sections)):
    if not name.startswith('.text.'):
        continue
    code = contents(section)
    funcs = [s for s in symbols if s[3] == i and s[1] & 15 == 2]
    assert len(funcs) == 1 and funcs[0][4:] == (0, len(code)), name
    assert section[8] <= 16, 'unsupported code alignment'
    relocs = []
    for r in sections:
        if r[7] != i or r[1] not in (4, 9):
            continue
        assert r[1] == 4 and r[9] == 24 and r[6] == symi, 'only linked RELA supported'
        for off in range(0, r[5], 24):
            pos, info, addend = struct.unpack_from('<QQq', contents(r), off)
            kind, sym = info & 0xffffffff, symbols[info >> 32]
            symbol = string(strtab, sym[0])
            if sym[3] in readonly:
                assert kind == 2, 'read-only data requires PC-relative addressing'
                symbol = readonly[sym[3]]
                addend += sym[4]
            else:
                assert sym[3] == 0 and symbol in ('NEXT', 'ZERO', 'IMM', 'OFFSET', 'LITERAL', 'cp_native_call', 'cp_invoke_frame', 'memcpy', 'memset'), symbol
                assert (symbol in ('IMM', 'OFFSET')) == (kind in (10, 11)), (symbol, kind)
            assert kind in (2, 4, 10, 11) and pos + 4 <= len(code), kind
            relocs.append('{offset=%d, kind=%d, symbol="%s", addend=%d}' %
                          (pos, kind, symbol, addend))
    encoded = escaped(code)
    key = string(strtab, funcs[0][0])
    assert key.startswith('cp_'), 'unexpected stencil function ' + key
    assert key not in seen
    seen.add(key)
    result.append('["%s"]={code="%s", align=%d, relocs={%s}},' %
                  (key, encoded, max(1, section[8]), ','.join(relocs)))
assert seen, 'empty stencil pack'
result.append('}}')
dst.write_text('\n'.join(result) + '\n')
print('direct pack: %d stencils, %d object bytes' % (len(seen), len(data)))
