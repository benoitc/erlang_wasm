#!/usr/bin/env python3
"""Instrument the attr-inst scratch tree. Usage: patch.py TREE"""
import sys, shutil, os
tree = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(here, 'wasm_prof_c.erl'), os.path.join(tree, 'src/wasm_prof_c.erl'))

def sub(path, old, new, count=1):
    p = os.path.join(tree, path)
    s = open(p).read()
    n = s.count(old)
    assert n == count, (path, old[:70], n)
    s = s.replace(old, new)
    open(p, 'w').write(s)

C = 'src/wasm_core.erl'
# Store recording at every compiled store site (both access and cached), and
# entry counters: 13 cached, 14 access.
old = '''      cerl:c_let([A], Addr,
        cerl:c_let([Bit], bif('*', [bif('band', [A, cerl:abstract(7)]),
                                    cerl:abstract(8)]),'''
new = '''      cerl:c_let([A], Addr, prof_store(Dir, A, N, Mem, PROFENTRY,
        cerl:c_let([Bit], bif('*', [bif('band', [A, cerl:abstract(7)]),
                                    cerl:abstract(8)]),'''
p = os.path.join(tree, C); s = open(p).read()
assert s.count(old) == 2
i = s.index(old); s = s[:i] + new.replace('PROFENTRY', '14') + s[i+len(old):]
i = s.index(old); s = s[:i] + new.replace('PROFENTRY', '13') + s[i+len(old):]
open(p, 'w').write(s)
# close the extra paren: access ends with "Slow)))).", cached ends with "Slow)))))."
sub(C, '''                                                           Slow))]),
                   Slow)))).''', '''                                                           Slow))]),
                   prof_seq(12, Slow)))))).''')
sub(C, '''                all([bif('=:=', [Pg, TP])], Hit,
                    all([bif('=:=', [Pg, TP2])], Hit2, Miss)),
                Slow))))).''', '''                all([bif('=:=', [Pg, TP])], prof_seq(1, Hit),
                    all([bif('=:=', [Pg, TP2])], prof_seq(2, Hit2), Miss)),
                prof_seq(8, Slow))))))).''')
# misses: growth (3 cached, 9 access), not-ordinary (11 cached)
sub(C, '''    Miss = ordinary(Mem, A, N, Bit,
                    cerl:c_case(bif('>=', [A, field(Mem, ?MEM_IMG_BYTES)]),
                                [cerl:c_clause([cerl:abstract(true)], Growth),''',
'''    Miss = ordinary(Mem, A, N, Bit,
                    cerl:c_case(bif('>=', [A, field(Mem, ?MEM_IMG_BYTES)]),
                                [cerl:c_clause([cerl:abstract(true)], prof_seq(3, Growth)),''')
sub(C, '''                                 cerl:c_clause([cerl:c_var('_Img')], Image)]),
                    Slow),''', '''                                 cerl:c_clause([cerl:c_var('_Img')], Image)]),
                    prof_seq(11, Slow)),''')
sub(C, '''                               [cerl:c_clause([cerl:abstract(true)], Growth),
                                cerl:c_clause([cerl:c_var('_Img')],''', '''                               [cerl:c_clause([cerl:abstract(true)], prof_seq(9, Growth)),
                                cerl:c_clause([cerl:c_var('_Img')],''')
# image region: 4 private, 5 untouched load, 6 untouched store (slow), 7 unseen chunk (slow)
sub(C, '''              [cerl:c_clause(
                 [cerl:abstract(true)],
                 cerl:c_let([Ck], bif(element, [K, Ar]),''', '''              [cerl:c_clause(
                 [cerl:abstract(true)],
                 prof_seq(4, cerl:c_let([Ck], bif(element, [K, Ar]),''')
sub(C, '''                            end, Ck, Ix)))),
               cerl:c_clause([cerl:c_var('_Unseen')], Slow)]))),''', '''                            end, Ck, Ix))))),
               cerl:c_clause([cerl:c_var('_Unseen')], prof_seq(7, Slow))]))),''')
sub(C, '''                    load -> image_load(Mem, A, N, Kind, Slow, Keep);
                    store -> Slow''', '''                    load -> prof_seq(5, image_load(Mem, A, N, Kind, prof_seq(10, Slow), Keep));
                    store -> prof_seq(6, Slow)''')
s = open(p).read()
s += '''
prof_seq(I, E) ->
    cerl:c_seq(cerl:c_call(cerl:c_atom(wasm_prof_c), cerl:c_atom(hit),
                           [cerl:abstract(I)]), E).

prof_store(load, _A, _N, _Mem, I, E) -> prof_seq(I, E);
prof_store(store, A, N, Mem, I, E) ->
    prof_seq(I, cerl:c_seq(cerl:c_call(cerl:c_atom(wasm_prof_c), cerl:c_atom(st),
                                      [A, cerl:abstract(N),
                                       field(Mem, ?MEM_IMG_BYTES)]), E)).
'''
open(p, 'w').write(s)

E = 'src/wasm_exec.erl'
sub(E, '''load_at(Mu, M, N, Kind, Addr) ->
    Mem''', '''load_at(Mu, M, N, Kind, Addr) ->
    wasm_prof_c:hit(20),
    Mem''')
sub(E, '''store_at(Mu, M, N, Kind, Addr, Value) ->
    Mem''', '''store_at(Mu, M, N, Kind, Addr, Value) ->
    wasm_prof_c:hit(21),
    Mem''')

M = 'src/wasm_memory.erl'
# scalar image writes recorded (put_word, cas_word) -> 22 count
sub(M, '''put_word(#mem{img_bytes = IB} = M, Addr, Value) when Addr < IB ->
''', '''put_word(#mem{img_bytes = IB} = M, Addr, Value) when Addr < IB ->
    wasm_prof_c:st(Addr, 8, IB),
''')
sub(M, '''cas_word(#mem{img_bytes = IB} = M, Addr, Expected, Desired) when Addr < IB ->
''', '''cas_word(#mem{img_bytes = IB} = M, Addr, Expected, Desired) when Addr < IB ->
    wasm_prof_c:st(Addr, 8, IB),
''')
# bulk prepares: store_bytes, fill, copy
sub(M, '    ok = prepare(M, Addr, byte_size(Bin)),', '    ok = bulk_prepare(M, Addr, byte_size(Bin)),')
sub(M, '    ok = prepare(M, Addr, Len),\n    fill_at', '    ok = bulk_prepare(M, Addr, Len),\n    fill_at')
sub(M, 'false -> ok = prepare(M, Dst, Len), copy_at', 'false -> ok = bulk_prepare(M, Dst, Len), copy_at')
# fault: 30 count, 31 ns, 32 fill ns, 33 nonzero copies, 34 extend count, 35 extend ns
sub(M, '''fault(#mem{tab = Tab} = M, P) ->
    E = located(claim(M)),
    ok = fill_slot(M, E, P),''', '''fault(M, P) ->
    T0 = erlang:monotonic_time(nanosecond),
    R = fault_0(M, P),
    wasm_prof_c:hit(30),
    wasm_prof_c:add(31, erlang:monotonic_time(nanosecond) - T0),
    R.

fault_0(#mem{tab = Tab} = M, P) ->
    E = located(claim(M)),
    T1 = erlang:monotonic_time(nanosecond),
    ok = fill_slot(M, E, P),
    wasm_prof_c:add(32, erlang:monotonic_time(nanosecond) - T1),''')
sub(M, '''                    {C, I} = slot_word(M, S, P bsl ?SLOT_SHIFT),
                    scatter_run(C, I, Page)''', '''                    wasm_prof_c:hit(33),
                    {C, I} = slot_word(M, S, P bsl ?SLOT_SHIFT),
                    scatter_run(C, I, Page)''')
sub(M, '''            ok = extend_arena(M, chunk_of(N + 1)),
            claim(M)''', '''            T0 = erlang:monotonic_time(nanosecond),
            ok = extend_arena(M, chunk_of(N + 1)),
            wasm_prof_c:hit(34),
            wasm_prof_c:add(35, erlang:monotonic_time(nanosecond) - T0),
            claim(M)''')
s = open(os.path.join(tree, M)).read()
s += '''
%% attr: a bulk write's prepare, with its first-write faults classified by
%% whether the write covers the whole 4 KiB page: 40 full, 41 partial; 42 bulk
%% ops, 43 bulk bytes in the image region.
bulk_prepare(#mem{img_bytes = IB, tab = Tab} = M, Addr, Len) when Addr < IB, Len > 0 ->
    wasm_prof_c:st_range(Addr, Len, IB),
    wasm_prof_c:hit(42),
    wasm_prof_c:add(43, min(Addr + Len, IB) - Addr),
    Last = (min(Addr + Len, IB) - 1) bsr ?SLOT_SHIFT,
    [case atomics:get(Tab, P + 1) of
         0 ->
             case Addr =< P bsl ?SLOT_SHIFT
                 andalso Addr + Len >= (P + 1) bsl ?SLOT_SHIFT of
                 true -> wasm_prof_c:hit(40);
                 false -> wasm_prof_c:hit(41)
             end;
         _ -> ok
     end || P <- lists:seq(Addr bsr ?SLOT_SHIFT, Last)],
    prepare(M, Addr, Len);
bulk_prepare(M, Addr, Len) ->
    prepare(M, Addr, Len).
'''
open(os.path.join(tree, M), 'w').write(s)
print('patched', tree)
