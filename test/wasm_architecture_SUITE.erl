%% @doc The shape of the module graph, held to what `docs/architecture.md' says.
%%
%% That page draws the runtime as eleven layers with three cycles in it, and a
%% drawing nobody checks stops being true. This recomputes the graph from the
%% compiled modules and fails when it has changed.
%%
%% The point is not that cycles are forbidden. All three of these are
%% deliberate and each is defensible in one sentence; what is forbidden is a
%% *fourth* one appearing without anybody deciding it should. A cycle is the
%% one structural property a reader cannot discover locally: every other
%% question about a module can be answered by reading that module, and this one
%% can only be answered by reading all sixty-eight.
-module(wasm_architecture_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [the_module_graph_has_the_three_documented_cycles,
     every_module_says_what_it_is,
     the_layer_diagram_names_every_module,
     every_function_a_moduledoc_names_exists].

%% The three components `docs/architecture.md' names, and why each one is there.
%%
%% - the decoder: a SIMD immediate can hold a memory argument and a GC
%%   instruction can hold a block type, so the opcode-space modules and the
%%   instruction decoder call each other. The format's own recursion.
%% - the tier: `wasm_core' reads `wasm_exec:load_spec/1' and `store_spec/1' at
%%   generation time, so the interpreted and generated paths cannot describe a
%%   load differently, and `wasm_exec' calls `wasm_jit:reentered/0' on the way
%%   back in. Two edges, one function each.
%% - the facade: `wasm_module_cache' calls `wasm:compile/2' on a miss, and
%%   `wasm_snapshot_owner' holds an image's claim on its module, which means
%%   calling the cache. A claim is given back by the process holding it, so
%%   anything long-lived enough to hold one is in this cycle; what is chosen is
%%   which module, and `wasm_snapshot' itself stays out.
documented_cycles() ->
    [[wasm, wasm_module_cache, wasm_snapshot_owner],
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

%% A doc that points at a function that is not there is worse than no pointer:
%% it sends a reader looking for code that was renamed or never existed, and
%% nothing tells them the doc is wrong rather than their grep.
%%
%% Three had rotted when this was written. `wasm_num' pointed at `wasm_num_f32'
%% and `wasm_num_f64', a split that was considered and rejected; two modules
%% pointed at `wasm_ir', which has never existed; and a navigation table added
%% in the same commit as this case invented `wasm_instance:run_start/2',
%% `wasm_validate_code:validate/4' and three `wasi_fs' functions.
%%
%% Only same-module `` `f/2` `` references are checked, and only against
%% exports and local functions of that module. A qualified `` `m:f/2` `` is
%% somebody else's business and is left to xref.
every_function_a_moduledoc_names_exists(_) ->
    Bad = lists:append([missing_refs(M) || M <- modules()]),
    ?assertEqual([], Bad).

missing_refs(M) ->
    case code:get_doc(M) of
        {ok, {docs_v1, _, _, _, #{<<"en">> := D}, _, _}} ->
            Have = local_names(M),
            [{M, R} || {F, A} = R <- refs(binary_to_list(D)),
                       not lists:member(R, Have),
                       not erl_internal:bif(F, A)];
        _ ->
            []
    end.

%% `` `name/2` `` inside backticks, with no module in front of it. The regexp
%% takes the backtick as the left boundary, which is what excludes `m:f/2'.
refs(Doc) ->
    case re:run(Doc, "`([a-z_][a-zA-Z_0-9]*)/([0-9]+)`",
                [global, {capture, all_but_first, list}]) of
        {match, Ms} -> lists:usort([{list_to_atom(N), list_to_integer(A)}
                                    || [N, A] <- Ms]);
        nomatch     -> []
    end.

%% Exports plus locals: a doc may point at a private function, and often should
%% -- `run/3' and `do_call/4' are the two most important functions in
%% `wasm_exec' and neither is exported.
local_names(M) ->
    M:module_info(exports) ++ beam_locals(M).

%% From `ebin()' and not `code:which/1': `cover_enabled' is set for this
%% project and a cover-compiled module answers a bare `"m.beam"' with no
%% directory, which reads nothing and would make every local look missing. It
%% did, on the first run of this case.
beam_locals(M) ->
    Path = filename:join(ebin(), atom_to_list(M) ++ ".beam"),
    case beam_lib:chunks(Path, [locals]) of
        {ok, {_, [{locals, L}]}} -> L;
        _                        -> []
    end.

%% The layer diagram is the only map of this runtime, and a map missing a
%% subsystem is worse than no map: a reader who cannot find `wasm_snapshot' in
%% it concludes the runtime has no snapshots rather than that the page is
%% stale. Seven modules went missing that way -- the four snapshot ones,
%% `wasm_file_cache', `wasm_store' and `wasm_subsup' -- because the cycles
%% below were kept current by hand and the diagram above them was not.
%%
%% Parsed out of the page rather than duplicated here. A copy of the list in
%% this file would be a second thing to forget.
the_layer_diagram_names_every_module(_) ->
    Drawn = drawn_modules(),
    Built = lists:sort(modules()),
    ?assertEqual([], Built -- Drawn, "modules missing from the diagram"),
    ?assertEqual([], Drawn -- Built, "diagram names something that is gone").

%% The first fenced block on the page, which is the `L8'..`L0' listing. Taken
%% by position and then checked, so a page that stops holding one fails here
%% rather than passing with an empty set: `[] -- []' is `[]' and an empty
%% diagram would agree with anything.
drawn_modules() ->
    Body = architecture_page(),
    [Fence | _] = [B || B <- fences(Body), string:find(B, "L8") =/= nomatch],
    Names = lists:sort([list_to_atom(W) || W <- string:lexemes(Fence, " \n"),
                                           is_module_name(W)]),
    ?assert(length(Names) > 40),
    Names.

%% Everything between an opening fence and its closing one: split on the fence
%% and keep every other piece, starting with the one after the first.
fences(Body) ->
    case string:split(Body, "```", all) of
        [_ | Rest] -> inside(Rest);
        _          -> []
    end.

inside([])           -> [];
inside([In])         -> [In];
inside([In, _ | Tl]) -> [In | inside(Tl)].

is_module_name("L" ++ _) -> false;
is_module_name(W) ->
    (lists:prefix("wasm", W) orelse lists:prefix("wasi", W))
        andalso lists:member(list_to_atom(W), modules()).

architecture_page() ->
    Path = filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                          "docs", "architecture.md"]),
    case file:read_file(Path) of
        {ok, B} -> binary_to_list(B);
        {error, _} ->
            {ok, B2} = file:read_file("docs/architecture.md"),
            binary_to_list(B2)
    end.

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
