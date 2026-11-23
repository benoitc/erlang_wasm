-module(decalloc).
-export([main/1]).
main([Guest]) ->
    {ok, Bin} = file:read_file(filename:join(["test", "fixtures", "lang", Guest ++ ".wasm"])),
    [code:ensure_loaded(M) || M <- [wasm_decode, wasm_decode_code, wasm_leb128]],
    {_, Raw} = tprof:profile(fun() -> {ok, _} = wasm_decode:module(Bin) end,
                             #{type => call_memory,
                               pattern => [{wasm_decode_code, '_', '_'}, {wasm_leb128, '_', '_'}, {wasm_decode, '_', '_'}],
                               report => return}),
    #{all := {call_memory, Total, Lines}} = tprof:inspect(Raw, total, {measurement, descending}),
    io:format("total ~p~n", [Total]),
    [io:format("~p:~p calls ~p words ~p~n", [M, F, C, W]) || {M, F, C, W, _, _} <- lists:sublist(Lines, 12)],
    halt().
