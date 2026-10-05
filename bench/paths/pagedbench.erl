-module(pagedbench).
-moduledoc """
The memory kernels of `storebench` and `gap sieve`, over a plain memory and
over a restored one.

Use it to hold a change to how restored memory is read and written against
the memory kernel gate. `plain` instantiates the kernel; `paged` instantiates
it snapshotable, runs it once so its memory has content, captures it with
`wasm:snapshot/2`, destroys it and restores it, so the timed memory is a
restored one. On a build with images the harness asserts the restored memory
has an image region (`img_bytes`, from `wasm_memory:field_indices/0`); on a
build without one it reports `no_image` and the arm is the restored memory.

    erlc -o bench/paths -I include -pa _build/default/lib/wasm/ebin \\
        bench/paths/benchlib.erl bench/paths/pagedbench.erl
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run pagedbench main store paged compiled

Kernels: `store` (the `storebench` loop, ns per store) and `sieve` (the
`gap` sieve of 1000000, ns per unit). Modes: `plain`, `paged`. Tiers:
`interp`, `compiled`. The compiled tier is forced on and every timed call
must enter generated code. Setup and timing run in one fresh process: one
untimed call, then seven timed ones, minimum reported.

The kernels are the `storebench` and `gap` text, encoded once with
`wasm-tools parse` into `paged_store.wasm` and `paged_sieve.wasm` beside this
file, and loaded with `wasm:load/1` in both modes: a capture needs a module
built through the module cache, which a `{wat, _}` compile is not.
""".
-export([main/1]).

-include("wasm_exec.hrl").

-define(COMPILED, #{compile => true, compile_after => 1, compile_force => true,
                    compile_sync => true, fuel => infinity}).


main([Kernel, Mode, Tier]) ->
    {ok, _} = application:ensure_all_started(wasm),
    Load = string:trim(os:cmd("uptime | sed 's/.*averages*: //'")),
    R = try run(list_to_atom(Kernel), list_to_atom(Mode), list_to_atom(Tier))
        catch C:E:S -> io_lib:format("failed ~p ~p", [{C, E}, S])
        end,
    io:format("~s\t~s\t~s\t~s\tload=~s~n", [Kernel, Mode, Tier, R, Load]),
    halt().

%% `{File, Export, Args, Units}', units being what the time is divided by.
kernel(store, interp) -> {"store", ~"run", [200_000], 400_000};
kernel(store, compiled) -> {"store", ~"run", [2_000_000], 4_000_000};
kernel(sieve, _) -> {"sieve", ~"sieve", [1_000_000], 1_000_000}.

opts(interp) -> #{fuel => infinity};
opts(compiled) -> ?COMPILED.

run(Kernel, Mode, Tier) ->
    {File, Name, Args, Units} = kernel(Kernel, Tier),
    {ok, Bytes} = file:read_file("bench/paths/paged_" ++ File ++ ".wasm"),
    {Us, Image, V} =
        benchlib:in_process(
          fun() ->
                  {ok, M} = wasm:load(Bytes),
                  I = instance(Mode, M, Name, Args, opts(Tier)),
                  Img = image_bytes(I),
                  Mode =:= paged andalso Img =:= 0 andalso
                      erlang:error(paged_memory_has_no_image),
                  ok = warm(Tier, I, Name, Args),
                  F = timed(Tier, I, Name, Args),
                  _ = F(),
                  Rs = [timer:tc(F) || _ <- lists:seq(1, 7)],
                  {lists:min([T || {T, _} <- Rs]), Img,
                   element(2, hd(Rs))}
          end),
    io_lib:format("~.3f ns/unit\tmin_us=~p units=~p img_bytes=~p result=~p",
                  [Us * 1000 / Units, Us, Units, Image, V]).

instance(plain, M, _Name, _Args, Opts) ->
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    I;
instance(paged, M, Name, Args, Opts) ->
    {ok, I0} = wasm:instantiate(M, #{}, #{snapshotable => true,
                                          fuel => infinity}),
    {ok, _} = wasm:call(I0, Name, populate(Args)),
    {ok, S} = wasm:snapshot(I0, #{}),
    ok = wasm:destroy(I0),
    {ok, I} = wasm:restore(S, #{}, Opts),
    I.

%% Enough of the kernel to give every page it touches content.
populate([N]) -> [min(N, 1_000_000)].

%% `img_bytes' where the build has it, `no_image' where it does not.
image_bytes(I) ->
    case maps:get(img_bytes, wasm_memory:field_indices(), undefined) of
        undefined ->
            no_image;
        Ix ->
            Mut = wasm_instance:mut(I),
            {Mem} = Mut#mut.mems,
            element(Ix, Mem)
    end.

warm(interp, I, Name, Args) ->
    {ok, _} = wasm:call(I, Name, Args, opts(interp)),
    ok;
warm(compiled, I, Name, Args) ->
    spin(I, Name, Args, 200).

spin(_I, _Name, _Args, 0) -> erlang:error(never_entered);
spin(I, Name, Args, K) ->
    E0 = entered(),
    {ok, _} = wasm:call(I, Name, Args, ?COMPILED),
    case entered() > E0 of
        true -> ok;
        false -> timer:sleep(20), spin(I, Name, Args, K - 1)
    end.

timed(interp, I, Name, Args) ->
    fun() -> {ok, V} = wasm:call(I, Name, Args, opts(interp)), V end;
timed(compiled, I, Name, Args) ->
    fun() ->
            E0 = entered(),
            {ok, V} = wasm:call(I, Name, Args, ?COMPILED),
            true = entered() > E0,
            V
    end.

entered() -> maps:get(entered, wasm_jit:counts()).
