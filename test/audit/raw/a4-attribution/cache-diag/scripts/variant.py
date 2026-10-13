#!/usr/bin/env python3
"""Make a translation-cache variant of a main tree. Usage: variant.py TREE v1|v2|v3"""
import sys, os
tree, v = sys.argv[1], sys.argv[2]
C = os.path.join(tree, 'src/wasm_core.erl')
J = os.path.join(tree, 'src/wasm_jit.erl')
s = open(C).read()

def sub(old, new, count=1):
    global s
    n = s.count(old)
    assert n == count, (old[:80], n)
    s = s.replace(old, new)

abi = {'v1': 101, 'v2': 102, 'v3': 103}[v]
js = open(J).read()
assert js.count('-define(ABI, 14).') == 1
open(J, 'w').write(js.replace('-define(ABI, 14).', '-define(ABI, %d).' % abi))

EMPTY6 = '''{cerl:abstract(-1), cerl:abstract(none),
                           cerl:abstract(0), cerl:abstract(-1),
                           cerl:abstract(none), cerl:abstract(0)}'''

if v == 'v2':
    # No cache: an empty tuple, so no access or trap matches the cached clauses
    # and nothing is carried.
    sub('-define(TLB_SIZE, 6).', '-define(TLB_SIZE, 0).')
    sub('stateful -> ' + EMPTY6, 'stateful -> {}')

elif v == 'v1':
    sub('-define(TLB_SIZE, 6).', '-define(TLB_SIZE, 3).')
    sub('stateful -> ' + EMPTY6, '''stateful -> {cerl:abstract(-1), cerl:abstract(none),
                           cerl:abstract(0)}''')
    sub("instr(unreachable, _Rest, #g{mut = Mut, tlb = {_, _, _, _, _, _} = Tlb},",
        "instr(unreachable, _Rest, #g{mut = Mut, tlb = {_, _, _} = Tlb},")
    # The trap helper takes two entries; hand it the one twice.
    sub("    call_op(unreachable_at, [Mut | tuple_to_list(Tlb)]);",
        "    call_op(unreachable_at, [Mut | tuple_to_list(Tlb) ++ tuple_to_list(Tlb)]);")
    sub("instr({Op, {_Align, Offset, 0}}, Rest, #g{tlb = {_, _, _, _, _, _}} = G0,",
        "instr({Op, {_Align, Offset, 0}}, Rest, #g{tlb = {_, _, _}} = G0,")
    sub('''    {P, G1} = var(G0), {Ar, G2} = var(G1), {B, G2a} = var(G2),
    {P2, G2b} = var(G2a), {Ar2, G2c} = var(G2b), {B2, G3} = var(G2c),
    Tlb = G0#g.tlb,
    New = {P, Ar, B, P2, Ar2, B2},''', '''    {P, G1} = var(G0), {Ar, G2} = var(G1), {B, G3} = var(G2),
    Tlb = G0#g.tlb,
    New = {P, Ar, B},''')
    sub('''    {TP, TA, TB, TP2, TA2, TB2} = Tlb,''', '''    {TP, TA, TB} = Tlb,''')
    sub('''                     Done(R, {Pg, C, bif('-', [I, Off]), TP, TA, TB})''',
        '''                     Done(R, {Pg, C, bif('-', [I, Off])})''')
    sub('''    Hit2 = cerl:c_let([Ix], bif('+', [TB2, Off]),
                      Done(Do(TA2, Ix), {TP2, TA2, TB2, TP, TA, TB})),
''', '')
    sub('''                all([bif('=:=', [Pg, TP])], Hit,
                    all([bif('=:=', [Pg, TP2])], Hit2, Miss)),''',
        '''                all([bif('=:=', [Pg, TP])], Hit, Miss),''')
    sub('''    Vs = [cerl:c_var(V) || V <- ['Tr', 'Tp', 'Ta', 'Tb', 'Tp2', 'Ta2', 'Tb2']],''',
        '''    Vs = [cerl:c_var(V) || V <- ['Tr', 'Tp', 'Ta', 'Tb']],''')
    sub('''order(first, [R, P, Ar, B, P2, Ar2, B2]) -> [R, Ar2, B2, Ar, B, P2, P];
order(last, [R, P, Ar, B, P2, Ar2, B2]) -> [Ar2, B2, Ar, B, P2, P, R].''',
        '''order(first, [R, P, Ar, B]) -> [R, Ar, B, P];
order(last, [R, P, Ar, B]) -> [Ar, B, P, R].''')

elif v == 'v3':
    # The cache lives in straight-line code only: a continuation, a loop head
    # and a call start it empty, so nothing carries it.
    sub('''carried(#g{mut = Mut, d = D, tlb = Tlb} = G) ->
    locals(G) ++ [Mut, D | tuple_to_list(Tlb)].''',
        '''carried(#g{mut = Mut, d = D} = G) ->
    locals(G) ++ [Mut, D].

empty_tlb() -> ''' + EMPTY6.replace('\n                           ', '\n              ') + '.')
    sub('''    NCarried = case Mut of undefined -> NL; _ -> NL + 2 + ?TLB_SIZE end,''',
        '''    NCarried = case Mut of undefined -> NL; _ -> NL + 2 end,''')
    sub('''            _ -> {lists:nth(NL + 1, Vars), lists:nth(NL + 2, Vars),
                  list_to_tuple(lists:sublist(Vars, NL + 3, ?TLB_SIZE))}''',
        '''            _ -> {lists:nth(NL + 1, Vars), lists:nth(NL + 2, Vars),
                  empty_tlb()}''')
    # Calls: the cache after a call is empty.
    sub('''    Clause = cerl:c_clause([cerl:c_tuple([list_pat(Rs), M1])],
                           seq(Rest, G3#g{mut = M1,
                                          stack = lists:reverse(Rs) ++ G1#g.stack},
                               Exit)),''',
        '''    Clause = cerl:c_clause([cerl:c_tuple([list_pat(Rs), M1])],
                           seq(Rest, reset_tlb(G3#g{mut = M1,
                                          stack = lists:reverse(Rs) ++ G1#g.stack}),
                               Exit)),''')
    sub('''                           seq(Rest, G4#g{mut = M1,
                                          stack = lists:reverse(Rs) ++ G2#g.stack},
                               Exit)),''', '''                           seq(Rest, reset_tlb(G4#g{mut = M1,
                                          stack = lists:reverse(Rs) ++ G2#g.stack}),
                               Exit)),''')
    s += '''
reset_tlb(#g{tlb = undefined} = G) -> G;
reset_tlb(G) -> G#g{tlb = empty_tlb()}.
'''
    # A continuation, a loop or a branch to one is no longer a use, and a call
    # ends the cache's life.
    sub('''paths([], _K, _D) -> {true, false};''', '''paths([], _K, _D) -> {false, true};''')
    sub('''paths([{loop, _, _, _} | _], _Exit, _D) -> {true, false};''',
        '''paths([{loop, _, _, _} | _], _Exit, _D) -> {false, true};
paths([{call, _} | _], _Exit, _D) -> {false, true};
paths([{call_indirect, _, _} | _], _Exit, _D) -> {false, true};''')
    sub('''branch(N, D) when N < D -> {true, false};''', '''branch(N, D) when N < D -> {false, true};''')
open(C, 'w').write(s)
print('variant', v, tree)
