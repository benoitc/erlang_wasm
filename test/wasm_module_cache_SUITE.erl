-module(wasm_module_cache_SUITE).
-moduledoc """
The module cache under concurrency, and what happens to a claim nobody drops.

Every case here comes from a defect found by measuring rather than by reading:
the cache used to block the whole node for 24 seconds inside a `handle_call`,
`load/1` used to exit rather than return a value when that timed out, a process
that loaded and died kept its module resident for the life of the node, and two
callers racing to load the same bytes ended up sharing one claim between them.

They are cheap and they are about behaviour under concurrency, which is exactly
what a single-caller test cannot see.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").

all() ->
    [a_dead_holder_gives_its_claim_back,
     concurrent_loads_of_one_module_each_keep_a_claim,
     a_large_load_does_not_block_the_server,
     load_returns_a_value_when_the_server_is_gone,
     release_from_a_non_holder_does_not_evict,
     a_failed_compile_answers_everybody_waiting,
     a_restart_leaves_nothing_published,
     a_waiter_that_dies_before_the_compile_lands_leaves_no_claim,
     a_waiter_that_gave_up_leaves_no_claim,
     a_holder_that_dies_after_the_compile_lands_leaves_no_claim,
     two_loads_of_the_same_bytes_share_an_identity,
     a_module_without_bytes_still_has_an_identity].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Small} = file:read_file(filename:join(
                                   [wasm_spec_runner:fixtures_dir(), "seeds", "fac.wasm"])),
    [{small, Small} | Config].

end_per_suite(_) -> ok.

%% Distinct bytes per case, so cases cannot inherit each other's residency.
%% A custom section carries the difference: the decoder skips it, so the module
%% still validates and only its hash changes.
unique(Bin) ->
    Name = integer_to_binary(erlang:unique_integer([positive])),
    Payload = <<(byte_size(Name)), Name/binary>>,
    <<Bin/binary, 0, (byte_size(Payload)), Payload/binary>>.

holders(Bin) ->
    Hash = crypto:hash(sha256, Bin),
    case maps:find(Hash, element(2, sys:get_state(wasm_module_cache))) of
        {ok, #{holders := N}} -> N;
        error -> absent
    end.

%%% ----------------------------------------------------------------- cases ---

%% Nothing monitored the loader, so a worker that loaded a module and then
%% crashed kept it resident forever. Twenty-one of them left twenty-one claims
%% on a module nobody held, and the resident cap filled with the dead.
a_dead_holder_gives_its_claim_back(Config) ->
    Bin = unique(?config(small, Config)),
    [begin
         {P, M} = spawn_monitor(fun() -> {ok, _} = wasm:load(Bin) end),
         receive {'DOWN', M, process, P, _} -> ok after 5000 -> ct:fail(no_down) end
     end || _ <- lists:seq(1, 21)],
    wait_until(fun() -> holders(Bin) =:= absent end, 5000),
    ?assertEqual(absent, holders(Bin)),
    ?assertEqual({error, not_loaded},
                 wasm_module_cache:get({wasm_module, crypto:hash(sha256, Bin)})).

%% Both callers asked for the module, so both must keep a handle that works.
%% The cache used to let them both compile it and then write `holders => 1',
%% discarding one claim; the first `unload/1' then erased the module under the
%% other one.
concurrent_loads_of_one_module_each_keep_a_claim(Config) ->
    Bin = unique(?config(small, Config)),
    Self = self(),
    Ps = [element(1, spawn_monitor(
                       fun() ->
                               Self ! {self(), catch_load(Bin)},
                               receive done -> ok end
                       end)) || _ <- [1, 2]],
    Rs = [receive {P, R} -> R after 30000 -> ct:fail(slow) end || P <- Ps],
    ?assertEqual([ok, ok], Rs),
    ?assertEqual(2, holders(Bin)),
    %% One of them drops out; the other's handle still works.
    [First, Second] = Ps,
    First ! done,
    wait_until(fun() -> holders(Bin) =:= 1 end, 5000),
    ?assertMatch({ok, _}, wasm_module_cache:get({wasm_module, crypto:hash(sha256, Bin)})),
    Second ! done.

%% `erts_debug:size/1' on a compiled 1.8 MB module measured 24 seconds, and it
%% ran inside `handle_call', so every other loader waited behind it. The
%% expensive work belongs to the loading process.
a_large_load_does_not_block_the_server(Config) ->
    Bin = unique(?config(small, Config)),
    Self = self(),
    Loader = spawn(fun() ->
                           {ok, _} = wasm:load(Bin),
                           Self ! loaded,
                           receive done -> ok end
                   end),
    Worst = poll_worst(300, 0),
    receive loaded -> ok after 30000 -> ct:fail(slow) end,
    Loader ! done,
    %% Generous by three orders of magnitude against the 24 s it used to be,
    %% so this cannot go red because the machine is busy.
    ?assert(Worst < 1000000, {worst_latency_us, Worst}).

poll_worst(0, Worst) -> Worst;
poll_worst(N, Worst) ->
    {T, _} = timer:tc(fun() -> wasm_module_cache:resident() end),
    timer:sleep(1),
    poll_worst(N - 1, erlang:max(T, Worst)).

%% Every failure in this library is a value, including this one. It used to be
%% an `exit' from `gen_server:call/3', which a supervised loader could not
%% report as anything better than a crash.
load_returns_a_value_when_the_server_is_gone(Config) ->
    Bin = unique(?config(small, Config)),
    Pid = whereis(wasm_module_cache),
    Ref = erlang:monitor(process, Pid),
    true = exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ct:fail(no_down) end,
    Result = catch_load(Bin),
    %% The supervisor restarts it, so this races: either the server was still
    %% missing and we get a value describing that, or it was back and the load
    %% succeeded. Both are values, which is the property under test.
    case Result of
        ok -> ok;
        {error, #{class := link, kind := K}} ->
            ?assert(lists:member(K, [cache_unavailable, cache_timeout]), K);
        Other ->
            ct:fail({not_a_value, Other})
    end,
    wait_until(fun() -> is_pid(whereis(wasm_module_cache)) end, 5000).

%% A claim belongs to the process that took it. Releasing one you never took
%% must not take somebody else's away.
release_from_a_non_holder_does_not_evict(Config) ->
    Bin = unique(?config(small, Config)),
    {ok, Handle} = wasm:load(Bin),
    ?assertEqual(1, holders(Bin)),
    {P, M} = spawn_monitor(fun() -> ok = wasm:unload(Handle) end),
    receive {'DOWN', M, process, P, _} -> ok after 5000 -> ct:fail(no_down) end,
    ?assertEqual(1, holders(Bin)),
    ?assertMatch({ok, _}, wasm_module_cache:get(Handle)),
    ok = wasm:unload(Handle),
    wait_until(fun() -> holders(Bin) =:= absent end, 5000).

%% A second caller waits for the first to finish compiling instead of
%% compiling the same bytes again. If the compile fails, waiting must not mean
%% waiting forever.
a_failed_compile_answers_everybody_waiting(_Config) ->
    Bad = <<0, 97, 115, 109, 1, 0, 0, 0, 99, 99, 99, 99>>,
    Self = self(),
    _ = [spawn(fun() -> Self ! {self(), catch_load(Bad)} end) || _ <- [1, 2]],
    Rs = [receive {_, R} -> R after 30000 -> ct:fail(slow) end || _ <- [1, 2]],
    [?assertMatch({error, #{class := _}}, R) || R <- Rs].

%%% ---------------------------------------------------------------- helpers ---

catch_load(Bin) ->
    try wasm:load(Bin) of
        {ok, _} -> ok;
        Other -> Other
    catch
        Class:Reason -> {raised, Class, Reason}
    end.

wait_until(F, Timeout) when Timeout =< 0 -> F() orelse ct:fail(timeout);
wait_until(F, Timeout) ->
    case F() of
        true -> ok;
        false -> timer:sleep(50), wait_until(F, Timeout - 50)
    end.

%% The cache's state is a map of what is resident and it starts empty, but the
%% modules themselves live in `persistent_term', which is node-wide and
%% outlives the process. After a restart every module ever loaded was still
%% published with nothing tracking it: an old handle still worked, no claim was
%% counted against it, and no eviction would ever reach it. Modules are
%% megabytes each, so a restart loop held the node's memory for good while the
%% cache believed it held nothing.
a_restart_leaves_nothing_published(Config) ->
    Bin = unique(?config(small, Config)),
    {ok, Handle} = wasm:load(Bin),
    ?assertMatch({ok, _}, wasm_module_cache:get(Handle)),
    Before = published(),
    ?assert(Before >= 1),

    Pid = whereis(wasm_module_cache),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_for_restart(Pid, 2000),

    ?assertEqual(0, published()),
    %% The handle names a module the node no longer has, which is a value
    %% callers already deal with rather than a stale success.
    ?assertEqual({error, not_loaded}, wasm_module_cache:get(Handle)),
    ?assertMatch({error, #{kind := module_not_loaded}},
                 wasm:instantiate(Handle, #{})),
    %% And loading it again works, which a cache still holding the old entry
    %% would have made a no-op with no claim behind it.
    ?assertMatch({ok, _}, wasm:load(Bin)).

published() ->
    length([K || {{wasm_module, _} = K, _} <- persistent_term:get()]).

wait_for_restart(_Old, 0) -> ct:fail(no_restart);
wait_for_restart(Old, Ms) ->
    case whereis(wasm_module_cache) of
        undefined -> timer:sleep(20), wait_for_restart(Old, Ms - 20);
        Old -> timer:sleep(20), wait_for_restart(Old, Ms - 20);
        _New -> ok
    end.

%% Three points at which a caller can vanish, and the module has to end up
%% held by exactly the ones still there to hold it. The third, dying after the
%% claim was granted, is `a_dead_holder_gives_its_claim_back` above; these are
%% the two before it.

%% Dying while waiting for somebody else's compile. Its `DOWN` is handled
%% before the compile finishes, so granting it a claim afterwards puts back one
%% that nothing will ever remove and the module stays resident for the life of
%% the node.
%%
%% The window needs a compile long enough to die inside, which is what the
%% 1.8 MB QuickJS build is for: 300 ms rather than the 1 ms the small fixture
%% takes. With the small one the waiter cannot get in at all and the case
%% passes against a cache that has the defect.
a_waiter_that_dies_before_the_compile_lands_leaves_no_claim(Config) ->
    Bin = unique(big_module(Config)),
    Hash = crypto:hash(sha256, Bin),
    Self = self(),
    Compiler = spawn(fun() -> {ok, _} = wasm:load(Bin), Self ! loaded,
                              receive never -> ok end end),
    %% Once somebody is compiling these bytes, anybody else asking waits.
    wait_until(fun() -> compiling(Hash) end, 5000),
    Waiter = spawn(fun() -> _ = wasm:load(Bin), Self ! waited end),
    wait_until(fun() -> waiting_on(Hash) >= 1 end, 5000),

    Ref = monitor(process, Waiter),
    exit(Waiter, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,

    receive loaded -> ok after 30000 -> ct:fail(no_load) end,
    timer:sleep(200),
    %% One holder, the compiler. A claim for the dead waiter would make it two,
    %% and nothing would ever take it back.
    ?assertEqual(1, holders(Bin)),
    exit(Compiler, kill),
    wait_until(fun() -> holders(Bin) =:= absent end, 5000).

%% Dying is not the only way to stop waiting. `wasm_module_cache:load/1` has a
%% thirty-second deadline, and a caller that reaches it is very much alive: it
%% got an error, has no handle, and will never call `unload/1`. The claim
%% `stored` made for it was therefore permanent, and the module stayed resident
%% for the life of the node.
%%
%% Driven through the message the timeout path now sends rather than by waiting
%% out thirty seconds, and the two orders that message can arrive in are the
%% two this asserts: before the compile lands, and after it.
a_waiter_that_gave_up_leaves_no_claim(Config) ->
    Bin = unique(big_module(Config)),
    Hash = crypto:hash(sha256, Bin),
    Self = self(),
    Compiler = spawn(fun() -> {ok, _} = wasm:load(Bin), Self ! loaded,
                              receive never -> ok end end),
    wait_until(fun() -> compiling(Hash) end, 5000),

    %% `send_request/2` puts this process in the server's waiting list exactly
    %% as a call does, and then lets the test decide when it gives up. Shortening
    %% a real deadline instead made the case a race against how long the compile
    %% takes, which is a different number every run.
    Waiter = spawn(fun() ->
                       _Req = gen_server:send_request(wasm_module_cache,
                                                      {acquire, Hash}),
                       Self ! registered,
                       receive give_up -> ok end,
                       %% What `wasm_module_cache:call/1` now does on a timeout.
                       %% The result is deliberately not matched: a server that
                       %% does not know this message must leave the waiter
                       %% *alive*, or the case passes against the defect for the
                       %% wrong reason, a dead waiter being skipped.
                       _ = try gen_server:call(wasm_module_cache,
                                               {gave_up, Hash})
                           catch exit:_ -> ignored
                           end,
                       Self ! {waiter, gave_up},
                       receive never -> ok end
                   end),
    receive registered -> ok after 5000 -> ct:fail(never_registered) end,
    wait_until(fun() -> waiting_on(Hash) >= 1 end, 5000),
    Waiter ! give_up,
    receive {waiter, gave_up} -> ok
    after 5000 -> ct:fail(never_gave_up)
    end,

    receive loaded -> ok after 60000 -> ct:fail(no_load) end,
    timer:sleep(200),
    %% One holder, the compiler. The waiter is alive and has no handle, so a
    %% claim for it is one nothing will ever take back and the module would stay
    %% resident for the life of the node.
    ?assertEqual(1, holders(Bin)),
    exit(Waiter, kill),
    exit(Compiler, kill),
    wait_until(fun() -> holders(Bin) =:= absent end, 5000).

big_module(_Config) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "lang", "qjs.wasm"]),
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, _} -> ct:fail({no_qjs_fixture, Path})
    end.

%% Straight off the server's state: whether these bytes are being compiled, and
%% how many callers are parked behind that compile.
compiling(Hash) ->
    maps:is_key(Hash, element(3, sys:get_state(wasm_module_cache))).

waiting_on(Hash) ->
    case maps:find(Hash, element(3, sys:get_state(wasm_module_cache))) of
        {ok, {_Compiler, Waiting}} -> length(Waiting);
        error -> 0
    end.

%% Dying between the compile landing and the claim being counted. Same rule,
%% reached from the other side.
a_holder_that_dies_after_the_compile_lands_leaves_no_claim(Config) ->
    Bin = unique(?config(small, Config)),
    Self = self(),
    Loader = spawn(fun() -> {ok, _} = wasm:load(Bin), Self ! done,
                            receive never -> ok end end),
    receive done -> ok after 20000 -> ct:fail(no_load) end,
    ?assertEqual(1, holders(Bin)),
    Ref = monitor(process, Loader),
    exit(Loader, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> holders(Bin) =:= 0 orelse holders(Bin) =:= absent end,
               3000).

two_loads_of_the_same_bytes_share_an_identity(Config) ->
    %% Identity is what anything caching work derived from a module keys on, so
    %% two loads of the same bytes have to agree and two different modules must
    %% never agree. The cache hands its content hash down rather than letting
    %% the module take a fresh reference, which is the only reason the first
    %% holds.
    Bin = unique(?config(small, Config)),
    {ok, H1} = wasm:load(Bin),
    {ok, H2} = wasm:load(Bin),
    {ok, M1} = wasm_module_cache:get(H1),
    {ok, M2} = wasm_module_cache:get(H2),
    ?assertMatch({sha256, _}, M1#module.identity),
    ?assertEqual(M1#module.identity, M2#module.identity),

    %% An instance carries it, which is how a call finds the compiled code for
    %% the module it is running.
    {ok, I} = wasm:instantiate(M1, #{}),
    ?assertEqual(M1#module.identity, wasm_instance:identity(I)),
    ?assertEqual(undefined, wasm_instance:code_slot(I)),
    ?assertEqual(true, wasm_instance:set_code_slot(I, 3)),
    ?assertEqual(3, wasm_instance:code_slot(I)),
    %% Only the first setter wins: two processes may reach a hot call together
    %% and only one should take the instance lease.
    ?assertEqual(false, wasm_instance:set_code_slot(I, 4)),
    ok = wasm:destroy(I),
    ok = wasm:unload(H1), ok = wasm:unload(H2).

%% A module built without bytes still gets an identity, and a different one
%% every time, which is correct: it simply does not share.
a_module_without_bytes_still_has_an_identity(_Config) ->
    Wat = ~"(module (func (export \"f\") (result i32) (i32.const 1)))",
    {ok, P} = wasm_wat:module(Wat),
    {ok, A} = wasm_validate:module(P),
    {ok, B} = wasm_validate:module(P),
    ?assert(is_reference(A#module.identity)),
    ?assertNotEqual(A#module.identity, B#module.identity).
