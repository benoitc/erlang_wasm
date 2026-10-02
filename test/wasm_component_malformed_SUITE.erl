-module(wasm_component_malformed_SUITE).
-moduledoc """
Malformed component binaries are values, never crashes.

The runtime's contract is that hostile or corrupt input cannot destabilise the caller: a
component that does not decode, does not link, or is truncated comes back as `{error, _}`.
This fuzzes a real component - every truncation, a swept single-byte corruption, an
oversized section, and non-component inputs - and asserts each returns a value and never
raises. The specific named errors (unknown alias, bad discriminant, and so on) are checked
in `wasm_component_link_SUITE` and `wasm_component_vectors_SUITE`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [not_a_component_is_named,
     every_truncation_is_a_value,
     single_byte_corruption_is_a_value,
     an_oversized_section_is_a_value].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    %% A real, self-contained component (no host imports) to corrupt.
    {ok, Bin} = file:read_file(fixture_path("echo")),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% Non-component inputs are named, not crashes.
not_a_component_is_named(_Config) ->
    ?assertEqual({error, not_wasm}, decode(<<"not wasm at all">>)),
    ?assertEqual({error, not_wasm}, decode(<<>>)),
    %% A core module (starts with the core preamble) is not a component.
    ?assertEqual({error, not_a_component},
                 decode(<<16#00, 16#61, 16#73, 16#6d, 16#01, 16#00, 16#00, 16#00>>)).

%% Every prefix of a valid component instantiates to a value (an error for all but the
%% whole thing), never a raise: decode and the graph parsers signal by throwing and the
%% boundary captures.
every_truncation_is_a_value(Config) ->
    Bin = ?config(component, Config),
    lists:foreach(
      fun(N) -> assert_value(binary:part(Bin, 0, N)) end,
      lists:seq(0, byte_size(Bin))).

%% Flipping any single byte yields a value, never a raise. Sweep every offset.
single_byte_corruption_is_a_value(Config) ->
    Bin = ?config(component, Config),
    lists:foreach(
      fun(N) ->
          <<Pre:N/binary, B, Post/binary>> = Bin,
          assert_value(<<Pre/binary, (B bxor 16#FF), Post/binary>>)
      end,
      lists:seq(0, byte_size(Bin) - 1)).

%% A section whose declared size runs past the end of the stream is an error, not a crash.
an_oversized_section_is_a_value(_Config) ->
    %% Component preamble, then section id 1 with a huge LEB size and no content.
    Bin = <<16#00, 16#61, 16#73, 16#6d, 16#0d, 16#00, 16#01, 16#00,
            16#01, 16#FF, 16#FF, 16#FF, 16#FF, 16#0F>>,
    assert_value(Bin).

%% The result is `{ok, _}` or `{error, _}` and nothing was raised. `loader => compile`
%% builds any core inline rather than through the rate-limited node cache, so sweeping
%% hundreds of inputs does not trip the load rate.
assert_value(Bin) ->
    Result = try wasm_component:instantiate(Bin, #{}, #{loader => compile})
             catch Class:Reason -> {raised, Class, Reason}
             end,
    case Result of
        {ok, Inst} -> wasm_component:destroy(Inst);
        {error, _} -> ok;
        Other      -> ct:fail({raised_or_bad_shape, Other, byte_size(Bin)})
    end.

decode(Bin) ->
    wasm_component:decode(Bin).

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", Name ++ ".component.wasm"]).
