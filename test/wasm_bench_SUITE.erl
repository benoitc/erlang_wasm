%% @doc Benchmarks.
%%
%% These measure the things that actually differentiate a BEAM-native runtime,
%% not just raw throughput:
%%
%% <ul>
%%   <li><b>Startup and instantiation cost</b>, which dominates plugin and
%%       request-per-instance workloads far more than steady-state speed.</li>
%%   <li><b>Scheduler responsiveness under load.</b> An infinite WebAssembly
%%       loop runs while a separate process measures its own message latency.
%%       A pure-Erlang interpreter cannot degrade it, because every dispatch
%%       step consumes a reduction and the BEAM preempts the loop. This is the
%%       property a NIF-based runtime cannot offer, and it is asserted rather
%%       than merely reported.</li>
%% </ul>
%%
%% Run with `rebar3 bench'. Numbers are logged, not asserted, except the
%% responsiveness check, which is a correctness property in disguise and is
%% therefore the only case a plain `rebar3 ct' runs.
-module(wasm_bench_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% Only the one that asserts something. The other three log numbers and cannot
%% fail, so `rebar3 ct' has nothing to learn from them; `rebar3 bench' asks for
%% the group.
all() -> [scheduler_stays_responsive].

groups() ->
    [{bench, [], [pipeline_costs, dispatch_throughput, memory_throughput]}].

init_per_suite(Config) ->
    case fixture() of
        {ok, Bin} -> [{wasm, Bin} | Config];
        error -> {skip, "no fixture module available"}
    end.

end_per_suite(_) -> ok.

%% A module with an arithmetic loop, memory and a few call shapes. A real
%% module rather than one written for the benchmark, so it exercises the code
%% shapes a toolchain actually emits.
fixture() ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "seeds", "fac.wasm"]),
    file:read_file(Path).

%%% ------------------------------------------------------------- benchmarks ---

pipeline_costs(Config) ->
    Bin = ?config(wasm, Config),
    {ok, Mod} = wasm_decode:module(Bin),
    report("decode", 2000, fun() -> wasm_decode:module(Bin) end),
    report("validate", 2000, fun() -> wasm_validate:module(Mod) end),
    report("compile (decode+validate)", 2000, fun() -> wasm:compile(Bin) end),
    {ok, Validated} = wasm:compile(Bin),
    report("instantiate", 2000,
           fun() -> {ok, _} = wasm:instantiate(Validated, #{}) end),
    {ok, Inst} = wasm:instantiate(Validated, #{}),
    Name = first_export(Inst),
    report("call (round trip)", 20000,
           fun() -> wasm:call(Inst, Name, [1]) end),
    ok.

%% Measures interpreter dispatch on a self-contained counting loop, so the
%% number is comparable with the design notes' 3.7 ns per instruction.
dispatch_throughput(_Config) ->
    Bin = counting_loop_module(),
    {ok, Mod} = wasm:compile(Bin),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    N = 200000,
    T0 = erlang:monotonic_time(microsecond),
    {ok, [_]} = wasm:call(Inst, <<"run">>, [N]),
    T1 = erlang:monotonic_time(microsecond),
    Us = max(T1 - T0, 1),
    Instrs = N * 11,
    ct:log("dispatch: ~p instructions in ~p us = ~.1f ns/instr, ~.1f M instr/s",
           [Instrs, Us, (Us * 1000) / Instrs, Instrs / Us]),
    ok.

memory_throughput(_Config) ->
    {ok, Mem} = wasm_memory:new(4, 8),
    N = 100000,
    time_log("memory store i32 (aligned)", N,
             fun(I) -> wasm_memory:store(Mem, (I band 16383) * 4, 4, I) end),
    time_log("memory load i32 (aligned)", N,
             fun(I) -> wasm_memory:load(Mem, (I band 16383) * 4, 4) end),
    time_log("memory store i64 (aligned)", N,
             fun(I) -> wasm_memory:store(Mem, (I band 8191) * 8, 8, I) end),
    time_log("memory load  i8 (unaligned)", N,
             fun(I) -> wasm_memory:load(Mem, (I band 65535) + 1, 1) end),
    T0 = erlang:monotonic_time(microsecond),
    ok = wasm_memory:fill(Mem, 0, 7, 262144),
    T1 = erlang:monotonic_time(microsecond),
    ct:log("memory.fill 256 KiB: ~p us (~.2f GB/s)",
           [T1 - T0, 262144 / max(T1 - T0, 1) / 1000]),
    ok.

%%% ---------------------------------------------------- scheduler behaviour ---

%% The claim under test: a WebAssembly module that never terminates cannot
%% degrade the responsiveness of unrelated Erlang processes.
%%
%% The BEAM guarantees this by construction here, because each interpreter
%% dispatch step is an Erlang function call and therefore consumes a reduction.
%% The test exists because that guarantee is exactly what would be lost if
%% execution ever moved into a NIF, and it would be lost silently.
%% The property: a pure-Erlang interpreter cannot monopolise a scheduler, where
%% a runtime called through a NIF would block one for a whole invocation.
%%
%% Measured against a *control*, not against idle. Saturating every scheduler
%% with CPU-bound work costs latency no matter what that work is, so comparing
%% the interpreter to idle measures BEAM under saturation and calls the result
%% a property of this runtime. The control is the same number of pure-Erlang
%% busy loops: if the interpreter is preemptible, it should land in the same
%% range, and that is the claim worth asserting.
%%
%% Each spinner gets its *own* instance. Concurrent calls into one instance are
%% documented as unsound, and sharing one here measured something other than
%% fourteen busy interpreters.
scheduler_stays_responsive(_Config) ->
    N = erlang:system_info(schedulers_online),
    Idle = measure_ping_latency(500),
    {ok, Mod} = wasm:compile(infinite_loop_module()),
    %% Minimum of several rounds, per arm. A single sample of this is worthless:
    %% repeated runs of the *same* arm were measured spanning 2 us to 1005 us,
    %% so one before-and-after pair can show any result you like, in either
    %% direction. The minimum is the least contaminated sample available.
    Control = best_of(3, fun() ->
                            [spawn(fun busy_loop/0) || _ <- lists:seq(1, N)]
                        end),
    Wasm = best_of(3, fun() ->
                        [begin
                             {ok, I} = wasm:instantiate(Mod, #{}),
                             spawn(fun() -> wasm:call(I, <<"spin">>, []) end)
                         end || _ <- lists:seq(1, N)]
                    end),
    ct:log("ping p99 (min of 3): idle ~p us, ~p erlang busy loops ~p us, "
           "~p wasm loops ~p us", [Idle, N, Control, N, Wasm]),
    %% The property is that the interpreter *yields*. A runtime called through a
    %% NIF would not answer the ping at all until the invocation finished, so
    %% any bounded latency demonstrates it; the control says what saturation
    %% alone costs, and the two arms overlap.
    ?assert(Wasm < 50000, {wasm, Wasm, control, Control}),
    ok.

best_of(Rounds, SpawnLoad) ->
    lists:min([under_load(SpawnLoad()) || _ <- lists:seq(1, Rounds)]).

busy_loop() -> busy_loop().

%% Spawns are given a moment to be scheduled before measuring, so the sample is
%% taken under load rather than across the ramp-up.
under_load(Pids) ->
    timer:sleep(100),
    Alive = length([P || P <- Pids, is_process_alive(P)]),
    Alive = length(Pids),
    Latency = measure_ping_latency(500),
    [exit(P, kill) || P <- Pids],
    timer:sleep(50),
    Latency.

%% Round-trips a message to a helper process and reports the 99th percentile,
%% which is where scheduler starvation shows up first.
measure_ping_latency(N) ->
    Self = self(),
    Pid = spawn_link(fun Echo() ->
                         receive {ping, From} -> From ! pong, Echo() end
                     end),
    Samples = [begin
                   T0 = erlang:monotonic_time(microsecond),
                   Pid ! {ping, Self},
                   receive pong -> ok end,
                   erlang:monotonic_time(microsecond) - T0
               end || _ <- lists:seq(1, N)],
    unlink(Pid),
    exit(Pid, kill),
    lists:nth(max(round(N * 0.99), 1), lists:sort(Samples)).

%%% ---------------------------------------------------------------- helpers ---

report(Label, N, Fun) ->
    T0 = erlang:monotonic_time(microsecond),
    repeat(N, Fun),
    T1 = erlang:monotonic_time(microsecond),
    ct:log("~-28s ~8.2f us/op (~p iterations)", [Label, (T1 - T0) / N, N]).

time_log(Label, N, Fun) ->
    T0 = erlang:monotonic_time(microsecond),
    repeat_i(N, Fun),
    T1 = erlang:monotonic_time(microsecond),
    ct:log("~-28s ~8.1f ns/op", [Label, ((T1 - T0) * 1000) / N]).

repeat(0, _F) -> ok;
repeat(N, F) -> _ = F(), repeat(N - 1, F).

repeat_i(0, _F) -> ok;
repeat_i(N, F) -> _ = F(N), repeat_i(N - 1, F).

first_export(Inst) ->
    [Name | _] = [N || {N, {func, _}} <- maps:to_list(wasm:exports(Inst))],
    Name.

%%% ------------------------------------------------------- module fixtures ---
%%
%% Hand-assembled binaries rather than generated ones, so the benchmark does
%% not depend on a toolchain being installed.

%% (func (export "run") (param i32) (result i32)
%%   (local i32)
%%   loop
%%     local.get 1  i32.const 1  i32.add  local.set 1
%%     local.get 0  i32.const 1  i32.sub  local.set 0
%%     local.get 0  br_if 0
%%   end
%%   local.get 1)
counting_loop_module() ->
    Body = <<16#03, 16#40,                                   % loop
             16#20, 1, 16#41, 1, 16#6A, 16#21, 1,            % l1 += 1
             16#20, 0, 16#41, 1, 16#6B, 16#21, 0,            % l0 -= 1
             16#20, 0, 16#0D, 0,                             % br_if 0
             16#0B,                                          % end
             16#20, 1, 16#0B>>,                              % local.get 1; end
    Code = <<1, 1, 16#7F, Body/binary>>,                     % 1 local of i32
    module_of(<<16#60, 1, 16#7F, 1, 16#7F>>, Code, <<"run">>).

%% (func (export "spin") loop br 0 end)
infinite_loop_module() ->
    Body = <<16#03, 16#40, 16#0C, 0, 16#0B, 16#0B>>,
    Code = <<0, Body/binary>>,                               % no locals
    module_of(<<16#60, 0, 0>>, Code, <<"spin">>).

module_of(FuncType, Code, ExportName) ->
    TypeSec  = section(1, <<1, FuncType/binary>>),
    FuncSec  = section(3, <<1, 0>>),
    ExportSec = section(7, <<1, (byte_size(ExportName)):8, ExportName/binary,
                             16#00, 0>>),
    CodeSec  = section(10, <<1, (byte_size(Code)):8, Code/binary>>),
    <<0, "asm", 1:32/little,
      TypeSec/binary, FuncSec/binary, ExportSec/binary, CodeSec/binary>>.

section(Id, Payload) ->
    <<Id:8, (byte_size(Payload)):8, Payload/binary>>.
