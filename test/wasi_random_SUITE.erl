-module(wasi_random_SUITE).
-moduledoc """
`random_get`, and what it does with a request bigger than one megabyte.

The interesting case is not a failure the guest can see. It is the one where
the call reports success and does nothing, because a program seeding a
generator from `random_get` has no way to notice.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasi.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([a_two_megabyte_request_fills_the_whole_buffer/1,
         a_request_past_the_end_of_memory_is_a_fault/1,
         a_seeded_source_does_not_repeat_itself_within_a_run/1,
         a_seeded_source_repeats_across_runs/1,
         the_seeded_stream_is_the_one_recorded/1,
         no_random_capability_is_reported_as_such/1]).

-define(MIB, 1048576).
-define(PAGES, 40).

all() ->
    [a_two_megabyte_request_fills_the_whole_buffer,
     a_request_past_the_end_of_memory_is_a_fault,
     a_seeded_source_does_not_repeat_itself_within_a_run,
     a_seeded_source_repeats_across_runs,
     the_seeded_stream_is_the_one_recorded,
     no_random_capability_is_reported_as_such].

source() -> ~"""
(module
  (import "wasi_snapshot_preview1" "random_get"
    (func $random_get (param i32 i32) (result i32)))
  (memory (export "memory") 40)
  (func (export "fill") (param $ptr i32) (param $len i32) (result i32)
    (call $random_get (local.get $ptr) (local.get $len))))
""".

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Parsed} = wasm_wat:module(source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    [{mod, Mod} | Config].

end_per_suite(_) -> ok.

instance(Config, Random) ->
    {ok, I} = wasm:instantiate(?config(mod, Config),
                               wasi_preview1:imports(#{random => Random})),
    I.

%%% ------------------------------------------------------------------ size ---

%% Over a megabyte, the source answered `crypto:strong_rand_bytes(0)`. Writing
%% the empty binary succeeds, so the guest was told `ESUCCESS` and handed back
%% the buffer it started with: zeroes on a fresh page. Nothing about that is
%% visible to a program that asks for entropy and gets a success.
a_two_megabyte_request_fills_the_whole_buffer(Config) ->
    I = instance(Config, strong),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fill", [0, 2 * ?MIB])),
    {ok, Bytes} = wasm:read_memory(I, 0, 2 * ?MIB),
    <<First:?MIB/binary, Second:?MIB/binary>> = Bytes,
    %% The second megabyte is the one that used to be missing, and it must be
    %% neither absent nor a copy of the first.
    ?assertNotEqual(First, Second),
    ?assertEqual([], all_zero_blocks(Bytes)),
    ok = wasm:destroy(I).

%% The whole range is checked before a byte is generated, so a request that
%% cannot land is refused rather than half-served.
a_request_past_the_end_of_memory_is_a_fault(Config) ->
    I = instance(Config, strong),
    Size = ?PAGES * 65536,
    ?assertEqual({ok, [?EFAULT]}, wasm:call(I, ~"fill", [0, Size + 1])),
    {ok, Untouched} = wasm:read_memory(I, 0, 65536),
    ?assertEqual(binary:copy(<<0>>, 65536), Untouched),
    %% Exactly filling the memory is not past the end.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fill", [0, Size])),
    ok = wasm:destroy(I).

%%% ---------------------------------------------------------------- seeded ---

%% Deterministic means reproducible across runs, not constant within one. The
%% generator was re-seeded on every call, so two `random_get` calls in one run
%% handed back byte-identical streams.
a_seeded_source_does_not_repeat_itself_within_a_run(Config) ->
    I = instance(Config, {seed, 7}),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fill", [0, 4096])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fill", [4096, 4096])),
    {ok, A} = wasm:read_memory(I, 0, 4096),
    {ok, B} = wasm:read_memory(I, 4096, 4096),
    ?assertNotEqual(A, B),
    %% And a piece of one large request is not a copy of the piece before it,
    %% which is the same defect at a different scale.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fill", [0, 3 * 65536])),
    {ok, C1} = wasm:read_memory(I, 0, 65536),
    {ok, C2} = wasm:read_memory(I, 65536, 65536),
    {ok, C3} = wasm:read_memory(I, 131072, 65536),
    ?assertNotEqual(C1, C2),
    ?assertNotEqual(C2, C3),
    ok = wasm:destroy(I).

%% The half of determinism that has to hold: same seed, same bytes.
a_seeded_source_repeats_across_runs(Config) ->
    ?assertEqual(seeded_prefix(Config, 11, 4096),
                 seeded_prefix(Config, 11, 4096)),
    ?assertNotEqual(seeded_prefix(Config, 11, 4096),
                    seeded_prefix(Config, 12, 4096)).

%% Recorded, so a change to the generator or to how the pieces are cut is a
%% test failure rather than a silent difference in somebody's reproducible run.
the_seeded_stream_is_the_one_recorded(Config) ->
    Digest = crypto:hash(sha256, seeded_prefix(Config, 42, 200000)),
    ?assertEqual(~"138ef1d7fae223182e8d49cb9524f94cd5101fc8a5e971814885f8abc81fa5f3",
                 binary:encode_hex(Digest, lowercase)).

no_random_capability_is_reported_as_such(Config) ->
    I = instance(Config, none),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"fill", [0, 16])),
    ok = wasm:destroy(I).

%%% --------------------------------------------------------------- helpers ---

seeded_prefix(Config, Seed, Len) ->
    I = instance(Config, {seed, Seed}),
    {ok, [?ESUCCESS]} = wasm:call(I, ~"fill", [0, Len]),
    {ok, Bytes} = wasm:read_memory(I, 0, Len),
    ok = wasm:destroy(I),
    Bytes.

%% A block of 4096 zero bytes in two megabytes of randomness is about as likely
%% as anything gets, so this is a whole-buffer check rather than a sample.
all_zero_blocks(Bytes) ->
    Zero = binary:copy(<<0>>, 4096),
    [Block || <<Block:4096/binary>> <= Bytes, Block =:= Zero].
