%% @doc Real compiler output.
%%
%% Everything else in the test tree is either specification fixtures or
%% hand-assembled binaries. This suite runs a module produced by `clang -O2',
%% which exercises the shapes a real toolchain actually emits: a shadow stack
%% in linear memory, a function table for indirect calls, optimised loops, and
%% sign-extension and wrapping patterns that hand-written tests tend not to
%% produce.
%%
%% Rebuild with `scripts/build-native-fixture.sh'; the artefact is committed so
%% this runs without a wasm toolchain installed.
-module(wasm_native_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [arithmetic, recursion, loops, linear_memory, floats, indirect_calls,
          i64_arithmetic].

init_per_suite(Config) ->
    %% Locate the fixture by walking up, since Common Test, `rebar3 shell' and
    %% a plain `erl' all start in different directories.
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "native",
                          "real.wasm"]),
    case file:read_file(Path) of
        {error, _} -> {skip, "native fixture missing"};
        {ok, Bin} ->
            {ok, Mod} = wasm:compile(Bin),
            [{mod, Mod} | Config]
    end.

end_per_suite(_) -> ok.

%% A bare instance is scoped to the process that created it, and Common Test
%% runs `init_per_suite' in a different process from the test cases, so each
%% case makes its own. Sharing one means owning it in a process.
init_per_testcase(_Case, Config) ->
    {ok, I} = wasm:instantiate(?config(mod, Config), #{}),
    [{inst, I} | Config].

end_per_testcase(_Case, _Config) -> ok.

call(Config, Name, Args) -> wasm:call(?config(inst, Config), Name, Args).

arithmetic(C) ->
    ?assertEqual({ok, [7]}, call(C, <<"add">>, [3, 4])),
    ?assertEqual({ok, [-1]}, call(C, <<"add">>, [2147483647, 2147483648 - 4294967296])).

recursion(C) ->
    ?assertEqual({ok, [0]}, call(C, <<"fib">>, [0])),
    ?assertEqual({ok, [1]}, call(C, <<"fib">>, [1])),
    ?assertEqual({ok, [46368]}, call(C, <<"fib">>, [24])).

%% The result wraps: clang emits a plain 32-bit accumulator, so the runtime's
%% i32 wrapping has to match exactly.
loops(C) ->
    ?assertEqual({ok, [704982704]}, call(C, <<"sum_to">>, [100000])),
    ?assertEqual({ok, [0]}, call(C, <<"sum_to">>, [0])).

%% Writes then reads a static buffer, exercising the data segment, the shadow
%% stack and byte-granularity stores.
linear_memory(C) ->
    ?assertEqual({ok, [522240]}, call(C, <<"memops">>, [4096])),
    ?assertEqual({ok, [0]}, call(C, <<"memops">>, [0])).

floats(C) ->
    {ok, [V]} = call(C, <<"fmix">>, [1.0, 10]),
    ?assert(abs(V - 2.9289682539682538) < 1.0e-12).

indirect_calls(C) ->
    ?assertEqual({ok, [13]}, call(C, <<"indirect">>, [0, 6, 7])),
    ?assertEqual({ok, [42]}, call(C, <<"indirect">>, [1, 6, 7])).

i64_arithmetic(C) ->
    ?assertEqual({ok, [57879]}, call(C, <<"i64ops">>, [123, 456])),
    %% `(a * b) ^ (a >> 3) ^ (b << 5)' with a = -1: -2 xor -1 is 1, xor 64 is
    %% 65. The sign is the point -- the shift is arithmetic and the operands
    %% are two's complement -- so the answer is worth naming rather than
    %% checking that it is an integer.
    ?assertEqual({ok, [65]}, call(C, <<"i64ops">>, [-1, 2])).
