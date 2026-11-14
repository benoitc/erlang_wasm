-module(audit).
-export([main/1]).
%% For each component under the given directories: whether the single-core
%% fast path is taken, and each export's declared core function, string
%% encoding, realloc and post-return, as `wasm_component' prepares them. Run
%% on two trees and diff the output.
main(Dirs) ->
    {ok, _} = application:ensure_all_started(wasm),
    Files = lists:sort(lists:append([filelib:wildcard(filename:join(D, "*.component.wasm"))
                                     || D <- Dirs])),
    [one(F) || F <- Files],
    halt().

one(F) ->
    {ok, Bin} = file:read_file(F),
    Name = filename:basename(F, ".component.wasm"),
    case wasm_component:prepare(Bin) of
        {ok, {prepared, #{decoded := #{composed := true}}}} ->
            io:format("~s composed~n", [Name]);
        {ok, {prepared, #{decoded := #{sec := Sec} = Dec, pre := Pre}}} ->
            Entry = maps:get(entry_idx, Dec, 0),
            Cores = length(maps:get(cores, Dec, [x])),
            Simple = Cores =:= 1 orelse
                         resolve(Sec, Entry, maps:get(core, Dec)),
            io:format("~s cores=~p simple=~p~n", [Name, Cores, Simple]),
            [io:format("  ~s ~p ~p~n", [K, T, maps:get(K, Pre, undefined)])
             || K <- [export_map, str_enc, bindings], T <- [K]];
        Other ->
            io:format("~s ~p~n", [Name, Other])
    end.

%% The fast-path decision, on whichever tree this runs.
resolve(Sec, Entry, Core) ->
    case erlang:function_exported(wasm_component_link, exports_resolve_on_entry, 3) of
        true -> wasm_component_link:exports_resolve_on_entry(Sec, Entry, Core);
        false -> wasm_component_link:exports_resolve_on_entry(Sec, Entry)
    end.
