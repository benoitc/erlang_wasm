-module(optbshare).
-moduledoc """
What K held instances cost the node and the OS, per instance.

`densitybench sharing` measures `erlang:memory/0`, which cannot see memory a
NIF maps outside the BEAM's allocators. This samples the VM's physical
footprint (`footprint -p`) and resident set (`ps -o rss=`) as well, so an arm
whose linear memory lives in mmap regions and one whose memory lives on
process heaps and in `atomics` are compared on the same numbers.

    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run optbshare main py 50 raw/sharing.terms

Arguments: the guest (`py`, `py_entry`, `qjs`, `lua`, `plain`), K, and the
raw file (`none` for none).

`page_limit` 65536. The image is read from `_build/imagecache` (captured
there by `reactorlib` on a tree's first run) and put in `persistent_term`;
one warm restore, request and destroy runs first. Every process is
collected, then `erlang:memory/0`, the charged pages and the OS samples are
taken; K processes each restore and serve the fixed request through
`reactorlib:request/2`, check the answer and hold the instance; once all K
have acknowledged, the same samples are taken again. Every `erlang:memory/0`
category and each OS number is reported as a difference over K. A holder
that fails or does not answer within 60 s makes the round `VOID`.
""".

-export([main/1]).

-define(CACHE, "_build/imagecache").
-define(PT, {?MODULE, image}).
-define(ACK_MS, 60_000).

main([G, K]) -> main([G, K, "none"]);
main([G, K, Raw]) ->
    R = try sharing(list_to_atom(G), list_to_integer(K))
        catch C:E:S -> #{verdict => void, why => {failed, C, E, S}}
        end,
    ok = reactorlib:write_raw(case Raw of "none" -> none; P -> P end, R),
    case R of
        #{verdict := void, why := Why} -> io:format("VOID: ~p~n", [Why]);
        _ -> ok
    end,
    io:format("~p~n", [maps:without([meta, before, held, memory_before,
                                     memory_held], R)]),
    erlang:halt(0).

os_sample() ->
    Pid = os:getpid(),
    FP = os:cmd("footprint -p " ++ Pid ++ " 2>/dev/null | head -2 | tail -1"),
    Rss = list_to_integer(string:trim(os:cmd("ps -o rss= -p " ++ Pid))),
    #{footprint_kb => fp_kb(FP), rss_kb => Rss}.

fp_kb(Line) ->
    case re:run(Line, "Footprint: ([0-9.]+) (KB|MB|GB|B)",
                [{capture, all_but_first, list}]) of
        {match, [N, U]} ->
            V = list_to_float(case lists:member($., N) of
                                  true -> N; false -> N ++ ".0" end),
            V * case U of "B" -> 1 / 1024; "KB" -> 1; "MB" -> 1024;
                          "GB" -> 1024 * 1024 end;
        _ -> exit({footprint_unparsed, Line})
    end.

sharing(Name, K) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    {ok, G} = reactorlib:guest(Name),
    {ok, Image} = reactorlib:image(G, ?CACHE),
    persistent_term:put(?PT, Image),
    {ok, _, W} = reactorlib:request(G, Image),
    ok = reactorlib:finish(W),
    [erlang:garbage_collect(P) || P <- processes()],
    timer:sleep(200),
    P0 = wasm_engine:pages_in_use(),
    M0 = erlang:memory(), O0 = os_sample(),
    Self = self(),
    Ps = [spawn_monitor(fun() -> holder(Self, G) end)
          || _ <- lists:seq(1, K)],
    Acks = acks([P || {P, _} <- Ps], ?ACK_MS),
    timer:sleep(200),
    M1 = erlang:memory(), O1 = os_sample(),
    P1 = wasm_engine:pages_in_use(),
    [P ! stop || {P, _} <- Ps],
    [receive {'DOWN', Mon, process, P, _} -> ok after ?ACK_MS -> ok end
     || {P, Mon} <- Ps],
    Base = #{guest => Name, k => K, meta => Meta,
             image_bytes => maps:get(bytes, wasm:snapshot_info(Image)),
             before => O0, held => O1, memory_before => M0,
             memory_held => M1, pages_before => P0, pages_held => P1,
             load_end => reactorlib:uptime_now()},
    case Acks of
        ok ->
            D = fun(Key) -> (maps:get(Key, O1) - maps:get(Key, O0)) / K end,
            Mem = maps:from_list(
                    [{Cat, (V1 - proplists:get_value(Cat, M0)) / K / 1024}
                     || {Cat, V1} <- M1]),
            Base#{verdict => ok,
                  footprint_delta_kb => D(footprint_kb),
                  rss_delta_kb => D(rss_kb),
                  erlang_total_delta_kb => maps:get(total, Mem),
                  erlang_delta_kb => Mem,
                  charged_pages_per_instance => (P1 - P0) / K};
        {void, Why} ->
            Base#{verdict => void, why => Why}
    end.

holder(Parent, G) ->
    Image = persistent_term:get(?PT),
    case reactorlib:request(G, Image) of
        {ok, R, Inst} ->
            case R =:= reactorlib:expected(G) of
                true -> Parent ! {held, self(), ok};
                false -> Parent ! {held, self(), {wrong, R}}
            end,
            receive stop -> reactorlib:finish(Inst) end;
        Other ->
            Parent ! {held, self(), {failed, Other}}
    end.

acks(Ps, Ms) ->
    Until = erlang:monotonic_time(millisecond) + Ms,
    acks(Ps, Until, []).

acks([], _Until, []) -> ok;
acks([], _Until, Bad) -> {void, {bad_results, Bad}};
acks([P | Rest], Until, Bad) ->
    Left = max(0, Until - erlang:monotonic_time(millisecond)),
    receive
        {held, P, ok} -> acks(Rest, Until, Bad);
        {held, P, Why} -> acks(Rest, Until, [Why | Bad])
    after Left -> {void, {timeout, length(Rest) + 1}}
    end.
