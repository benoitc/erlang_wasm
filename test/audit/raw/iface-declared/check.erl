-module(check).
-export([main/1]).
%% For each component: every interface function whose declared core function
%% is not the core export of the same name (what main called), and every
%% export that now gets a declared realloc, post-return or encoding.
main(Dirs) ->
    {ok, _} = application:ensure_all_started(wasm),
    Files = lists:sort(lists:append([filelib:wildcard(filename:join(D, "*.component.wasm"))
                                     || D <- Dirs])),
    R = [one(F) || F <- Files],
    io:format("components ~p, interface functions ~p, renamed ~p~n",
              [length(R), lists:sum([N || {N, _, _} <- R]),
               lists:append([D || {_, D, _} <- R])]),
    io:format("bindings ~p~n", [lists:usort(lists:append([B || {_, _, B} <- R]))]),
    halt().

one(F) ->
    {ok, <<_:8/binary, Sec/binary>>} = file:read_file(F),
    Map = wasm_component_link:export_map(Sec),
    Iface = [{K, V} || {K, V} <- maps:to_list(Map), binary:match(K, <<"#">>) =/= nomatch],
    Diff = [{filename:basename(F), K, V} || {K, V} <- Iface, K =/= V],
    B = [{K, V} || {K, V} <- maps:to_list(wasm_component_link:export_bindings(Sec)),
                   binary:match(K, <<"#">>) =/= nomatch],
    {length(Iface), Diff, B}.
