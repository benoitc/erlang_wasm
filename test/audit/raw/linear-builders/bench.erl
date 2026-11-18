-module(bench).
-export([run/0]).
%% One launch of one arm. Each workload prints the minimum of its rounds,
%% in microseconds. Run from the repository root.
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    Large = large(10_000),
    {ok, _} = wasm_wat:module(Large),
    out(wat_large, [tc(fun() -> {ok, _} = wasm_wat:module(Large) end)
                    || _ <- lists:seq(1, 3)]),
    Forms = corpus(),
    _ = [wasm_wat:module_form(F) || F <- Forms],
    out(wat_corpus, [tc(fun() -> [wasm_wat:module_form(F) || F <- Forms] end)
                     || _ <- lists:seq(1, 5)]),
    _ = growers(2),
    out(keeper_depth1, [batch(fun() -> growers(2) end, 200)
                        || _ <- lists:seq(1, 5)]),
    out(keeper_depth1000, [tc(fun() -> growers(1000) end)
                           || _ <- lists:seq(1, 3)]),
    Cap = wasm_worker_reaper:setting(#{}, max_cleanup_jobs),
    _ = jobs(Cap + 1),
    out(manager_depth1, [batch(fun() -> jobs(Cap + 1) end, 50)
                         || _ <- lists:seq(1, 5)]),
    out(manager_depth1000, [tc(fun() -> jobs(Cap + 1000) end)
                            || _ <- lists:seq(1, 3)]),
    ok.

out(Name, Times) -> io:format("~s ~.1f~n", [Name, float(lists:min(Times))]).

tc(F) -> element(1, timer:tc(F)).

batch(F, K) -> tc(fun() -> [F() || _ <- lists:seq(1, K)] end) / K.

%% Small exported functions, as a generator or a compiler would write them.
large(N) ->
    iolist_to_binary(
      ["(module\n",
       [io_lib:format("(func $f~b (export \"f~b\") (param i32) (result i32) "
                      "local.get 0 i32.const ~b i32.add)\n", [I, I, I])
        || I <- lists:seq(1, N)],
       ")"]).

%% Every `(module ...)' form of the .wast files the corpus case reads.
corpus() ->
    Skip = ["id.wast", "annotations.wast", "names.wast"],
    Files = [F || F <- filelib:wildcard("testsuite/*.wast"),
                  not lists:member(filename:basename(F), Skip)],
    [Form || F <- Files,
             {ok, Bin} <- [file:read_file(F)],
             Form <- wasm_wat_sexp:forms_of(Bin),
             is_module(Form)].

is_module({list, _, [{keyword, _, <<"module">>} | _]}) -> true;
is_module(_) -> false.

%% N processes grow one shared memory by a page each, at the same time.
growers(N) ->
    {ok, Mem} = wasm_memory:new({limits, 1, N + 1, true, i32}),
    Self = self(),
    Pids = [spawn(fun() -> {ok, _, _} = wasm_memory:grow(Mem, 1),
                           Self ! {grown, self()} end)
            || _ <- lists:seq(1, N)],
    [receive {grown, P} -> ok end || P <- Pids],
    ok = wasm_memory:free(Mem).

%% N local cleanup jobs whose action returns at once, from the first submit
%% to the last completion. Past the cap they wait in the manager's queue.
jobs(N) ->
    Self = self(),
    Tag = make_ref(),
    Done = fun() -> Self ! {done, Tag} end,
    [ok = wasm_cleanup_manager:start_local_cleanup(
            Id, #{id => Id, dir => "/nonexistent/cleanup",
                  adapter_state => undefined, actions => [Done]})
     || I <- lists:seq(1, N),
        Id <- [iolist_to_binary(io_lib:format("bench-~p-~b", [Tag, I]))]],
    [receive {done, Tag} -> ok end || _ <- lists:seq(1, N)],
    ok.
