%% @doc The two worked examples, run as written.
%%
%% `examples/plugin_worker' and `examples/script_worker' are the two ways to use
%% this library: compile the logic ahead of time, or ship an interpreter and
%% send logic as text. Both are documented with commands, and a documented
%% command that nobody runs is a documented command that stops working.
%%
%% What each case checks is the part that makes the logic *untrusted* rather
%% than merely separate: a runaway is killed, and nothing survives a request.
-module(wasm_examples_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_plugin_normalises_a_record,
     a_plugin_refuses_what_it_does_not_accept,
     a_runaway_plugin_is_killed,
     a_script_is_evaluated,
     a_runaway_script_is_killed,
     scripts_cannot_see_each_other].

init_per_suite(Config) ->
    %% `examples/' is not in the application, so the examples are compiled here
    %% rather than assumed to be loaded. That also proves they still compile.
    Dir = filename:join(?config(priv_dir, Config), "examples"),
    ok = filelib:ensure_path(Dir),
    [{ok, _} = compile:file(source(M), [{outdir, Dir}, return_errors])
     || M <- [plugin_worker, script_worker]],
    true = code:add_patha(Dir),
    Config.

end_per_suite(_) -> ok.

source(Module) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "examples", atom_to_list(Module) ++ ".erl"]).

fixture(Parts) ->
    filename:join([wasm_spec_runner:fixtures_dir() | Parts]).

%%% ----------------------------------------------------------- the plugin ---

plugin(Config) -> plugin(Config, #{}).

plugin(_Config, Opts) ->
    Path = fixture(["plugin", "plugin.wasm"]),
    case filelib:is_regular(Path) of
        false -> {skip, "no plugin fixture: run scripts/build-plugin-fixture.sh"};
        true -> {ok, W} = plugin_worker:start_link(Path, Opts), W
    end.

a_plugin_normalises_a_record(Config) ->
    case plugin(Config) of
        {skip, _} = S -> S;
        W ->
            ?assertEqual({ok, ~"user@example.com"},
                         plugin_worker:normalise(W, ~"  User@Example.COM  ")),
            ok = plugin_worker:stop(W)
    end.

a_plugin_refuses_what_it_does_not_accept(Config) ->
    case plugin(Config) of
        {skip, _} = S -> S;
        W ->
            [?assertEqual({error, invalid}, plugin_worker:normalise(W, R))
             || R <- [~"nonsense", ~"@example.com", ~"user@localhost", ~""]],
            ok = plugin_worker:stop(W)
    end.

%% The property that makes it untrusted. `wasm:call/3' runs in the calling
%% process and cannot be interrupted, so without the process boundary this
%% would hang the worker and everything waiting on it.
a_runaway_plugin_is_killed(Config) ->
    case plugin(Config, #{timeout => 300}) of
        {skip, _} = S -> S;
        W ->
            Before = erlang:monotonic_time(millisecond),
            ?assertEqual({error, timeout}, plugin_worker:hang(W)),
            Waited = erlang:monotonic_time(millisecond) - Before,
            ?assert(Waited < 5000),
            %% And the worker is still usable afterwards, which is the point of
            %% killing the instance's process rather than the worker's.
            ?assertEqual({ok, ~"a@b.co"}, plugin_worker:normalise(W, ~"A@B.CO")),
            ok = plugin_worker:stop(W)
    end.

%%% ----------------------------------------------------------- the script ---

script(Config) -> script(Config, #{}).

script(Config, Opts) ->
    Path = fixture(["lang", "qjs.wasm"]),
    case filelib:is_regular(Path) of
        false ->
            {skip, "no QuickJS build: run scripts/fetch-qjs-fixture.sh"};
        true ->
            {ok, W} = script_worker:start_link(
                        Path, Opts#{scratch => ?config(priv_dir, Config)}),
            W
    end.

a_script_is_evaluated(Config) ->
    case script(Config) of
        {skip, _} = S -> S;
        W ->
            ?assertEqual({ok, ~"3\n"}, script_worker:eval(W, ~"print(1 + 2);")),
            ?assertEqual({ok, ~"6\n"},
                         script_worker:eval(W, ~"print([1,2,3].reduce((a,b)=>a+b));")),
            ok = script_worker:stop(W)
    end.

a_runaway_script_is_killed(Config) ->
    case script(Config, #{timeout => 2000}) of
        {skip, _} = S -> S;
        W ->
            ?assertEqual({error, timeout}, script_worker:eval(W, ~"for(;;){}")),
            %% Still usable, same as the plugin.
            ?assertEqual({ok, ~"1\n"}, script_worker:eval(W, ~"print(1);")),
            ok = script_worker:stop(W)
    end.

%% Each request gets its own scratch directory and its own instance, so one
%% script can neither read what another wrote nor leave state behind.
scripts_cannot_see_each_other(Config) ->
    case script(Config) of
        {skip, _} = S -> S;
        W ->
            {ok, _} = script_worker:eval(
                        W, ~"globalThis.marker = 'leaked'; print('one');"),
            ?assertEqual({ok, ~"undefined\n"},
                         script_worker:eval(W, ~"print(typeof globalThis.marker);")),
            ok = script_worker:stop(W)
    end.
