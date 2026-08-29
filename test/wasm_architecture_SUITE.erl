%% @doc The shape of the module graph, held to what `docs/architecture.md' says.
%%
%% That page draws the runtime as nine layers with three cycles in it, and a
%% drawing nobody checks stops being true. This recomputes the graph from the
%% compiled modules and fails when it has changed.
%%
%% The point is not that cycles are forbidden. All three of these are
%% deliberate and each is defensible in one sentence; what is forbidden is a
%% *fourth* one appearing without anybody deciding it should. A cycle is the
%% one structural property a reader cannot discover locally: every other
%% question about a module can be answered by reading that module, and this one
%% can only be answered by reading all forty-eight.
-module(wasm_architecture_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [the_module_graph_has_the_three_documented_cycles,
     every_module_says_what_it_is].

%% The three components `docs/architecture.md' names, and why each one is there.
%%
%% - the decoder: a SIMD immediate can hold a memory argument and a GC
%%   instruction can hold a block type, so the opcode-space modules and the
%%   instruction decoder call each other. The format's own recursion.
%% - the tier: `wasm_core' reads `wasm_exec:load_spec/1' and `store_spec/1' at
%%   generation time, so the interpreted and generated paths cannot describe a
%%   load differently, and `wasm_exec' calls `wasm_jit:reentered/0' on the way
%%   back in. Two edges, one function each.
%% - the facade: `wasm_module_cache' calls `wasm:compile/2' on a miss.
documented_cycles() ->
    [[wasm, wasm_module_cache],
     [wasm_core, wasm_exec, wasm_jit],
     [wasm_decode, wasm_decode_atomic, wasm_decode_code, wasm_decode_gc,
      wasm_decode_simd]].

the_module_graph_has_the_three_documented_cycles(_) ->
    Cycles = lists:sort([lists:sort(C) || C <- cycles()]),
    ct:log("module cycles:~n~p", [Cycles]),
    ?assertEqual(lists:sort(documented_cycles()), Cycles).

%% Every module opens by saying what it is, which is what makes the graph
%% navigable at all: you find the layer from the diagram and the module from
%% its first line.
every_module_says_what_it_is(_) ->
    Missing = [M || M <- modules(),
                    case code:get_doc(M) of
                        {ok, {docs_v1, _, _, _, #{<<"en">> := D}, _, _}}
                          when is_binary(D), byte_size(D) > 0 -> false;
                        _ -> true
                    end],
    ?assertEqual([], Missing).

%%% ---------------------------------------------------------------- helpers ---

%% Derived from the beams rather than from the sources. A moduledoc naming
%% another module reads as `wasm_exec:call/3' and would be counted as an edge by
%% anything that greps; xref sees calls and nothing else.
cycles() ->
    {ok, S} = xref:start(?MODULE),
    try
        {ok, _} = xref:add_directory(S, ebin(), [{warnings, false}]),
        {ok, Calls} = xref:q(S, "XC"),
        {ok, Mods} = xref:q(S, "AM"),
        ct:log("xref over ~s: ~p modules, ~p calls",
               [ebin(), length(Mods), length(Calls)]),
        %% An analysis that found nothing would report no cycles and look like
        %% a clean graph. Refuse to answer at all rather than answer wrongly.
        ?assert(length(Mods) >= 40),
        Known = sets:from_list(Mods),
        G = digraph:new(),
        try
            _ = [digraph:add_vertex(G, M) || M <- Mods],
            _ = [digraph:add_edge(G, A, B)
                 || {{A, _, _}, {B, _, _}} <- Calls,
                    A =/= B, sets:is_element(B, Known)],
            [C || C <- digraph_utils:strong_components(G), length(C) > 1]
        after
            digraph:delete(G)
        end
    after
        xref:stop(S)
    end.

modules() ->
    [list_to_atom(filename:basename(F, ".beam"))
     || F <- filelib:wildcard(filename:join(ebin(), "*.beam"))].

%% The first directory on the code path that really holds `wasm.beam'.
%%
%% Not `code:which/1': `cover_enabled' is set for this project, and a
%% cover-compiled module answers a bare `"wasm.beam"' with no directory in it,
%% so `dirname' gives `"."' and the analysis silently reads nothing. Not
%% `code:lib_dir/2' either, which is deprecated. Common Test also runs with its
%% own log directory as the working directory, so anything relative has to be
%% checked against the filesystem rather than assumed.
%%
%% Reading the beams on disk is right even when the loaded ones are
%% instrumented: the call graph under test is the module's own, not cover's.
ebin() ->
    [Dir | _] = [D || D <- code:get_path(),
                      filelib:is_regular(filename:join(D, "wasm.beam"))],
    Dir.
