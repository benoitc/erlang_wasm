-module(loadprof).
%% Profiling: wasm:load_snapshot/2 taken apart into its steps, on either tree.
%% Each step is timed on its own, L samples per guest after one discarded
%% load, with a garbage collection of this process before each sample.
%%
%%   erl ... -run loadprof main Guests L Raw
-export([main/1]).

-define(CACHE, "_build/imagecache").

main([Arms, L, Raw]) ->
    try run(arms(Arms), list_to_integer(L), Raw)
    catch C:R:S -> io:format("failed: ~p~n~p~n", [{C, R}, S])
    end,
    erlang:halt(0).

arms("all") -> [py, qjs, lua, plain];
arms(S) -> [list_to_atom(A) || A <- string:lexemes(S, ",")].

run(Arms, L, Raw) ->
    ok = reactorlib:page_limit(65536),
    _ = code:ensure_loaded(wasm_snapshot),
    Cand = erlang:function_exported(wasm_snapshot, build, 2),
    Up = os:cmd("uptime") -- "\n",
    io:format("# ~s cand=~p~n", [Up, Cand]),
    Rs = [arm(A, L, Cand) || A <- Arms],
    R = #{tree => element(2, file:get_cwd()), cand => Cand, uptime => Up,
          arms => Rs},
    case Raw of
        "none" -> ok;
        _ -> ok = file:write_file(Raw, io_lib:format("~p.~n", [R]), [append])
    end,
    ok.

arm(Name, L, Cand) ->
    {ok, G} = reactorlib:guest(Name),
    {ok, Image0} = reactorlib:image(G, ?CACHE),
    ok = wasm:release(Image0),
    Path = reactorlib:image_path(G, ?CACHE),
    H = maps:get(module, G),
    {ok, S0} = reactorlib:load_image(G, Path),
    Digest = restored_digest(G, S0),
    ok = wasm:release(S0),
    Samples = [sample(G, Path, H, Cand) || _ <- lists:seq(1, L)],
    Keys = maps:keys(hd(Samples)),
    Stats = maps:from_list(
              [{K, #{min => lists:min(V), median => med(V)}}
               || K <- Keys, V <- [[maps:get(K, X) || X <- Samples]]]),
    Shape = shape(Path, H),
    io:format("~p ~p~n  shape ~p~n  digest ~s~n",
              [Name, maps:map(fun(_, #{median := M}) -> round(M) end, Stats),
               Shape, Digest]),
    #{guest => Name, stats => Stats, shape => Shape, digest => Digest,
      samples => Samples}.

med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).

t(F) ->
    true = erlang:garbage_collect(),
    T0 = erlang:monotonic_time(nanosecond),
    R = F(),
    {(erlang:monotonic_time(nanosecond) - T0) / 1000, R}.

sample(G, Path, H, Cand) ->
    {TRead, {ok, Bin}} = t(fun() -> file:read_file(Path) end),
    {TDec, {ok, Parts}} =
        t(fun() ->
                  {ok, Lim} = wasm_snapshot_file:limits(),
                  wasm_snapshot_file:decode(Bin, Lim)
          end),
    {TFrom, {ok, S}} =
        t(fun() ->
                  {ok, M} = wasm_module_cache:get(H),
                  wasm_snapshot:from_parts(Parts, H, M)
          end),
    Bytes = wasm_snapshot:bytes(S),
    Steps = case Cand of
                true -> cand_steps(S, H, Bytes);
                false -> base_steps(S, H, Bytes)
            end,
    {TTotal, {ok, S2}} = t(fun() -> reactorlib:load_image(G, Path) end),
    ok = wasm:release(S2),
    Steps#{read => TRead, decode => TDec, from_parts => TFrom,
           total => TTotal}.

%% Owner start with a build that does nothing (claim, image_reserve, spawn,
%% the snapshot copied in and back), image_reserve alone, and the build alone
%% in this process; then the build's page assembly with and without the
%% binary:copy, by a local copy of `wasm_snapshot:built_mem/1'.
cand_steps(S, H, Bytes) ->
    {TOwner, {ok, Owner, _}} =
        t(fun() -> wasm_snapshot_owner:start(H, Bytes, self(),
                                             fun(_Img) -> S end)
          end),
    ok = wasm_snapshot_owner:release(Owner, self()),
    Id = make_ref(),
    {TRes, {ok, Img}} = t(fun() -> wasm_keeper:image_reserve(Bytes, self(), Id)
                          end),
    ok = wasm_keeper:release(Img, {snapshot, Id}),
    {TBuild, _} = t(fun() -> wasm_snapshot:build(S, make_ref()) end),
    Ms = mems_of(S),
    {TCopy, _} = t(fun() -> [built_mem(M, copy) || M <- Ms] end),
    {TNoCopy, _} = t(fun() -> [built_mem(M, nocopy) || M <- Ms] end),
    {TByPage, _} = t(fun() -> [by_pages(M) || M <- Ms] end),
    #{owner_nobuild => TOwner, image_reserve => TRes, build => TBuild,
      local_build_copy => TCopy, local_build_nocopy => TNoCopy,
      local_by_page => TByPage}.

base_steps(S, H, Bytes) ->
    {TCharge, ok} = t(fun() -> wasm_snapshot_owner:charge(Bytes) end),
    {TOwner, {ok, Owner}} =
        t(fun() -> wasm_snapshot_owner:start(H, Bytes, self()) end),
    %% The release refunds the charge taken above.
    ok = wasm_snapshot_owner:release(Owner, self()),
    #{charge => TCharge, owner_start => TOwner}.

%% The snapshot record's `mems' field: the one list of maps with `pages'.
mems_of(S) ->
    [L] = [L || L <- tuple_to_list(S), is_list(L), L =/= [],
                lists:all(fun(X) -> is_map(X) andalso is_map_key(pages, X)
                          end, L)],
    L.

by_pages(#{runs := Runs}) ->
    lists:foldl(fun({Off, Bin}, Acc) -> by_page(Off, Bin, Acc) end, #{}, Runs).

built_mem(#{pages := Pages, runs := Runs}, Mode) ->
    ByPage = lists:foldl(fun({Off, Bin}, Acc) -> by_page(Off, Bin, Acc) end,
                         #{}, Runs),
    list_to_tuple([page(maps:get(P, ByPage, []), Mode)
                   || P <- lists:seq(0, Pages - 1)]).

by_page(_Off, <<>>, Acc) -> Acc;
by_page(Off, Bin, Acc) ->
    P = Off div 65536,
    In = min(byte_size(Bin), (P + 1) * 65536 - Off),
    <<Here:In/binary, Rest/binary>> = Bin,
    by_page(Off + In, Rest,
            Acc#{P => [{Off rem 65536, Here} | maps:get(P, Acc, [])]}).

page([], _Mode) -> zero;
page(Pieces, Mode) ->
    {End, Parts} = lists:foldl(fun({Off, Bin}, {At, Acc}) ->
                                       {Off + byte_size(Bin),
                                        [Bin, <<0:((Off - At) * 8)>> | Acc]}
                               end, {0, []}, lists:reverse(Pieces)),
    B = iolist_to_binary(lists:reverse([<<0:((65536 - End) * 8)>> | Parts])),
    Page = case Mode of copy -> binary:copy(B); nocopy -> B end,
    case Page of
        <<0:(65536 * 8)>> -> zero;
        _ -> Page
    end.

%% Pages, non-zero pages, pages one run covers whole, runs, run bytes.
shape(Path, H) ->
    {ok, Bin} = file:read_file(Path),
    {ok, Lim} = wasm_snapshot_file:limits(),
    {ok, Parts} = wasm_snapshot_file:decode(Bin, Lim),
    {ok, M} = wasm_module_cache:get(H),
    {ok, S} = wasm_snapshot:from_parts(Parts, H, M),
    [begin
         BP = by_pages(Mem),
         Whole = length([P || {P, [{0, B}]} <- maps:to_list(BP),
                              byte_size(B) =:= 65536]),
         #{pages => maps:get(pages, Mem), touched_pages => map_size(BP),
           whole_run_pages => Whole, runs => length(maps:get(runs, Mem)),
           run_bytes => lists:sum([byte_size(B)
                                   || {_, B} <- maps:get(runs, Mem)]),
           file_bytes => byte_size(Bin)}
     end || Mem <- mems_of(S)].

%% sha256 of every memory's bytes in an instance restored from the image.
restored_digest(G, S) ->
    {Bindings, Opts} = reactorlib:restore_args(G),
    {ok, I} = wasm:restore(S, Bindings, Opts),
    Len = wasm_snapshot:logical_bytes(S),
    {ok, Bytes} = wasm:read_memory(I, 0, Len),
    ok = wasm:destroy(I),
    binary:encode_hex(crypto:hash(sha256, Bytes)).
