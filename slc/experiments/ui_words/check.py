#!/usr/bin/env python3
"""Focused design probe; all generated files stay under the root build directory."""
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
build = root / 'build/ui-words'
build.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env.setdefault('SLC_CACHE', str(root / 'build/cache'))
env.setdefault('TMPDIR', str(root / 'build/tmp'))
Path(env['TMPDIR']).mkdir(parents=True, exist_ok=True)
if 'LUA_CPATH' not in env:
    rocks = subprocess.check_output(['luarocks', '--lua-version=5.1', 'path', '--lr-cpath'], text=True)
    env['LUA_CPATH'] = rocks.strip() + ';;'
local_jit = root / '.local/lib/libgccjit.so.0'
if local_jit.is_file():
    env.setdefault('SLC_GCCJIT', str(local_jit))


def run(*args):
    subprocess.run([str(a) for a in args], cwd=root, env=env, check=True)


compiler = ['luajit', root / 'slc.lua']
run(*compiler, '-o', build / 'probe.c', '-H', build / 'probe.h', here / 'probe.slc')
generated = (build / 'probe.c').read_text()
# The normal header has prototypes; share the emitted type declarations too,
# so the C/JIT harness does not manually duplicate the compiler's ABI layout.
marker = '\nApp probe_init('
assert generated.count(marker) == 1
prefix = generated.split(marker)[0]
(build / 'probe-api.h').write_text(prefix + '\n' + (build / 'probe.h').read_text())
for name in ('confirmation(', 'counter(', 'application(', 'activated(', 'vocabulary('):
    assert not re.search(r'\b' + re.escape(name), generated), 'unexpected residual composition call: ' + name
assert '"paint"' not in generated and '"input"' not in generated, 'phase was not specialized'
assert 'uint32_t known_counter(void) {\n    return 1u;\n}' in generated
print('specialization: no component/continuation calls or runtime phase strings; known composition folds', flush=True)
flags = ['-std=c99', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I', root / 'runtime', '-I', build]
cc = shlex.split(env.get('CC', 'cc'))
run(*cc, *flags, '-O2', here / 'check.c', '-o', build / 'check-c')
run(build / 'check-c')
# This experiment explicitly requires the same optional JIT used in the design
# evidence. Compilation failures are not converted into skips.
run(*compiler, '--gccjit', '-o', build / 'probe-jit.o', here / 'probe.slc')
run(*cc, *flags, '-O2', '-DUI_WORDS_JIT', here / 'check.c', build / 'probe-jit.o', '-o', build / 'check-jit')
run(build / 'check-jit')
if shutil.which('clang'):
    run('clang', *flags, '-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
        here / 'check.c', '-o', build / 'check-san')
    run(build / 'check-san')
else:
    print('skip: Clang sanitizer variant (clang not installed)')
print('ordinary-word UI composition: all available checks passed')
