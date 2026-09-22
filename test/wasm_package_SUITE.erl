%% @doc What the hex package carries.
%%
%% `src/wasm.app.src' names the files rebar3_hex publishes, and that list
%% replaces the plugin's default rather than adding to it. 0.4.1 and 0.4.2
%% shipped without `priv/', so `wasm_python_command' and
%% `wasm_javascript_command' crashed at start for anyone who installed from
%% hex.pm and worked for anyone who cloned. This suite expands the list the
%% way the plugin does and checks every file the runtime reads through
%% `code:priv_dir/1' is in it.
-module(wasm_package_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [the_boot_scripts_are_in_the_published_files].

%% Every path under `priv/' that `src/' opens at run time:
%% `wasm_python_command:boot/0' and `wasm_javascript_command:boot/0'.
%% `wasi_file_nif' looks for its `.so' there too, but the consumer builds
%% that from the shipped `c_src/', so it must not be in the package.
runtime_priv_files() ->
    ["priv/script_v1/boot.py", "priv/script_v1/boot.js"].

the_boot_scripts_are_in_the_published_files(_Config) ->
    Root = root(),
    {ok, [{application, wasm, App}]} =
        file:consult(filename:join([Root, "src", "wasm.app.src"])),
    Files = proplists:get_value(files, App),
    Published = lists:usort(lists:flatmap(fun(P) -> expand(P, Root) end,
                                          Files)),
    [?assert(filelib:is_regular(filename:join(Root, F)), F)
     || F <- runtime_priv_files()],
    ?assertEqual([], runtime_priv_files() -- Published),
    %% The NIF is built by `scripts/build-nif.sh' on the consumer's side
    %% and must stay out, whatever this checkout has built.
    ?assertEqual([], [F || F <- Published,
                           lists:prefix("priv/", F),
                           filename:extension(F) =/= ".py",
                           filename:extension(F) =/= ".js"]).

%% How `rebar3_hex_file:expand_paths/2' reads an entry: a directory means
%% everything under it, anything else is a wildcard.
expand(Entry, Root) ->
    case filelib:is_dir(filename:join(Root, Entry)) of
        true  -> filelib:wildcard(filename:join(Entry, "**"), Root);
        false -> filelib:wildcard(Entry, Root)
    end.

root() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", ".."]).
