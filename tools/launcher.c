/* The slc launcher: embed slc's own parts, run them on the host's LuaJIT.
 *
 * This is the single-binary entry point (architecture §14.3). It writes the files
 * the host tools must see (the runtime archive and the headers) into a work
 * directory per run, loads everything else from memory, and runs slc.lua from
 * there with the host's LuaJIT (linked dynamically) and the host's libgccjit
 * (loaded at run time by slc itself). It compiles no C and embeds no compiler.
 */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>

typedef struct slc_embedded_file { const char *name; const char *data; size_t size; } slc_embedded_file;
extern const slc_embedded_file slc_embedded_files[];
extern const size_t slc_embedded_count;
extern const char *slc_embedded_hash;

static char root[2048];

static void die(const char *what, const char *detail) {
    fprintf(stderr, "slc: %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
    exit(2);
}

/* join with an explicit length check: the compiler cannot bound a name argument */
static void join(char *dst, size_t n, const char *a, const char *b) {
    size_t at = (size_t)snprintf(dst, n, "%s/%s", a, b);
    if (at + 1 > n) die("path too long", b);
}

/* mkdir -p for the parent directories of `path`, which is modified in place */
static void make_parents(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(path, 0777) != 0 && errno != EEXIST) die("cannot create directory", path);
        *p = '/';
    }
}

static int same_file(const char *path, const slc_embedded_file *f) {
    FILE *in = fopen(path, "rb");
    if (!in) return 0;
    char buf[65536];
    size_t at = 0;
    int same = 1;
    for (;;) {
        size_t n = fread(buf, 1, sizeof buf, in);
        if (n == 0) break;
        if (at + n > f->size || memcmp(buf, f->data + at, n) != 0) { same = 0; break; }
        at += n;
    }
    fclose(in);
    return same && at == f->size;
}

/* Files the host tools must see: the runtime archive (for `slc build` and the
 * fuzz harnesses) and the headers the generated C includes. Everything else —
 * the compiler, the vocabularies — is loaded from memory. */
static int on_disk(const char *name) {
    return strncmp(name, "runtime/", 8) == 0 || strncmp(name, "tests/", 6) == 0;
}

static void extract_all(void) {
    for (size_t i = 0; i < slc_embedded_count; i++) {
        const slc_embedded_file *f = &slc_embedded_files[i];
        if (!on_disk(f->name)) continue;
        char path[4096], tmp[4200];
        join(path, sizeof path, root, f->name);
        if (same_file(path, f)) continue;
        make_parents(path);
        int at = snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
        if (at < 0 || (size_t)at >= sizeof tmp) die("path too long", f->name);
        FILE *out = fopen(tmp, "wb");
        if (!out) die("cannot write", tmp);
        if (fwrite(f->data, 1, f->size, out) != f->size) die("short write", tmp);
        fclose(out);
        if (rename(tmp, path) != 0) die("cannot rename", path);
    }
}

/* A work directory per run, not a cache: only the files the host tools must see
 * are written (the runtime archive and the headers), and they are removed when
 * the process exits. Nothing is reused between runs. */
static void work_root(void) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    snprintf(root, sizeof root, "%s/slc-run-%s-%d", tmp, slc_embedded_hash, (int)getpid());
    /* mkdir -p the root */
    char path[4096];
    join(path, sizeof path, root, ".");
    path[strlen(path) - 1] = 0;
    make_parents(path);
    if (mkdir(root, 0777) != 0 && errno != EEXIST) die("cannot create work directory", root);
}

/* slc_embedded(name): the text or bytes of an embedded file, matched by suffix
 * so a cache-root prefix or a relative path both find it. */
static int l_embedded(lua_State *L) {
    size_t n = 0;
    const char *name = luaL_checklstring(L, 1, &n);
    const slc_embedded_file *best = NULL;
    size_t best_len = 0;
    for (size_t i = 0; i < slc_embedded_count; i++) {
        const slc_embedded_file *f = &slc_embedded_files[i];
        size_t fl = strlen(f->name);
        if (n == fl && strcmp(name, f->name) == 0) { best = f; best_len = fl; break; }
        /* a caller may pass a path with a root prefix: take the longest name
           that ends this path at a boundary ("macro/slc.lua" must not match
           "slc.lua") */
        if (n > fl && name[n - fl - 1] == '/' && strcmp(name + n - fl, f->name) == 0 && fl > best_len) {
            best = f; best_len = fl;
        }
    }
    if (!best) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, best->data, best->size);
    return 1;
}

/* remove what this run wrote: the work directory is not a cache */
static void cleanup(void) {
    for (size_t i = 0; i < slc_embedded_count; i++) {
        const slc_embedded_file *f = &slc_embedded_files[i];
        if (!on_disk(f->name)) continue;
        char path[4096];
        join(path, sizeof path, root, f->name);
        unlink(path);
    }
    static const char *dirs[] = { "runtime", "tests/fuzz/regressions", "tests/fuzz", "tests" };
    char path[4096];
    for (size_t i = 0; i < sizeof dirs / sizeof dirs[0]; i++) {
        join(path, sizeof path, root, dirs[i]);
        rmdir(path);
    }
    rmdir(root);
}

int main(int argc, char **argv) {
    work_root();
    extract_all();
    atexit(cleanup);

    /* tools that must call the compiler again (the fuzzers) use this binary */
    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n > 0) { exe[n] = 0; setenv("SLC_DIST", exe, 1); }
    /* the runtime is linked into this process; the archive is carried for
       `slc build` and for harnesses that link C */
    {
        char archive[4096];
        setenv("SLC_RUNTIME_IN_PROCESS", "1", 1);
        join(archive, sizeof archive, root, "runtime/libslc_rt.a");
        setenv("SLC_RT", archive, 1);
        join(archive, sizeof archive, root, "runtime");
        setenv("SLC_RUNTIME_INCLUDE", archive, 1);
    }

    lua_State *L = luaL_newstate();
    if (!L) die("cannot start LuaJIT", NULL);
    luaL_openlibs(L);

    /* arg = { [0] = "<root>/slc.lua", <program arguments...> } */
    lua_newtable(L);
    char script[4096];
    join(script, sizeof script, root, "slc.lua");
    lua_pushstring(L, script);
    lua_rawseti(L, -2, 0);
    for (int i = 1; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    lua_pushcfunction(L, l_embedded);
    lua_setglobal(L, "slc_embedded");
    lua_pushstring(L, root);
    lua_setglobal(L, "slc_root");

    char bootstrap[16384];
    int bs = snprintf(bootstrap, sizeof bootstrap,
        "package.path = [[%s]] .. '/?.lua;' .. package.path\n"
        "local embedded = slc_embedded\n"
        "_G.__slc_embedded_source = function(path) return embedded(path) end\n"
        "table.insert(package.loaders, 2, function(name)\n"
        "  local bytes = embedded(name:gsub('%%.', '/') .. '.lua')\n"
        "  if not bytes then return nil end\n"
        "  local chunk, err = loadstring(bytes, '@' .. name:gsub('%%.', '/') .. '.lua')\n"
        "  if not chunk then error('embedded ' .. name .. ': ' .. tostring(err), 0) end\n"
        "  if os.getenv('SLC_DIST_DEBUG') then io.stderr:write('load ', name, '\\n') end\n"
        "  return chunk\n"
        "end)\n"
        "local chunk, err = loadstring(embedded('slc.lua'), '@%s/slc.lua')\n"
        "if not chunk then io.stderr:write(tostring(err), '\\n'); os.exit(1) end\n"
        "local ok, failure = xpcall(chunk, debug.traceback)\n"
        "if not ok then io.stderr:write(tostring(failure), '\\n'); os.exit(1) end\n",
        root, root);
    if (bs < 0 || (size_t)bs >= sizeof bootstrap) die("bootstrap too long", root);
    if (luaL_loadbuffer(L, bootstrap, strlen(bootstrap), "=slc-bootstrap") || lua_pcall(L, 0, 0, 0)) {
        const char *err = lua_tostring(L, -1);
        fprintf(stderr, "slc: %s\n", err ? err : "bootstrap failed");
        lua_close(L);
        return 2;
    }
    lua_close(L);
    return 0;
}
