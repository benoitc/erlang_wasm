-module(guestarm).
-moduledoc """
One start-up of a real language runtime, measured on the process that runs it.

This is the arm the allocation work is judged by. It runs a guest that reads one
JSON object from stdin and writes one back, which is a start-up plus one
request, and reports what that cost the process doing it.

    erlc -o bench/paths bench/paths/allocwords.erl bench/paths/guestarm.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run guestarm main <guest.wasm> <script-dir> compile|load [workers]

Everything it prints is per process, from that process's own collection trace,
via `allocwords`. `erlang:statistics(garbage_collection)` is node-wide and gets
this question wrong.

Two things it always prints, because both have been read as results when they
were not: whether the module went in **inline or as a handle**, so an arm that
did not take its branch is visible, and the **reply**, so a guest that never
reached its script cannot report a time.

Worker positions are reported separately. The first wasm run in a fresh
emulator costs about 2.4x the second on identical work, so a number without its
position is not a number. One `erl` invocation is one emulator: to interleave,
run this repeatedly rather than raising `workers`.
""".

-export([main/1]).

%% Escaped quotes, so plain binaries rather than a `~"..."' sigil.
-define(REQUEST, <<"{\"name\": \"ada\"}\n">>).
-define(EXPECT, <<"{\"name\": \"ADA\"}">>).

main([Guest, Dir, Mode]) -> main([Guest, Dir, Mode, "2"]);
main([Guest, Dir, Mode, Workers]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Guest),
    io:format("~s | ~w bytes | sha256 ~s~n",
              [filename:basename(Guest), byte_size(Bin),
               binary:encode_hex(crypto:hash(sha256, Bin), lowercase)]),
    io:format("load average ~s~n", [loadavg()]),
    {ok, Mod} = case Mode of
                    "load" -> wasm:load(Bin);
                    "compile" -> wasm:compile(Bin)
                end,
    io:format("module went in ~s~n",
              [case Mod of {wasm_module, _} -> "as a handle"; _ -> "inline" end]),
    io:format("~n~-8s ~10s ~14s ~12s ~9s ~9s ~10s~n",
              ["worker", "wall ms", "allocated", "reclaimed", "colls",
               "live end", "reply"]),
    [report(W, run(Mod, Dir)) || W <- lists:seq(1, list_to_integer(Workers))],
    init:stop().

report(W, #{wall := Wall, allocated := A, reclaimed := R, collections := C,
            live_after := L, result := Reply}) ->
    io:format("~-8w ~10w ~14w ~12w ~9w ~9w   ~s~n",
              [W, Wall, A, R, C, L, ok_or(Reply)]).

%% The reply, or what came instead. An arm that prints anything but `ok' here
%% measured a guest that did not do the work.
ok_or(?EXPECT) -> "ok";
ok_or(Other) -> io_lib:format("WRONG ~p", [Other]).

%% The whole guest runs inside the measured process: `allocwords' traces the
%% process it spawns, so the instance has to live there too. The stdin fun
%% answers once and then reports end of file, which is what lets `_start'
%% return without a second process driving it.
run(Mod, Dir) ->
    T0 = erlang:monotonic_time(millisecond),
    M = allocwords:measure(
          fun() ->
              Wasi = #{args => [~"python", ~"-u", ~"/app/worker.py"],
                       dirs => [{~"/app", Dir, read}],
                       stdin => fun(_) -> once(?REQUEST) end,
                       stdout => fun(D) -> line(D) end,
                       stderr => fun(_) -> ok end},
              {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi),
                                         #{max_memory_pages => 4096}),
              _ = wasm:call(I, ~"_start", []),
              ok = wasm:destroy(I),
              get(line)
          end),
    M#{wall => erlang:monotonic_time(millisecond) - T0}.

once(Data) ->
    case get(sent) of
        undefined -> put(sent, true), {ok, Data};
        true -> eof
    end.

line(Data) ->
    B = <<(case get(buf) of undefined -> <<>>; X -> X end)/binary,
          (iolist_to_binary(Data))/binary>>,
    case binary:split(B, ~"\n") of
        [L, Rest] -> put(line, L), put(buf, Rest);
        [_] -> put(buf, B)
    end,
    ok.

loadavg() ->
    case os:cmd("uptime") of
        [] -> "unknown";
        S -> string:trim(lists:last(string:split(S, "average", trailing)))
    end.
