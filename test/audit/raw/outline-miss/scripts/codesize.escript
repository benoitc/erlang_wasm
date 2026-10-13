#!/usr/bin/env escript
%% codesize.escript CACHE_DIR...: per cache dir, the slot modules' BEAM
%% instruction count, y-register moves, functions and continuation arities.
main(Dirs) -> [one(D) || D <- Dirs], ok.

one(Dir) ->
    Files = [F || F <- filelib:wildcard(filename:join(Dir, "*")), filelib:is_regular(F)],
    Ms = lists:filtermap(fun mod/1, Files),
    {Ins, Ym, Fs, Ks, Bytes} = lists:foldl(
        fun({I, Y, F, K, B}, {I0, Y0, F0, K0, B0}) -> {I0 + I, Y0 + Y, F0 + F, K ++ K0, B0 + B} end,
        {0, 0, 0, [], 0}, Ms),
    S = lists:sort(Ks),
    {Med, Max, Mean} = case S of
        [] -> {0, 0, 0.0};
        _ -> {lists:nth((length(S) + 1) div 2, S), lists:last(S), lists:sum(S) / length(S)}
    end,
    io:format("~s\tmodules=~p\tbeam_bytes=~p\tinstrs=~p\tymoves=~p\tfuns=~p\tconts=~p\tk_arity_med=~p\tk_arity_max=~p\tk_arity_mean=~.2f~n",
              [Dir, length(Ms), Bytes, Ins, Ym, Fs, length(S), Med, Max, Mean]).

mod(File) ->
    {ok, Bin} = file:read_file(File),
    case Bin of
        <<"WASMJIT", 0, _:16, _:32, _:32/binary, Beam/binary>> ->
            {beam_file, _M, _Ex, _A, _C, Code} = beam_disasm:file(Beam),
            Res = [fun_stats(F) || F <- Code],
            {true, {lists:sum([I || {I, _, _} <- Res]),
                    lists:sum([Y || {_, Y, _} <- Res]),
                    length(Code),
                    [A || {_, _, {k, A}} <- Res],
                    byte_size(Beam)}};
        _ -> false
    end.

fun_stats({function, Name, Arity, _, Is}) ->
    N = length([I || I <- Is, not is_label(I)]),
    Y = length([I || I <- Is, ymove(I)]),
    K = case string:find(atom_to_list(Name), "wasm_k_") of
            nomatch -> f;
            _ -> {k, Arity}
        end,
    {N, Y, K}.

is_label({label, _}) -> true;
is_label({line, _}) -> true;
is_label(_) -> false.

ymove({move, {y, _}, _}) -> true;
ymove({move, _, {y, _}}) -> true;
ymove({init_yregs, _}) -> true;
ymove({allocate, _, _}) -> false;
ymove(_) -> false.
