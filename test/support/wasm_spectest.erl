%% @doc The `spectest' module the specification test suite imports.
%%
%% Many suites (`imports', `linking', `global', `table', `elem') import a
%% standard host module the suite itself never defines. Without it those
%% modules cannot even instantiate, and the several hundred assertions that
%% follow are reported as cascading failures rather than as the one missing
%% dependency they actually are.
%%
%% The values are fixed by the suite: the integer globals are 666 and the
%% float ones 666.6.
-module(wasm_spectest).

-include_lib("wasm/include/wasm.hrl").

-export([imports/0]).

-spec imports() -> map().
imports() ->
    #{{<<"spectest">>, <<"print">>}         => fun print/2,
      {<<"spectest">>, <<"print_i32">>}     => fun print/2,
      {<<"spectest">>, <<"print_i64">>}     => fun print/2,
      {<<"spectest">>, <<"print_f32">>}     => fun print/2,
      {<<"spectest">>, <<"print_f64">>}     => fun print/2,
      {<<"spectest">>, <<"print_i32_f32">>} => fun print/2,
      {<<"spectest">>, <<"print_f64_f64">>} => fun print/2,
      {<<"spectest">>, <<"global_i32">>}    => 666,
      {<<"spectest">>, <<"global_i64">>}    => 666,
      {<<"spectest">>, <<"global_f32">>}    => 666.6,
      {<<"spectest">>, <<"global_f64">>}    => 666.6,
      {<<"spectest">>, <<"table">>}         =>
          wasm_table:new(#tabletype{limits = #limits{min = 10, max = 20},
                                    elemtype = ?FUNCREF}, null),
      {<<"spectest">>, <<"table64">>}       =>
          wasm_table:new(#tabletype{limits = #limits{min = 10, max = 20,
                                                    index_type = i64},
                                    elemtype = ?FUNCREF}, null),
      {<<"spectest">>, <<"memory">>}        => spectest_memory(),
      {<<"spectest">>, <<"shared_memory">>} => spectest_shared_memory()}.

%% Results are discarded by the suite; only the side effect matters, and even
%% that is only observable as "did not trap".
print(_Ctx, _Args) -> {ok, []}.

spectest_memory() ->
    {ok, Mem} = wasm_memory:new(1, 2),
    Mem.

%% The threads suite imports this to check that a shared memory links only
%% against a shared import, and the non-shared one above to check the reverse.
spectest_shared_memory() ->
    {ok, Mem} = wasm_memory:new(#limits{min = 1, max = 2, shared = true}),
    Mem.
