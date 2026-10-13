#!/usr/bin/env python3
"""Out-of-line miss variants of a main tree. Usage: variant4.py TREE v4|v5|v6|v4c

v4   both hits inline; the miss in one module-local function per access shape
v5   entry-1 hit inline; entry-2 hit and the miss in the module-local function
v6   as v4, the function being wasm_exec:tlb_load/10 and tlb_store/11
v4c  v4 counting hits and misses (never a timed arm)
"""
import sys, os
tree, v = sys.argv[1], sys.argv[2]
C = os.path.join(tree, 'src/wasm_core.erl')
J = os.path.join(tree, 'src/wasm_jit.erl')
X = os.path.join(tree, 'src/wasm_exec.erl')
s = open(C).read()

def sub(old, new, count=1):
    global s
    n = s.count(old)
    assert n == count, (old[:80], n)
    s = s.replace(old, new)

abi = {'v4': 104, 'v5': 105, 'v6': 106, 'v4c': 107}[v]
js = open(J).read()
assert js.count('-define(ABI, 14).') == 1
open(J, 'w').write(js.replace('-define(ABI, 14).', '-define(ABI, %d).' % abi))

sub('-define(MAX_FUNS, 4096).', '-define(MAX_FUNS, 4096).\noutline() -> %s.' % v)

# The module gets the out-of-line functions when any function is stateful.
sub('''        {ok, cerl:c_module(cerl:c_atom(Name), Exports, [], [Invoke | Defs])}''',
    '''        Outs = case lists:any(fun({_, S}) -> S =:= stateful end, Shapes)
                   andalso outline() =/= v6 of
                   true -> miss_defs();
                   false -> []
               end,
        {ok, cerl:c_module(cerl:c_atom(Name), Exports, [],
                           [Invoke | Defs] ++ Outs)}''')

OLD_TAIL = '''    cerl:c_let([Mem], mem_at(Mut, 0),
      cerl:c_let([A], Addr,
        cerl:c_let([Bit], bif('*', [bif('band', [A, cerl:abstract(7)]),
                                    cerl:abstract(8)]),
          cerl:c_let([Pg], bif('bsr', [A, cerl:abstract(12)]),
            all([bif('=<', [bif('+', [Bit, cerl:abstract(N * 8)]),
                            cerl:abstract(64)])],
                all([bif('=:=', [Pg, TP])], Hit,
                    all([bif('=:=', [Pg, TP2])], Hit2, Miss)),
                Slow))))).
'''
NEW_TAIL = '''    Count = fun(I, E) ->
                    case outline() of
                        v4c -> cerl:c_seq(call_op(cdiag_count,
                                                  [cerl:abstract(I)]), E);
                        _ -> E
                    end
            end,
    Vals = case Dir of load -> []; store -> [Val] end,
    Out = case outline() of
              v6 ->
                  F = case Dir of load -> tlb_load; store -> tlb_store end,
                  call_op(F, [Mut, cerl:abstract(N), cerl:c_atom(Kind), A
                              | Vals] ++ tuple_to_list(Tlb));
              _ ->
                  cerl:c_apply(cerl:c_fname(miss_name(Dir, N, Kind),
                                            8 + length(Vals)),
                               [Mut, A | Vals] ++ tuple_to_list(Tlb))
          end,
    case Where of
        site ->
            %% The hits, and a call for everything else.
            Outer = from_tuple(Form, Out),
            Inner = case outline() of
                        v5 -> all([bif('=:=', [Pg, TP])], Hit, Outer);
                        _ -> all([bif('=:=', [Pg, TP])], Count(1, Hit),
                                 all([bif('=:=', [Pg, TP2])], Count(2, Hit2),
                                     Outer))
                    end,
            cerl:c_let([A], Addr,
              cerl:c_let([Bit], bif('*', [bif('band', [A, cerl:abstract(7)]),
                                          cerl:abstract(8)]),
                cerl:c_let([Pg], bif('bsr', [A, cerl:abstract(12)]),
                  all([bif('=<', [bif('+', [Bit, cerl:abstract(N * 8)]),
                                  cerl:abstract(64)])],
                      Inner, Slow))));
        out ->
            %% The function's body: what the site did not settle.
            Rest = case outline() of
                       v5 -> all([bif('=:=', [Pg, TP2])], Hit2, Miss);
                       _ -> Count(3, Miss)
                   end,
            cerl:c_let([Mem], mem_at(Mut, 0),
              cerl:c_let([A], Addr,
                cerl:c_let([Bit], bif('*', [bif('band', [A, cerl:abstract(7)]),
                                            cerl:abstract(8)]),
                  cerl:c_let([Pg], bif('bsr', [A, cerl:abstract(12)]),
                             Rest))))
    end.

%% What the out-of-line function answers is always the tuple, so a site that
%% wants a value list takes it apart.
from_tuple(tuple, Call) -> Call;
from_tuple(Form, Call) ->
    Vs = [cerl:c_var(V) || V <- ['Or', 'Op', 'Oa', 'Ob', 'Op2', 'Oa2', 'Ob2']],
    cerl:c_case(Call, [cerl:c_clause([cerl:c_tuple(Vs)],
                                     cerl:c_values(order(Form, Vs)))]).

miss_name(Dir, N, Kind) ->
    list_to_atom("wasm_m_" ++ atom_to_list(Dir) ++ "_" ++ integer_to_list(N)
                 ++ "_" ++ atom_to_list(Kind)).

miss_defs() ->
    Ls = lists:usort([wasm_exec:load_spec(Op) || Op <- ?LOADS]),
    Ss = lists:usort([wasm_exec:store_spec(Op) || Op <- ?STORES]),
    [miss_def(Dir, N, Kind) || {Dir, N, Kind} <- Ls ++ Ss].

miss_def(Dir, N, Kind) ->
    Mut = cerl:c_var('Mu'), A0 = cerl:c_var('A0'), Val = cerl:c_var('Val0'),
    Tlb = list_to_tuple([cerl:c_var(V)
                         || V <- ['P1', 'A1', 'B1', 'P2', 'A2', 'B2']]),
    Vals = case Dir of load -> []; store -> [Val] end,
    {cerl:c_fname(miss_name(Dir, N, Kind), 8 + length(Vals)),
     cerl:c_fun([Mut, A0 | Vals] ++ tuple_to_list(Tlb),
                cached(Dir, Mut, N, Kind, A0, Val, Tlb, tuple, out))}.
'''
sub(OLD_TAIL, NEW_TAIL)
sub('''cached(Dir, Mut, N, Kind, Addr, Val, Tlb, Form) ->
    {TP, TA, TB, TP2, TA2, TB2} = Tlb,''',
    '''cached(Dir, Mut, N, Kind, Addr, Val, Tlb, Form) ->
    cached(Dir, Mut, N, Kind, Addr, Val, Tlb, Form, site).

cached(Dir, Mut, N, Kind, Addr, Val, Tlb, Form, Where) ->
    {TP, TA, TB, TP2, TA2, TB2} = Tlb,''')
open(C, 'w').write(s)

xs = open(X).read()
def xsub(old, new):
    global xs
    assert xs.count(old) == 1, old
    xs = xs.replace(old, new)

if v == 'v6':
    xsub('''-export([load_spec/1, store_spec/1]).''',
         '''-export([load_spec/1, store_spec/1]).
-export([tlb_load/10, tlb_store/11]).
-include("wasm_memory.hrl").''')
    xs += '''
%%% ------------------------------------------- translation cache, out of line ---

tlb_load(Mu, N, Kind, A, P1, A1, B1, P2, A2, B2) ->
    Mem = element(1, Mu#mut.mems),
    case tlb_find(Mem, A, N) of
        {C, Ix} ->
            Raw = case N of
                      8 -> atomics:get(C, Ix);
                      _ -> (atomics:get(C, Ix) bsr ((A band 7) * 8))
                               band wasm_memory:mask(N)
                  end,
            {decode_loaded(Kind, N, Raw), A bsr 12, C,
             Ix - ((A band 4095) bsr 3), P1, A1, B1};
        image ->
            Bits = N * 8, Po = A band 16#FFFF,
            R = case element((A bsr 16) + 1, element(?MEM_IMAGE, Mem)) of
                    zero -> decode_loaded(Kind, N, 0);
                    <<_:Po/binary, X:Bits/little-unsigned, _/binary>> ->
                        decode_loaded(Kind, N, X);
                    _ -> load_at(Mu, 0, N, Kind, A)
                end,
            {R, P1, A1, B1, P2, A2, B2};
        none ->
            {load_at(Mu, 0, N, Kind, A), P1, A1, B1, P2, A2, B2}
    end.

tlb_store(Mu, N, Kind, A, Val, P1, A1, B1, P2, A2, B2) ->
    Mem = element(1, Mu#mut.mems),
    case tlb_find(Mem, A, N) of
        {C, Ix} ->
            V = encode_stored(Kind, Val) band wasm_memory:mask(N),
            case N of
                8 -> atomics:put(C, Ix, V);
                _ ->
                    Bit = (A band 7) * 8,
                    Keep = 16#FFFFFFFFFFFFFFFF bxor (wasm_memory:mask(N) bsl Bit),
                    atomics:put(C, Ix, (atomics:get(C, Ix) band Keep)
                                    bor (V bsl Bit))
            end,
            {Mu, A bsr 12, C, Ix - ((A band 4095) bsr 3), P1, A1, B1};
        _ ->
            {store_at(Mu, 0, N, Kind, A, Val), P1, A1, B1, P2, A2, B2}
    end.

%% The array and word an in-bounds, one-word access is at, or `none' for
%% everything the helpers settle: a straddle, out of bounds, an untouched image
%% page, an arena chunk this handle has not seen.
tlb_find(Mem, A, N) ->
    case (A band 7) * 8 + N * 8 =< 64 andalso
        A + N =< element(?MEM_PAGES, Mem) * 65536 of
        false -> none;
        true ->
            case A >= element(?MEM_IMG_BYTES, Mem) of
                true ->
                    Sh = element(?MEM_SHIFT, Mem),
                    {element((A bsr Sh) + 1, element(?MEM_CHUNKS, Mem)),
                     ((A band ((1 bsl Sh) - 1)) bsr 3) + 1};
                false ->
                    case atomics:get(element(?MEM_TAB, Mem), (A bsr 12) + 1) of
                        0 -> image;
                        E ->
                            K = E bsr 16, Ar = element(?MEM_ARENA, Mem),
                            case K =< tuple_size(Ar) of
                                true ->
                                    {element(K, Ar),
                                     (E band 16#FFFF) * 512
                                     + ((A band 4095) bsr 3) + 1};
                                false -> none
                            end
                    end
            end
    end.
'''
elif v == 'v4c':
    xsub('''-export([load_spec/1, store_spec/1]).''',
         '''-export([load_spec/1, store_spec/1]).
-export([cdiag_count/1, cdiag_read/0]).''')
    xs += '''
cdiag_count(I) ->
    counters:add(cdiag_ref(), I, 1).

cdiag_read() ->
    R = cdiag_ref(),
    {counters:get(R, 1), counters:get(R, 2), counters:get(R, 3)}.

cdiag_ref() ->
    case persistent_term:get(cdiag, undefined) of
        undefined ->
            R = counters:new(3, [write_concurrency]),
            persistent_term:put(cdiag, R),
            R;
        R -> R
    end.
'''
open(X, 'w').write(xs)
print('variant', v, tree)
