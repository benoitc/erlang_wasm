#!/usr/bin/env python3
"""Instrument a scratch tree for first-write counting. Usage: patch.py TREE a|b"""
import sys, shutil, os
tree, kind = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(here, 'arb_inst.erl'), os.path.join(tree, 'src/arb_inst.erl'))

def sub(path, old, new, count=1):
    p = os.path.join(tree, path)
    s = open(p).read()
    n = s.count(old)
    assert n == count, (path, old[:60], n)
    s = s.replace(old, new)
    open(p, 'w').write(s)

TIMED = '''
{name}({args}) ->
    case arb_inst:on() of
        false -> {name}_0({args});
        C ->
            T0 = erlang:monotonic_time(nanosecond),
            try {name}_0({args})
            after
                arb_inst:add(C, {name}, erlang:monotonic_time(nanosecond) - T0)
            end
    end.

'''

if kind == 'a':
    sub('src/wasm_memory.erl', 'fault(#mem{tab = Tab} = M, P) ->',
        TIMED.format(name='fault', args='M, P').lstrip('\n') +
        'fault_0(#mem{tab = Tab} = M, P) ->')
else:
    p = os.path.join(tree, 'src/wasm_memory.erl')
    s = open(p).read()
    a = s.index('buy(#mem{id = Res, nif = Nif, arena_ref = Ref} = M, Need) ->')
    b = s.index("%% The fewest chunks past `Have'")
    body = s[a:b].replace('buy(', 'buy_0(')
    s = s[:a] + TIMED.format(name='buy', args='M, Need').lstrip('\n') + body + s[b:]
    open(p, 'w').write(s)
    c = 'c_src/wasm_mem_nif.c'
    sub(c, '/* ------------------------------------------------------------ accounting */',
        '''/* arb: first-write counters, scratch instrumentation only. */
static uint64_t arb_pages, arb_writes, arb_ns;
static __thread uint64_t arb_tl_new;
#define ARB_TIMED(stmt) do {                                               \\
    uint64_t arb_n = arb_tl_new;                                           \\
    ErlNifTime arb_t0 = arb_n ? enif_monotonic_time(ERL_NIF_NSEC) : 0;     \\
    stmt;                                                                  \\
    if (arb_n) {                                                           \\
        __atomic_fetch_add(&arb_writes, 1, __ATOMIC_RELAXED);              \\
        __atomic_fetch_add(&arb_ns, (uint64_t)(enif_monotonic_time(       \\
                               ERL_NIF_NSEC) - arb_t0), __ATOMIC_RELAXED); \\
        arb_tl_new = 0;                                                    \\
    }                                                                      \\
} while (0)

static ERL_NIF_TERM arb_firstwrite(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return enif_make_tuple3(
        env, enif_make_uint64(env, __atomic_load_n(&arb_pages, __ATOMIC_RELAXED)),
        enif_make_uint64(env, __atomic_load_n(&arb_writes, __ATOMIC_RELAXED)),
        enif_make_uint64(env, __atomic_load_n(&arb_ns, __ATOMIC_RELAXED)));
}

/* ------------------------------------------------------------ accounting */''')
    sub(c, '''    int64_t c;
    if (n == 0 || o >= m->img) return 0;''', '''    int64_t c;
    arb_tl_new = 0;
    if (n == 0 || o >= m->img) return 0;''')
    sub(c, '''        if (__atomic_fetch_or(&m->bits[p >> 6], bit, __ATOMIC_ACQ_REL) & bit)
            __atomic_fetch_add(&m->credit, 1, __ATOMIC_RELAXED);
    }
    return 0;''', '''        if (__atomic_fetch_or(&m->bits[p >> 6], bit, __ATOMIC_ACQ_REL) & bit)
            __atomic_fetch_add(&m->credit, 1, __ATOMIC_RELAXED);
        else
            arb_tl_new++;
    }
    if (arb_tl_new)
        __atomic_fetch_add(&arb_pages, arb_tl_new, __ATOMIC_RELAXED);
    return 0;''')
    sub(c, '    store_n(m->base + o, n, v);\n    return A_OK;',
        '    ARB_TIMED(store_n(m->base + o, n, v));\n    return A_OK;')
    sub(c, '    GUEST_BYTES(memset(m->base + o, (int)(b & 0xff), len));',
        '    ARB_TIMED(GUEST_BYTES(memset(m->base + o, (int)(b & 0xff), len)));')
    sub(c, '    GUEST_BYTES(memmove(dm->base + d, sm->base + s, len));',
        '    ARB_TIMED(GUEST_BYTES(memmove(dm->base + d, sm->base + s, len)));')
    sub(c, '    GUEST_BYTES(memcpy(m->base + o, b.data, b.size));',
        '    ARB_TIMED(GUEST_BYTES(memcpy(m->base + o, b.data, b.size)));')
    sub(c, '{"map_image", 2, map_image, 0},\n};',
        '{"map_image", 2, map_image, 0},\n    {"arb_firstwrite", 0, arb_firstwrite, 0},\n};')
    e = 'src/wasm_mem_nif.erl'
    sub(e, '         map_image/2]).', '         map_image/2, arb_firstwrite/0]).')
    sub(e, '       map_image/2]).', '       map_image/2, arb_firstwrite/0]).')
    p = os.path.join(tree, e)
    s = open(p).read()
    s += '\narb_firstwrite() -> ?NOT_LOADED.\n'
    open(p, 'w').write(s)
print('patched', tree, kind)
