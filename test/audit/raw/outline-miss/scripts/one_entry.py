#!/usr/bin/env python3
"""One-entry variant of the outline-miss candidate. Usage: one_entry.py TREE

The same design with a cache of one translation: the site is the straddle
guard, the hit and an apply; the function is the miss and nothing else, and
answers {Result, P, A, B}. Scratch only; ABI 115.
"""
import sys, os
tree = sys.argv[1]
C = os.path.join(tree, 'src/wasm_core.erl')
J = os.path.join(tree, 'src/wasm_jit.erl')
s = open(C).read()

def sub(old, new, count=1):
    global s
    n = s.count(old)
    assert n == count, (old[:80], n)
    s = s.replace(old, new)

js = open(J).read()
assert js.count('-define(ABI, 15).') == 1
open(J, 'w').write(js.replace('-define(ABI, 15).', '-define(ABI, 115).'))

sub('-define(TLB_SIZE, 6).', '-define(TLB_SIZE, 3).')
sub('''              stateful -> {cerl:abstract(-1), cerl:abstract(none),
                           cerl:abstract(0), cerl:abstract(-1),
                           cerl:abstract(none), cerl:abstract(0)}''',
    '''              stateful -> {cerl:abstract(-1), cerl:abstract(none),
                           cerl:abstract(0)}''')
sub('''instr(unreachable, _Rest, #g{mut = Mut, tlb = {_, _, _, _, _, _} = Tlb},
      _Exit) ->
    call_op(unreachable_at, [Mut | tuple_to_list(Tlb)]);''',
    '''instr(unreachable, _Rest, #g{mut = Mut, tlb = {_, _, _} = Tlb},
      _Exit) ->
    call_op(unreachable_at, [Mut | tuple_to_list(Tlb) ++ tuple_to_list(Tlb)]);''')
sub('''instr({Op, {_Align, Offset, 0}}, Rest, #g{tlb = {_, _, _, _, _, _}} = G0,''',
    '''instr({Op, {_Align, Offset, 0}}, Rest, #g{tlb = {_, _, _}} = G0,''')
sub('''    {P, G1} = var(G0), {Ar, G2} = var(G1), {B, G2a} = var(G2),
    {P2, G2b} = var(G2a), {Ar2, G2c} = var(G2b), {B2, G3} = var(G2c),
    Tlb = G0#g.tlb,
    New = {P, Ar, B, P2, Ar2, B2},''',
    '''    {P, G1} = var(G0), {Ar, G2} = var(G1), {B, G3} = var(G2),
    Tlb = G0#g.tlb,
    New = {P, Ar, B},''')
sub('''    {TP, TA, TB, _TP2, _TA2, _TB2} = Tlb,''', '''    {TP, TA, TB} = Tlb,''')
sub('''    Vs = [cerl:c_var(V) || V <- ['Or', 'Op', 'Oa', 'Ob', 'Op2', 'Oa2', 'Ob2']],''',
    '''    Vs = [cerl:c_var(V) || V <- ['Or', 'Op', 'Oa', 'Ob']],''')
sub('''    Tlb = {TP, TA, TB, TP2, TA2, TB2} =
        list_to_tuple([cerl:c_var(V)
                       || V <- ['P1', 'A1', 'B1', 'P2', 'A2', 'B2']]),''',
    '''    Tlb = list_to_tuple([cerl:c_var(V) || V <- ['P1', 'A1', 'B1']]),''')
sub('''                     Done(R, {Pg, C, bif('-', [I, page_word(A)]), TP, TA, TB})''',
    '''                     Done(R, {Pg, C, bif('-', [I, page_word(A)])})''')
sub('''    Hit2 = cerl:c_let([Ix], bif('+', [TB2, page_word(A)]),
                      Done(Do(TA2, Ix), {TP2, TA2, TB2, TP, TA, TB})),
''', '')
sub('''                    all([bif('=:=', [Pg, TP2])], Hit2, Miss))))}.''',
    '''                    Miss)))}.''')
sub('''                 case Dir of load -> 8; store -> 9 end).''',
    '''                 case Dir of load -> 5; store -> 6 end).''')
sub('''    Vs = [cerl:c_var(V) || V <- ['Tr', 'Tp', 'Ta', 'Tb', 'Tp2', 'Ta2', 'Tb2']],''',
    '''    Vs = [cerl:c_var(V) || V <- ['Tr', 'Tp', 'Ta', 'Tb']],''')
sub('''order(first, [R, P, Ar, B, P2, Ar2, B2]) -> [R, Ar2, B2, Ar, B, P2, P];
order(last, [R, P, Ar, B, P2, Ar2, B2]) -> [Ar2, B2, Ar, B, P2, P, R].''',
    '''order(first, [R, P, Ar, B]) -> [R, Ar, B, P];
order(last, [R, P, Ar, B]) -> [Ar, B, P, R].''')
open(C, 'w').write(s)
print('one-entry variant', tree)
