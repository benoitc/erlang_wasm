%% @doc Tail calls: the properties the specification fixtures cannot show here.
%%
%% The `return_call' and `return_call_indirect' suites have one executable
%% module each, and both use typed function references, so every one of their
%% 95 execution assertions is skipped until that proposal lands. Their
%% `assert_invalid' cases do run and do pass; what is left unproven by the
%% fixtures is that tail calls *work*, and in particular that they are space
%% safe, which is the entire reason the proposal exists.
-module(wasm_tailcall_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).
-define(I64, 16#7E).
-define(FUNCREF, 16#70).

all() ->
    [self_tail_recursion_runs_in_constant_space,
     mutual_tail_recursion_runs_in_constant_space,
     indirect_tail_call_is_space_safe,
     a_plain_call_still_exhausts_the_depth_limit,
     tail_call_results_must_match_the_caller].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------------ rule ---

%% A tail call reuses the current frame, so recursion depth stays at one.
%%
%% `max_depth' defaults to 1024, and this recurses a million times. If the
%% implementation pushed a frame it would fail with `call_stack_exhausted'
%% after the first thousand, which is exactly the check that makes this test
%% meaningful rather than merely slow.
self_tail_recursion_runs_in_constant_space(_Config) ->
    {ok, Inst} = instantiate(sum_module(return_call)),
    ?assertMatch({ok, [500000500000]}, wasm:call(Inst, ~"sum", [1000000, 0])),
    ok = wasm:destroy(Inst).

%% Two functions calling each other, so the frame being reused is not always
%% the same function's. This is the case a naive "self tail call becomes a
%% loop" optimisation gets wrong.
mutual_tail_recursion_runs_in_constant_space(_Config) ->
    {ok, Inst} = instantiate(ping_pong_module()),
    ?assertMatch({ok, [0]}, wasm:call(Inst, ~"ping", [1000000])),
    ok = wasm:destroy(Inst).

%% `return_call_indirect' resolves through a table at run time and must be just
%% as space safe.
indirect_tail_call_is_space_safe(_Config) ->
    {ok, Inst} = instantiate(sum_module(return_call_indirect)),
    ?assertMatch({ok, [500000500000]}, wasm:call(Inst, ~"sum", [1000000, 0])),
    ok = wasm:destroy(Inst).

%% The same program with a plain `call' must still hit the depth limit, which
%% is what proves the previous cases are measuring tail calls rather than a
%% depth limit that never applied.
a_plain_call_still_exhausts_the_depth_limit(_Config) ->
    {ok, Inst} = instantiate(sum_module(call)),
    ?assertMatch({error, #{class := exhaustion, kind := call_stack_exhausted}},
                 wasm:call(Inst, ~"sum", [1000000, 0])),
    %% The instance survives the exhaustion and stays usable, as it must after
    %% any aborted invocation.
    ?assertMatch({ok, [6]}, wasm:call(Inst, ~"sum", [3, 0])),
    ok = wasm:destroy(Inst).

%% A tail call's results become the *caller's* results without passing through
%% it, so the callee's result types must equal the enclosing function's. A
%% plain call in the same position would be valid.
tail_call_results_must_match_the_caller(_Config) ->
    ?assertMatch({error, #{class := invalid, kind := type_mismatch,
                           ctx := #{reason := tail_call_results}}},
                 wasm:load(mismatched_module())).

%%% --------------------------------------------------------- module builder ---

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

%% ```
%% (func $sum (param $n i64) (param $acc i64) (result i64)
%%   (if (result i64) (i64.eqz (local.get $n))
%%     (then (local.get $acc))
%%     (else (return_call $sum (i64.sub (local.get $n) (i64.const 1))
%%                             (i64.add (local.get $acc) (local.get $n))))))
%% ```
%%
%% Built three ways so the same program can be run with a tail call, an
%% indirect tail call, and a plain call.
sum_module(Kind) ->
    Recurse = case Kind of
                  return_call -> <<16#12, 0>>;              % return_call 0
                  call -> <<16#10, 0, 16#0F>>;              % call 0, return
                  return_call_indirect ->
                      %% Push the table index, then dispatch through type 0.
                      <<16#41, 0, 16#13, 0, 0>>             % i32.const 0
              end,
    Body = <<16#20, 0,                       % local.get $n
             16#50,                          % i64.eqz
             16#04, ?I64,                    % if (result i64)
               16#20, 1,                     %   local.get $acc
             16#05,                          % else
               16#20, 0, 16#42, 1, 16#7D,    %   n - 1
               16#20, 1, 16#20, 0, 16#7C,    %   acc + n
               Recurse/binary,
             16#0B,                          % end if
             16#0B>>,                        % end func
    Sections =
        [wasm_asm:type_section([{[?I64, ?I64], [?I64]}]),
         wasm_asm:func_section([0]),
         wasm_asm:export_section([{~"sum", 0, 0}]),
         wasm_asm:code_section([Body])],
    %% The indirect form needs a table holding the function it calls back into.
    wasm_asm:module(
      case Kind of
          return_call_indirect ->
              insert_table(Sections, [{?FUNCREF, 1, 1}], [{0, [0]}]);
          _ -> Sections
      end).

%% ```
%% (func $ping (param i64) (result i64)
%%   (if (result i64) (i64.eqz (local.get 0))
%%     (then (i64.const 0))
%%     (else (return_call $pong (i64.sub (local.get 0) (i64.const 1))))))
%% (func $pong (param i64) (result i64) ... (return_call $ping ...))
%% ```
ping_pong_module() ->
    Body = fun(Other) ->
                   <<16#20, 0,
                     16#50,
                     16#04, ?I64,
                       16#42, 0,
                     16#05,
                       16#20, 0, 16#42, 1, 16#7D,
                       16#12, Other,
                     16#0B,
                     16#0B>>
           end,
    wasm_asm:module(
      [wasm_asm:type_section([{[?I64], [?I64]}]),
       wasm_asm:func_section([0, 0]),
       wasm_asm:export_section([{~"ping", 0, 0}]),
       wasm_asm:code_section([Body(1), Body(0)])]).

%% A function returning i32 whose tail call returns i64.
mismatched_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], [?I32]}, {[], [?I64]}]),
       wasm_asm:func_section([0, 1]),
       wasm_asm:code_section([<<16#12, 1, 16#0B>>,       % return_call 1
                              <<16#42, 0, 16#0B>>])]).   % i64.const 0

%% Sections must appear in id order, so the table and element sections go in at
%% the right points rather than being appended.
insert_table([Types, Funcs | Rest], Tables, Elems) ->
    [Types, Funcs, wasm_asm:table_section(Tables)] ++
        insert_elem(Rest, Elems).

insert_elem([Exports | Rest], Elems) ->
    [Exports, wasm_asm:elem_section(Elems) | Rest].
