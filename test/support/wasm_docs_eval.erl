%% @doc The process a documentation page runs in, inside a peer node.
%%
%% `wasm_docs_SUITE' starts one of these per page and sends it the page's
%% `run' blocks in order. It keeps the bindings each block leaves, the way a
%% shell does, so `W' from one block is usable in the next, and it stays alive
%% between blocks so a worker a block links to stays alive with it.
%%
%% It traps exits. Every link a block creates is attributed to that block, so
%% an abnormal exit is reported with the block that started the process, even
%% when the exit arrives later, between blocks or during another one. A
%% `normal' exit is ignored: a later block stopping a worker is not a failure.
-module(wasm_docs_eval).

-export([start/0, run/5, finish/1, chunks/1]).

-spec start() -> pid().
start() ->
    spawn(fun() -> process_flag(trap_exit, true), loop(#{}, #{}) end).

%% Block is a label for reports. Expect is `none' or the source of a pattern
%% the block's value must match. ExpectExit is the exit reasons this block may
%% cause without failing.
-spec run(pid(), term(), string(), none | string(), [term()]) ->
          ok | {error, term()}.
run(Eval, Block, Src, Expect, ExpectExit) ->
    Ref = monitor(process, Eval),
    Eval ! {run, self(), Ref, Block, Src, Expect, ExpectExit},
    receive
        {Ref, Result}                  -> demonitor(Ref, [flush]), Result;
        {'DOWN', Ref, _, _, Why}       -> {error, {evaluator_died, Why}}
    end.

%% Waits briefly for exits still in flight, then reports any abnormal one.
-spec finish(pid()) -> ok | {error, term()}.
finish(Eval) ->
    Ref = monitor(process, Eval),
    Eval ! {finish, self(), Ref},
    receive
        {Ref, Result}            -> demonitor(Ref, [flush]), Result;
        {'DOWN', Ref, _, _, Why} -> {error, {evaluator_died, Why}}
    end.

%%% ------------------------------------------------------------ the loop ---

loop(Bindings, Owners) ->
    receive
        {run, From, Ref, Block, Src, Expect, ExpectExit} ->
            {Pending, Owners1} = exits(Owners, [], none, []),
            case Pending of
                [_ | _] ->
                    From ! {Ref, {error, {abnormal_exit, Pending}}},
                    loop(Bindings, Owners1);
                [] ->
                    Before = links(),
                    {Result, Bindings1} = eval(Src, Expect, Bindings),
                    New = links() -- Before,
                    Owners2 = maps:merge(Owners1,
                                         maps:from_keys(New, Block)),
                    {Late, Owners3} = exits(Owners2, ExpectExit, Block, []),
                    From ! {Ref, merge(Result, Late)},
                    loop(Bindings1, Owners3)
            end;
        {finish, From, Ref} ->
            timer:sleep(200),
            {Late, _} = exits(Owners, [], none, []),
            From ! {Ref, merge(ok, Late)}
    end.

eval(Src, Expect, Bindings) ->
    try
        {ok, Toks, _} = erl_scan:string(Src),
        Exprs = parse_all(Toks),
        {value, V, B1} = erl_eval:exprs(Exprs, Bindings),
        {check(Expect, V), B1}
    catch
        Class:Reason:St ->
            {{error, {Class, Reason, lists:sublist(St, 3)}}, Bindings}
    end.

%% A block is a sequence of dot-terminated expression lists, as typed at a
%% shell prompt. A missing final dot is supplied.
parse_all(Toks) ->
    lists:append([begin {ok, E} = erl_parse:parse_exprs(C), E end
                  || C <- chunks(Toks)]).

chunks(Toks) -> chunks(Toks, [], []).

chunks([], [], Acc) -> lists:reverse(Acc);
chunks([], Cur, Acc) ->
    Line = element(2, hd(Cur)),
    lists:reverse([lists:reverse([{dot, Line} | Cur]) | Acc]);
chunks([{dot, _} = D | T], Cur, Acc) ->
    chunks(T, [], [lists:reverse([D | Cur]) | Acc]);
chunks([Tok | T], Cur, Acc) ->
    chunks(T, [Tok | Cur], Acc).

check(none, _V) -> ok;
check(Pattern, V) ->
    Src = "case '__V' of " ++ Pattern ++ " -> true; _ -> false end.",
    {ok, Toks, _} = erl_scan:string(Src),
    {ok, [E0]} = erl_parse:parse_exprs(Toks),
    E = replace_var(E0),
    case erl_eval:expr(E, #{'__V__' => V}) of
        {value, true, _} -> ok;
        _                -> {error, {no_match, Pattern, V}}
    end.

%% `'__V'' is an atom in the source so the scanner accepts it anywhere; it is
%% turned into the variable holding the value here.
replace_var({atom, L, '__V'}) -> {var, L, '__V__'};
replace_var(T) when is_tuple(T) ->
    list_to_tuple([replace_var(E) || E <- tuple_to_list(T)]);
replace_var(L) when is_list(L) -> [replace_var(E) || E <- L];
replace_var(X) -> X.

links() ->
    {links, L} = process_info(self(), links),
    [P || P <- L, is_pid(P)].

%% Drains the exits already delivered. Normal ones and the ones the current
%% block declared are dropped; the rest are returned with their origin.
exits(Owners, Allowed, Seen, Acc) ->
    receive
        {'EXIT', Pid, normal} ->
            exits(maps:remove(Pid, Owners), Allowed, Seen, Acc);
        {'EXIT', Pid, Why} ->
            Origin = maps:get(Pid, Owners, unknown),
            Owners1 = maps:remove(Pid, Owners),
            case lists:member(Why, Allowed) of
                true  -> exits(Owners1, Allowed, Seen, Acc);
                false -> exits(Owners1, Allowed, Seen,
                               [#{pid => Pid, reason => Why,
                                  linked_by => Origin, seen_in => Seen}
                                | Acc])
            end
    after 0 ->
        {lists:reverse(Acc), Owners}
    end.

merge(Result, [])    -> Result;
merge(ok, Late)      -> {error, {abnormal_exit, Late}};
merge({error, E}, L) -> {error, {E, {abnormal_exit, L}}}.
