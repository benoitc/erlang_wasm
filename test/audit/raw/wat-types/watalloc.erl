-module(watalloc).
-export([main/0]).

%% Compile watbench with +export_all for this diagnostic so it can use the
%% exact corpus. Keep the ordinary watbench build for the timing gate.
main() ->
    ok = allocwords:validate(),
    Modules = watbench:corpus(),
    2240 = length(Modules),
    Parse = fun() -> lists:foreach(fun wasm_wat:module/1, Modules) end,
    ok = Parse(),
    GC = allocwords:measure(Parse),
    Options = #{type => call_memory, pattern => [{wasm_wat, module, 1}],
                report => return},
    {_, Profile} = tprof:profile(Parse, Options),
    #{all := {call_memory, Words, [{wasm_wat, {module, 1}, 2240, _, _, _}]}} =
        tprof:inspect(Profile, total, {measurement, descending}),
    Result = maps:with([allocated, minor, major], GC),
    io:format("~p.~n", [Result#{inputs => length(Modules),
                                call_memory => Words}]),
    halt().
